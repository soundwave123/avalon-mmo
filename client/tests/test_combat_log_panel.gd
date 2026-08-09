extends "res://addons/gut/test.gd"
# T-027 §4: CombatLogPanel (RichTextLabel renderer) tests.

var _panel: CombatLogPanel = null


func before_each() -> void:
	_panel = CombatLogPanel.new()
	add_child(_panel)
	await get_tree().process_frame


func after_each() -> void:
	_panel.queue_free()


func test_starts_empty() -> void:
	assert_eq(_panel.get_line_count(), 0)


func test_append_line_increments_count() -> void:
	_panel.append_line("PlayerA hits Mob for 34 damage.", Color.RED)
	assert_eq(_panel.get_line_count(), 1)


func test_append_line_contains_message() -> void:
	_panel.append_line("PlayerA hits Mob for 34 damage.")
	assert_true(_panel.get_text().contains("34 damage"))


func test_append_wraps_in_bbcode_color() -> void:
	_panel.append_line("hit", Color(1, 0, 0))
	assert_true(_panel.get_text().contains("[color=#ff0000]"))


func test_cap_at_max_lines() -> void:
	for i in range(CombatLogPanel.MAX_LINES + 50):
		_panel.append_line("line %d" % i)
	assert_eq(_panel.get_line_count(), CombatLogPanel.MAX_LINES)


func test_oldest_lines_dropped_when_capped() -> void:
	for i in range(CombatLogPanel.MAX_LINES + 50):
		_panel.append_line("line %d" % i)
	var text: String = _panel.get_text()
	# 250 lines, cap 200 → lines 0..49 dropped, 50..249 retained.
	assert_false(text.contains("line 49[/color]"), "line 49 should be dropped")
	assert_true(text.contains("line 50[/color]"), "line 50 should be retained")
	assert_true(text.contains("line 249[/color]"), "newest line should be retained")


func test_clear_empties_panel() -> void:
	_panel.append_line("something")
	_panel.clear()
	assert_eq(_panel.get_line_count(), 0)


func test_bind_renders_combat_log_entries() -> void:
	var log := CombatLog.new()
	add_child(log)
	await get_tree().process_frame
	_panel.bind(log)
	log.add_entry("bound entry", Color.YELLOW)
	assert_true(_panel.get_text().contains("bound entry"))
	log.queue_free()


# T-396: the log is born invisible (no empty framed box on the idle HUD) and wakes on a line.
func test_born_silent_and_wakes_on_line() -> void:
	assert_eq(_panel.modulate.a, 0.0, "empty log renders nothing")
	_panel.append_line("You hit the wolf for 7.")
	await get_tree().process_frame
	assert_gt(_panel.modulate.a, 0.5, "a combat line wakes the log")


# T-400: apply_frame sizes the visible text rect to a WHOLE number of lines so the top line can
# never clip mid-glyph. Assert the clipped height is an exact multiple of the theme's line pitch.
func test_apply_frame_snaps_to_whole_line_multiple() -> void:
	_panel.theme = UiTheme.build()  # real font/size so the pitch matches production
	_panel.apply_frame()
	var pitch: float = _panel.get_line_pitch()
	var visible: float = _panel.get_visible_text_height()
	assert_gt(pitch, 0.0, "line pitch resolves from the theme font")
	assert_almost_eq(fmod(visible, pitch), 0.0, 0.01, "visible text rect is a whole-line multiple")
	assert_gt(visible, 0.0, "the log still shows several lines")


# T-400: the presence-fade behaviour is untouched by the resize (born silent, still wakes).
func test_apply_frame_keeps_presence_fade() -> void:
	_panel.theme = UiTheme.build()
	_panel.apply_frame()
	assert_eq(_panel.modulate.a, 0.0, "still born silent after framing")
	_panel.append_line("You hit the wolf for 7.")
	await get_tree().process_frame
	assert_gt(_panel.modulate.a, 0.5, "still wakes on a line")


# ---- T-465: the combat log adopts the chat chrome — no opaque box, idle fade ------------------


func test_apply_frame_carries_no_opaque_box() -> void:
	_panel.theme = UiTheme.build()
	_panel.apply_frame()
	var frame := _panel.get_node("LogFrame") as PanelContainer
	var sb := frame.get_theme_stylebox("panel")
	assert_true(sb is StyleBoxEmpty, "the log surface has no StyleBoxFlat fill or border at all")


func test_apply_frame_backdrop_is_the_chat_gradient() -> void:
	_panel.theme = UiTheme.build()
	_panel.apply_frame()
	var backdrop := _panel.get_node("LogGradient") as TextureRect
	assert_not_null(backdrop, "a subtle gradient sits behind the log lines (chat idiom)")
	assert_true(backdrop.texture is GradientTexture2D, "gradient, not a filled box")
	assert_lte(
		backdrop.modulate.a,
		ChatPresence.BG_IDLE_ALPHA + 0.001,
		"backdrop stays at the chat panel's idle subtlety"
	)


func test_log_fades_out_after_idle_delay() -> void:
	_panel.theme = UiTheme.build()
	_panel.apply_frame()
	_panel.append_line("Wolf hits pilot for 4.", Color.RED)
	_panel._process(0.0)
	assert_gt(_panel.modulate.a, 0.9, "a combat line wakes the surface")
	# Advance the injected clock past the shared idle delay: the surface fades back out.
	_panel._process(ChatPresence.IDLE_FADE_DELAY + 1.0)
	_panel._process(1.0)  # one more tick lets the fade lerp settle at its target
	assert_eq(_panel.modulate.a, 0.0, "silent past the idle delay -> the log is gone, like chat")


func test_new_line_revives_a_faded_log() -> void:
	_panel.append_line("first", Color.RED)
	_panel._process(ChatPresence.IDLE_FADE_DELAY + 1.0)
	_panel._process(1.0)
	assert_eq(_panel.modulate.a, 0.0, "faded out")
	_panel.append_line("second — combat resumed", Color.RED)
	_panel._process(0.0)  # presence snaps awake on the line; the next tick pushes it to the node
	assert_gt(_panel.modulate.a, 0.9, "a fresh combat event snaps the log back in")
