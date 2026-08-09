extends GutTest

# T-734: the client half of the server-authoritative day clock — wrap math, join snap,
# rate-capped slew, and the AVALON_FREEZE_DAY precedence on WorldView itself.

const DayClockSync = preload("res://scripts/world/day_clock_sync.gd")
const WorldView = preload("res://scripts/world/world_view.gd")


func test_wrapped_err_is_shortest_signed_distance_across_midnight() -> void:
	assert_almost_eq(DayClockSync.wrapped_err(0.01, 0.99), 0.02, 0.000001)  # forward over wrap
	assert_almost_eq(DayClockSync.wrapped_err(0.99, 0.01), -0.02, 0.000001)  # backward over wrap
	assert_almost_eq(DayClockSync.wrapped_err(0.30, 0.25), 0.05, 0.000001)  # plain forward
	assert_almost_eq(DayClockSync.wrapped_err(0.25, 0.30), -0.05, 0.000001)  # plain backward


func test_first_server_value_snaps_unconditionally() -> void:
	var sync = DayClockSync.new()
	assert_almost_eq(sync.on_server_day_t(0.7, 0.3), 0.7, 0.000001)  # the join case


func test_negative_means_no_value_and_is_ignored() -> void:
	var sync = DayClockSync.new()
	assert_almost_eq(sync.on_server_day_t(-1.0, 0.3), 0.3, 0.000001)  # older server: free-run


func test_big_drift_snaps_small_drift_slews() -> void:
	var sync = DayClockSync.new()
	sync.on_server_day_t(0.30, 0.30)  # synced
	# Small drift: local value is NOT snapped; the error drains through advance() instead.
	assert_almost_eq(sync.on_server_day_t(0.31, 0.30), 0.30, 0.000001)
	# Big drift (a suspended client): snap.
	assert_almost_eq(sync.on_server_day_t(0.50, 0.30), 0.50, 0.000001)


func test_advance_free_runs_at_the_shared_rate_when_in_sync() -> void:
	var sync = DayClockSync.new()
	# 12 s of a 1200 s day = 0.01 — identical to the old client fmod walk.
	assert_almost_eq(sync.advance(0.25, 12.0), 0.26, 0.000001)


func test_advance_slew_is_rate_capped_and_converges_without_overshoot() -> void:
	var sync = DayClockSync.new()
	sync.on_server_day_t(0.300, 0.300)
	sync.on_server_day_t(0.302, 0.300)  # +0.002 of drift to drain (2.4 s of game time)
	var t := 0.300
	var step := 1.0 / 60.0  # one 60 fps frame
	var base: float = step / DayClockSync.DAY_SECONDS
	var max_per_frame: float = base * (1.0 + DayClockSync.CORR_RATE_MULT)
	var total_base := 0.0
	for _i in range(60 * 90):  # 90 s of frames — plenty to converge
		var before := t
		t = sync.advance(t, step)
		assert_true(t - before <= max_per_frame + 0.0000001, "per-frame slew exceeds the cap")
		total_base += base
	# All drift drained: local == where a perfect clock (start + drift + elapsed) would be.
	assert_almost_eq(t, 0.302 + total_base, 0.000001)


func test_advance_corrects_backward_drift_without_reversing_the_sun() -> void:
	var sync = DayClockSync.new()
	sync.on_server_day_t(0.300, 0.300)
	sync.on_server_day_t(0.298, 0.300)  # server is BEHIND: sun must slow, never run backward
	var t := 0.300
	var step := 1.0 / 60.0
	for _i in range(60 * 90):
		var before := t
		t = sync.advance(t, step)
		assert_true(t >= before - 0.0000001, "sun ran backward during a small correction")
	assert_almost_eq(t, 0.298 + (60.0 * 90.0) * (step / DayClockSync.DAY_SECONDS), 0.000001)


func test_freeze_day_precedence_server_sync_is_ignored_while_frozen() -> void:
	var wv = WorldView.new()  # never enters the tree: no _ready, just the sync seam
	wv._day_frozen = true
	wv._day_t = 0.25  # the QA noon pin (T-415 convention)
	wv.server_day_sync(0.9)
	assert_almost_eq(wv._day_t, 0.25, 0.000001)  # AVALON_FREEZE_DAY beats server truth
	wv._day_frozen = false
	wv.server_day_sync(0.9)
	assert_almost_eq(wv._day_t, 0.9, 0.000001)  # unfrozen: first server value snaps (join)
	wv.free()
