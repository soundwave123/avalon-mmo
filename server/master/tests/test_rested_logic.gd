extends "res://addons/gut/test.gd"
# T-360: Rested XP — pure accrual + award-split. No OS time / DB; exhaustive determinism coverage.

const RL = preload("res://scripts/rested_logic.gd")

# ---- accrue ----


func test_accrue_basic_rate() -> void:
	# 50/hr for exactly 2h = 100 points, well under the cap.
	assert_eq(RL.accrue(0, 7200, 50, 10000), 100)


func test_accrue_adds_to_existing_pool() -> void:
	assert_eq(RL.accrue(40, 3600, 50, 10000), 90)


func test_accrue_caps_at_ceiling() -> void:
	# 50/hr for 100h would be 5000, but the cap clamps it.
	assert_eq(RL.accrue(0, 360000, 50, 300), 300)


func test_accrue_over_cap_pool_clamps_down_even_with_no_time() -> void:
	# A pool above a (newly lowered) cap reads back clamped, even with zero elapsed.
	assert_eq(RL.accrue(500, 0, 50, 300), 300)


func test_accrue_zero_and_negative_elapsed_is_noop() -> void:
	assert_eq(RL.accrue(120, 0, 50, 10000), 120)
	assert_eq(RL.accrue(120, -9999, 50, 10000), 120)


func test_accrue_zero_rate_is_noop() -> void:
	assert_eq(RL.accrue(120, 7200, 0, 10000), 120)


func test_accrue_never_negative() -> void:
	assert_eq(RL.accrue(-50, 3600, 50, 10000), 50, "negative pool floors to 0 then accrues")


func test_accrue_integer_floor() -> void:
	# 50/hr for 100s = 5000/3600 = 1 (floored), never fractional.
	assert_eq(RL.accrue(0, 100, 50, 10000), 1)


func test_accrue_deterministic() -> void:
	assert_eq(RL.accrue(33, 12345, 50, 5000), RL.accrue(33, 12345, 50, 5000))


# ---- split_award ----


func test_split_full_boost_within_pool() -> void:
	# base 100 fully covered by a 150 pool: doubled, pool drained by the boosted base.
	var r := RL.split_award(150, 100, 100)
	assert_eq(int(r["base"]), 100)
	assert_eq(int(r["bonus"]), 100)
	assert_eq(int(r["total"]), 200)
	assert_eq(int(r["pool_after"]), 50)


func test_split_award_exceeds_pool_partial_boost() -> void:
	# pool 150, base 200: first 150 boosted (+150), last 50 normal. Pool drains to 0.
	var r := RL.split_award(150, 200, 100)
	assert_eq(int(r["boosted_base"]), 150)
	assert_eq(int(r["bonus"]), 150)
	assert_eq(int(r["total"]), 350)
	assert_eq(int(r["pool_after"]), 0)


func test_split_empty_pool_is_plain_award() -> void:
	var r := RL.split_award(0, 200, 100)
	assert_eq(int(r["bonus"]), 0)
	assert_eq(int(r["total"]), 200)
	assert_eq(int(r["pool_after"]), 0)


func test_split_partial_bonus_percent() -> void:
	# 50% bonus: 100 boosted base -> +50 bonus.
	var r := RL.split_award(200, 100, 50)
	assert_eq(int(r["bonus"]), 50)
	assert_eq(int(r["total"]), 150)
	assert_eq(int(r["pool_after"]), 100, "pool drains by boosted BASE (100), not by the bonus")


func test_split_zero_base_is_noop() -> void:
	var r := RL.split_award(150, 0, 100)
	assert_eq(int(r["bonus"]), 0)
	assert_eq(int(r["total"]), 0)
	assert_eq(int(r["pool_after"]), 150, "no award spends no pool")


func test_split_negative_inputs_safe() -> void:
	var r := RL.split_award(-5, -20, -100)
	assert_eq(int(r["total"]), 0)
	assert_eq(int(r["pool_after"]), 0)


# The core promise: rested drains, then subsequent awards are plain — never an infinite doubler.
func test_split_drains_then_normal() -> void:
	var pool := 150
	var first := RL.split_award(pool, 120, 100)
	assert_eq(int(first["total"]), 240, "first 120 fully boosted")
	pool = int(first["pool_after"])  # 30 left
	var second := RL.split_award(pool, 120, 100)
	assert_eq(int(second["boosted_base"]), 30, "only 30 of the next 120 is boosted")
	assert_eq(int(second["total"]), 150, "120 base + 30 bonus")
	pool = int(second["pool_after"])
	assert_eq(pool, 0)
	var third := RL.split_award(pool, 120, 100)
	assert_eq(int(third["total"]), 120, "pool empty -> plain award, no doubling")
