extends "res://addons/gut/test.gd"
# T-065: ClassPanel — real Buttons (click affordance + keyboard), one-shot class selection.

var _panel: ClassPanel = null


func before_each() -> void:
	_panel = ClassPanel.new()
	add_child(_panel)
	await get_tree().process_frame


func after_each() -> void:
	_panel.queue_free()


func test_starts_hidden_with_three_class_buttons() -> void:
	assert_false(_panel.visible)
	assert_eq(_panel.get_buttons().size(), 3, "one button per class")
	for cls in ["Warrior", "Mage", "Priest"]:
		assert_string_contains(_panel.get_text(), cls)


func test_button_press_emits_set_class_action() -> void:
	var got: Array = []
	_panel.action_selected.connect(func(meta): got.append(meta))
	(_panel.get_buttons()[1] as Button).pressed.emit()
	assert_eq(got, ["set_class|mage"])


func test_first_button_grabs_focus_when_shown() -> void:
	_panel.visible = true
	await get_tree().process_frame
	var first: Button = _panel.get_buttons()[0]
	assert_true(first.has_focus(), "keyboard (arrows + Enter) must work immediately")


# T-400: migrated off the hand-rolled ColorRect box onto the theme's SolidWindow frame (T-396 seam).
func test_uses_solidwindow_frame_not_colorrect() -> void:
	assert_not_null(_panel.theme, "carries the shared UiTheme so SolidWindow resolves")
	var frame := _panel.get_node_or_null("Frame") as PanelContainer
	assert_not_null(frame, "a PanelContainer frame roots the window")
	assert_eq(frame.theme_type_variation, &"SolidWindow", "opaque deliberate-window variation")
	var vbox := frame.get_child(0) as VBoxContainer
	assert_not_null(vbox, "the class-button column is parented into the frame")
	assert_eq(
		(_panel.get_buttons()[0] as Button).get_parent(), vbox, "buttons live under the frame"
	)
	# T-400: the hand-rolled CONTENT box is gone (the frame is a SolidWindow PanelContainer).
	# T-512: a full-screen dim "Shade" ColorRect is allowed — it's the modal backdrop, not the box.
	for child in _panel.get_children():
		if child is ColorRect:
			assert_eq(child.name, &"Shade", "the only ColorRect is the T-512 modal shade")


# T-512: the panel is a true blocking modal — full-rect, topmost, in the input-gate group, so its
# keys/clicks can't leak to the world (the fresh-account "Enter opened chat / clicks did nothing").
func test_is_a_blocking_input_modal() -> void:
	assert_eq(_panel.anchor_right, 1.0, "full-rect so its shade covers the screen")
	assert_eq(_panel.anchor_bottom, 1.0, "full-rect vertically too")
	assert_eq(
		_panel.mouse_filter, Control.MOUSE_FILTER_STOP, "off-button clicks are eaten, not leaked"
	)
	assert_gt(_panel.z_index, 0, "renders above the other HUD panels")
	assert_true(
		_panel.is_in_group("ui_blocking_modal"), "registered so UiInputGate silences hotkeys"
	)
	var shade := _panel.get_node_or_null("Shade") as ColorRect
	assert_not_null(shade, "a full-screen shade backs the modal")
	assert_eq(shade.mouse_filter, Control.MOUSE_FILTER_STOP, "the shade eats background clicks")


# ---- T-718 (portal #108): the click path must be identical to the key path -----------------------


func _left_click_at(pos: Vector2) -> InputEventMouseButton:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = true
	event.position = pos
	return event


# The regression: GUI mouse picking goes by TREE ORDER and ignores z_index, so a later full-rect
# MOUSE_FILTER_STOP sibling used to swallow the press — no set_class intent was ever sent and the
# panel stayed up (only a following 1/2/3 key press completed creation). Routing the click through
# _input (the stage the keys already own) makes an overlay irrelevant.
func test_click_on_a_row_emits_set_class_even_under_a_full_rect_overlay() -> void:
	var blocker := ColorRect.new()  # added AFTER the panel => it wins GUI picking
	blocker.set_anchors_preset(Control.PRESET_FULL_RECT)
	blocker.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(blocker)
	_panel.visible = true
	await get_tree().process_frame
	var got: Array = []
	_panel.action_selected.connect(func(meta): got.append(meta))
	var row: Button = _panel.get_buttons()[1]  # mage
	_panel._input(_left_click_at(row.get_global_rect().get_center()))
	assert_eq(got, ["set_class|mage"], "a click sends exactly what pressing 2 sends")
	blocker.queue_free()


func test_click_dispatches_once_and_marks_the_event_handled() -> void:
	_panel.visible = true
	await get_tree().process_frame
	var got: Array = []
	_panel.action_selected.connect(func(meta): got.append(meta))
	var row: Button = _panel.get_buttons()[0]
	_panel._input(_left_click_at(row.get_global_rect().get_center()))
	assert_eq(got.size(), 1, "one click == one intent (gui_input must never re-fire it)")
	assert_true(get_viewport().is_input_handled(), "handled, so the Button can't dispatch it again")


func test_click_that_misses_every_row_selects_nothing_and_is_not_swallowed() -> void:
	_panel.visible = true
	await get_tree().process_frame
	var got: Array = []
	_panel.action_selected.connect(func(meta): got.append(meta))
	var away: Vector2 = (
		(_panel.get_buttons()[2] as Button).get_global_rect().end + Vector2(600, 600)
	)
	_panel._input(_left_click_at(away))  # the shade, well clear of every row
	# A miss picks nothing AND is left unhandled (see _route_mouse) so an illegally-stacked surface
	# above the modal stays closable by mouse; the shade's MOUSE_FILTER_STOP still eats it normally.
	assert_eq(got, [], "an off-row click picks no class")


func test_click_is_inert_while_the_panel_is_hidden() -> void:
	var got: Array = []
	_panel.action_selected.connect(func(meta): got.append(meta))
	var row: Button = _panel.get_buttons()[0]
	_panel._input(_left_click_at(row.get_global_rect().get_center()))
	assert_eq(got, [], "a hidden creation modal owns no input at all")


# The picking half: the modal is built early in $HUD, so it re-orders itself last while it is up.
func test_showing_the_panel_raises_it_above_later_siblings() -> void:
	var later := Control.new()
	add_child(later)
	assert_ne(get_children()[-1], _panel, "precondition: a later sibling sits above the panel")
	_panel.visible = true
	await get_tree().process_frame
	assert_eq(get_children()[-1], _panel, "shown => topmost for GUI picking, not just for drawing")
	later.queue_free()
