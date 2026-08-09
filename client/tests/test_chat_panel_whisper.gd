extends "res://addons/gut/test.gd"
# T-626: /w, /tell, /r command parsing (whisper intents) + incoming/outgoing whisper rendering.
# Split from test_chat_panel.gd (already large) — same per-command-family split as the existing
# test_chat_panel_party.gd (T-598).

var _panel: ChatPanel = null
var _sent: Array = []


func before_each() -> void:
	_panel = ChatPanel.new()
	add_child(_panel)
	await get_tree().process_frame
	_sent = []
	_panel.setup(func(intent: Dictionary): _sent.append(intent))


func after_each() -> void:
	_panel.queue_free()


func test_w_command_sends_whisper_intent_with_target_and_body() -> void:
	_panel._on_submit("/w Bob hey there")
	assert_eq(_sent.size(), 1)
	assert_eq(str(_sent[0]["type"]), "chat", "a whisper rides the same chat intent shape")
	assert_eq(str(_sent[0]["channel"]), "whisper")
	assert_eq(str(_sent[0]["target"]), "Bob", "the target name is preserved (case intact)")
	assert_eq(str(_sent[0]["text"]), "hey there", "the multi-word body is rejoined")


func test_tell_command_is_a_whisper_alias() -> void:
	_panel._on_submit("/tell Alice yo")
	assert_eq(_sent.size(), 1)
	assert_eq(str(_sent[0]["channel"]), "whisper")
	assert_eq(str(_sent[0]["target"]), "Alice")
	assert_eq(str(_sent[0]["text"]), "yo")


func test_reply_command_targets_the_last_incoming_whisper() -> void:
	_panel.receive(
		{"type": "chat", "channel": "whisper", "direction": "in", "from": "Carol", "text": "psst"}
	)
	_panel._on_submit("/r right back at you")
	assert_eq(_sent.size(), 1)
	assert_eq(str(_sent[0]["channel"]), "whisper")
	assert_eq(str(_sent[0]["target"]), "Carol", "/r targets whoever whispered you last")
	assert_eq(str(_sent[0]["text"]), "right back at you")


func test_reply_command_after_an_outgoing_whisper_targets_the_same_person() -> void:
	_panel._on_submit("/w Dora hi")
	_panel._on_submit("/r still there?")
	assert_eq(_sent.size(), 2)
	assert_eq(
		str(_sent[1]["target"]), "Dora", "/r also follows a whisper YOU sent, not just one you got"
	)


func test_reply_command_before_any_whisper_targets_nobody() -> void:
	_panel._on_submit("/r hello?")
	assert_eq(_sent.size(), 1)
	assert_eq(str(_sent[0]["target"]), "", "no prior whisper means no reply target yet")


func test_incoming_whisper_renders_from_prefix() -> void:
	_panel.receive(
		{"type": "chat", "channel": "whisper", "direction": "in", "from": "Carol", "text": "psst"}
	)
	assert_eq(_panel.line_count(), 1)
	assert_true(
		_panel.get_text().contains("From Carol"), "an incoming whisper is labeled by sender"
	)
	assert_true(_panel.get_text().contains("psst"))


func test_outgoing_whisper_echo_renders_to_prefix() -> void:
	(
		_panel
		. receive(
			{
				"type": "chat",
				"channel": "whisper",
				"direction": "out",
				"from": "Alice",
				"to": "Bob",
				"text": "hey",
			}
		)
	)
	assert_eq(_panel.line_count(), 1)
	assert_true(_panel.get_text().contains("To Bob"), "the sender's own echo is labeled by target")
	assert_true(_panel.get_text().contains("hey"))


func test_whisper_rejection_renders_as_system_notice() -> void:
	_panel.receive({"type": "chat_rejected", "reason": "unknown_player"})
	assert_eq(_panel.line_count(), 1)
	assert_true(_panel.get_text().contains("unknown_player"))
