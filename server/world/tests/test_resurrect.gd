extends "res://addons/gut/test.gd"

# T-364: priest Resurrection — the healer's field rez. Server-authoritative like every ability:
# it INVERTS the dead-target rule (needs a dead ally, rejects a living target), restores the ally at
# a fraction of max HP/mana with a revive-sickness window, and a rez-sick caster's damage/heal output
# is reduced until the window expires. All params are data-tunable (ability JSON + ServerConfig).

const _AE = preload("res://scripts/combat/ability_executor.gd")
const _ES = preload("res://scripts/combat/entity_snapshot.gd")
const _CS = preload("res://scripts/combat/combat_state.gd")
const _CR = preload("res://scripts/combat/combat_resources.gd")
const _CSTATS = preload("res://scripts/combat/character_stats.gd")
const _ADAT = preload("res://scripts/combat/ability_data.gd")
const _SC = preload("res://scripts/server_config.gd")


func _rng() -> RandomNumberGenerator:
	var r := RandomNumberGenerator.new()
	r.seed = 1
	return r


func _stats() -> CharacterStats:
	var s := _CSTATS.new()
	s.str_val = 20
	s.int_val = 20
	s.dex_val = 20
	s.spirit_val = 20
	s.stamina_val = 20
	return s


func _res(max_hp: int = 200, max_mana: int = 200) -> CombatResources:
	var r := _CR.new()
	r.max_hp = max_hp
	r.hp = max_hp
	r.max_mana = max_mana
	r.mana = max_mana
	r.resource_kind = "mana"
	r.stamina = 500
	r.max_stamina = 500
	return r


func _actor(pos: Vector3, char_class: String = "priest", is_mob: bool = false):
	var s := _ES.new()
	s.peer_id = 1 if not is_mob else 9001
	s.position = pos
	s.combat_state = _CS.new()
	s.resources = _res()
	s.stats = _stats()
	s.char_class = char_class
	s.is_mob = is_mob
	return s


func _rez() -> AbilityData:
	var a := _ADAT.new()
	a.id = 306
	a.name = "Resurrection"
	a.effect = "resurrect"
	a.char_class = "priest"
	a.targets_friendly = true
	a.cast_ticks = 0  # instant in the unit test so execute_ability resolves it directly
	a.range_units = 30.0
	a.revive_hp_pct = 0.35
	a.revive_mana_pct = 0.35
	a.revive_sickness_ticks = 200
	return a


func test_rez_restores_dead_ally_at_reduced_hp_and_sets_sickness() -> void:
	var caster = _actor(Vector3.ZERO)
	var ally = _actor(Vector3(3.0, 0.0, 0.0))
	ally.resources = ally.resources.apply_damage(999)  # kill them (hp -> 0)
	ally.combat_state.state = _CS.CombatStateEnum.DEAD
	ally.combat_state.respawn_at = 400
	var result = _AE.execute_ability(caster, ally, _rez(), 100, _rng())
	assert_true(result.accepted, "a dead ally can be resurrected")
	assert_eq(result.outcome, "resurrect")
	assert_eq(result.new_target_state.state, _CS.CombatStateEnum.IDLE, "ally stands up (IDLE)")
	assert_eq(result.new_target_state.respawn_at, 0, "the pending respawn is cancelled")
	assert_eq(
		result.new_target_state.revive_sickness_until, 300, "sickness window = now(100)+ticks(200)"
	)
	assert_eq(result.new_target_resources.hp, 70, "revived to 35% of 200 max HP")
	assert_eq(result.new_target_resources.mana, 70, "revived to 35% of 200 max mana")
	assert_gt(result.new_target_resources.hp, 0, "the revived ally is actually alive")


func test_rez_rejects_a_living_target() -> void:
	var caster = _actor(Vector3.ZERO)
	var living = _actor(Vector3(3.0, 0.0, 0.0))  # IDLE, alive
	var result = _AE.execute_ability(caster, living, _rez(), 0, _rng())
	assert_false(result.accepted, "you cannot resurrect the living")
	assert_eq(result.rejection_reason, "target_not_dead")


func test_rez_rejects_a_mob_target() -> void:
	var caster = _actor(Vector3.ZERO)
	var mob = _actor(Vector3(3.0, 0.0, 0.0), "", true)
	mob.combat_state.state = _CS.CombatStateEnum.DEAD  # even a dead mob
	var result = _AE.execute_ability(caster, mob, _rez(), 0, _rng())
	assert_false(result.accepted, "rez is friendly-only — no rezzing a mob corpse")
	assert_eq(result.rejection_reason, "invalid_target")


func test_rez_out_of_range_rejected() -> void:
	var caster = _actor(Vector3.ZERO)
	var ally = _actor(Vector3(100.0, 0.0, 0.0))  # past the 30u range
	ally.combat_state.state = _CS.CombatStateEnum.DEAD
	var result = _AE.execute_ability(caster, ally, _rez(), 0, _rng())
	assert_false(result.accepted, "range is validated server-side even for a rez")
	assert_eq(result.rejection_reason, "out_of_range")


func _melee(base: int) -> AbilityData:
	var a := _ADAT.new()
	a.id = 42
	a.effect = "damage"
	a.base_damage = base
	a.range_units = 10.0
	a.char_class = ""
	a.variance_min = 1.0
	a.variance_max = 1.0
	return a


func test_revive_sickness_reduces_damage_output() -> void:
	var target = _actor(Vector3(1.0, 0.0, 0.0), "", true)
	var healthy = _actor(Vector3.ZERO)
	var sick = _actor(Vector3.ZERO)
	sick.combat_state.revive_sickness_until = 500  # still sick at now=0
	var dmg_healthy = _AE.execute_ability(healthy, target, _melee(100), 0, _rng()).damage_amount
	var dmg_sick = _AE.execute_ability(sick, target, _melee(100), 0, _rng()).damage_amount
	assert_gt(dmg_healthy, dmg_sick, "a rez-sick attacker deals less")
	assert_almost_eq(
		float(dmg_sick), float(dmg_healthy) * _SC.REVIVE_SICKNESS_MULT, 1.0, "sick output ~= mult"
	)


func test_sickness_expired_restores_full_output() -> void:
	var target = _actor(Vector3(1.0, 0.0, 0.0), "", true)
	var was_sick = _actor(Vector3.ZERO)
	was_sick.combat_state.revive_sickness_until = 50  # window ends before now=100
	var dmg = _AE.execute_ability(was_sick, target, _melee(100), 100, _rng()).damage_amount
	var full = (
		_AE.execute_ability(_actor(Vector3.ZERO), target, _melee(100), 100, _rng()).damage_amount
	)
	assert_eq(dmg, full, "once the sickness window passes, output is full again")
