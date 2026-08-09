# T-074: per-peer movement budget — distance per one-second window, not per message.

extends GutTest

const _MRL = preload("res://scripts/move_rate_limiter.gd")
const _SC = preload("res://scripts/server_config.gd")


func test_single_hop_within_budget_allowed() -> void:
	var lim = _MRL.new()
	assert_true(lim.allow(7, 36.0, 100), "one harness-scale hop fits the budget")


func test_budget_exhausts_within_one_window() -> void:
	var lim = _MRL.new()
	assert_true(lim.allow(7, 60.0, 100))
	assert_true(lim.allow(7, 40.0, 105), "exactly at budget still allowed")
	assert_false(lim.allow(7, 1.0, 110), "over budget inside the window must reject")


func test_window_resets_after_one_second() -> void:
	var lim = _MRL.new()
	assert_true(lim.allow(7, 100.0, 100))
	assert_false(lim.allow(7, 10.0, 110), "still inside the window")
	assert_true(
		lim.allow(7, 10.0, 100 + _SC.TICK_RATE_HZ), "new window (1 s later) restores the budget"
	)


func test_peers_have_independent_budgets() -> void:
	var lim = _MRL.new()
	assert_true(lim.allow(7, 100.0, 100))
	assert_true(lim.allow(8, 100.0, 100), "peer 8 unaffected by peer 7's spend")


func test_forget_clears_state() -> void:
	var lim = _MRL.new()
	assert_true(lim.allow(7, 100.0, 100))
	lim.forget(7)
	assert_true(lim.allow(7, 100.0, 101), "forgotten peer starts a fresh window")
