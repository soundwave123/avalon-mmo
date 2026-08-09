extends "res://addons/gut/test.gd"
# T-598 (bug #48): /party accept|decline mirrors /duel accept|decline (test_chat_panel.gd), and the
# PartyInvitePrompt notice rides the same "system" channel path as the duel offer line. Split into
# its own file — test_chat_panel.gd is already at GUT's 20-public-method class cap.

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


func test_party_accept_decline_intents() -> void:
	_panel._on_submit("/party accept")
	_panel._on_submit("/party decline")
	assert_eq(_sent.size(), 2)
	assert_eq(str(_sent[0]["type"]), "party_accept")
	assert_eq(str(_sent[1]["type"]), "party_decline")


func test_party_invite_system_line_renders_as_notice() -> void:
	# PartyInvitePrompt (T-598) pushes its prompt through the SAME "system" channel path the duel
	# offer uses — this is that shared rendering seam, proven with a party-shaped line.
	(
		_panel
		. receive(
			{
				"type": "chat",
				"channel": "system",
				"from": "",
				"text":
				"Bob invites you to a party — type /party accept to join, /party decline to decline.",
			}
		)
	)
	assert_eq(_panel.line_count(), 1, "a system-channel party-invite line is appended")
	assert_true(_panel.get_text().contains("Bob invites you to a party"), "the offer text renders")
