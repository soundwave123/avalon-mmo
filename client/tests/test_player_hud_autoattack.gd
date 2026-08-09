extends GutTest

# T-571 (report #26): re-pressing the auto-attack key silently canceled combat because nothing on
# screen showed whether it was already on. PlayerHud.set_autoattack() is the render side of the
# fix — main.gd owns the bool, this only proves the indicator reflects whatever it's told.

const State = preload("res://scripts/ui/autoattack_indicator_state.gd")

var _hud: PlayerHud = null


func before_each() -> void:
	_hud = PlayerHud.new()
	add_child_autofree(_hud)
	await get_tree().process_frame


func test_indicator_exists_and_starts_off() -> void:
	assert_not_null(_hud.autoattack_indicator, "an always-on indicator exists")
	assert_eq(_hud.autoattack_indicator.text, State.OFF_TEXT, "starts OFF (no target yet)")


func test_set_autoattack_true_shows_on_state() -> void:
	_hud.set_autoattack(true)
	assert_eq(_hud.autoattack_indicator.text, State.ON_TEXT)
	assert_eq(
		_hud.autoattack_indicator.get_theme_color("font_color"),
		State.ON_COLOR,
		"ON reads in a distinct color from OFF"
	)


func test_set_autoattack_false_shows_off_state() -> void:
	_hud.set_autoattack(true)
	_hud.set_autoattack(false)
	assert_eq(_hud.autoattack_indicator.text, State.OFF_TEXT)
	assert_eq(_hud.autoattack_indicator.get_theme_color("font_color"), State.OFF_COLOR)


func test_set_autoattack_is_safe_before_ready_indicator_missing() -> void:
	# A HUD never added to the tree (some tests construct main.gd standalone) has no indicator yet
	# — set_autoattack must no-op instead of crashing.
	var bare := PlayerHud.new()
	assert_null(bare.autoattack_indicator, "no _ready() has run yet — nothing built")
	bare.set_autoattack(true)  # must not crash
	assert_null(bare.autoattack_indicator, "still no indicator to update")
	bare.free()
