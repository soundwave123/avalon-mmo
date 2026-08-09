# T-064: pure talent ability modifiers + their effect on executor resolution.

extends GutTest

const _TEF = preload("res://scripts/combat/talent_effects.gd")
const _AE = preload("res://scripts/combat/ability_executor.gd")
const _ES = preload("res://scripts/combat/entity_snapshot.gd")
const _CS = preload("res://scripts/combat/combat_state.gd")

var _defs := {
	"tal_fire":
	{
		"id": "tal_fire",
		"effect": {"kind": "ability_damage_pct", "ability_id": 201, "pct_per_rank": 5},
	},
	"tal_all":
	{"id": "tal_all", "effect": {"kind": "ability_damage_pct", "ability_id": 0, "pct_per_rank": 5}},
	"tal_thrift":
	{
		"id": "tal_thrift",
		"effect": {"kind": "ability_cost_pct", "ability_id": 1, "pct_per_rank": 20},
	},
}


func test_ability_mods_resolution_stacks_ranks() -> void:
	var mods: Dictionary = _TEF.ability_mods({"tal_fire": 3, "tal_all": 1}, _defs)
	assert_eq(float(mods["damage_pct"][201]), 15.0, "5% x 3 ranks")
	assert_eq(float(mods["damage_pct"][0]), 5.0)


func test_damage_multiplier_specific_plus_all() -> void:
	var mods: Dictionary = _TEF.ability_mods({"tal_fire": 3, "tal_all": 1}, _defs)
	assert_almost_eq(_TEF.damage_multiplier(mods, 201), 1.20, 0.001, "15% + 5% all")
	assert_almost_eq(_TEF.damage_multiplier(mods, 999), 1.05, 0.001, "only the all-bonus")


func test_effective_cost_reduction_and_floor() -> void:
	var mods: Dictionary = _TEF.ability_mods({"tal_thrift": 2}, _defs)
	assert_eq(_TEF.effective_cost(10, mods, 1), 6, "10 * (1 - 40%) = 6")
	assert_eq(_TEF.effective_cost(10, mods, 2), 10, "other abilities unaffected")
	assert_eq(_TEF.effective_cost(0, mods, 1), 0)
	assert_eq(_TEF.effective_cost(10, {}, 1), 10, "no mods = base")


func _snap(pos: Vector3, mods: Dictionary = {}) -> Object:
	var s = _ES.new()
	s.peer_id = 1
	s.position = pos
	s.combat_state = CombatState.new()
	var cr := CombatResources.new()
	cr.hp = 100
	cr.max_hp = 100
	cr.mana = 50
	cr.max_mana = 50
	cr.stamina = 100
	cr.max_stamina = 100
	s.resources = cr
	s.stats = CharacterStats.new()
	s.ability_mods = mods
	return s


func _strike() -> AbilityData:
	var ab := AbilityData.new()
	ab.id = 1
	ab.name = "Strike"
	ab.cast_ticks = 0
	ab.triggers_gcd = true
	ab.stamina_cost = 5
	ab.range_units = 2.5
	ab.base_damage = 20
	ab.variance_min = 1.0
	ab.variance_max = 1.0
	return ab


func _rng() -> RandomNumberGenerator:
	var r := RandomNumberGenerator.new()
	r.seed = 42
	return r


func test_executor_applies_damage_talent() -> void:
	var target := _snap(Vector3(1, 0, 0))
	target.peer_id = 2
	var baseline = _AE.execute_ability(_snap(Vector3.ZERO), target, _strike(), 0, _rng())
	var target2 := _snap(Vector3(1, 0, 0))
	target2.peer_id = 2
	var mods := {"damage_pct": {1: 20.0}, "cost_pct": {}}
	var talented = _AE.execute_ability(_snap(Vector3.ZERO, mods), target2, _strike(), 0, _rng())
	assert_true(baseline.accepted and talented.accepted)
	assert_eq(
		talented.damage_amount,
		int(round(baseline.damage_amount * 1.2)),
		"+20% talent damage (same rng seed)"
	)


func test_executor_applies_cost_talent() -> void:
	# Base stamina cost 5; -40% => 3. Caster with exactly 3 stamina can strike ONLY with talents.
	var mods := {"damage_pct": {}, "cost_pct": {1: 40.0}}
	var poor := _snap(Vector3.ZERO)
	poor.resources.stamina = 3
	var target := _snap(Vector3(1, 0, 0))
	target.peer_id = 2
	var rejected = _AE.execute_ability(poor, target, _strike(), 0, _rng())
	assert_false(rejected.accepted, "3 stamina < base cost 5")

	var talented := _snap(Vector3.ZERO, mods)
	talented.resources.stamina = 3
	var target2 := _snap(Vector3(1, 0, 0))
	target2.peer_id = 2
	var accepted = _AE.execute_ability(talented, target2, _strike(), 0, _rng())
	assert_true(accepted.accepted, "cost talent lowers the gate: 5 -> 3")
	assert_eq(accepted.new_caster_resources.stamina, 0, "spends the REDUCED cost")
