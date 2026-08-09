# T-021: Damage formula unit tests — pure function, no network, no engine loop.
# All tests call _DF.compute_damage() directly with injected RNG.
# Variance is forced to 1.0 in truth-table tests (variance_min=variance_max=1.0)
# so expected values are exact and independent of the RNG seed.

extends GutTest

const _DF = preload("res://scripts/combat/damage_formula.gd")
const _SC = preload("res://scripts/server_config.gd")


func _make_rng(seed_val: int) -> RandomNumberGenerator:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_val
	return rng


func _make_attacker(swordsmanship: int, tactics: int) -> CharacterStats:
	var s := CharacterStats.new()
	s.skills = {"Swordsmanship": swordsmanship, "Tactics": tactics}
	return s


func _make_defender(anatomy: int) -> CharacterStats:
	var d := CharacterStats.new()
	d.skills = {"Anatomy": anatomy}
	return d


func _make_strike_fixed_variance() -> AbilityData:
	var ab := AbilityData.new()
	ab.id = 1
	ab.name = "Strike"
	ab.base_damage = 10
	ab.variance_min = 1.0
	ab.variance_max = 1.0
	ab.attacker_skill_coeffs = {"Swordsmanship": 0.3, "Tactics": 0.2}
	ab.mitigation_skill_coeffs = {"Anatomy": 0.15}
	ab.miss_chance = 0.0
	ab.dodge_chance = 0.0
	ab.parry_chance = 0.0
	ab.crit_chance = 0.0
	ab.crit_multiplier = 2.0
	return ab


# T-399: a coeff-free ability isolates the gear attack/armor terms from skill/stat scaling.
func _make_plain_ability(base: int) -> AbilityData:
	var ab := AbilityData.new()
	ab.id = 2
	ab.name = "Plain"
	ab.base_damage = base
	ab.variance_min = 1.0
	ab.variance_max = 1.0
	ab.miss_chance = 0.0
	ab.dodge_chance = 0.0
	ab.parry_chance = 0.0
	ab.crit_chance = 0.0
	ab.crit_multiplier = 2.0
	return ab


# --- Tests ---


# T-399: gear attack power lifts every hit; a naked attacker (attack_val 0) is unchanged.
func test_gear_attack_val_adds_flat_damage() -> void:
	var naked := CharacterStats.new()
	var geared := CharacterStats.new()
	geared.attack_val = 8
	var ab := _make_plain_ability(10)
	var d0 = _DF.compute_damage(naked, CharacterStats.new(), ab, _make_rng(1))
	var d1 = _DF.compute_damage(geared, CharacterStats.new(), ab, _make_rng(1))
	assert_eq(d0.amount, 10, "naked attacker: base only (0 gear attack) — pre-T-399 number holds")
	assert_eq(d1.amount, 18, "gear attack +8 adds flat to the hit (10 + 8)")


# T-399: gear armor mitigates ANY incoming hit via K/(K+defense); naked (armor_val 0) is unchanged.
func test_gear_armor_val_mitigates_incoming_damage() -> void:
	var attacker := CharacterStats.new()
	var unarmored := CharacterStats.new()
	var armored := CharacterStats.new()
	armored.armor_val = 100  # equal to MITIGATION_K → exactly halves the hit
	var ab := _make_plain_ability(100)
	var d0 = _DF.compute_damage(attacker, unarmored, ab, _make_rng(1))
	var d1 = _DF.compute_damage(attacker, armored, ab, _make_rng(1))
	assert_eq(
		d0.amount, 100, "unarmored target: full damage (0 gear armor) — pre-T-399 number holds"
	)
	assert_eq(d1.amount, 50, "armor 100 with K=100 halves the hit: 100 * 100/(100+100)")


func test_01_zero_skills_zero_defense_equals_base_damage():
	# raw=10, variance=1.0, defense=0, K/(K+0)=1.0 → floor(10)=10
	var result = _DF.compute_damage(
		_make_attacker(0, 0), _make_defender(0), _make_strike_fixed_variance(), _make_rng(1)
	)
	assert_eq(result.amount, 10, "zero skills, no defense → damage equals base_damage")
	assert_eq(result.outcome, "hit")


func test_02_attacker_skill_bonus_and_mitigation_spec_truth_table():
	# Swordsmanship=100, Tactics=0, Anatomy=100, variance=1.0
	# raw = 10 + 100*0.3 + 0*0.2 = 40
	# defense = 100*0.15 = 15
	# mitigated = 40 * 100/115 = 34.782... → floor = 34
	var attacker := CharacterStats.new()
	attacker.skills = {"Swordsmanship": 100}
	var result = _DF.compute_damage(
		attacker, _make_defender(100), _make_strike_fixed_variance(), _make_rng(1)
	)
	assert_eq(result.amount, 34, "spec truth-table: Swordsmanship=100, Anatomy=100 → 34")
	assert_eq(result.mitigated_amount, 6, "server exposes floor(raw 40) - floor(hit 34)")
	assert_eq(result.outcome, "hit")


func test_03_attacker_skills_raise_damage_above_base():
	# Swordsmanship=100, Tactics=100, no defense → raw=60, mitigated=60
	var result = _DF.compute_damage(
		_make_attacker(100, 100), _make_defender(0), _make_strike_fixed_variance(), _make_rng(1)
	)
	assert_true(
		result.amount > 10, "max attacker skills with no defense must exceed base_damage=10"
	)
	assert_eq(result.amount, 60, "10 + 100*0.3 + 100*0.2 = 60 (no mitigation)")


func test_04_miss_chance_one_always_misses():
	var ab := _make_strike_fixed_variance()
	ab.miss_chance = 1.0
	var result = _DF.compute_damage(_make_attacker(0, 0), _make_defender(0), ab, _make_rng(42))
	assert_eq(result.outcome, "miss", "miss_chance=1.0 must always return miss")
	assert_eq(result.amount, 0, "miss deals 0 damage")


func test_05_crit_chance_one_crits_on_mitigated_value():
	# crit_chance=1.0, variance=1.0, zero skills, zero defense
	# raw=10, defense=0, mitigated=10 → crit: 10 * 2.0 = 20
	var ab := _make_strike_fixed_variance()
	ab.crit_chance = 1.0
	var result = _DF.compute_damage(_make_attacker(0, 0), _make_defender(0), ab, _make_rng(1))
	assert_eq(result.outcome, "crit", "crit_chance=1.0 must always crit")
	assert_eq(result.amount, 20, "crit doubles mitigated value: floor(10 * 2.0) = 20")
	assert_eq(result.mitigated_amount, 0, "zero defense prevents no crit damage")
	assert_true(result.amount >= _SC.MIN_DAMAGE, "crit result respects MIN_DAMAGE floor")


func test_06_high_defense_never_zeroes_damage():
	# Anatomy=9999 — get_skill() clamps to 100; defense=15; ratio still > 0
	# With variance=1.0: mitigated=10*(100/115)≈8.69 → floor=8 → max(1,8)=8
	# Even if defense were unclamped at 9999: mitigated→0 → max(1,0)=1
	var defender := CharacterStats.new()
	defender.skills = {"Anatomy": 9999}
	var result = _DF.compute_damage(
		_make_attacker(0, 0), defender, _make_strike_fixed_variance(), _make_rng(1)
	)
	assert_true(result.amount >= _SC.MIN_DAMAGE, "ratio mitigation must never produce 0 damage")
	assert_eq(result.outcome, "hit")


func test_07_determinism_same_seed_same_result():
	var ab := _make_strike_fixed_variance()
	ab.variance_min = 0.85
	ab.variance_max = 1.0
	var attacker := _make_attacker(50, 30)
	var defender := _make_defender(40)
	var r1 = _DF.compute_damage(attacker, defender, ab, _make_rng(12345))
	var r2 = _DF.compute_damage(attacker, defender, ab, _make_rng(12345))
	assert_eq(r1.amount, r2.amount, "same seed must produce identical damage")
	assert_eq(r1.outcome, r2.outcome, "same seed must produce identical outcome")


func test_08_fuzz_no_zero_or_negative_damage():
	# 5000 calls with varied skills (including > 100 to exercise clamping) — none may return 0.
	var rng := RandomNumberGenerator.new()
	rng.seed = 999
	var ab := AbilityData.new()
	ab.base_damage = 10
	ab.variance_min = 0.85
	ab.variance_max = 1.0
	ab.attacker_skill_coeffs = {"Swordsmanship": 0.3, "Tactics": 0.2}
	ab.mitigation_skill_coeffs = {"Anatomy": 0.15}
	ab.miss_chance = 0.0
	ab.dodge_chance = 0.0
	ab.parry_chance = 0.0
	ab.crit_chance = 0.0
	ab.crit_multiplier = 2.0
	for i in range(5000):
		var attacker := CharacterStats.new()
		attacker.skills = {
			"Swordsmanship": rng.randi_range(0, 200),
			"Tactics": rng.randi_range(0, 200),
		}
		var defender := CharacterStats.new()
		defender.skills = {"Anatomy": rng.randi_range(0, 200)}
		var result = _DF.compute_damage(attacker, defender, ab, rng)
		assert_true(result.amount >= 1, "damage must be >= 1 (got %d at i=%d)" % [result.amount, i])


# T-061: stat-based scaling — the L67 fix. Damage is no longer flat across levels/stats.


func _make_str_attacker(str_val: int) -> CharacterStats:
	var s := CharacterStats.new()
	s.str_val = str_val
	return s


func _make_str_scaling_ability() -> AbilityData:
	var ab := AbilityData.new()
	ab.id = 1
	ab.name = "StrStrike"
	ab.base_damage = 10
	ab.variance_min = 1.0
	ab.variance_max = 1.0
	ab.attacker_stat_coeffs = {"str": 0.5}
	return ab


func test_stat_str_increases_damage() -> void:
	var ab := _make_str_scaling_ability()
	var low = _DF.compute_damage(_make_str_attacker(10), _make_defender(0), ab, _make_rng(1))
	var high = _DF.compute_damage(_make_str_attacker(50), _make_defender(0), ab, _make_rng(1))
	assert_gt(high.amount, low.amount, "more str -> more damage (L67 closed: not flat)")


func test_stat_scaling_exact_value() -> void:
	# base 10 + str(20)*0.5 = 20; no defense, variance forced to 1.0 -> exactly 20
	var r = _DF.compute_damage(
		_make_str_attacker(20), _make_defender(0), _make_str_scaling_ability(), _make_rng(1)
	)
	assert_eq(r.amount, 20, "10 + 20*0.5 = 20")


func test_stat_zero_leaves_base_only() -> void:
	# Backward-compat: zero stats (and the existing M1 skill abilities) are a no-op.
	var r = _DF.compute_damage(
		_make_str_attacker(0), _make_defender(0), _make_str_scaling_ability(), _make_rng(1)
	)
	assert_eq(r.amount, 10, "0 str -> base only")


func test_stat_and_skill_stack() -> void:
	# Mixed: base 10 + Swordsmanship(100)*0.3 + str(20)*0.5 = 10 + 30 + 10 = 50
	var ab := _make_str_scaling_ability()
	ab.attacker_skill_coeffs = {"Swordsmanship": 0.3}
	var atk := _make_str_attacker(20)
	atk.skills = {"Swordsmanship": 100}
	var r = _DF.compute_damage(atk, _make_defender(0), ab, _make_rng(1))
	assert_eq(r.amount, 50, "skill scaffold + stat driver are additive")
