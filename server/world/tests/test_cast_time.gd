# T-022: Cast-time ability unit tests — pure function calls, no network.
# process_cast_tick() and the cast-started path in execute_ability are both tested.

extends GutTest

const _ASM = preload("res://scripts/combat/action_state_machine.gd")
const _AE = preload("res://scripts/combat/ability_executor.gd")
const _CS = preload("res://scripts/combat/combat_state.gd")
const _SC = preload("res://scripts/server_config.gd")
const _ES = preload("res://scripts/combat/entity_snapshot.gd")


func _make_casting_state(cast_start: int, cast_end: int, snapshot: Vector3) -> CombatState:
	var cs := CombatState.new()
	cs.state = _CS.CombatStateEnum.CASTING
	cs.cast_start = cast_start
	cs.cast_end = cast_end
	cs.position_snapshot = snapshot
	cs.cast_ability_id = 2
	cs.cast_target_id = 99
	return cs


func _make_emberstrike() -> AbilityData:
	var ab := AbilityData.new()
	ab.id = 2
	ab.name = "Emberstrike"
	ab.cast_ticks = 40
	ab.triggers_gcd = true
	ab.mana_cost = 25
	ab.stamina_cost = 0
	ab.range_units = 10.0
	ab.base_damage = 30
	ab.variance_min = 1.0
	ab.variance_max = 1.0
	ab.attacker_skill_coeffs = {"Magery": 0.4, "EvaluatingInt": 0.25}
	ab.mitigation_skill_coeffs = {"MagicResistance": 0.2}
	ab.miss_chance = 0.0
	ab.dodge_chance = 0.0
	ab.parry_chance = 0.0
	ab.crit_chance = 0.0
	ab.crit_multiplier = 2.0
	return ab


func _make_strike() -> AbilityData:
	var ab := AbilityData.new()
	ab.id = 1
	ab.name = "Strike"
	ab.cast_ticks = 0
	ab.triggers_gcd = true
	ab.mana_cost = 0
	ab.stamina_cost = 5
	ab.range_units = 2.5
	ab.base_damage = 10
	ab.variance_min = 1.0
	ab.variance_max = 1.0
	return ab


func _make_caster(pos: Vector3, mana: int) -> Object:
	var snap = _ES.new()
	snap.peer_id = 1
	snap.position = pos
	snap.combat_state = CombatState.new()
	snap.combat_state.state = _CS.CombatStateEnum.IDLE
	var cr := CombatResources.new()
	cr.hp = 100
	cr.max_hp = 100
	cr.mana = mana
	cr.max_mana = 100
	cr.stamina = 100
	cr.max_stamina = 100
	snap.resources = cr
	snap.stats = CharacterStats.new()
	return snap


func _make_target(pos: Vector3) -> Object:
	var snap = _ES.new()
	snap.peer_id = 2
	snap.position = pos
	snap.combat_state = CombatState.new()
	snap.combat_state.state = _CS.CombatStateEnum.IDLE
	var cr := CombatResources.new()
	cr.hp = 100
	cr.max_hp = 100
	cr.mana = 50
	cr.max_mana = 50
	cr.stamina = 100
	cr.max_stamina = 100
	snap.resources = cr
	snap.stats = CharacterStats.new()
	return snap


func _make_rng() -> RandomNumberGenerator:
	var rng := RandomNumberGenerator.new()
	rng.seed = 42
	return rng


# --- Tests ---


func test_01_process_cast_tick_before_cast_end_is_ongoing():
	var state := _make_casting_state(100, 140, Vector3(5.0, 5.0, 0.0))
	var asm := _ASM.new()
	var result = asm.process_cast_tick(state, Vector3(5.0, 5.0, 0.0), 139)
	assert_eq(result.status, "ongoing", "tick at now=139 (cast_end=140) must be ongoing")


func test_02_process_cast_tick_at_cast_end_is_complete():
	var state := _make_casting_state(100, 140, Vector3(5.0, 5.0, 0.0))
	var asm := _ASM.new()
	var result = asm.process_cast_tick(state, Vector3(5.0, 5.0, 0.0), 140)
	assert_eq(result.status, "complete", "tick at now=140 (cast_end=140) must complete")


func test_03_process_cast_tick_position_moved_cancels_cast():
	var snapshot := Vector3(5.0, 5.0, 0.0)
	var state := _make_casting_state(100, 140, snapshot)
	var asm := _ASM.new()
	# Move 1 unit — well beyond POSITION_EPSILON
	var result = asm.process_cast_tick(state, Vector3(6.0, 5.0, 0.0), 120)
	assert_eq(result.status, "cancelled", "movement > POSITION_EPSILON must cancel cast")
	assert_eq(result.cancel_reason, "moved")


func test_04_use_ability_during_casting_is_rejected():
	var state := _make_casting_state(100, 140, Vector3.ZERO)
	var intent := _CS.CombatIntent.new()
	intent.type = _CS.IntentType.USE_ABILITY
	intent.ability_id = 1
	intent.triggers_gcd = true
	var asm := _ASM.new()
	var result = asm.tick(state, intent, 110)
	assert_false(result.accepted, "USE_ABILITY during CASTING must be rejected")
	assert_eq(
		result.rejection_reason, "already_casting", "reason must be already_casting (underscore)"
	)


func test_05_cancel_cast_during_casting_is_accepted():
	var state := _make_casting_state(100, 140, Vector3.ZERO)
	var intent := _CS.CombatIntent.new()
	intent.type = _CS.IntentType.CANCEL_CAST
	var asm := _ASM.new()
	var result = asm.tick(state, intent, 110)
	assert_true(result.accepted, "CANCEL_CAST during CASTING must be accepted")
	assert_eq(
		result.new_state.state, _CS.CombatStateEnum.IDLE, "state must return to IDLE on cancel"
	)


func test_06_execute_cast_time_ability_enters_casting_no_mana_drain():
	var caster = _make_caster(Vector3(0, 0, 0.0), 100)
	var target = _make_target(Vector3(1, 0, 0.0))
	var result = _AE.execute_ability(caster, target, _make_emberstrike(), 0, _make_rng())
	assert_true(result.accepted, "Emberstrike with full mana in range should be accepted")
	assert_eq(result.outcome, "cast_started", "cast-time ability must return cast_started outcome")
	assert_eq(
		result.new_caster_state.state,
		_CS.CombatStateEnum.CASTING,
		"caster must enter CASTING state"
	)
	assert_eq(result.new_caster_resources.mana, 100, "mana must NOT be deducted at cast-start")
	assert_eq(result.damage_amount, 0, "no damage on cast-start")


func test_07_instant_ability_not_movement_cancelled():
	# Instant abilities never enter CASTING — no position_snapshot check.
	# Move the caster far from origin to prove it makes no difference.
	var caster = _make_caster(Vector3(99, 99, 0.0), 100)
	caster.combat_state.position_snapshot = Vector3(0, 0, 0.0)  # snapshot far from current
	var target = _make_target(Vector3(100, 99, 0.0))  # 1 unit from caster, in range for Strike
	var result = _AE.execute_ability(caster, target, _make_strike(), 0, _make_rng())
	assert_true(result.accepted, "instant ability must not be cancelled by position change")
	assert_ne(result.outcome, "cast_started", "instant ability must not enter CASTING")


# --- T-068: complete_cast — completion routes through the executor effect dispatch ---


func _make_mob_target(pos: Vector3) -> Object:
	var snap = _make_target(pos)
	snap.peer_id = 1001
	snap.is_mob = true
	snap.char_class = ""
	return snap


func _make_flash_mend() -> AbilityData:
	# Synthetic cast-time heal — proves the heal verb heals (not damages) at completion.
	var ab := AbilityData.new()
	ab.id = 999
	ab.name = "Flash Mend"
	ab.effect = "heal"
	ab.targets_friendly = true
	ab.cast_ticks = 30
	ab.mana_cost = 10
	ab.range_units = 30.0
	ab.heal_base = 20
	ab.variance_min = 1.0
	ab.variance_max = 1.0
	return ab


func test_20_complete_cast_damages_mob_target():
	var caster = _make_caster(Vector3.ZERO, 50)
	caster.combat_state = _make_casting_state(100, 140, Vector3.ZERO)
	var target = _make_mob_target(Vector3(5.0, 5.0, 0.0))
	var result = _AE.complete_cast(caster, target, _make_emberstrike(), 140, _make_rng())
	assert_true(result.accepted, "mob-target completion must be accepted (was: target_lost)")
	assert_gt(result.damage_amount, 0, "completion must deal damage to the mob")
	assert_lt(result.new_target_resources.hp, 100, "mob hp must drop")


func test_21_complete_cast_enters_gcd():
	var caster = _make_caster(Vector3.ZERO, 50)
	caster.combat_state = _make_casting_state(100, 140, Vector3.ZERO)
	var target = _make_mob_target(Vector3(5.0, 5.0, 0.0))
	var result = _AE.complete_cast(caster, target, _make_emberstrike(), 140, _make_rng())
	assert_eq(
		result.new_caster_state.state,
		_CS.CombatStateEnum.GLOBAL_COOLDOWN,
		"caster must leave CASTING into GCD"
	)
	assert_eq(result.new_caster_state.gcd_until, 140 + _SC.GCD_TICKS)


func test_22_complete_cast_deducts_mana_at_completion():
	var caster = _make_caster(Vector3.ZERO, 50)
	caster.resources.resource_kind = "mana"
	caster.combat_state = _make_casting_state(100, 140, Vector3.ZERO)
	var target = _make_mob_target(Vector3(5.0, 5.0, 0.0))
	var result = _AE.complete_cast(caster, target, _make_emberstrike(), 140, _make_rng())
	assert_true(result.accepted)
	assert_eq(result.new_caster_resources.mana, 25, "mana_cost (25) spent at completion")
	assert_eq(result.new_caster_resources.last_spend_tick, 140, "5s-rule tick recorded")


func test_23_complete_cast_heal_verb_heals_not_damages():
	var caster = _make_caster(Vector3.ZERO, 50)
	caster.combat_state = _make_casting_state(100, 130, Vector3.ZERO)
	var target = _make_target(Vector3(5.0, 5.0, 0.0))
	target.resources.hp = 50
	var result = _AE.complete_cast(caster, target, _make_flash_mend(), 130, _make_rng())
	assert_true(result.accepted, "friendly cast-time heal must be accepted")
	assert_eq(result.outcome, "heal", "heal verb must resolve as heal")
	assert_gt(result.new_target_resources.hp, 50, "target hp must INCREASE (was: damaged)")


func test_24_complete_cast_out_of_range_rejects():
	var caster = _make_caster(Vector3.ZERO, 50)
	caster.combat_state = _make_casting_state(100, 140, Vector3.ZERO)
	var target = _make_mob_target(Vector3(100.0, 0.0, 0.0))  # emberstrike range is 10
	var result = _AE.complete_cast(caster, target, _make_emberstrike(), 140, _make_rng())
	assert_false(result.accepted, "target out of range at completion must reject")
	assert_eq(result.rejection_reason, "out_of_range")
	# T-402 item 3: completion-path reject carries the same dist/reach detail as the instant path.
	assert_eq(float(result.detail.get("dist_m", -1.0)), 100.0, "detail carries actual distance")
	assert_eq(float(result.detail.get("range_m", -1.0)), 10.0, "detail carries ability reach")


func test_24b_complete_cast_out_of_range_wins_over_insufficient_resource():
	# T-402 item-3 polish: mirror the instant path — at cast completion, an out-of-range +
	# resource-starved caster gets the actionable out_of_range read, not silent insufficient_resource.
	var caster = _make_caster(Vector3.ZERO, 5)  # mana 5 < emberstrike cost 25
	caster.combat_state = _make_casting_state(100, 140, Vector3.ZERO)
	var target = _make_mob_target(Vector3(100.0, 0.0, 0.0))  # 100m > emberstrike range 10
	var result = _AE.complete_cast(caster, target, _make_emberstrike(), 140, _make_rng())
	assert_false(result.accepted, "both range and resource fail at completion")
	assert_eq(result.rejection_reason, "out_of_range", "range wins over silent resource reject")
	assert_eq(float(result.detail.get("dist_m", -1.0)), 100.0, "out_of_range detail still attached")


func test_25_complete_cast_insufficient_mana_rejects():
	var caster = _make_caster(Vector3.ZERO, 5)  # emberstrike costs 25
	caster.combat_state = _make_casting_state(100, 140, Vector3.ZERO)
	var target = _make_mob_target(Vector3(5.0, 5.0, 0.0))
	var result = _AE.complete_cast(caster, target, _make_emberstrike(), 140, _make_rng())
	assert_false(result.accepted, "mana drained during cast must reject at completion")
	assert_eq(result.rejection_reason, "insufficient_resource")


func test_26_complete_cast_dead_target_rejects():
	var caster = _make_caster(Vector3.ZERO, 50)
	caster.combat_state = _make_casting_state(100, 140, Vector3.ZERO)
	var target = _make_mob_target(Vector3(5.0, 5.0, 0.0))
	target.combat_state.state = _CS.CombatStateEnum.DEAD
	var result = _AE.complete_cast(caster, target, _make_emberstrike(), 140, _make_rng())
	assert_false(result.accepted, "dead target at completion must reject")
	assert_eq(result.rejection_reason, "target_is_dead")
