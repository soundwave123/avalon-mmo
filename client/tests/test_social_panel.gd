extends "res://addons/gut/test.gd"
# T-361 item 2: SocialPanel — server-fed friends/ignore render, online decoration, and the
# desire-only sends (add/remove/ignore/trade entry point).

var _panel: SocialPanel = null
var _sent: Array = []


func before_each() -> void:
	_panel = SocialPanel.new()
	add_child(_panel)
	await get_tree().process_frame
	_sent = []
	_panel.setup(func(msg): _sent.append(msg))


func after_each() -> void:
	_panel.queue_free()


func _lists() -> Dictionary:
	return {
		"type": "social_list",
		"friends": [{"name": "Bob", "online": true}, {"name": "Zed", "online": false}],
		"ignored": ["Troll"],
	}


func test_renders_friends_with_online_status_and_ignores() -> void:
	_panel.receive(_lists())
	assert_true(_panel.body_text().contains("Bob"))
	assert_true(_panel.body_text().contains("(online)"))
	assert_true(_panel.body_text().contains("Zed"))
	assert_true(_panel.body_text().contains("(offline)"))
	assert_true(_panel.body_text().contains("Troll"))


func test_online_friend_offers_trade_link_offline_does_not() -> void:
	_panel.receive(_lists())
	assert_true(_panel.body_text().contains("[url=trade|Bob]"), "online friend gets [trade]")
	assert_false(_panel.body_text().contains("[url=trade|Zed]"), "offline friend does not")
	_panel._on_meta("trade|Bob")
	assert_eq(str(_sent[0]["type"]), "trade_request")
	assert_eq(str(_sent[0]["target"]), "Bob")


func test_add_and_remove_send_desires_only() -> void:
	_panel._name_box.text = "Carol"
	_panel._named("social_add_friend")
	assert_eq(str(_sent[0]["type"]), "social_add_friend")
	assert_eq(str(_sent[0]["name"]), "Carol")
	assert_eq(_panel._name_box.text, "", "name box clears after sending")
	_panel._on_meta("unignore|Troll")
	assert_eq(str(_sent[1]["type"]), "social_remove_ignore")
	_panel._on_meta("unfriend|Zed")
	assert_eq(str(_sent[2]["type"]), "social_remove_friend")


func test_blank_name_sends_nothing() -> void:
	_panel._name_box.text = "   "
	_panel._named("social_add_friend")
	assert_eq(_sent.size(), 0)


func test_non_list_messages_ignored() -> void:
	_panel.receive({"type": "social_result", "ok": false, "reason": "unknown_target"})
	assert_true(_panel.body_text().contains("(none)"), "render stays on empty lists")


# T-513: playtest — the window had only the O toggle, no visible close. A title-bar [X] hides it.
func test_close_button_hides_the_window() -> void:
	_panel.visible = true
	var close := _panel.find_child("SocialClose", true, false) as Button
	assert_not_null(close, "the title bar carries a close button")
	close.pressed.emit()
	assert_false(_panel.visible, "clicking close hides the friends window")


# T-504: every self-registered panel sees _input before the focused Control gets the key. The
# viewport-wide text-input gate must therefore stop G at GuildPanel while the add-friend LineEdit
# owns focus, then leave the event unhandled so Godot inserts the character into that field.
func test_add_friend_field_accepts_g_without_opening_guild_panel() -> void:
	var guild := GuildPanel.new()
	add_child_autofree(guild)
	await get_tree().process_frame
	guild.setup(func(_msg): pass)
	_panel.visible = true
	_panel._name_box.text = "dan"
	_panel._name_box.caret_column = _panel._name_box.text.length()
	_panel._name_box.grab_focus()
	await get_tree().process_frame
	assert_eq(get_viewport().gui_get_focus_owner(), _panel._name_box, "add-friend field owns focus")

	var key := InputEventKey.new()
	key.keycode = KEY_G
	key.physical_keycode = KEY_G
	key.unicode = "g".unicode_at(0)
	key.pressed = true
	Input.parse_input_event(key)
	Input.flush_buffered_events()
	await get_tree().process_frame

	assert_false(guild.visible, "G does not open the guild panel while a text field owns focus")
	assert_eq(_panel._name_box.text, "dang", "the focused add-friend field receives the g")


func test_shared_gate_recognizes_multiline_text_edit_focus() -> void:
	var edit := TextEdit.new()
	add_child_autofree(edit)
	edit.grab_focus()
	await get_tree().process_frame
	assert_true(
		UiInputGate.is_text_input_focused(get_viewport()),
		"TextEdit focus suppresses panel hotkeys through the same shared gate"
	)


# ---- T-755: BBCode injection through friend / ignore names ----------------------
#
# Same shape as the GuildPanel hole: bbcode_enabled label + meta_clicked wired to unfriend/trade.
# character_name.gd keeps "[" out of names today, so this is the regression pin that will notice if
# that charset ever loosens — the panel must not depend on a rule enforced three layers away.
func test_hostile_friend_name_renders_literally_and_forges_no_link() -> void:
	(
		_panel
		. receive(
			{
				"type": "social_list",
				"friends": [{"name": "[url=unfriend|bob]x[/url]", "online": true}],
				"ignored": [],
			}
		)
	)
	var body := _panel.body_text()
	assert_false(body.contains("[url=unfriend|bob]"), "a name cannot paint a second unfriend link")
	var rtl := RichTextLabel.new()
	rtl.bbcode_enabled = true
	add_child_autofree(rtl)
	rtl.text = body
	assert_string_contains(
		rtl.get_parsed_text(), "[url=unfriend|bob]x[/url]", "the hostile name renders as text"
	)
	# Exactly ONE live unfriend link on the row — the panel's own. Counting is the assertion that
	# actually states the threat: the bug was a name manufacturing extra clickable intents.
	assert_eq(body.count("[url=unfriend|"), 1, "the name manufactured no extra unfriend link")
	assert_eq(body.count("[url=trade|"), 1, "...nor an extra trade link")


func test_ignored_name_with_brackets_does_not_swallow_the_list() -> void:
	(
		_panel
		. receive(
			{
				"type": "social_list",
				"friends": [],
				"ignored": ["[color=red]troll", "second"],
			}
		)
	)
	var rtl := RichTextLabel.new()
	rtl.bbcode_enabled = true
	add_child_autofree(rtl)
	rtl.text = _panel.body_text()
	var parsed := rtl.get_parsed_text()
	assert_string_contains(parsed, "[color=red]troll", "the ignored name renders inert")
	assert_string_contains(parsed, "second", "an unclosed tag must not swallow the next row")
