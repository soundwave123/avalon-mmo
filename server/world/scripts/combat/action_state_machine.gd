# T-017: Action state machine — pure functions, no OS time, no global state.
# T-022: Added CastTickResult + process_cast_tick() for cast-time ability processing.
#
# tick(state, intent, now)         — validates intent + returns new CombatState.
# advance_timers(state, now)       — timer-driven transitions (GCD expiry).
# process_cast_tick(state, pos, now) — per-tick cast progress check (pure).
#
# HARD CONSTRAINTS:
#   - All functions return a NEW CombatState (input never mutated).
#   - No OS.get_ticks_msec() or any OS time call here.
#   - Determinism: same inputs always produce identical output.

extends RefCounted


class CastTickResult:
	var status: String = "ongoing"  # "ongoing" | "complete" | "cancelled"
	var cancel_reason: String = ""

	static func ongoing() -> CastTickResult:
		var r = CastTickResult.new()
		r.status = "ongoing"
		return r

	static func complete() -> CastTickResult:
		var r = CastTickResult.new()
		r.status = "complete"
		return r

	static func cancelled(reason: String) -> CastTickResult:
		var r = CastTickResult.new()
		r.status = "cancelled"
		r.cancel_reason = reason
		return r


# Preload combat_state to register its class_name and nested classes.
const _CS = preload("res://scripts/combat/combat_state.gd")
const _CR = preload("res://scripts/combat/combat_resources.gd")
# Preload server_config for GCD_TICKS — single source of truth (T-018).
const _SC = preload("res://scripts/server_config.gd")

# ---- Pure tick function ----


func tick(state, intent, now: int):
	"""Returns CombatState.CombatResult — new state + accept/reject decision."""
	# T-063: a stunned entity cannot act (CC). Reject any ability intent while stunned, in any state.
	if intent.type == _CS.IntentType.USE_ABILITY and now < state.stunned_until:
		return _reject(state, "stunned")
	var result
	match state.state:
		_CS.CombatStateEnum.DEAD:
			result = _reject(state, "entity is dead")
		_CS.CombatStateEnum.CHANNELING:
			result = _handle_channeling(state, intent)
		_CS.CombatStateEnum.EXECUTING:
			result = _reject(state, "entity is executing")
		_CS.CombatStateEnum.CASTING:
			result = _handle_casting(state, intent)
		_CS.CombatStateEnum.GLOBAL_COOLDOWN:
			result = _handle_gcd(state, intent, now)
		_CS.CombatStateEnum.IDLE:
			result = _handle_idle(state, intent, now)
		_:
			result = _reject(state, "unknown state")
	return result


func _handle_channeling(state, intent):
	if intent.type == _CS.IntentType.CANCEL_CAST:
		return _accept(_transition_to(state, _CS.CombatStateEnum.IDLE))
	return _reject(state, "entity is channeling")


func _handle_casting(state, intent):
	if intent.type == _CS.IntentType.CANCEL_CAST:
		return _accept(_transition_to(state, _CS.CombatStateEnum.IDLE))
	return _reject(state, "already_casting")


func _handle_gcd(state, intent, now: int):
	if intent.type == _CS.IntentType.USE_ABILITY:
		# Off-GCD abilities bypass the GCD check entirely.
		if intent.triggers_gcd == false:
			return _accept(_copy_and_set(state, _CS.CombatStateEnum.GLOBAL_COOLDOWN))
		if now < state.gcd_until:
			return _reject(state, "on_gcd")
		# Cast-time: enter CASTING; execute_ability fills cast metadata after this returns.
		if intent.cast_ticks > 0:
			return _accept(_copy_and_set(state, _CS.CombatStateEnum.CASTING))
		var new_state = _copy_and_set(state, _CS.CombatStateEnum.GLOBAL_COOLDOWN)
		new_state.gcd_until = now + _SC.GCD_TICKS
		return _accept(new_state)
	return _reject(state, "global cooldown active")


func _handle_idle(state, intent, now: int):
	if intent.type == _CS.IntentType.USE_ABILITY:
		# Off-GCD abilities do not enter GLOBAL_COOLDOWN.
		if intent.triggers_gcd == false:
			return _accept(_copy_state(state))
		# Cast-time: enter CASTING; execute_ability fills cast metadata after this returns.
		if intent.cast_ticks > 0:
			return _accept(_copy_and_set(state, _CS.CombatStateEnum.CASTING))
		var new_state = _copy_and_set(state, _CS.CombatStateEnum.GLOBAL_COOLDOWN)
		new_state.gcd_until = now + _SC.GCD_TICKS
		return _accept(new_state)
	return _reject(state, "no valid intent for idle state")


# ---- Pure advance_timers function ----


func advance_timers(state, now: int):
	"""
	Called by the world server loop on each tick. Handles timer-driven transitions.
	Returns a NEW CombatState — input is never mutated.
	"""
	var new_state = _copy_state(state)

	match state.state:
		_CS.CombatStateEnum.GLOBAL_COOLDOWN:
			if now >= state.gcd_until:
				new_state.state = _CS.CombatStateEnum.IDLE
		_CS.CombatStateEnum.DEAD:
			if state.respawn_at > 0 and now >= state.respawn_at:
				new_state.state = _CS.CombatStateEnum.IDLE
				new_state.respawn_at = 0
		# CASTING completion is handled by process_cast_tick() called from main.gd.
		# CHANNELING, EXECUTING, IDLE — no timer transitions in M1.

	return new_state


func process_cast_tick(state, current_pos: Vector3, now: int) -> CastTickResult:
	"""
	Called once per server tick for each entity in CASTING state. Pure — no mutation.
	main.gd owns state changes based on the returned status.
	"""
	if current_pos.distance_to(state.position_snapshot) > _SC.POSITION_EPSILON:
		return CastTickResult.cancelled("moved")
	if now >= state.cast_end:
		return CastTickResult.complete()
	return CastTickResult.ongoing()


static func apply_interrupt(
	state: CombatState, hitting_ability: AbilityData, registry, now: int
) -> CombatState:
	"""
	Apply hit-based cast disruption. Pure — no mutation and no global registry lookup.
	`now` is injected for the stable public contract; M1 pushback does not need it yet.
	"""
	var is_casting := state.state == _CS.CombatStateEnum.CASTING
	var is_channeling := state.state == _CS.CombatStateEnum.CHANNELING
	if not is_casting and not is_channeling:
		return _copy_state_static(state)

	if hitting_ability.can_full_interrupt:
		var cast_ability: AbilityData = registry.get_ability(state.cast_ability_id)
		var interrupted_state: CombatState = _clear_cast_fields(_copy_state_static(state))
		interrupted_state.state = _CS.CombatStateEnum.IDLE
		interrupted_state.last_full_interrupt_at = now
		if (
			cast_ability != null
			and cast_ability.school != ""
			and hitting_ability.school_lock_ticks > 0
		):
			interrupted_state.school_locks[cast_ability.school] = (
				now + hitting_ability.school_lock_ticks
			)
		return interrupted_state
	# Ordinary damage pushes back casts but never stretches a channel.
	if is_channeling:
		return _copy_state_static(state)

	var cast_ability: AbilityData = registry.get_ability(state.cast_ability_id)
	if cast_ability == null:
		return _copy_state_static(state)
	var max_cast_end: int = state.cast_start + cast_ability.cast_ticks + _SC.MAX_PUSHBACK_TICKS
	var new_cast_end: int = min(state.cast_end + _SC.PUSHBACK_TICKS, max_cast_end)
	var pushed_state = _copy_state_static(state)
	pushed_state.cast_end = new_cast_end
	return pushed_state


# ---- Internal helpers (pure, no side effects) ----


# T-051: both delegate to the single CombatState.copy() (no more drifting hand-copies).
static func _copy_state_static(src):
	return src.copy()


static func _clear_cast_fields(dst):
	dst.cast_start = 0
	dst.cast_end = 0
	dst.cast_target_id = -1
	dst.cast_ability_id = -1
	dst.position_snapshot = Vector3.ZERO
	return dst


func _copy_state(src):
	return src.copy()


func _copy_and_set(src, new_enum):
	"""Copy state and set a new enum value."""
	var dst = _copy_state(src)
	dst.state = new_enum
	return dst


func _transition_to(src, target_enum):
	"""Transition to a new state, clearing all transient cast fields on IDLE entry."""
	var dst = _copy_state(src)
	dst.state = target_enum
	if target_enum == _CS.CombatStateEnum.IDLE:
		dst.cast_start = 0
		dst.cast_end = 0
		dst.cast_target_id = -1
		dst.cast_ability_id = -1
		dst.position_snapshot = Vector3.ZERO
	return dst


func _accept(new_state):
	var result = _CS.CombatResult.new()
	result.new_state = new_state
	result.accepted = true
	result.rejection_reason = ""
	# events already defaults to [] in CombatResult class
	return result


func _reject(original_state, reason: String):
	var result = _CS.CombatResult.new()
	result.new_state = _copy_state(original_state)
	result.accepted = false
	result.rejection_reason = reason
	# events already defaults to [] in CombatResult class
	return result


func check_death_transition(state, resources, now: int, respawn_ticks: int) -> CombatState:
	"""
	T-026: Pure death transition check.
	Precondition: resources.hp <= 0 (damage already confirmed).
	Returns a NEW CombatState in DEAD with respawn_at set.
	No-op if already DEAD or if hp > 0 (guard against misfire).
	"""
	var new_state = _copy_state(state)
	# No-op: already dead — double-death guard.
	if state.state == _CS.CombatStateEnum.DEAD:
		return new_state
	# No-op: not actually dead yet.
	if not _CR.is_dead(resources):
		return new_state
	# Transition to DEAD — clear active combat timers.
	new_state.state = _CS.CombatStateEnum.DEAD
	new_state.respawn_at = now + respawn_ticks
	new_state.gcd_until = 0
	new_state.cast_start = 0
	new_state.cast_end = 0
	new_state.cast_ability_id = -1
	new_state.cast_target_id = -1
	return new_state
