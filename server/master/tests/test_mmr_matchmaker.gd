extends GutTest

# T-392: the PURE MMR matcher — band widening, hard floor/ceiling, fair pairing, balanced teams.
# No I/O; every case injects its own band params so the curve is deterministic.

const MmrMatchmaker = preload("res://scripts/mmr_matchmaker.gd")

var _band := {"base_band": 100, "widen_per_sec": 8, "max_band": 600}


func test_band_starts_tight_and_widens_with_wait() -> void:
	assert_eq(MmrMatchmaker.band_for(0, _band), 100, "a fresh queuer only faces a near-peer")
	assert_eq(MmrMatchmaker.band_for(10, _band), 180, "band opens up while you wait")
	assert_gt(
		MmrMatchmaker.band_for(20, _band),
		MmrMatchmaker.band_for(5, _band),
		"longer wait => wider band",
	)


func test_band_hard_floor_and_ceiling() -> void:
	# Negative/zero wait can never tighten below the base floor.
	assert_eq(MmrMatchmaker.band_for(-99, _band), 100, "hard floor at base_band")
	# No wait ever widens past the ceiling (no unwinnable blowout).
	assert_eq(MmrMatchmaker.band_for(100000, _band), 600, "hard ceiling at max_band")


func test_can_match_uses_the_longer_waiters_band() -> void:
	# 200 apart, both fresh: base band 100 is too tight.
	assert_false(MmrMatchmaker.can_match(1500, 1700, 0, 0, _band))
	# The same gap once ONE of them has waited 15s (band -> 220): now matchable.
	assert_true(MmrMatchmaker.can_match(1500, 1700, 15, 0, _band))


func test_pair_queue_pairs_nearest_and_leaves_the_odd_one_out() -> void:
	var res := (
		MmrMatchmaker
		. pair_queue(
			[
				{"id": "a", "mmr": 1500, "wait": 0},
				{"id": "b", "mmr": 1520, "wait": 0},
				{"id": "c", "mmr": 1530, "wait": 0},
			],
			_band,
		)
	)
	# a-b (or b-c) pair within band; exactly one stays unmatched (odd count).
	assert_eq((res["pairs"] as Array).size(), 1)
	assert_eq((res["unmatched"] as Array).size(), 1)
	var pair: Array = res["pairs"][0]
	assert_true("a" in pair and "b" in pair, "nearest-MMR neighbours pair first")


func test_pair_queue_refuses_a_lopsided_pair_at_base_band() -> void:
	# Two players 500 apart with no wait: base band 100 forbids the blowout — both keep waiting.
	var res := (
		MmrMatchmaker
		. pair_queue(
			[{"id": "low", "mmr": 1100, "wait": 0}, {"id": "high", "mmr": 1600, "wait": 0}],
			_band,
		)
	)
	assert_eq((res["pairs"] as Array).size(), 0, "no unfair pair at the tight band")
	assert_eq((res["unmatched"] as Array).size(), 2)


func test_pair_queue_allows_the_gap_after_a_long_wait() -> void:
	# The same 500 gap becomes matchable once one has waited long enough to widen the band.
	var res := (
		MmrMatchmaker
		. pair_queue(
			[{"id": "low", "mmr": 1100, "wait": 60}, {"id": "high", "mmr": 1600, "wait": 60}],
			_band,
		)
	)
	assert_eq((res["pairs"] as Array).size(), 1, "a patient queuer's band absorbs the gap")


func test_balance_teams_minimizes_the_rating_gap() -> void:
	var res := (
		MmrMatchmaker
		. balance_teams(
			[
				{"id": "a", "mmr": 2000},
				{"id": "b", "mmr": 1000},
				{"id": "c", "mmr": 1800},
				{"id": "d", "mmr": 1200},
			],
			2,
		)
	)
	assert_eq((res["teams"][0] as Array).size(), 2)
	assert_eq((res["teams"][1] as Array).size(), 2)
	# Perfect split: {2000,1000} vs {1800,1200} both sum 3000 -> gap 0 (never the naive 2000+1800 stack).
	assert_eq(int(res["mmr_gap"]), 0, "teams balanced, not stacked")
