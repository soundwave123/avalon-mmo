extends "res://addons/gut/test.gd"
# T-027 §6: CastBar component tests. Fresh instance per test for state isolation.

var _bar: CastBar = null


func before_each() -> void:
	_bar = CastBar.new()
	add_child(_bar)
	await get_tree().process_frame


func after_each() -> void:
	_bar.queue_free()


func test_hidden_and_idle_initially() -> void:
	assert_false(_bar.is_casting())
	assert_false(_bar.visible)


func test_start_cast_shows_and_sets_casting() -> void:
	_bar.start_cast(7, 40)
	assert_true(_bar.is_casting())
	assert_true(_bar.visible)
	assert_eq(_bar.get_ability_id(), 7)


func test_start_cast_begins_near_zero_progress() -> void:
	_bar.start_cast(7, 40)
	# Fills over time; immediately after start it should be near 0, not full.
	assert_lt(_bar.get_progress(), 0.5)


func test_cancel_hides_and_stops() -> void:
	_bar.start_cast(7, 40)
	_bar.cancel()
	assert_false(_bar.is_casting())
	assert_false(_bar.visible)


func test_cancel_when_idle_is_noop() -> void:
	_bar.cancel()
	assert_false(_bar.is_casting())


func test_cast_shown_signal_carries_params() -> void:
	watch_signals(_bar)
	_bar.start_cast(3, 20)
	assert_signal_emitted_with_parameters(_bar, "cast_shown", [3, 20])


func test_cast_hidden_signal_on_cancel() -> void:
	_bar.start_cast(3, 20)
	watch_signals(_bar)
	_bar.cancel()
	assert_signal_emitted(_bar, "cast_hidden")


func test_zero_cast_ticks_does_not_crash() -> void:
	_bar.start_cast(1, 0)
	assert_eq(_bar.get_ability_id(), 1)
