# T-020: Strike ability — unit tests for the full validation pipeline.
# All tests call ability_executor.execute_ability() directly — no network, no engine loop.

extends GutTest

const _AE = preload("res://scripts/combat/ability_executor.gd")
const _CS = preload("res://scripts/combat/combat_state.gd")
const _SC = preload("res://scripts/server_config.gd")
const _ES = preload("res://scripts/combat/entity_snapshot.gd")


func _make_entity(pos: Vector3, state_enum: int, stamina: int):
	var snap = _ES.new()
	snap.peer_id = 1
	snap.position = pos
	var cs := CombatState.new()
	cs.state = state_enum
	snap.combat_state = cs
	var cr := CombatResources.new()
	cr.hp = 100
	cr.max_hp = 100
	cr.mana = 50
	cr.max_mana = 50
	cr.stamina = stamina
	cr.max_stamina = 100
	snap.resources = cr
	snap.stats = CharacterStats.new()
	return snap


func _make_target(pos: Vector3):
	var snap = _make_entity(pos, _CS.CombatStateEnum.IDLE, 100)
	snap.peer_id = 2
	return snap


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
	# Force variance=1.0 so damage_amount assertions stay exact after T-021 fills the formula.
	# Empty attacker/mitigation coeffs + zero-skill CharacterStats → raw=10, defense=0.
	ab.variance_min = 1.0
	ab.variance_max = 1.0
	return ab


func _make_rng() -> RandomNumberGenerator:
	var rng := RandomNumberGenerator.new()
	rng.seed = 42
	return rng


# --- Tests ---


func test_01_valid_strike_accepted():
	var caster = _make_entity(Vector3(0, 0, 0.0), _CS.CombatStateEnum.IDLE, 100)
	var target = _make_target(Vector3(1, 0, 0.0))
	var result = _AE.execute_ability(caster, target, _make_strike(), 0, _make_rng())
	assert_true(result.accepted, "in-range Strike from IDLE should be accepted")
	assert_eq(result.damage_amount, 10, "zero skills, variance=1.0, no defense → base_damage=10")
	assert_eq(
		result.new_caster_state.state,
		_CS.CombatStateEnum.GLOBAL_COOLDOWN,
		"caster enters GCD after accepted ability"
	)
	assert_eq(
		result.new_caster_state.gcd_until, _SC.GCD_TICKS, "gcd_until = now(0) + GCD_TICKS(30)"
	)
	assert_eq(result.new_caster_resources.stamina, 95, "stamina 100 - cost 5 = 95")


func test_02_insufficient_stamina_rejected():
	var caster = _make_entity(Vector3(0, 0, 0.0), _CS.CombatStateEnum.IDLE, 4)
	var target = _make_target(Vector3(1, 0, 0.0))
	var result = _AE.execute_ability(caster, target, _make_strike(), 0, _make_rng())
	assert_false(result.accepted, "stamina 4 < cost 5 should reject")
	assert_eq(result.rejection_reason, "insufficient_resource")
	assert_eq(result.new_caster_resources.stamina, 4, "stamina unchanged on rejection")


func test_03_on_gcd_rejected():
	var caster = _make_entity(Vector3(0, 0, 0.0), _CS.CombatStateEnum.GLOBAL_COOLDOWN, 100)
	caster.combat_state.gcd_until = 100
	var target = _make_target(Vector3(1, 0, 0.0))
	var result = _AE.execute_ability(caster, target, _make_strike(), 50, _make_rng())
	assert_false(result.accepted, "GCD active should reject")
	assert_eq(result.rejection_reason, "on_gcd")
	# T-721: the refusal tells the client WHEN the GCD frees so its press queue can retry then.
	assert_eq(
		int(result.detail.get("gcd_ready_in_ticks", -1)),
		50,
		"on_gcd detail carries gcd_until - now (100 - 50)"
	)


func test_04_out_of_range_rejected():
	var caster = _make_entity(Vector3(0, 0, 0.0), _CS.CombatStateEnum.IDLE, 100)
	var target = _make_target(Vector3(3, 0, 0.0))  # distance 3.0 > range_units 2.5
	var result = _AE.execute_ability(caster, target, _make_strike(), 0, _make_rng())
	assert_false(result.accepted, "target 3.0 units away is out of range 2.5")
	assert_eq(result.rejection_reason, "out_of_range")
	# T-402 item 3: the reject carries server-computed dist/reach for the caster's HUD read.
	assert_eq(float(result.detail.get("dist_m", -1.0)), 3.0, "detail carries actual distance")
	assert_eq(float(result.detail.get("range_m", -1.0)), 2.5, "detail carries ability reach")


func test_04b_in_range_and_other_rejects_have_empty_detail():
	# T-402 item 3: detail is out_of_range-only — an accepted hit and a non-range reject carry {}.
	var caster = _make_entity(Vector3(0, 0, 0.0), _CS.CombatStateEnum.IDLE, 100)
	var target = _make_target(Vector3(1, 0, 0.0))
	var result = _AE.execute_ability(caster, target, _make_strike(), 0, _make_rng())
	assert_true(result.accepted, "in-range strike accepted")
	assert_eq(result.detail.size(), 0, "accepted result carries no detail")
	var dead = _make_entity(Vector3(0, 0, 0.0), _CS.CombatStateEnum.DEAD, 100)
	var rej = _AE.execute_ability(dead, target, _make_strike(), 0, _make_rng())
	assert_false(rej.accepted, "dead caster rejected")
	assert_eq(rej.detail.size(), 0, "non-range reject carries no detail")


func test_04c_out_of_range_wins_over_insufficient_resource():
	# T-402 item-3 polish (hud-judge): a resource-starved player mashing OUT OF RANGE must get the
	# actionable out_of_range read, not the T-027-silent insufficient_resource. Range precedes
	# resource in the validation order — verify the reason + that no resource was spent.
	var caster = _make_entity(Vector3(0, 0, 0.0), _CS.CombatStateEnum.IDLE, 4)  # stamina 4 < cost 5
	var target = _make_target(Vector3(3, 0, 0.0))  # distance 3.0 > range_units 2.5
	var result = _AE.execute_ability(caster, target, _make_strike(), 0, _make_rng())
	assert_false(result.accepted, "both range and resource fail")
	assert_eq(result.rejection_reason, "out_of_range", "range wins over silent resource reject")
	assert_eq(float(result.detail.get("dist_m", -1.0)), 3.0, "out_of_range detail still attached")
	assert_eq(result.new_caster_resources.stamina, 4, "no resource spent on the rejection")


func test_05_dead_caster_rejected():
	var caster = _make_entity(Vector3(0, 0, 0.0), _CS.CombatStateEnum.DEAD, 100)
	var target = _make_target(Vector3(1, 0, 0.0))
	var result = _AE.execute_ability(caster, target, _make_strike(), 0, _make_rng())
	assert_false(result.accepted, "dead caster cannot use abilities")


func test_06_gcd_expired_accepted():
	# GCD was set but has now expired (gcd_until <= now).
	var caster = _make_entity(Vector3(0, 0, 0.0), _CS.CombatStateEnum.GLOBAL_COOLDOWN, 100)
	caster.combat_state.gcd_until = 50
	var target = _make_target(Vector3(1, 0, 0.0))
	var result = _AE.execute_ability(caster, target, _make_strike(), 50, _make_rng())
	assert_true(result.accepted, "GCD expired at exactly now should be accepted")


func test_07_exact_range_boundary_accepted():
	# Target at exactly range_units (2.5) should be accepted.
	var caster = _make_entity(Vector3(0, 0, 0.0), _CS.CombatStateEnum.IDLE, 100)
	var target = _make_target(Vector3(2.5, 0, 0.0))
	var result = _AE.execute_ability(caster, target, _make_strike(), 0, _make_rng())
	assert_true(result.accepted, "target at exactly range_units 2.5 should be accepted")


# T-062: class-resource gate (rage|mana) on use_ability.


func _make_rage_ability(cost: int) -> AbilityData:
	var ab := _make_strike()
	ab.stamina_cost = 0  # cost the class resource, not the swing pool
	ab.resource_cost = cost
	return ab


func test_08_insufficient_class_resource_rejected():
	var caster = _make_entity(Vector3(0, 0, 0.0), _CS.CombatStateEnum.IDLE, 100)
	caster.resources.resource_kind = "rage"
	caster.resources.rage = 10
	caster.resources.max_rage = 100
	var target = _make_target(Vector3(1, 0, 0.0))
	var result = _AE.execute_ability(caster, target, _make_rage_ability(30), 0, _make_rng())
	assert_false(result.accepted, "rage 10 < cost 30 rejects")
	assert_eq(result.rejection_reason, "insufficient_resource")
	assert_eq(result.new_caster_resources.rage, 10, "rage unchanged on rejection")


func test_09_class_resource_spent_on_cast():
	var caster = _make_entity(Vector3(0, 0, 0.0), _CS.CombatStateEnum.IDLE, 100)
	caster.resources.resource_kind = "rage"
	caster.resources.rage = 50
	caster.resources.max_rage = 100
	var target = _make_target(Vector3(1, 0, 0.0))
	var result = _AE.execute_ability(caster, target, _make_rage_ability(30), 100, _make_rng())
	assert_true(result.accepted, "rage 50 >= cost 30 accepted")
	# Spend 30 (-> 20), then gain 5 from the 10-damage hit (warriors build rage from damage dealt).
	assert_eq(result.new_caster_resources.rage, 25, "rage 50 - 30 spent + 5 from the hit = 25")
	assert_eq(result.new_caster_resources.last_spend_tick, 100, "spend tick recorded")


# T-063: class-gating + the new effect verbs (heal / taunt / threat / control).


func _make_heal_ability() -> AbilityData:
	var ab := _make_strike()
	ab.effect = "heal"
	ab.heal_base = 20
	ab.base_damage = 0
	ab.stamina_cost = 0
	ab.variance_min = 1.0
	ab.variance_max = 1.0
	return ab


func test_10_class_gate_rejects_wrong_class():
	var caster = _make_entity(Vector3(0, 0, 0.0), _CS.CombatStateEnum.IDLE, 100)
	caster.char_class = "mage"
	var target = _make_target(Vector3(1, 0, 0.0))
	var ab := _make_strike()
	ab.char_class = "warrior"
	var result = _AE.execute_ability(caster, target, ab, 0, _make_rng())
	assert_false(result.accepted, "a mage can't use a warrior ability")
	assert_eq(result.rejection_reason, "wrong_class")


func test_11_class_gate_allows_matching_class():
	var caster = _make_entity(Vector3(0, 0, 0.0), _CS.CombatStateEnum.IDLE, 100)
	caster.char_class = "warrior"
	var target = _make_target(Vector3(1, 0, 0.0))
	var ab := _make_strike()
	ab.char_class = "warrior"
	var result = _AE.execute_ability(caster, target, ab, 0, _make_rng())
	assert_true(result.accepted, "matching class is allowed")


func test_12_heal_restores_target_hp():
	var caster = _make_entity(Vector3(0, 0, 0.0), _CS.CombatStateEnum.IDLE, 100)
	caster.stats.int_val = 40
	var target = _make_target(Vector3(1, 0, 0.0))
	target.resources.hp = 50  # damaged (max 100)
	var result = _AE.execute_ability(caster, target, _make_heal_ability(), 0, _make_rng())
	assert_true(result.accepted)
	assert_eq(result.outcome, "heal")
	assert_gt(result.new_target_resources.hp, 50, "heal raised target hp")
	assert_true(result.new_target_resources.hp <= 100, "clamped to max")


func test_13_taunt_makes_caster_top_threat():
	var caster = _make_entity(Vector3(0, 0, 0.0), _CS.CombatStateEnum.IDLE, 100)  # peer_id 1
	var target = _make_target(Vector3(1, 0, 0.0))  # peer_id 2 (the mob)
	var tt := ThreatTable.new()
	tt.add_threat(target.peer_id, 99, 500)  # someone else holds aggro
	var ab := _make_strike()
	ab.effect = "taunt"
	ab.stamina_cost = 0
	var result = _AE.execute_ability(caster, target, ab, 0, _make_rng(), tt)
	assert_true(result.accepted)
	assert_eq(result.outcome, "taunt")
	assert_eq(tt.get_top_threat_target(target.peer_id), caster.peer_id, "caster now top threat")


func test_14_control_stuns_target():
	var caster = _make_entity(Vector3(0, 0, 0.0), _CS.CombatStateEnum.IDLE, 100)
	var target = _make_target(Vector3(1, 0, 0.0))
	var ab := _make_strike()
	ab.effect = "control"
	ab.control_kind = "stun"
	ab.control_ticks = 40
	ab.stamina_cost = 0
	var result = _AE.execute_ability(caster, target, ab, 100, _make_rng())
	assert_true(result.accepted)
	assert_eq(result.outcome, "control")
	assert_eq(result.new_target_state.stunned_until, 140, "stun until now(100)+40")


func test_15_friendly_heal_rejects_enemy_target():
	var caster = _make_entity(Vector3(0, 0, 0.0), _CS.CombatStateEnum.IDLE, 100)
	var target = _make_target(Vector3(1, 0, 0.0))
	target.is_mob = true  # an enemy mob
	var ab := _make_heal_ability()
	ab.targets_friendly = true
	var result = _AE.execute_ability(caster, target, ab, 0, _make_rng())
	assert_false(result.accepted, "a friendly-only heal can't target an enemy mob")
	assert_eq(result.rejection_reason, "invalid_target")
