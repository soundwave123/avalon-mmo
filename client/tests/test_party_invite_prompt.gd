extends "res://addons/gut/test.gd"
# T-598 (bug #48): party invite had zero client-side UI — the invitee never saw a popup/toast/chat
# line, only the dev pilot harness could see `_pending_party_invite`. PartyInvitePrompt mirrors the
# duel_request client surface (chat_panel.gd's escaped "system" channel notice, T-381) so a real
# player sees the invite land and knows how to act on it.

const PartyInvitePrompt = preload("res://scripts/net/party_invite_prompt.gd")


# A minimal chat_panel double — PartyInvitePrompt only ever calls .receive(dict) on it, the same
# seam ChatPanel.receive() exposes for a "system" channel notice.
class FakeChatPanel:
	var received: Array = []

	func receive(d: Dictionary) -> void:
		received.append(d)


func test_show_pushes_a_system_chat_line_naming_the_inviter() -> void:
	var chat := FakeChatPanel.new()
	var prompt := PartyInvitePrompt.new()
	prompt.show(chat, "Bob")
	assert_eq(chat.received.size(), 1, "one prompt line is pushed to chat")
	var msg: Dictionary = chat.received[0]
	assert_eq(
		str(msg.get("channel", "")), "system", "rides the same channel as the duel offer line"
	)
	assert_string_contains(str(msg.get("text", "")), "Bob", "the inviter's name is visible")
	assert_string_contains(
		str(msg.get("text", "")), "/party accept", "the accept command is spelled out"
	)
	assert_string_contains(
		str(msg.get("text", "")), "/party decline", "the decline command is spelled out"
	)


func test_show_records_the_pending_inviter() -> void:
	var prompt := PartyInvitePrompt.new()
	assert_eq(prompt.pending_from, "", "no invite until one lands")
	prompt.show(FakeChatPanel.new(), "Alice")
	assert_eq(prompt.pending_from, "Alice")


func test_show_with_no_chat_panel_still_records_pending() -> void:
	# Mirrors the duel pattern's fail-open UI: a not-yet-wired chat_panel must never crash the
	# receive path, and the pending state still updates for pilot/E2E truth.
	var prompt := PartyInvitePrompt.new()
	prompt.show(null, "Cara")
	assert_eq(prompt.pending_from, "Cara")


func test_on_result_clears_pending_on_accept_and_decline() -> void:
	var prompt := PartyInvitePrompt.new()
	prompt.show(FakeChatPanel.new(), "Bob")
	prompt.on_result({"intent": "party_decline", "ok": true})
	assert_eq(prompt.pending_from, "", "my own decline ack clears the prompt")

	prompt.show(FakeChatPanel.new(), "Bob")
	prompt.on_result({"intent": "party_accept", "ok": true})
	assert_eq(prompt.pending_from, "", "my own accept ack clears the prompt")

	prompt.show(FakeChatPanel.new(), "Bob")
	prompt.on_result({"intent": "party_accept", "ok": false, "reason": "already_in_party"})
	assert_eq(prompt.pending_from, "", "a REJECTED accept still clears — nothing left to act on")


func test_on_result_ignores_unrelated_replies() -> void:
	var prompt := PartyInvitePrompt.new()
	prompt.show(FakeChatPanel.new(), "Bob")
	prompt.on_result({"intent": "raid_convert", "ok": true})
	assert_eq(
		prompt.pending_from, "Bob", "a reply for a different intent leaves the invite pending"
	)


func test_clear() -> void:
	var prompt := PartyInvitePrompt.new()
	prompt.show(FakeChatPanel.new(), "Bob")
	prompt.clear()
	assert_eq(prompt.pending_from, "")
