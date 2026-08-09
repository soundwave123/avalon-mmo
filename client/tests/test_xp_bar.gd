extends "res://addons/gut/test.gd"
# T-060: XpBar — renders the peer-only player_stats payload.

var _bar: XpBar = null


func before_each() -> void:
	_bar = XpBar.new()
	add_child(_bar)
	await get_tree().process_frame


func after_each() -> void:
	_bar.queue_free()


func test_update_sets_level_fill_and_text() -> void:
	_bar.update_stats({"level": 3, "xp_into_level": 150, "xp_for_next_level": 300})
	assert_eq(_bar.get_level(), 3)
	assert_almost_eq(_bar.get_fill(), 0.5, 0.001)
	assert_eq(_bar.get_text(), "Lv 3  150/300 XP")


func test_max_level_renders_full_bar() -> void:
	_bar.update_stats({"level": 15, "xp_into_level": 0, "xp_for_next_level": 0})
	assert_almost_eq(_bar.get_fill(), 1.0, 0.001)
	assert_string_contains(_bar.get_text(), "(max)")


func test_level_up_resets_progress() -> void:
	_bar.update_stats({"level": 2, "xp_into_level": 190, "xp_for_next_level": 200})
	_bar.update_stats({"level": 3, "xp_into_level": 10, "xp_for_next_level": 300})
	assert_eq(_bar.get_level(), 3)
	assert_true(_bar.get_fill() < 0.1, "bar resets after a level-up")


# T-360: a rested pool tints the bar + appends a "zzz N" readout; zero rest shows neither.
func test_rested_band_shows_when_banked() -> void:
	_bar.update_stats(
		{"level": 3, "xp_into_level": 150, "xp_for_next_level": 300, "rested_remaining": 120}
	)
	assert_eq(_bar.get_rested(), 120)
	assert_string_contains(_bar.get_text(), "zzz 120")


func test_no_rested_band_when_empty() -> void:
	_bar.update_stats({"level": 3, "xp_into_level": 150, "xp_for_next_level": 300})
	assert_eq(_bar.get_rested(), 0)
	assert_eq(_bar.get_text(), "Lv 3  150/300 XP", "no rested tag when the pool is empty")


# T-400: the belt reads as translucent glass (not the opaque navy panel-fill the judge flagged) and
# its text is outlined like the rest of the standing HUD.
func test_belt_is_translucent_and_outlined() -> void:
	var pb: ProgressBar = _bar._bar
	var bg := pb.get_theme_stylebox("background") as StyleBoxFlat
	assert_not_null(bg, "bar carries an own background stylebox override")
	assert_lt(bg.bg_color.a, 1.0, "trough is translucent glass, not an opaque fill")
	var fill := pb.get_theme_stylebox("fill") as StyleBoxFlat
	assert_lt(fill.bg_color.a, 1.0, "fill is translucent")
	var lbl: Label = _bar._label
	assert_gt(lbl.get_theme_constant("outline_size"), 0, "label text is outlined like the HUD")


# T-400: the normal/rested cue now rides the fill colour (node modulate stays neutral).
func test_rested_tints_fill_blue() -> void:
	_bar.update_stats({"level": 3, "xp_into_level": 150, "xp_for_next_level": 300})
	assert_almost_eq(_bar._fill_sb.bg_color.b, XpBar._XP_NORMAL.b, 0.01, "normal XP is purple")
	_bar.update_stats(
		{"level": 3, "xp_into_level": 150, "xp_for_next_level": 300, "rested_remaining": 80}
	)
	assert_almost_eq(
		_bar._fill_sb.bg_color.b, XpBar._XP_RESTED.b, 0.01, "rested tints the fill blue"
	)
	assert_almost_eq(_bar.modulate.a, 1.0, 0.001, "colour rides the fill stylebox, not modulate")
