extends "res://addons/gut/test.gd"

# T-063: pure effect resolvers — heal scaling. Deterministic (variance forced to 1.0; injected rng).
# T-365: ability rank ladder — rank-for-level resolution + per-band damage/heal scaling.

const AE = preload("res://scripts/combat/ability_effects.gd")
const DF = preload("res://scripts/combat/damage_formula.gd")


func _rng() -> RandomNumberGenerator:
	var r := RandomNumberGenerator.new()
	r.seed = 1
	return r


func _caster(int_val: int, spirit_val: int) -> CharacterStats:
	var s := CharacterStats.new()
	s.int_val = int_val
	s.spirit_val = spirit_val
	return s


func _heal(base: int) -> AbilityData:
	var ab := AbilityData.new()
	ab.effect = "heal"
	ab.heal_base = base
	ab.variance_min = 1.0
	ab.variance_max = 1.0
	return ab


func test_heal_base_plus_stat_power() -> void:
	# base 20 + heal_power(int 40, spirit 0) = 20 + 40*0.5 = 40
	assert_eq(AE.compute_heal(_caster(40, 0), _heal(20), _rng()), 40)


func test_heal_scales_with_int_and_spirit() -> void:
	var low := AE.compute_heal(_caster(10, 10), _heal(0), _rng())
	var high := AE.compute_heal(_caster(40, 40), _heal(0), _rng())
	assert_gt(high, low, "more int/spirit -> bigger heal")


func test_heal_minimum_one() -> void:
	assert_eq(AE.compute_heal(_caster(0, 0), _heal(0), _rng()), 1, "a landed heal restores >= 1")


# --- T-365: rank ladder ------------------------------------------------------------------------
func _ranked_damage() -> AbilityData:
	# Fireball's shipped ladder: R1 @L1 (30), R2 @L6 (42), R3 @L12 (58). No stat scaling; variance 1.
	var ab := AbilityData.new()
	ab.effect = "damage"
	ab.base_damage = 30
	ab.variance_min = 1.0
	ab.variance_max = 1.0
	ab.ranks = [
		{"min_level": 1, "base_damage": 30},
		{"min_level": 6, "base_damage": 42},
		{"min_level": 12, "base_damage": 58},
	]
	return ab


func _ranked_heal() -> AbilityData:
	var ab := _heal(20)
	ab.ranks = [
		{"min_level": 1, "heal_base": 20},
		{"min_level": 6, "heal_base": 30},
		{"min_level": 12, "heal_base": 44},
	]
	return ab


func test_rank_for_level_table() -> void:
	var ab := _ranked_damage()
	# below/at/above each band boundary — the highest qualifying rank wins.
	assert_eq(ab.rank_for_level(1), 1, "L1 -> rank 1")
	assert_eq(ab.rank_for_level(5), 1, "just below the R2 band -> still rank 1")
	assert_eq(ab.rank_for_level(6), 2, "at the R2 band -> rank 2")
	assert_eq(ab.rank_for_level(11), 2, "just below the R3 band -> rank 2")
	assert_eq(ab.rank_for_level(12), 3, "at the R3 band -> rank 3")
	assert_eq(ab.rank_for_level(40), 3, "past the top band -> highest rank")


func test_flat_ability_returns_self() -> void:
	# An ability with no ladder is unchanged and allocates nothing (identity).
	var ab := _heal(20)
	assert_eq(ab.rank_for_level(50), 1, "no ladder -> always rank 1")
	assert_same(ab.effective_at_level(50), ab, "no ladder -> the same instance (no clone)")


func test_effective_damage_scales_per_band() -> void:
	var ab := _ranked_damage()
	var atk := CharacterStats.new()
	var def := CharacterStats.new()
	var r1 := DF.compute_damage(atk, def, ab.effective_at_level(1), _rng()).amount
	var r2 := DF.compute_damage(atk, def, ab.effective_at_level(6), _rng()).amount
	var r3 := DF.compute_damage(atk, def, ab.effective_at_level(12), _rng()).amount
	assert_eq(r1, 30, "rank 1 damage")
	assert_eq(r2, 42, "rank 2 damage")
	assert_eq(r3, 58, "rank 3 damage")
	assert_true(r1 < r2 and r2 < r3, "a higher rank does strictly more than a lower rank")


func test_effective_heal_scales_per_band() -> void:
	var ab := _ranked_heal()
	var low := AE.compute_heal(_caster(0, 0), ab.effective_at_level(1), _rng())
	var mid := AE.compute_heal(_caster(0, 0), ab.effective_at_level(6), _rng())
	var high := AE.compute_heal(_caster(0, 0), ab.effective_at_level(12), _rng())
	assert_eq(low, 20, "rank 1 heal")
	assert_eq(mid, 30, "rank 2 heal")
	assert_eq(high, 44, "rank 3 heal")
	assert_true(low < mid and mid < high, "a higher heal rank restores strictly more")
