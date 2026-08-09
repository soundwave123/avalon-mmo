extends GutTest

const Countdown = preload("res://scripts/maintenance_countdown.gd")


func test_ten_minute_schedule_has_required_beats_and_zero() -> void:
	assert_eq(Countdown.schedule(600), [600, 300, 120, 60, 30, 0])


func test_short_custom_duration_announces_immediately_then_standard_beats() -> void:
	assert_eq(Countdown.schedule(180), [180, 120, 60, 30, 0])


func test_advance_emits_each_crossed_beat_once() -> void:
	var countdown = Countdown.new()
	assert_eq(countdown.start(10, "database maintenance")["remaining_seconds"], 600)
	assert_eq(countdown.advance(300.0).map(func(e): return e["remaining_seconds"]), [300])
	assert_eq(countdown.advance(180.0).map(func(e): return e["remaining_seconds"]), [120])
	assert_eq(countdown.advance(60.0).map(func(e): return e["remaining_seconds"]), [60])
	assert_eq(countdown.advance(30.0).map(func(e): return e["remaining_seconds"]), [30])
	assert_eq(countdown.advance(30.0).map(func(e): return e["remaining_seconds"]), [0])
	assert_false(countdown.is_active())
	assert_true(countdown.advance(60.0).is_empty(), "finished countdown never repeats zero")


func test_current_notice_can_seed_a_player_who_logs_in_mid_countdown() -> void:
	var countdown = Countdown.new()
	countdown.start(5, "routine restart")
	countdown.advance(61.0)
	var notice: Dictionary = countdown.current_notice()
	assert_eq(int(notice["remaining_seconds"]), 239)
	assert_eq(str(notice["reason"]), "routine restart")
	assert_eq(str(notice["type"]), "maintenance")
