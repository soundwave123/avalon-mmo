# T-020: Full server-authoritative validation pipeline for ability use.
# T-021: Wired to real damage formula; AbilityResult carries outcome string.
# T-022: Cast-time path — returns cast_started outcome; no resource drain until completion.
#
# Pure — all inputs are parameters; no OS time, no global state.
# `now` (server tick) is passed by the caller (main.gd); never read from OS here.
# `rng` is server-owned and seeded at startup; threads into compute_damage.
#
# Validation order: state/cooldown → range → resource → LoS → commit/cast → execute.
# T-402 item-3 polish: range precedes resource so an out-of-range + resource-starved press
# surfaces the actionable out_of_range reason instead of the T-027-silent insufficient_resource.

extends RefCounted

const _SC = preload("res://scripts/server_config.gd")
const _CS = preload("res://scripts/combat/combat_state.gd")
const _ASM = preload("res://scripts/combat/action_state_machine.gd")
const _DF = preload("res://scripts/combat/damage_formula.gd")
const _ES = preload("res://scripts/combat/entity_snapshot.gd")
const _RM = preload("res://scripts/combat/resource_model.gd")
const _AEF = preload("res://scripts/combat/ability_effects.gd")  # T-063: effect resolvers
const _TEF = preload("res://scripts/combat/talent_effects.gd")  # T-064: talent modifiers
const _CTRL = preload("res://scripts/combat/control_rules.gd")  # T-434: pure PvP CC DR


class AbilityResult:
	var accepted: bool = false
	var rejection_reason: String = ""
	# T-402 item 3: server-computed rejection context relayed to the caster's HUD (out_of_range
	# carries dist_m/range_m). Informational, server-computed — grants nothing, trusts nothing.
	var detail: Dictionary = {}
	var damage_amount: int = 0
	var mitigated_amount: int = 0  # T-429: server-computed prevented damage for the defender recap
	var interrupt_landed: bool = false  # pushback or full interrupt actually changed the cast
	var outcome: String = "hit"
	var new_caster_state: CombatState = null
	var new_caster_resources: CombatResources = null
	var new_target_state: CombatState = null
	var new_target_resources: CombatResources = null

	static func reject(
		reason: String, state: CombatState, res: CombatResources, detail_ctx: Dictionary = {}
	) -> AbilityResult:
		var r := AbilityResult.new()
		r.accepted = false
		r.rejection_reason = reason
		r.detail = detail_ctx
		r.new_caster_state = state
		r.new_caster_resources = res
		return r

	static func accept(
		state: CombatState,
		res: CombatResources,
		damage: int,
		outcome: String,
		target_state: CombatState = null,
		target_res: CombatResources = null,
		mitigated: int = 0,
		interrupted: bool = false
	) -> AbilityResult:
		var r := AbilityResult.new()
		r.accepted = true
		r.new_caster_state = state
		r.new_caster_resources = res
		r.damage_amount = damage
		r.mitigated_amount = maxi(0, mitigated)
		r.interrupt_landed = interrupted
		r.outcome = outcome
		r.new_target_state = target_state
		r.new_target_resources = target_res
		return r


static func execute_ability(
	caster,
	target,
	ability: AbilityData,
	now: int,
	rng: RandomNumberGenerator,
	threat_table = null,  # T-024: ThreatTable instance; null = no tracking (tests)
	ability_registry = null,
	pvp_eligible := Callable(),  # T-381: player→player consent predicate (invalid = pure-unit skip)
) -> AbilityResult:
	# 1. State/cooldown — action_state_machine.tick() handles GCD and state guards.
	# T-026: Skip DEAD targets — EXCEPT resurrect, which requires a dead ally and rejects a living one.
	var target_gate := _target_state_gate(caster, target, ability)
	if target_gate != null:
		return target_gate

	# T-063: class gate — an ability tagged for a class can only be used by that class (mobs use "").
	if ability.char_class != "" and caster.char_class != ability.char_class:
		return AbilityResult.reject("wrong_class", caster.combat_state, caster.resources)

	# T-063: friendly-only abilities (heals/buffs) can't target an enemy (a mob).
	if ability.targets_friendly and target.is_mob:
		return AbilityResult.reject("invalid_target", caster.combat_state, caster.resources)

	# T-381: PvP consent — a hostile ability on ANOTHER player needs an active consensual duel.
	var pvp_gate := _pvp_gate(caster, target, ability, pvp_eligible)
	if pvp_gate != null:
		return pvp_gate

	# T-365: trained-ability ownership gate — a trainer-unlocked ability the caster has not purchased
	# is not castable, even if a forged intent names its id. Ownership is read from the session
	# snapshot (server-authoritative), never asserted by the client.
	if ability.trained and not (ability.id in caster.unlocked):
		return AbilityResult.reject("not_trained", caster.combat_state, caster.resources)

	# T-365: resolve the rank the caster's AUTHORITATIVE level grants, then run every downstream
	# number (costs, damage/heal, cast-start threat) off the scaled copy. The client can't name a rank.
	ability = ability.effective_at_level(caster.level)
	# T-434: ability cooldowns and spell-school lockouts are server clocks stored on CombatState.
	# They gate before resources/range and never read a client-provided remaining duration.
	var timed_gate := _timed_ability_gate(caster, ability, now)
	if timed_gate != null:
		return timed_gate

	var intent := _CS.CombatIntent.new()
	intent.type = _CS.IntentType.USE_ABILITY
	intent.ability_id = ability.id
	intent.target_id = target.peer_id
	intent.triggers_gcd = ability.triggers_gcd
	intent.cast_ticks = ability.cast_ticks
	var sm_result = _ASM.new().tick(caster.combat_state, intent, now)
	if not sm_result.accepted:
		# T-721: an on_gcd refusal carries WHEN the GCD frees (server ticks) so the client's press
		# queue can retry exactly then instead of eating the press silently (T-719's 5-of-22 gap).
		# Informational and server-computed — grants nothing, trusts nothing from the wire.
		var sm_detail: Dictionary = {}
		if sm_result.rejection_reason == "on_gcd":
			sm_detail = {"gcd_ready_in_ticks": maxi(0, caster.combat_state.gcd_until - now)}
		return AbilityResult.reject(
			sm_result.rejection_reason, caster.combat_state, caster.resources, sm_detail
		)

	# 2. Range — 2D distance; M1 world is flat (Vector3 / height deferred to T-023/M2).
	# T-402 item 3: attach dist/reach so the caster's HUD can say HOW far (kiting-gunsel read).
	# T-402 item-3 polish (hud-judge): range is checked BEFORE resource so a resource-starved
	# player mashing OUT OF RANGE gets the actionable "out of range" feedback rather than the
	# T-027-silent insufficient_resource. Both are pure reads with no side effects — the order
	# only decides which reason wins when both fail; range feedback is the one worth surfacing.
	var dist: float = caster.position.distance_to(target.position)
	if dist > ability.range_units:
		return AbilityResult.reject(
			"out_of_range",
			caster.combat_state,
			caster.resources,
			{"dist_m": snappedf(dist, 0.1), "range_m": ability.range_units}
		)

	# 3. Resource — stamina + mana must cover costs; mana deducted on cast-completion, not
	# cast-start. T-064: costs are talent-modified (ability_cost_pct).
	var insufficient: bool = (
		(
			caster.resources.stamina
			< _TEF.effective_cost(ability.stamina_cost, caster.ability_mods, ability.id)
		)
		or (
			caster.resources.mana
			< _TEF.effective_cost(ability.mana_cost, caster.ability_mods, ability.id)
		)
		or (
			caster.resources.class_resource()
			< _TEF.effective_cost(ability.resource_cost, caster.ability_mods, ability.id)
		)
	)
	if insufficient:
		return AbilityResult.reject("insufficient_resource", caster.combat_state, caster.resources)

	# 4. LoS — M1 stub: flat test zone, no obstacles. T-023/M2 replaces with raycast.
	if not _check_los(caster.position, target.position):
		return AbilityResult.reject("los_blocked", caster.combat_state, caster.resources)

	# 5a. Cast-time: enter CASTING state. Fill metadata; mana deducted on completion by main.gd.
	if ability.cast_ticks > 0:
		# T-024: Generate threat on cast start (tank threat generation).
		if threat_table != null:
			var threat: int = int(ability.base_damage * ability.threat_multiplier)
			threat_table.add_threat(target.peer_id, caster.peer_id, threat)
		var cast_state: CombatState = _stamp_ability_cooldown(sm_result.new_state, ability, now)
		cast_state.cast_start = now
		cast_state.cast_end = now + ability.cast_ticks
		cast_state.position_snapshot = caster.position
		cast_state.cast_ability_id = ability.id
		cast_state.cast_target_id = target.peer_id
		return AbilityResult.accept(cast_state, caster.resources, 0, "cast_started")

	# 5b. Instant: commit costs + resolve the effect via the shared path (T-068).
	var committed_state := _stamp_ability_cooldown(sm_result.new_state, ability, now)
	return _commit_and_resolve(
		caster, target, ability, now, rng, committed_state, threat_table, ability_registry
	)


# T-068: cast-completion entry point — identical semantics to instant execution.
# Re-validates everything that can change during a cast (target death, resources, range,
# LoS), then routes through the same effect dispatch. The caster leaves CASTING into
# GLOBAL_COOLDOWN here; main.gd commits the returned states.
static func complete_cast(
	caster,
	target,
	ability: AbilityData,
	now: int,
	rng: RandomNumberGenerator,
	threat_table = null,
	ability_registry = null,
	pvp_eligible := Callable(),  # T-381: player→player consent predicate (invalid = pure-unit skip)
) -> AbilityResult:
	var target_gate := _target_state_gate(caster, target, ability)
	if target_gate != null:
		return target_gate

	if ability.targets_friendly and target.is_mob:
		return AbilityResult.reject("invalid_target", caster.combat_state, caster.resources)

	# T-381: PvP consent gate applies to cast-completion damage too (target may still be a player).
	var pvp_gate := _pvp_gate(caster, target, ability, pvp_eligible)
	if pvp_gate != null:
		return pvp_gate

	# T-365: re-validate ownership + re-resolve rank on completion (identical semantics to instant).
	if ability.trained and not (ability.id in caster.unlocked):
		return AbilityResult.reject("not_trained", caster.combat_state, caster.resources)
	ability = ability.effective_at_level(caster.level)
	# A school lock that lands during a cast cancels that cast through the interrupt path. This gate
	# also keeps direct complete_cast calls fail-closed if handed a locked-school state.
	var school_ready := int(caster.combat_state.school_locks.get(ability.school, 0))
	if ability.school != "" and now < school_ready:
		return AbilityResult.reject("school_locked", caster.combat_state, caster.resources)

	# Range/LoS re-validation — target may have moved during the cast (live positions, T-067).
	# T-402 item 3: same dist/reach detail as the instant path (caster HUD out-of-range read).
	# T-402 item-3 polish: range precedes resource here too (mirror the instant path) so the
	# out-of-range read wins over the silent insufficient_resource when both fail.
	var cast_dist: float = caster.position.distance_to(target.position)
	if cast_dist > ability.range_units:
		return AbilityResult.reject(
			"out_of_range",
			caster.combat_state,
			caster.resources,
			{"dist_m": snappedf(cast_dist, 0.1), "range_m": ability.range_units}
		)

	# Resource re-validation — mana may have drained between cast start and completion.
	# T-064: costs are talent-modified (ability_cost_pct).
	var insufficient: bool = (
		(
			caster.resources.stamina
			< _TEF.effective_cost(ability.stamina_cost, caster.ability_mods, ability.id)
		)
		or (
			caster.resources.mana
			< _TEF.effective_cost(ability.mana_cost, caster.ability_mods, ability.id)
		)
		or (
			caster.resources.class_resource()
			< _TEF.effective_cost(ability.resource_cost, caster.ability_mods, ability.id)
		)
	)
	if insufficient:
		return AbilityResult.reject("insufficient_resource", caster.combat_state, caster.resources)

	if not _check_los(caster.position, target.position):
		return AbilityResult.reject("los_blocked", caster.combat_state, caster.resources)

	# Preserve per-ability cooldowns, school locks, and DR clocks stamped before/during this cast.
	var gcd_state: CombatState = caster.combat_state.copy()
	gcd_state.state = _CS.CombatStateEnum.GLOBAL_COOLDOWN
	gcd_state.gcd_until = now + _SC.GCD_TICKS
	gcd_state.cast_start = 0
	gcd_state.cast_end = 0
	gcd_state.cast_ability_id = -1
	gcd_state.cast_target_id = -1
	gcd_state.position_snapshot = Vector3.ZERO
	return _commit_and_resolve(
		caster, target, ability, now, rng, gcd_state, threat_table, ability_registry
	)


# T-068: shared commit path — resource costs + effect dispatch. Instant execution and cast
# completion MUST stay identical; completion drifted to a damage-only/player-only private
# path while this logic was duplicated in main.gd.
static func _commit_and_resolve(
	caster,
	target,
	ability: AbilityData,
	now: int,
	rng: RandomNumberGenerator,
	caster_state: CombatState,
	threat_table,
	ability_registry
) -> AbilityResult:
	# T-064: spend the TALENT-MODIFIED costs (must mirror the validation gates above).
	var eff_stamina: int = _TEF.effective_cost(
		ability.stamina_cost, caster.ability_mods, ability.id
	)
	var eff_resource: int = _TEF.effective_cost(
		ability.resource_cost, caster.ability_mods, ability.id
	)
	var eff_mana: int = _TEF.effective_cost(ability.mana_cost, caster.ability_mods, ability.id)
	var new_resources: CombatResources = caster.resources.apply_stamina_drain(eff_stamina)
	# T-062: spend the class resource (rage|mana) + apply any explicit gen; stamp the combat tick.
	if eff_resource > 0:
		new_resources = new_resources.spend_class_resource(eff_resource, now)
	# T-068: cast-time abilities carry mana_cost — spent at completion (records the 5s-rule tick).
	if eff_mana > 0:
		new_resources = new_resources.spend_class_resource(eff_mana, now)
	if ability.resource_gen > 0:
		new_resources = new_resources.with_class_resource(
			new_resources.class_resource() + ability.resource_gen
		)
	new_resources = new_resources.mark_combat(now)

	# T-063: dispatch on the effect verb (damage = M1 default; heal/threat/taunt/control are new).
	match ability.effect:
		"resurrect":
			return _resolve_resurrect(target, ability, now, caster_state, new_resources)
		"heal":
			return _resolve_heal(caster, target, ability, now, rng, caster_state, new_resources)
		"taunt":
			return _resolve_taunt(caster, target, caster_state, new_resources, threat_table)
		"threat":
			return _resolve_threat(
				caster, target, ability, caster_state, new_resources, threat_table
			)
		"control":
			return _resolve_control(target, ability, now, caster_state, new_resources)
		_:
			return _resolve_damage(
				caster,
				target,
				ability,
				now,
				rng,
				caster_state,
				new_resources,
				threat_table,
				ability_registry
			)


# T-063: damage (M1 default verb) — compute, build rage from it, apply, interrupt, generate threat.
static func _resolve_damage(
	caster,
	target,
	ability: AbilityData,
	now: int,
	rng: RandomNumberGenerator,
	caster_state: CombatState,
	caster_resources: CombatResources,
	threat_table,
	ability_registry
) -> AbilityResult:
	var dmg = _DF.compute_damage(caster.stats, target.stats, ability, rng)
	# T-064: talent damage modifier (ability_damage_pct) layers on the computed damage.
	var output_mult := _TEF.damage_multiplier(caster.ability_mods, ability.id)
	dmg.amount = int(round(dmg.amount * output_mult))
	dmg.mitigated_amount = int(round(dmg.mitigated_amount * output_mult))
	# T-364: a rez-sick attacker deals reduced damage until the sickness window expires.
	var sickness_mult := _sickness_mult(caster, now)
	dmg.amount = int(round(dmg.amount * sickness_mult))
	dmg.mitigated_amount = int(round(dmg.mitigated_amount * sickness_mult))
	if caster_resources.resource_kind == "rage" and dmg.amount > 0:
		caster_resources = caster_resources.with_class_resource(
			_RM.rage_on_damage_dealt(caster_resources.rage, dmg.amount)
		)
	var new_target_resources: CombatResources = target.resources.apply_damage(dmg.amount)
	var new_target_state: CombatState = target.combat_state
	var interrupt_landed := false
	var interruptible_state: bool = (
		target.combat_state.state == _CS.CombatStateEnum.CASTING
		or target.combat_state.state == _CS.CombatStateEnum.CHANNELING
	)
	if ability_registry != null and interruptible_state and not target.interrupt_immune:
		new_target_state = _ASM.apply_interrupt(target.combat_state, ability, ability_registry, now)
		interrupt_landed = (
			new_target_state.state != target.combat_state.state
			or new_target_state.cast_end != target.combat_state.cast_end
		)
	if threat_table != null and dmg.amount > 0:
		threat_table.add_threat(
			target.peer_id, caster.peer_id, int(float(dmg.amount) * ability.threat_multiplier)
		)
	return AbilityResult.accept(
		caster_state,
		caster_resources,
		dmg.amount,
		dmg.outcome,
		new_target_state,
		new_target_resources,
		dmg.mitigated_amount,
		interrupt_landed
	)


# T-063: heal — restore target hp (clamped to max), no threat/interrupt. Heal scales with the
# CASTER's Int/Spirit; carried as the amount with outcome "heal" so the client renders it green.
static func _resolve_heal(
	caster,
	target,
	ability: AbilityData,
	now: int,
	rng: RandomNumberGenerator,
	caster_state: CombatState,
	caster_resources: CombatResources
) -> AbilityResult:
	var heal: int = _AEF.compute_heal(caster.stats, ability, rng)
	# T-064: healing talents use the same damage_pct verb (the amount modifier).
	heal = int(round(heal * _TEF.damage_multiplier(caster.ability_mods, ability.id)))
	# T-364: a rez-sick healer heals for less until the sickness window expires (min 1).
	heal = maxi(1, int(round(heal * _sickness_mult(caster, now))))
	var new_target_resources: CombatResources = target.resources.apply_heal(heal)
	return AbilityResult.accept(
		caster_state, caster_resources, heal, "heal", target.combat_state, new_target_resources
	)


# T-063: taunt — force the caster to the top of the target's threat (Warrior tanking).
static func _resolve_taunt(
	caster, target, caster_state: CombatState, caster_resources: CombatResources, threat_table
) -> AbilityResult:
	if threat_table != null:
		threat_table.taunt(target.peer_id, caster.peer_id)
	return AbilityResult.accept(
		caster_state, caster_resources, 0, "taunt", target.combat_state, target.resources
	)


# T-063: threat — add a flat amount of threat without dealing damage (threat builder).
static func _resolve_threat(
	caster,
	target,
	ability: AbilityData,
	caster_state: CombatState,
	caster_resources: CombatResources,
	threat_table
) -> AbilityResult:
	if threat_table != null:
		threat_table.add_threat(target.peer_id, caster.peer_id, ability.threat_amount)
	return AbilityResult.accept(
		caster_state, caster_resources, 0, "threat", target.combat_state, target.resources
	)


# T-063: control — apply a root or stun timer to the target's combat_state (enforced in the tick
# loop / movement). Minimal: a duration; interrupt/movement gating is wired where those checks live.
static func _resolve_control(
	target,
	ability: AbilityData,
	now: int,
	caster_state: CombatState,
	caster_resources: CombatResources
) -> AbilityResult:
	if target.control_immune:
		return AbilityResult.accept(
			caster_state,
			caster_resources,
			0,
			"control_immune",
			target.combat_state.copy(),
			target.resources
		)
	var control = _CTRL.resolve(
		target.combat_state,
		ability.control_dr_category,
		ability.control_ticks,
		now,
		not target.is_mob
	)
	var new_target_state: CombatState = control.new_state
	if ability.control_kind == "stun":
		new_target_state.stunned_until = now + control.duration_ticks
	else:
		new_target_state.rooted_until = now + control.duration_ticks
	return AbilityResult.accept(
		caster_state,
		caster_resources,
		0,
		"control_immune" if control.resisted else "control",
		new_target_state,
		target.resources
	)


# T-434: pure state/cooldown gate. Ability id + school originate in the registry, and the clocks
# originate in CombatState; the wire supplies neither cooldown remaining nor lock status.
static func _timed_ability_gate(caster, ability: AbilityData, now: int) -> AbilityResult:
	var ready_at := int(caster.combat_state.ability_cooldowns.get(ability.id, 0))
	if now < ready_at:
		return AbilityResult.reject("ability_on_cooldown", caster.combat_state, caster.resources)
	if ability.school != "":
		var school_ready := int(caster.combat_state.school_locks.get(ability.school, 0))
		if now < school_ready:
			return AbilityResult.reject("school_locked", caster.combat_state, caster.resources)
	return null


static func _stamp_ability_cooldown(
	state: CombatState, ability: AbilityData, now: int
) -> CombatState:
	var out := state.copy()
	if ability.cooldown_ticks > 0:
		out.ability_cooldowns[ability.id] = now + ability.cooldown_ticks
	return out


# T-381: the PvP-consent gate. A hostile ability (not `targets_friendly`) against a DIFFERENT player
# is rejected unless the injected `pvp_eligible(attacker_id, target_id)` predicate confirms an
# active consensual duel between the pair. Fail discipline: an INVALID predicate (pure combat unit
# tests that don't wire one) skips the gate; the world ALWAYS injects a predicate that defaults
# FALSE, so open-world / non-consensual player→player damage is off. Mobs/self are never gated.
static func _pvp_gate(caster, target, ability: AbilityData, pvp_eligible) -> AbilityResult:
	if not pvp_eligible.is_valid():
		return null
	if target.is_mob or ability.targets_friendly or caster.peer_id == target.peer_id:
		return null
	if bool(pvp_eligible.call(caster.peer_id, target.peer_id)):
		return null
	return AbilityResult.reject("pvp_not_allowed", caster.combat_state, caster.resources)


# T-364: the DEAD-target gate. Resurrect INVERTS the normal rule — it needs a dead ally and rejects
# a living target; everything else rejects a dead one. Returns an AbilityResult reject, or null to
# proceed. (targets_friendly already rejects a mob target separately for heal/rez.)
static func _target_state_gate(caster, target, ability: AbilityData) -> AbilityResult:
	var is_dead: bool = target.combat_state.state == _CS.CombatStateEnum.DEAD
	if ability.effect == "resurrect":
		if not is_dead:
			return AbilityResult.reject("target_not_dead", caster.combat_state, caster.resources)
		return null
	if is_dead:
		return AbilityResult.reject("target_is_dead", caster.combat_state, caster.resources)
	return null


# T-364: resurrect — restore a DEAD ally to IDLE at a fraction of max HP/mana with a revive-sickness
# window. The caller (main.gd) repositions the ally to the caster on the "resurrect" outcome.
static func _resolve_resurrect(
	target,
	ability: AbilityData,
	now: int,
	caster_state: CombatState,
	caster_resources: CombatResources
) -> AbilityResult:
	var revived_state: CombatState = target.combat_state.copy()
	revived_state.state = _CS.CombatStateEnum.IDLE
	revived_state.respawn_at = 0
	revived_state.revive_sickness_until = now + ability.revive_sickness_ticks
	var revived_res: CombatResources = target.resources.revive(
		ability.revive_hp_pct, ability.revive_mana_pct
	)
	return AbilityResult.accept(
		caster_state, caster_resources, revived_res.hp, "resurrect", revived_state, revived_res
	)


# T-364: revive-sickness output multiplier — a caster still in the sickness window deals/heals a
# reduced fraction (ServerConfig.REVIVE_SICKNESS_MULT). 1.0 when not sick.
static func _sickness_mult(caster, now: int) -> float:
	if now < caster.combat_state.revive_sickness_until:
		return _SC.REVIVE_SICKNESS_MULT
	return 1.0


static func _check_los(_from: Vector3, _to: Vector3) -> bool:
	return true  # M1 stub — T-023/M2 replaces with PhysicsDirectSpaceState3D raycast
