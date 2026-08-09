extends "res://addons/gut/test.gd"
# T-520: GenderPanel — a TRUE blocking modal (mirrors ClassPanel) with real Female/Male Buttons that
# emit the set_gender intent. Shown FIRST at character creation, before the class panel.

var _panel: GenderPanel = null


func before_each() -> void:
	_panel = GenderPanel.new()
	add_child(_panel)
	await get_tree().process_frame


func after_each() -> void:
	_panel.queue_free()


func test_starts_hidden_with_two_gender_buttons() -> void:
	assert_false(_panel.visible)
	assert_eq(_panel.get_buttons().size(), 2, "one button per gender (female / male)")
	for label in ["Female", "Male"]:
		assert_string_contains(_panel.get_text(), label)


func test_button_press_emits_set_gender_action() -> void:
	var got: Array = []
	_panel.action_selected.connect(func(meta): got.append(meta))
	(_panel.get_buttons()[0] as Button).pressed.emit()
	(_panel.get_buttons()[1] as Button).pressed.emit()
	assert_eq(got, ["set_gender|female", "set_gender|male"])


func test_first_button_grabs_focus_when_shown() -> void:
	_panel.visible = true
	await get_tree().process_frame
	assert_true(
		(_panel.get_buttons()[0] as Button).has_focus(),
		"keyboard (arrows + Enter) works immediately"
	)


# The panel is a true blocking modal — full-rect, topmost, in the input-gate group, with a shade —
# so its keys/clicks can't leak to the world (the fresh-account "Enter opened chat" failure mode).
func test_is_a_blocking_input_modal() -> void:
	assert_eq(_panel.anchor_right, 1.0, "full-rect so its shade covers the screen")
	assert_eq(_panel.anchor_bottom, 1.0, "full-rect vertically too")
	assert_eq(_panel.mouse_filter, Control.MOUSE_FILTER_STOP, "off-button clicks are eaten")
	assert_gt(_panel.z_index, 0, "renders above the other HUD panels")
	assert_true(
		_panel.is_in_group("ui_blocking_modal"), "registered so UiInputGate silences hotkeys"
	)
	var shade := _panel.get_node_or_null("Shade") as ColorRect
	assert_not_null(shade, "a full-screen shade backs the modal")
	assert_eq(shade.mouse_filter, Control.MOUSE_FILTER_STOP, "the shade eats background clicks")


# T-520: uses the SolidWindow frame (the T-396 seam) — the only ColorRect is the modal shade.
func test_uses_solidwindow_frame() -> void:
	assert_not_null(_panel.theme, "carries the shared UiTheme so SolidWindow resolves")
	var frame := _panel.get_node_or_null("Frame") as PanelContainer
	assert_not_null(frame, "a PanelContainer frame roots the window")
	assert_eq(frame.theme_type_variation, &"SolidWindow", "opaque deliberate-window variation")
	for child in _panel.get_children():
		if child is ColorRect:
			assert_eq(child.name, &"Shade", "the only ColorRect is the modal shade")


# T-535: the T-526 "both share one body for now" honesty note is REMOVED — gender now visibly
# drives a distinct female hero body (char_hero_<class>_female.glb), so the caveat is obsolete and
# must not reappear (a stale "coming soon" note would now be a lie).
func test_shared_body_note_is_gone() -> void:
	var note := _panel.find_child("Note", true, false)
	assert_null(note, "the obsolete T-526 shared-body note is removed")


# ---- T-718 (portal #108): the click path must be identical to the key path -----------------------
# ClassPanel is where this was caught live; GenderPanel is structurally identical and carried the
# same latent bug (GUI mouse picking resolves by tree order and ignores z_index).


func _left_click_at(pos: Vector2) -> InputEventMouseButton:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = true
	event.position = pos
	return event


func test_click_on_a_row_emits_set_gender_even_under_a_full_rect_overlay() -> void:
	var blocker := ColorRect.new()  # added AFTER the panel => it wins GUI picking
	blocker.set_anchors_preset(Control.PRESET_FULL_RECT)
	blocker.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(blocker)
	_panel.visible = true
	await get_tree().process_frame
	var got: Array = []
	_panel.action_selected.connect(func(meta): got.append(meta))
	var row: Button = _panel.get_buttons()[0]  # female
	_panel._input(_left_click_at(row.get_global_rect().get_center()))
	assert_eq(got, ["set_gender|female"], "a click sends exactly what pressing 1 sends")
	blocker.queue_free()


func test_showing_the_panel_raises_it_above_later_siblings() -> void:
	var later := Control.new()
	add_child(later)
	_panel.visible = true
	await get_tree().process_frame
	assert_eq(get_children()[-1], _panel, "shown => topmost for GUI picking, not just for drawing")
	later.queue_free()
