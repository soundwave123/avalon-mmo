# T-019: Auto-attack swing timer (stamina-gated).
# T-025: Wired real damage formula (was stubbed at 0 since T-021 only wired ability_executor).
#
# Pure functions — no OS time, no global RNG, no side effects.
# All constants sourced from ServerConfig.
#
# process_auto_attack optional tail params (target_stats, ability, rng):
#   - Provide all three for real damage (mob and future player auto-attack).
#   - Omit (or pass null) for swing-timer-only tests — damage stays 0.
#   - rng MUST be the caller's injected RNG — never create one inside here.

extends RefCounted

const _SC = preload("res://scripts/server_config.gd")
const _CS = preload("res://scripts/combat/combat_state.gd")
const _DF = preload("res://scripts/combat/damage_formula.gd")


class AutoAttackResult:
	"""Returned by process_auto_attack(). Immutable result object."""

	var new_next_swing_tick: int = 0
	var stamina_after: int = 0
	var damage_amount: int = 0
	var mitigated_amount: int = 0  # T-429: server-truth prevention carried to the recap event
	var outcome: String = "hit"
	var is_noop: bool = true

	func _init():
		pass

	static func noop() -> AutoAttackResult:
		var r = AutoAttackResult.new()
		r.is_noop = true
		return r

	static func swing(
		next_tick: int, stamina: int, damage: int, out: String = "hit", mitigated: int = 0
	) -> AutoAttackResult:
		var r = AutoAttackResult.new()
		r.is_noop = false
		r.new_next_swing_tick = next_tick
		r.stamina_after = stamina
		r.damage_amount = damage
		r.mitigated_amount = maxi(0, mitigated)
		r.outcome = out
		return r


static func compute_swing_ticks(current_stamina: int, weapon_speed: float) -> int:
	"""Compute swing interval in ticks based on current stamina and weapon speed.

	Formula (UO T2A community-reconstructed):
	max(SWING_TICKS_MIN, floor(NOMINATOR / ((stamina + STAMINA_ADDEND) * weapon_speed)))

	Pure function — no side effects. Constants from ServerConfig.
	"""
	var raw: float = (
		float(_SC.SWING_FORMULA_NOMINATOR)
		/ ((float(current_stamina) + float(_SC.SWING_FORMULA_STAMINA_ADDEND)) * weapon_speed)
	)
	return max(_SC.SWING_TICKS_MIN, int(floor(raw)))


static func process_auto_attack(
	attacker_state: CombatState,
	attacker_res: CombatResources,
	attacker_stats: CharacterStats,
	target_id: int,
	now: int,
	target_stats = null,  # CharacterStats — null keeps damage=0 (backward-compat for tests)
	ability = null,  # AbilityData — null keeps damage=0
	rng = null  # RandomNumberGenerator — MUST be caller's injected rng, never created here
) -> AutoAttackResult:
	"""Process auto-attack for one tick. Returns new AutoAttackResult; inputs never mutated.

	Validation order: state -> resource -> target -> timer -> execute.
	Range check stubbed as always-in-range for M1.
	Provide target_stats/ability/rng for real damage (mob path); omit for tests.
	"""
	# Dead entity: cannot attack
	if attacker_state.state == _CS.CombatStateEnum.DEAD:
		return AutoAttackResult.noop()

	# No target set: nothing to attack
	if target_id == -1:
		return AutoAttackResult.noop()

	# Timer not yet reached
	if now < attacker_state.next_swing_tick:
		return AutoAttackResult.noop()

	# M1 stub: range check — always in range until M2 range system
	# var in_range = check_range(attacker_state, target_entity)  # M1 stub

	var swing_ticks = compute_swing_ticks(attacker_res.stamina, attacker_stats.weapon_speed)
	var new_next_swing: int = now + swing_ticks
	var stamina_after: int = attacker_res.stamina - _SC.STAMINA_DRAIN_PER_SWING

	var damage_amount: int = 0
	var mitigated_amount: int = 0
	var outcome: String = "hit"
	if target_stats != null and ability != null and rng != null:
		var dmg = _DF.compute_damage(attacker_stats, target_stats, ability, rng)
		damage_amount = dmg.amount
		mitigated_amount = dmg.mitigated_amount
		outcome = dmg.outcome

	return AutoAttackResult.swing(
		new_next_swing, stamina_after, damage_amount, outcome, mitigated_amount
	)
