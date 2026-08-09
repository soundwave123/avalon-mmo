extends "res://addons/gut/test.gd"
# T-027 §5: ScreenFlash component tests. Fresh instance per test for state isolation.

var _flash: ScreenFlash = null


func before_each() -> void:
	_flash = ScreenFlash.new()
	add_child(_flash)
	await get_tree().process_frame


func after_each() -> void:
	_flash.queue_free()


func test_idle_initially() -> void:
	assert_false(_flash.is_flashing())
	assert_almost_eq(_flash.get_alpha(), 0.0, 0.001)


func test_flash_sets_flashing_and_peak_alpha() -> void:
	_flash.flash(Color.RED, 0.2, 0.2)
	assert_true(_flash.is_flashing())
	assert_almost_eq(_flash.get_alpha(), 0.2, 0.01)


func test_flash_emits_signal() -> void:
	watch_signals(_flash)
	_flash.flash()
	assert_signal_emitted(_flash, "flash_started")


func test_default_flash_uses_default_peak_alpha() -> void:
	_flash.flash()
	assert_almost_eq(_flash.get_alpha(), ScreenFlash.DEFAULT_PEAK_ALPHA, 0.01)
