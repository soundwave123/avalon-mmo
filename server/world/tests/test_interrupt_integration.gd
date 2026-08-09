# T-023: Hit-based interrupt integration tests for the validated ability executor path.

extends GutTest

const _AE = preload("res://scripts/combat/ability_executor.gd")
const _AR = preload("res://scripts/combat/ability_registry.gd")
const _CS = preload("res://scripts/combat/combat_state.gd")
const _ES = preload("res://scripts/combat/entity_snapshot.gd")
const _SC = preload("res://scripts/server_config.gd")


func _make_registry() -> Object:
	var registry = _AR.new()
	registry._abilities[1] = _make_strike()
	registry._abilities[2] = _make_emberstrike()
	return registry


func _make_strike() -> AbilityData:
	var strike := AbilityData.new()
	strike.id = 1
	strike.name = "Strike"
	strike.cast_ticks = 0
	strike.triggers_gcd = true
	strike.mana_cost = 0
	strike.stamina_cost = 5
	strike.range_units = 2.5
	strike.base_damage = 10
	strike.variance_min = 1.0
	strike.variance_max = 1.0
	strike.can_full_interrupt = false
	return strike


func _make_emberstrike() -> AbilityData:
	var emberstrike := AbilityData.new()
	emberstrike.id = 2
	emberstrike.name = "Emberstrike"
	emberstrike.cast_ticks = 40
	return emberstrike


func _make_entity(peer_id: int, pos: Vector3, state_enum: int) -> Object:
	var snap = _ES.new()
	snap.peer_id = peer_id
	snap.position = pos
	snap.combat_state = CombatState.new()
	snap.combat_state.state = state_enum
	var resources := CombatResources.new()
	resources.hp = 100
	resources.max_hp = 100
	resources.mana = 100
	resources.max_mana = 100
	resources.stamina = 100
	resources.max_stamina = 100
	snap.resources = resources
	snap.stats = CharacterStats.new()
	return snap


func _make_casting_target() -> Object:
	var target = _make_entity(1, Vector3(1, 0, 0.0), _CS.CombatStateEnum.CASTING)
	target.combat_state.cast_start = 100
	target.combat_state.cast_end = 140
	target.combat_state.cast_ability_id = 2
	target.combat_state.cast_target_id = 2
	target.combat_state.position_snapshot = target.position
	return target


func _make_rng() -> RandomNumberGenerator:
	var rng := RandomNumberGenerator.new()
	rng.seed = 42
	return rng


func test_01_valid_hit_damages_target_and_pushes_cast_end():
	var registry = _make_registry()
	var attacker = _make_entity(2, Vector3(0, 0, 0.0), _CS.CombatStateEnum.IDLE)
	var target = _make_casting_target()
	var result = _AE.execute_ability(
		attacker, target, registry.get_ability(1), 120, _make_rng(), null, registry
	)
	assert_true(result.accepted, "Strike must be accepted against in-range casting target")
	assert_lt(
		result.new_target_resources.hp, target.resources.hp, "validated hit must reduce target HP"
	)
	assert_eq(result.new_target_state.cast_end, 150, "validated hit must push cast_end to 150")
	assert_true(result.interrupt_landed, "server event metadata records the landed pushback")


func test_02_repeated_valid_hits_extend_cast_end_and_cap():
	var registry = _make_registry()
	var attacker = _make_entity(2, Vector3(0, 0, 0.0), _CS.CombatStateEnum.IDLE)
	var target = _make_casting_target()
	var max_cast_end: int = 100 + 40 + _SC.MAX_PUSHBACK_TICKS
	target.combat_state.cast_end = max_cast_end - (5 * _SC.PUSHBACK_TICKS)
	for i in range(6):
		attacker.combat_state = CombatState.new()
		attacker.combat_state.state = _CS.CombatStateEnum.IDLE
		var result = _AE.execute_ability(
			attacker, target, registry.get_ability(1), 120 + i, _make_rng(), null, registry
		)
		assert_true(result.accepted, "each Strike in the loop must be accepted")
		target.combat_state = result.new_target_state
	assert_eq(target.combat_state.cast_end, max_cast_end, "pushback must not exceed max_cast_end")


func test_03_hit_against_non_casting_target_damages_without_state_change():
	var registry = _make_registry()
	var attacker = _make_entity(2, Vector3(0, 0, 0.0), _CS.CombatStateEnum.IDLE)
	var target = _make_entity(1, Vector3(1, 0, 0.0), _CS.CombatStateEnum.IDLE)
	var result = _AE.execute_ability(
		attacker, target, registry.get_ability(1), 120, _make_rng(), null, registry
	)
	assert_true(result.accepted, "Strike must be accepted against in-range idle target")
	assert_lt(
		result.new_target_resources.hp, target.resources.hp, "validated hit must reduce target HP"
	)
	assert_eq(
		result.new_target_state.state, _CS.CombatStateEnum.IDLE, "IDLE target must remain IDLE"
	)
	assert_false(result.interrupt_landed, "ordinary damage is not credited as an interrupt")


func test_04_full_interrupt_cancels_boss_channel_server_side():
	var registry = _make_registry()
	var kick = _make_strike()
	kick.can_full_interrupt = true
	kick.triggers_gcd = false
	kick.school_lock_ticks = 80
	var attacker = _make_entity(2, Vector3.ZERO, _CS.CombatStateEnum.IDLE)
	var boss = _make_entity(9001, Vector3(1, 0, 0), _CS.CombatStateEnum.CHANNELING)
	boss.is_mob = true
	boss.combat_state.cast_start = 100
	boss.combat_state.cast_end = 260
	boss.combat_state.cast_ability_id = -100  # boss Dirge, not a player ability in the registry
	var result = _AE.execute_ability(attacker, boss, kick, 120, _make_rng(), null, registry)
	assert_true(result.accepted)
	assert_true(result.interrupt_landed, "purposeful interrupt is credited")
	assert_eq(result.new_target_state.state, _CS.CombatStateEnum.IDLE, "boss channel is cancelled")
	assert_eq(
		result.new_target_state.last_full_interrupt_at, 120, "boss cadence sees the cancel tick"
	)


func test_05_interrupt_immune_boss_keeps_channeling():
	var registry = _make_registry()
	var kick = _make_strike()
	kick.can_full_interrupt = true
	var attacker = _make_entity(2, Vector3.ZERO, _CS.CombatStateEnum.IDLE)
	var boss = _make_entity(9001, Vector3(1, 0, 0), _CS.CombatStateEnum.CHANNELING)
	boss.is_mob = true
	boss.interrupt_immune = true
	boss.combat_state.cast_end = 260
	boss.combat_state.cast_ability_id = -100
	var result = _AE.execute_ability(attacker, boss, kick, 120, _make_rng(), null, registry)
	assert_true(result.accepted, "the damage portion still resolves")
	assert_false(result.interrupt_landed, "immunity prevents a forged successful interrupt")
	assert_eq(result.new_target_state.state, _CS.CombatStateEnum.CHANNELING)
