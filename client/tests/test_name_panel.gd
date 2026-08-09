extends "res://addons/gut/test.gd"

# T-716: shared module — preloaded, never class_name (its copies would collide).
const CharacterName = preload("res://scripts/ui/character_name.gd")
# T-716: NamePanel — the creation NAME modal (gender -> class -> NAME -> handbook). The two things
# that must never regress here are (a) hotkeys can't fire while the player is typing (T-513/T-504)
# and (b) hiding the panel RELEASES focus, or a focused LineEdit keeps UiInputGate.is_text_input_
# focused true and kills every hotkey client-wide with no way out but a relog (the s15 GuildPanel
# focus trap).

var _panel: NamePanel = null


func before_each() -> void:
	_panel = NamePanel.new()
	add_child(_panel)
	await get_tree().process_frame


func after_each() -> void:
	_panel.queue_free()


func test_starts_hidden_with_a_field_and_a_confirm_button() -> void:
	assert_false(_panel.visible, "shown only when the flow says the name step is owed")
	assert_not_null(_panel.get_field(), "a free-type field")
	assert_not_null(_panel.get_confirm_button(), "and an explicit confirm affordance")
	assert_eq(_panel.get_field().max_length, CharacterName.MAX_LENGTH, "field caps at the rule")


# T-513 class of bug: while a creation modal is up, world hotkeys must stand down. Group membership
# is what UiInputGate reads, and it is what lets this panel keep normal typing (unlike ClassPanel,
# which swallows keys outright — it would eat the player's letters).
func test_is_a_blocking_modal_so_hotkeys_stand_down_while_typing() -> void:
	assert_true(_panel.is_in_group("ui_blocking_modal"), "UiInputGate silences hotkeys off this")
	_panel.visible = true
	await get_tree().process_frame
	assert_true(
		UiInputGate.is_text_input_focused(get_viewport()), "typing owns the keyboard, not the world"
	)


# The s15 focus-trap lesson, asserted: hiding must hand the keyboard back.
func test_hiding_releases_focus_so_hotkeys_come_back() -> void:
	_panel.visible = true
	await get_tree().process_frame
	assert_true(_panel.get_field().has_focus(), "the caret is in the field the moment it opens")
	_panel.visible = false
	await get_tree().process_frame
	assert_false(_panel.get_field().has_focus(), "no orphaned LineEdit focus after the step")
	assert_false(
		UiInputGate.is_text_input_focused(get_viewport()), "hotkeys work again — no relog needed"
	)


func test_suggestion_prefills_once_and_never_overwrites_typing() -> void:
	_panel.set_suggestion("steamfresh")
	assert_eq(_panel.get_field().text, "steamfresh", "the account name is the default offer")
	_panel.get_field().text = "aldric"
	_panel.set_suggestion("steamfresh")  # a later player_stats resend
	assert_eq(_panel.get_field().text, "aldric", "a resend must not wipe a half-typed name")


func test_confirm_emits_the_normalised_set_name_meta() -> void:
	var got: Array = []
	_panel.action_selected.connect(func(meta): got.append(meta))
	_panel.get_field().text = "  Aldric  "
	_panel.get_confirm_button().pressed.emit()
	assert_eq(got, ["set_name|aldric"], "trimmed + case-folded before it leaves the client")


func test_obviously_bad_name_is_rejected_locally_with_plain_english() -> void:
	var got: Array = []
	_panel.action_selected.connect(func(meta): got.append(meta))
	_panel.get_field().text = "ab"
	_panel.get_confirm_button().pressed.emit()
	assert_eq(got, [], "no round trip for a name the rules already reject")
	assert_string_contains(_panel.get_error_text(), "too short")


# The acceptance case: a DUPLICATE name can only be caught by the server, so the rejection has to
# arrive as an ack — and it must read as English and leave the player able to retry immediately.
func test_duplicate_name_ack_shows_plain_english_and_keeps_the_step_open() -> void:
	_panel.visible = true
	await get_tree().process_frame
	_panel.on_result({"ok": false, "reason": "name_taken"})
	assert_eq(_panel.get_error_text(), "Someone already goes by that name. Pick another.")
	assert_true(_panel.visible, "the step stays up so 'try another' is one keystroke away")
	assert_true(_panel.get_field().has_focus(), "and the field is handed straight back")


func test_unknown_rejection_reason_degrades_to_an_honest_sentence() -> void:
	_panel.on_result({"ok": false, "reason": "wat"})
	assert_eq(_panel.get_error_text(), "That name couldn't be set. Try another.")


# T-718: the confirm click is routed at the _input stage so no later full-rect sibling can eat it
# (GUI picking goes by tree order, not z_index) — but ONLY that click, because the LineEdit needs
# the normal GUI path for its caret.
func test_confirm_click_survives_a_full_rect_overlay_but_field_clicks_pass_through() -> void:
	var blocker := ColorRect.new()
	blocker.set_anchors_preset(Control.PRESET_FULL_RECT)
	blocker.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(blocker)
	_panel.visible = true
	await get_tree().process_frame
	var got: Array = []
	_panel.action_selected.connect(func(meta): got.append(meta))
	_panel.get_field().text = "aldric"
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = true
	event.position = _panel.get_confirm_button().get_global_rect().get_center()
	_panel._input(event)
	assert_eq(got, ["set_name|aldric"], "confirm works under an overlay")
	var on_field := InputEventMouseButton.new()
	on_field.button_index = MOUSE_BUTTON_LEFT
	on_field.pressed = true
	on_field.position = _panel.get_field().get_global_rect().get_center()
	_panel._input(on_field)
	assert_eq(got.size(), 1, "a click in the text field is left to the normal GUI path")
	blocker.queue_free()
