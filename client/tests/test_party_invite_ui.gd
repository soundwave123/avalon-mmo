extends GutTest

# T-736: the party-invite client surface — context menu, Accept/Decline dialog, and the flow
# orchestrator's pure joins (relationship gating, refusal copy, prompt bookkeeping). The full
# wire path (right-click -> menu -> intent -> modal -> roster) is proven over real transport in
# scripts/test-t736-invite-e2e.sh; these lock the headless state machines.

const ContextMenu = preload("res://scripts/ui/target_context_menu.gd")
const InviteDialog = preload("res://scripts/ui/party_invite_dialog.gd")
const InviteFlow = preload("res://scripts/ui/party_invite_flow.gd")
const InvitePrompt = preload("res://scripts/net/party_invite_prompt.gd")


class FakeChatPanel:
	extends RefCounted
	var lines: Array = []

	func receive(msg: Dictionary) -> void:
		lines.append(msg)

	func text() -> String:
		var out := ""
		for line: Dictionary in lines:
			out += str(line.get("text", "")) + "\n"
		return out


class FakeOnboarding:
	extends RefCounted
	var hints: Array = []

	func hint(id: String, _override := "") -> void:
		hints.append(id)


class FakeMain:
	extends Node
	var last_positions: Dictionary = {}
	var party_members: Array = []
	var player_hud = null  # flow falls back to the 5-slot default bar
	var chat_panel = null
	var sent: Array = []
	var _my_peer_id: int = 1
	var _target_id: int = -1
	var _party_prompt = null
	var _onboarding = null

	func _send_to_server(msg: Dictionary) -> void:
		sent.append(msg)

	func _on_entity_clicked(target_id: int) -> void:
		_target_id = target_id


func _flow() -> Dictionary:
	var main := FakeMain.new()
	main._party_prompt = InvitePrompt.new()
	main.chat_panel = FakeChatPanel.new()
	main._onboarding = FakeOnboarding.new()
	add_child_autofree(main)
	var flow = InviteFlow.new()
	flow._main = main
	flow.menu = ContextMenu.new()
	flow.dialog = InviteDialog.new()
	main.add_child(flow.menu)  # freed with the autofree'd fake main
	main.add_child(flow.dialog)
	flow.menu.action_selected.connect(flow._on_menu_action)
	flow.dialog.answered.connect(flow._on_answer)
	flow.dialog.lapsed.connect(flow._on_lapse)
	return {"flow": flow, "main": main}


func _positions_with(players: Array) -> Dictionary:
	return {"players": players}


# ---- context menu ------------------------------------------------------------------------


func test_menu_open_choose_emits_meta_once_and_closes() -> void:
	var menu := ContextMenu.new()
	add_child_autofree(menu)
	watch_signals(menu)
	menu.open_for("bob", Vector2(50, 50))
	assert_true(menu.is_open())
	menu._choose_invite()
	assert_false(menu.is_open(), "choosing closes the menu")
	assert_signal_emitted_with_parameters(menu, "action_selected", ["party_invite|bob"])
	menu._choose_invite()  # a stray re-emit after closing must not double-send
	assert_signal_emit_count(menu, "action_selected", 1)


func test_menu_clamps_into_viewport() -> void:
	var menu := ContextMenu.new()
	add_child_autofree(menu)
	menu.open_for("bob", Vector2(99999, 99999))
	var vp := menu.get_viewport_rect().size
	assert_lt(menu._panel.position.x, vp.x, "panel stays inside the viewport (x)")
	assert_lt(menu._panel.position.y, vp.y, "panel stays inside the viewport (y)")


# ---- invite dialog -----------------------------------------------------------------------


func test_dialog_open_answer_accept_emits_once() -> void:
	var dlg := InviteDialog.new()
	add_child_autofree(dlg)
	watch_signals(dlg)
	dlg.open("alice", 45000)
	assert_true(dlg.is_open())
	assert_string_contains(dlg._body.text, "alice has invited you to their party.")
	assert_string_contains(dlg._countdown.text, "Expires in")
	dlg._answer(true)
	assert_false(dlg.is_open(), "answering closes the dialog")
	assert_signal_emitted_with_parameters(dlg, "answered", [true])
	dlg._answer(false)  # after closing: no second send
	assert_signal_emit_count(dlg, "answered", 1)


func test_dialog_lapse_emits_lapsed_not_answered() -> void:
	var dlg := InviteDialog.new()
	add_child_autofree(dlg)
	watch_signals(dlg)
	dlg.open("alice", 45000)
	dlg._deadline_ms = Time.get_ticks_msec() - 1  # force the countdown past its deadline
	dlg._process(0.016)
	assert_false(dlg.is_open(), "a lapsed invite dismisses itself")
	assert_signal_emitted(dlg, "lapsed")
	assert_signal_not_emitted(dlg, "answered", "a timeout answers NOTHING (never a decline)")


# ---- flow: invitee side ------------------------------------------------------------------


func test_on_invite_shows_dialog_and_chat_fallback() -> void:
	var f := _flow()
	f["flow"].on_invite({"type": "party_invite", "from": "alice", "ttl_ms": 45000})
	assert_true(f["flow"].dialog.is_open())
	assert_eq(f["flow"].dialog.inviter(), "alice")
	assert_eq(f["main"]._party_prompt.pending_from, "alice", "T-598 pending bookkeeping kept")
	assert_string_contains(f["main"].chat_panel.text(), "alice invites you to a party")


func test_dialog_answer_sends_accept_and_result_closes() -> void:
	var f := _flow()
	f["flow"].on_invite({"from": "alice", "ttl_ms": 45000})
	f["flow"].dialog._answer(true)
	assert_eq(f["main"].sent, [{"type": "party_accept"}], "accept rides the T-280 intent")
	f["flow"].on_result({"type": "party_result", "intent": "party_accept", "ok": true})
	assert_eq(f["main"]._party_prompt.pending_from, "", "ack clears the pending prompt")


func test_lapse_clears_prompt_and_sends_nothing() -> void:
	var f := _flow()
	f["flow"].on_invite({"from": "alice", "ttl_ms": 45000})
	f["flow"].dialog._deadline_ms = Time.get_ticks_msec() - 1
	f["flow"].dialog._process(0.016)
	assert_eq(f["main"].sent, [], "a timeout sends no intent at all")
	assert_eq(f["main"]._party_prompt.pending_from, "", "the stale prompt is cleared")


# ---- flow: inviter side ------------------------------------------------------------------


func test_menu_action_sends_party_invite_intent() -> void:
	var f := _flow()
	f["flow"]._on_menu_action("party_invite|bob")
	assert_eq(f["main"].sent, [{"type": "party_invite", "target": "bob"}])


func test_refusal_reason_lands_as_system_chat_for_the_actor() -> void:
	var f := _flow()
	f["flow"].on_result(
		{"type": "party_result", "intent": "party_invite", "ok": false, "reason": "invite_cooldown"}
	)
	assert_string_contains(f["main"].chat_panel.text(), "aren't taking invites")


func test_unknown_reasons_stay_silent() -> void:
	var f := _flow()
	f["flow"].on_result(
		{"type": "party_result", "intent": "party_decline", "ok": false, "reason": "whatever"}
	)
	assert_eq(f["main"].chat_panel.lines, [], "unmapped refusals add no chat noise")
	assert_eq(InviteFlow.reason_text("party_invite", "nope"), "")
	assert_eq(InviteFlow.reason_text("party_invite", "party_full"), "Your party is full.")


# ---- flow: relationship gating -----------------------------------------------------------


func test_menu_opens_only_for_friendly_players() -> void:
	var f := _flow()
	f["main"].last_positions = _positions_with(
		[
			{"peer_id": 1, "party_id": 3},  # self (viewer, in party 3)
			{"peer_id": 2, "party_id": 3, "username": "mate"},  # party-mate
			{"peer_id": 4, "username": "stranger"},  # friendly
		]
	)
	f["flow"]._try_open(2, Vector2.ZERO)
	assert_false(f["flow"].menu.is_open(), "no invite offer for a PARTY member")
	f["flow"]._try_open(1, Vector2.ZERO)
	assert_false(f["flow"].menu.is_open(), "no invite offer for SELF")
	f["flow"]._try_open(99, Vector2.ZERO)
	assert_false(f["flow"].menu.is_open(), "no offer for an id missing from the broadcast")
	f["flow"]._try_open(4, Vector2.ZERO)
	assert_true(f["flow"].menu.is_open(), "FRIENDLY player gets the menu")
	assert_eq(f["flow"].menu.target_name(), "stranger")


func test_friendly_target_fires_both_hints_self_only_the_target_one() -> void:
	var f := _flow()
	f["main"].last_positions = _positions_with(
		[{"peer_id": 1}, {"peer_id": 4, "username": "stranger"}]
	)
	f["flow"].on_target_selected(4)
	assert_eq(
		f["main"]._onboarding.hints,
		["target", "party_invite"],
		"friendly selection teaches targeting AND the invite affordance"
	)
	f["flow"].on_target_selected(1)
	assert_eq(
		f["main"]._onboarding.hints.slice(2),
		["target"],
		"self selection adds no invite hint (the controller dedupes repeats itself)"
	)
