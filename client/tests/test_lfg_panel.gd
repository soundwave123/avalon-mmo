extends "res://addons/gut/test.gd"
# T-625: LfgPanel — the deferred client half of T-334. Server-fed board render, the flag/unflag
# toggle reconciled from the ack, and the desire-only party invite off a row. The panel never grants
# itself anything: every button/link emits an INTENT the server re-validates.

var _panel: LfgPanel = null
var _sent: Array = []
var _typing := false
var _level := 7


func before_each() -> void:
	_panel = LfgPanel.new()
	add_child(_panel)
	await get_tree().process_frame
	_sent = []
	_typing = false
	_level = 7
	_panel.setup(func(msg): _sent.append(msg), func(): return _typing, func(): return _level)


func after_each() -> void:
	_panel.queue_free()


func _board(rows: Array = []) -> Dictionary:
	return {"type": "lfg_board", "intent": "lfg_list", "ok": true, "reason": "", "board": rows}


func _u_key() -> InputEventKey:
	var ev := InputEventKey.new()
	ev.keycode = KEY_U
	ev.physical_keycode = KEY_U
	ev.pressed = true
	return ev


# ---- build + idle presence ----


func test_panel_builds_hidden_with_a_flag_toggle() -> void:
	assert_false(_panel.visible, "the panel starts hidden")
	assert_not_null(_panel.find_child("LfgFlagToggle", true, false), "the flag toggle exists")
	assert_true(_panel.body_text().contains("Looking for Group"), "the board header renders")


func test_idle_root_mouse_filter_is_ignore() -> void:
	# T-606: the panel's transparent margin must never eat a world click (the SolidWindow frame below
	# still catches clicks on the open window itself — Godot hit-tests children under an IGNORE root).
	assert_eq(
		_panel.mouse_filter,
		Control.MOUSE_FILTER_IGNORE,
		"the panel root is click-through so it never eats a world click when idle"
	)


# ---- flag / unflag toggle ----


func test_flag_button_sends_lfg_flag_with_the_live_level() -> void:
	_level = 12
	_panel._toggle_flag()
	assert_eq(str(_sent[0]["type"]), "lfg_flag")
	assert_eq(int(_sent[0]["level"]), 12, "the flag carries the player's real level as the hint")
	assert_false(_sent[0].has("role"), "the client never claims a role — the server derives it")


func test_flag_ack_flips_the_toggle_and_unflag_reverses_it() -> void:
	_panel._toggle_flag()
	_panel.receive({"type": "lfg_board", "intent": "lfg_flag", "ok": true, "board": []})
	assert_true(_panel.is_flagged(), "a successful flag ack marks us on the board")
	var btn := _panel.find_child("LfgFlagToggle", true, false) as Button
	assert_eq(btn.text, "Unflag", "the toggle now offers to unflag")
	_panel._toggle_flag()
	assert_eq(str(_sent[1]["type"]), "lfg_unflag", "flagged -> the toggle sends unflag")
	_panel.receive({"type": "lfg_board", "intent": "lfg_unflag", "ok": true, "board": []})
	assert_false(_panel.is_flagged(), "the unflag ack clears the local flag")
	assert_eq(btn.text, "Flag as LFG", "the toggle returns to offering a flag")


func test_flag_rejection_shows_status_without_flipping_the_toggle() -> void:
	_panel.receive(
		{"type": "lfg_board", "intent": "lfg_flag", "ok": false, "reason": "in_party", "board": []}
	)
	assert_false(_panel.is_flagged(), "a rejected flag does not mark us on the board")
	var status := _panel.find_child("LfgStatus", true, false) as Label
	assert_true(status.text.contains("in_party"), "the rejection surfaces as status text")


# ---- board render + invite ----


func test_board_reply_renders_name_level_and_role_rows() -> void:
	(
		_panel
		. receive(
			_board(
				[
					{"peer": 3, "name": "Borin", "level": 7, "role": "tank"},
					{"peer": 5, "name": "Wisp", "level": 9, "role": "heal"},
				]
			)
		)
	)
	var t := _panel.body_text()
	assert_true(t.contains("Borin"), "the first flagged player's name renders")
	assert_true(t.contains("L7"), "its level renders")
	assert_true(t.contains("tank"), "its role renders")
	assert_true(t.contains("Wisp") and t.contains("heal"), "the second row renders too")
	assert_true(t.contains("[url=invite|Borin]"), "each row exposes an invite link")


func test_empty_board_shows_a_be_the_first_prompt() -> void:
	_panel.receive(_board([]))
	assert_true(_panel.body_text().contains("be the first"), "an empty board invites flagging")


func test_invite_link_fires_the_normal_party_invite() -> void:
	_panel.receive(_board([{"peer": 3, "name": "Borin", "level": 7, "role": "tank"}]))
	_panel._on_meta("invite|Borin")
	assert_eq(
		_sent[0], {"type": "party_invite", "target": "Borin"}, "invite reuses T-280 party path"
	)


func test_non_lfg_board_messages_are_ignored() -> void:
	_panel.receive({"type": "social_list", "friends": [], "ignored": []})
	assert_true(_panel.body_text().contains("Looking for Group"), "render stays on the empty board")


# ---- open request + typing gate ----


func test_opening_the_panel_requests_the_board() -> void:
	_panel.toggle()
	assert_true(_panel.visible)
	assert_eq(str(_sent[0]["type"]), "lfg_list", "opening refreshes the board from the server")


func test_u_opens_the_panel_when_not_typing() -> void:
	_panel._input(_u_key())
	assert_true(_panel.visible, "U toggles the panel open")
	assert_eq(str(_sent[0]["type"]), "lfg_list")


func test_u_does_not_fire_while_chat_holds_the_keyboard() -> void:
	_typing = true
	_panel._input(_u_key())
	assert_false(_panel.visible, "U is inert while typing so the key reaches the chat field")
	assert_eq(_sent.size(), 0, "and no board request is sent")


func test_close_button_hides_the_window() -> void:
	_panel.visible = true
	var close := _panel.find_child("LfgClose", true, false) as Button
	assert_not_null(close, "the title bar carries a close button")
	close.pressed.emit()
	assert_false(_panel.visible, "clicking close hides the LFG window")


# ---- T-608: the open panel clears the standing HUD chrome at 1280x720 ----


func test_open_panel_clears_the_hud_safe_zone() -> void:
	# T-747: sized from the LIVE content rect, not a literal or even the constants — the client
	# really does run at this base now, so this asserts clearance at the real default.
	UiViewport.normalize_headless(self)
	await get_tree().process_frame
	var root := Control.new()
	root.size = get_tree().root.get_visible_rect().size
	add_child_autofree(root)
	_panel.get_parent().remove_child(_panel)
	root.add_child(_panel)
	_panel.visible = true
	await get_tree().process_frame
	await get_tree().process_frame
	var rect := _panel.get_global_rect()
	assert_false(HudSafeZone.intersects_vitals(rect), "clears the Vitals frame")
	assert_false(HudSafeZone.intersects_action_bar(rect), "clears the hotbar")
	assert_false(HudSafeZone.intersects_compass(rect), "clears the compass strip")
	# Restore ownership so after_each's plain queue_free doesn't race root's autofree cascade.
	root.remove_child(_panel)
	add_child(_panel)


# ---- T-755: BBCode injection through a board name ------------------------------
#
# bbcode_enabled label + meta_clicked -> party_invite. A board row is the one place this panel
# renders another player's identity, so it is the one place the escape has to hold.
func test_hostile_board_name_renders_literally_and_forges_no_invite_link() -> void:
	(
		_panel
		. receive(
			_board(
				[
					{"name": "[url=invite|victim]join[/url]", "level": 10, "role": "tank"},
					{"name": "honest", "level": 11, "role": "heal"},
				]
			)
		)
	)
	var body := _panel.body_text()
	assert_eq(body.count("[url=invite|"), 2, "one live invite link per row, no forged extras")
	var rtl := RichTextLabel.new()
	rtl.bbcode_enabled = true
	add_child_autofree(rtl)
	rtl.text = body
	var parsed := rtl.get_parsed_text()
	assert_string_contains(parsed, "[url=invite|victim]join[/url]", "the name renders as text")
	assert_string_contains(parsed, "honest", "the row below is not swallowed")
