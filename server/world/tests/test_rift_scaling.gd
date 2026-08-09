# T-393: the PURE Rift Trials scaling curve — the acceptance-criteria math. Proves the tier curve
# is strictly MONOTONIC (every tier is harder AND better paid than the last), UNBOUNDED (no hidden
# cap — the ladder never stops), non-linear (the per-tier gap widens at the top, the M+ soft
# self-limit), and fail-safe at the bottom (a corrupt tier clamps UP to the baseline, never to a
# free discount). No client input reaches these functions — the tier is server truth by contract.
extends GutTest

const _RS = preload("res://scripts/combat/rift_scaling.gd")

const _SWEEP := 120  # tiers swept for the monotonicity walk — far past any content today


func test_tier_one_is_the_unscaled_baseline() -> void:
	var p: Dictionary = _RS.params_for(1)
	assert_eq(float(p["hp_mult"]), 1.0, "tier 1 hp is the modeled crypt baseline")
	assert_eq(float(p["dmg_mult"]), 1.0, "tier 1 damage is the baseline")
	assert_eq(float(p["reward_weight"]), 1.0, "tier 1 reward weight is the published base odds")
	assert_gt(int(p["timer_secs"]), 0, "the clear timer exists")


func test_corrupt_tiers_clamp_up_to_baseline_never_below() -> void:
	for bad in [0, -1, -999]:
		var p: Dictionary = _RS.params_for(bad)
		assert_eq(int(p["tier"]), 1, "tier %d clamps to 1" % bad)
		assert_eq(float(p["hp_mult"]), 1.0, "no free sub-baseline discount")


func test_curves_are_strictly_monotonic_across_the_sweep() -> void:
	for t in range(1, _SWEEP):
		assert_gt(_RS.hp_mult(t + 1), _RS.hp_mult(t), "hp_mult rises at tier %d" % t)
		assert_gt(_RS.dmg_mult(t + 1), _RS.dmg_mult(t), "dmg_mult rises at tier %d" % t)
		assert_gt(
			_RS.reward_weight(t + 1), _RS.reward_weight(t), "reward_weight rises at tier %d" % t
		)
		assert_true(
			_RS.timer_secs(t + 1) <= _RS.timer_secs(t),
			"the timer never LOOSENS as tiers rise (tier %d)" % t
		)


func test_curve_is_unbounded_no_hidden_cap() -> void:
	# Compounding growth: deep tiers blow through any would-be cap. If someone ever slips a
	# clamp/plateau into the curve, these explode.
	assert_gt(_RS.hp_mult(100), 10_000.0, "hp at tier 100 has left any cap behind")
	assert_gt(_RS.hp_mult(200), _RS.hp_mult(100) * 100.0, "still compounding at tier 200")
	assert_gt(_RS.reward_weight(200), 1_000_000.0, "reward weight is unbounded too")


func test_curve_is_non_linear_gaps_widen_at_the_top() -> void:
	# The M+ shape (ticket D4): the step from t20 -> t21 is larger than t1 -> t2 in absolute
	# multiplier terms, so the ladder self-limits without a hard cap.
	var low_gap: float = _RS.hp_mult(2) - _RS.hp_mult(1)
	var high_gap: float = _RS.hp_mult(21) - _RS.hp_mult(20)
	assert_gt(high_gap, low_gap, "per-tier hp gap widens with tier")


func test_params_for_agrees_with_the_component_curves() -> void:
	for t in [1, 5, 13, 40]:
		var p: Dictionary = _RS.params_for(t)
		assert_eq(float(p["hp_mult"]), _RS.hp_mult(t))
		assert_eq(float(p["dmg_mult"]), _RS.dmg_mult(t))
		assert_eq(float(p["reward_weight"]), _RS.reward_weight(t))
		assert_eq(int(p["timer_secs"]), _RS.timer_secs(t))
