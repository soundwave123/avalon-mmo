# T-434: server-authoritative interrupt/crowd-control toolkit.
# Exercises the real ability registry through the pure executor: cooldown, school lock,
# PvP diminishing returns, PvE full duration, and encounter immunity.

extends GutTest

const _AE = preload("res://scripts/combat/ability_executor.gd")
const _AR = preload("res://scripts/combat/ability_registry.gd")
const _CS = preload("res://scripts/combat/combat_state.gd")
const _CR = preload("res://scripts/combat/combat_resources.gd")
const _CSTATS = preload("res://scripts/combat/character_stats.gd")
const _ES = preload("res://scripts/combat/entity_snapshot.gd")
const _TEF = preload("res://scripts/combat/talent_effects.gd")


func _registry():
	var r = _AR.new()
	r.load_from_dir("res://data/abilities")
	return r


func _actor(peer_id: int, char_class: String, is_mob: bool = false):
	var s = _ES.new()
	s.peer_id = peer_id
	s.position = Vector3.ZERO
	s.combat_state = _CS.new()
	s.resources = _CR.new()
	s.resources.hp = 500
	s.resources.max_hp = 500
	s.resources.mana = 500
	s.resources.max_mana = 500
	s.resources.stamina = 500
	s.resources.max_stamina = 500
	s.resources.rage = 100
	s.resources.max_rage = 100
	s.resources.resource_kind = "rage" if char_class == "warrior" else "mana"
	s.stats = _CSTATS.new()
	s.char_class = char_class
	s.is_mob = is_mob
	s.level = 12
	return s


func _rng() -> RandomNumberGenerator:
	var r := RandomNumberGenerator.new()
	r.seed = 434
	return r


func _consent(_attacker: int, _target: int) -> bool:
	return true


func _casting_player(peer_id: int, ability_id: int, school_class: String):
	var target = _actor(peer_id, school_class)
	target.combat_state.state = _CS.CombatStateEnum.CASTING
	target.combat_state.cast_start = 100
	target.combat_state.cast_end = 200
	target.combat_state.cast_ability_id = ability_id
	target.combat_state.cast_target_id = 9001
	return target


func test_pummel_cancels_player_cast_and_locks_its_school() -> void:
	var registry = _registry()
	var caster = _actor(1, "warrior")
	var target = _casting_player(2, 201, "mage")  # real Fireball
	var result = _AE.execute_ability(
		caster, target, registry.get_ability(106), 120, _rng(), null, registry, _consent
	)
	assert_true(result.accepted, "validated Pummel lands in a consented duel")
	assert_true(result.interrupt_landed, "server records the full interrupt")
	assert_eq(result.new_target_state.state, _CS.CombatStateEnum.IDLE, "cast is cancelled")
	assert_gt(
		int(result.new_target_state.school_locks.get("fire", 0)),
		120,
		"the interrupted Fireball's school is locked"
	)


func test_counterspell_cancels_real_smite_and_locks_holy_school() -> void:
	var registry = _registry()
	var mage = _actor(1, "mage")
	var priest = _casting_player(2, 303, "priest")  # real Smite
	var result = _AE.execute_ability(
		mage, priest, registry.get_ability(206), 120, _rng(), null, registry, _consent
	)
	assert_true(result.accepted)
	assert_true(result.interrupt_landed)
	assert_eq(result.new_target_state.state, _CS.CombatStateEnum.IDLE)
	assert_gt(int(result.new_target_state.school_locks.get("holy", 0)), 120)


func test_school_lock_rejects_same_school_but_not_another_school() -> void:
	var registry = _registry()
	var warrior = _actor(1, "warrior")
	var mage = _casting_player(2, 201, "mage")
	var kicked = _AE.execute_ability(
		warrior, mage, registry.get_ability(106), 120, _rng(), null, registry, _consent
	)
	assert_true(kicked.accepted)

	var locked_mage = _actor(2, "mage")
	locked_mage.combat_state = kicked.new_target_state
	var mob = _actor(9001, "", true)
	var fire = _AE.execute_ability(
		locked_mage, mob, registry.get_ability(201), 121, _rng(), null, registry
	)
	assert_false(fire.accepted, "the locked fire school cannot begin another Fireball")
	assert_eq(fire.rejection_reason, "school_locked")

	var frost = _AE.execute_ability(
		locked_mage, mob, registry.get_ability(204), 121, _rng(), null, registry
	)
	assert_true(frost.accepted, "a different school remains castable")


func test_per_ability_cooldown_gates_until_exact_expiry() -> void:
	var registry = _registry()
	var pummel = registry.get_ability(106).effective_at_level(12)
	var caster = _actor(1, "warrior")
	var mob = _actor(9001, "", true)
	var first = _AE.execute_ability(
		caster, mob, registry.get_ability(106), 100, _rng(), null, registry
	)
	assert_true(first.accepted)
	var ready_at := int(first.new_caster_state.ability_cooldowns.get(106, 0))
	assert_eq(ready_at, 100 + pummel.cooldown_ticks, "ranked server cooldown is stamped")

	caster.combat_state = first.new_caster_state
	var early = _AE.execute_ability(caster, mob, registry.get_ability(106), ready_at - 1, _rng())
	assert_false(early.accepted)
	assert_eq(early.rejection_reason, "ability_on_cooldown")
	var ready = _AE.execute_ability(caster, mob, registry.get_ability(106), ready_at, _rng())
	assert_true(ready.accepted, "cooldown expires on the exact authoritative tick")


func _stun() -> AbilityData:
	var ab := AbilityData.new()
	ab.id = 999
	ab.name = "DR Probe"
	ab.effect = "control"
	ab.control_kind = "stun"
	ab.control_ticks = 80
	ab.control_dr_category = "stun"
	ab.range_units = 5.0
	ab.triggers_gcd = true
	return ab


func _apply_player_stun(target, now: int):
	var caster = _actor(now + 1000, "warrior")  # a different player each link in the CC chain
	return _AE.execute_ability(caster, target, _stun(), now, _rng(), null, null, _consent)


func test_pvp_hard_cc_dr_is_full_half_quarter_immune_then_resets() -> void:
	var target = _actor(50, "mage")
	var starts := [100, 181, 222, 243]
	var expected := [80, 40, 20, 0]
	for i in starts.size():
		var result = _apply_player_stun(target, starts[i])
		assert_true(result.accepted, "CC link %d resolves server-side" % (i + 1))
		assert_eq(
			maxi(0, result.new_target_state.stunned_until - starts[i]),
			expected[i],
			"DR link %d duration" % (i + 1)
		)
		target.combat_state = result.new_target_state

	var reset_at := int(target.combat_state.control_dr_reset_at.get("stun", 0))
	var reset = _apply_player_stun(target, reset_at)
	assert_eq(reset.new_target_state.stunned_until - reset_at, 80, "full duration after DR reset")


func test_pve_control_keeps_full_duration_and_boss_immunity_resists() -> void:
	var mob = _actor(9001, "", true)
	var caster = _actor(1, "warrior")
	var first = _AE.execute_ability(caster, mob, _stun(), 100, _rng())
	assert_true(first.accepted)
	assert_eq(first.new_target_state.stunned_until, 180)

	mob.combat_state = first.new_target_state
	caster = _actor(2, "warrior")
	var second = _AE.execute_ability(caster, mob, _stun(), 181, _rng())
	assert_eq(second.new_target_state.stunned_until, 261, "PvE does not diminish control")

	var boss = _actor(9100, "", true)
	boss.control_immune = true
	var resisted = _AE.execute_ability(_actor(3, "warrior"), boss, _stun(), 200, _rng())
	assert_true(resisted.accepted, "the server resolves the attempt and spends the action")
	assert_eq(resisted.outcome, "control_immune")
	assert_eq(resisted.new_target_state.stunned_until, 0, "immune boss receives no control timer")


func test_real_warrior_and_priest_hard_cc_apply_ranked_duration() -> void:
	var registry = _registry()
	for row in [["warrior", 107], ["priest", 307]]:
		var cls := str(row[0])
		var ability_id := int(row[1])
		var caster = _actor(ability_id, cls)
		var mob = _actor(9000 + ability_id, "", true)
		var ability = registry.get_ability(ability_id).effective_at_level(caster.level)
		var result = _AE.execute_ability(caster, mob, registry.get_ability(ability_id), 500, _rng())
		assert_true(result.accepted, "%s hard CC resolves" % cls)
		assert_eq(result.outcome, "control")
		assert_eq(
			result.new_target_state.stunned_until,
			500 + ability.control_ticks,
			"%s hard CC uses its authoritative rank duration" % cls
		)


func test_each_class_has_a_talent_hook_for_its_control_toolkit() -> void:
	var expected := {"warrior": 106, "mage": 206, "priest": 307}
	var registry = _registry()
	for cls in expected:
		var parsed = JSON.parse_string(
			FileAccess.get_file_as_string("res://data/talents/%s.json" % cls)
		)
		assert_true(parsed is Dictionary, "%s talents parse" % cls)
		var found: Dictionary = {}
		for talent in parsed.get("talents", []):
			var effect: Dictionary = talent.get("effect", {})
			# T-523: the broadened trees also carry DAMAGE talents on these abilities; the
			# T-434 hook this test guards is specifically the COST reducer.
			if (
				int(effect.get("ability_id", -1)) == expected[cls]
				and str(effect.get("kind", "")) == "ability_cost_pct"
			):
				found = talent
		assert_false(found.is_empty(), "%s has a talent hook for ability %d" % [cls, expected[cls]])
		if found.is_empty():
			continue
		var talent_id := str(found["id"])
		var mods = _TEF.ability_mods({talent_id: int(found["max_ranks"])}, {talent_id: found})
		var ability = registry.get_ability(expected[cls]).effective_at_level(12)
		var base_cost: int = (
			ability.resource_cost if ability.resource_cost > 0 else ability.mana_cost
		)
		assert_lt(
			_TEF.effective_cost(base_cost, mods, ability.id),
			base_cost,
			"%s talent materially lowers its control-tool cost" % cls
		)
