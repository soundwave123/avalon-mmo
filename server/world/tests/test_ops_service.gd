extends GutTest

const OpsService = preload("res://scripts/ops_service.gd")
const PlayerSessions = preload("res://scripts/player_sessions.gd")

const TOKEN_A := "aaaaaaaa11111111aaaaaaaa11111111"
const TOKEN_B := "bbbbbbbb22222222bbbbbbbb22222222"
const TOKEN_C := "cccccccc33333333cccccccc33333333"

var _sent: Array = []
var _disconnected: Array = []
var _master_calls: Array = []


func before_each() -> void:
	PlayerSessions._reset_for_test()
	_sent.clear()
	_disconnected.clear()
	_master_calls.clear()
	PlayerSessions.add_player(11, TOKEN_A, "Alice", Vector3(10, 20, 0))
	PlayerSessions.add_player(12, TOKEN_B, "Bob", Vector3(11, 21, 0))
	PlayerSessions.add_player(13, TOKEN_C, "Cara", Vector3(200, 300, 0))


func after_each() -> void:
	PlayerSessions._reset_for_test()


func _service() -> RefCounted:
	var parties := {
		"party_of": {11: 8, 12: 8, 13: 9},
		"parties":
		{
			8: {"members": [11, 12], "subgroup": {11: 0, 12: 0}},
			9: {"members": [13]},
		},
	}
	var svc = OpsService.new()
	svc.setup(
		func(peer_id: int, payload: Dictionary): _sent.append([peer_id, payload.duplicate(true)]),
		func(peer_id: int): _disconnected.append(peer_id),
		func(method: String, params: Dictionary):
			_master_calls.append([method, params.duplicate(true)])
			if method == "ops_tail":
				return {"ok": true, "rows": [{"action": "who", "actor": "web-admin"}]}
			return {"ok": true, "audit_id": _master_calls.size(), "account_exists": true},
		parties,
		{11: "mage", 12: "warrior", 13: "priest"},
		{11: 7, 12: 9, 13: 12},
		{11: 44, 13: 44}
	)
	return svc


func test_who_snapshot_uses_authoritative_session_shape() -> void:
	var result: Dictionary = await _service().handle("web-admin", "who", {}, 2000000000.0)
	assert_true(result["ok"])
	var rows: Array = result["result"]["players"]
	assert_eq(rows.size(), 3)
	assert_eq(rows[0]["name"], "Alice")
	assert_eq(rows[0]["class"], "mage")
	assert_eq(rows[0]["level"], 7)
	assert_eq(rows[0]["peer_id"], 11)
	assert_true(rows[0]["pos"].has_all(["x", "y", "z"]))
	assert_true(rows[0].has_all(["zone", "session_age_seconds"]))
	assert_eq(_master_calls[0][0], "ops_apply", "read verb is audited too")


func test_message_verbs_resolve_recipients_from_server_stores_and_tag_gm() -> void:
	var svc = _service()
	await svc.handle("web-admin", "broadcast", {"text": "Server hello"}, 1.0)
	assert_eq(_sent.size(), 3)
	assert_true(_sent[0][1]["gm"], "trusted tag originates inside ops service")
	assert_eq(_sent[0][1]["channel"], "system")
	_sent.clear()
	await svc.handle(
		"web-admin", "msg_group", {"kind": "guild", "id": 44, "text": "Guild notice"}, 1.0
	)
	assert_eq(_sent.map(func(row): return row[0]), [11, 13])
	_sent.clear()
	await svc.handle("web-admin", "whisper", {"player": "Bob", "text": "Please relog"}, 1.0)
	assert_eq(_sent.size(), 1)
	assert_eq(_sent[0][0], 12)
	assert_eq(_sent[0][1]["channel"], "whisper")


func test_kick_and_ban_audit_before_reasoned_disconnect() -> void:
	var svc = _service()
	var kicked: Dictionary = await svc.handle(
		"web-admin", "kick", {"player": "Bob", "reason": "AFK in restricted area"}, 1.0
	)
	assert_true(kicked["ok"])
	assert_eq(_master_calls[0][1]["action"], "kick")
	assert_eq(_sent[0][1]["type"], "kicked")
	assert_eq(_sent[0][1]["reason"], "AFK in restricted area")
	assert_eq(_disconnected, [12])
	_sent.clear()
	_disconnected.clear()
	var banned: Dictionary = await svc.handle(
		"web-admin", "ban", {"player": "Alice", "reason": "confirmed exploit"}, 1.0
	)
	assert_true(banned["ok"])
	assert_eq(_master_calls[1][1]["action"], "ban")
	assert_true(_sent[0][1]["banned"])
	assert_eq(_disconnected, [11])


func test_kick_resolves_by_character_name_even_when_account_differs() -> void:
	# T-546/T-507: /who shows the CHARACTER NAME, so the GM types that. The live-session kick must
	# resolve the target by character name (the session `username`), independent of the owning
	# account — an alt whose character name != account login is still kicked by the name shown.
	PlayerSessions.add_player(
		14, "dddddddd44444444dddddddd44444444", "ShadowThief", Vector3.ZERO, "shrek"
	)
	var svc = _service()
	var kicked: Dictionary = await svc.handle(
		"web-admin", "kick", {"player": "ShadowThief", "reason": "grief"}, 1.0
	)
	assert_true(kicked["ok"])
	assert_eq(_disconnected, [14], "resolved the peer by the character name the GM saw in /who")
	# The account login must NOT resolve a peer — only the character name does.
	_disconnected.clear()
	var by_account: Dictionary = await svc.handle(
		"web-admin", "kick", {"player": "shrek", "reason": "grief"}, 1.0
	)
	assert_false(by_account["ok"], "the account login is not a live identity in /who")
	assert_eq(by_account.get("error", ""), "player_not_online")


func test_every_public_action_is_sent_to_audit_choke_point() -> void:
	var svc = _service()
	var cases := [
		["who", {}],
		["announce", {"minutes": 5, "reason": "restart"}],
		["broadcast", {"text": "hello"}],
		["msg_group", {"kind": "party", "id": 9, "text": "hello"}],
		["whisper", {"player": "Alice", "text": "hello"}],
		["kick", {"player": "Alice", "reason": "reason"}],
		["ban", {"player": "Alice", "reason": "reason"}],
	]
	for row: Array in cases:
		await svc.handle("web-admin", row[0], row[1], 1.0)
	assert_eq(
		_master_calls.map(func(call): return call[1]["action"]), cases.map(func(row): return row[0])
	)


func test_announce_emits_banner_and_mid_countdown_login_gets_current_notice() -> void:
	var svc = _service()
	await svc.handle("web-admin", "announce", {"minutes": 5, "reason": "patch"}, 1.0)
	assert_eq(_sent.size(), 3)
	assert_eq(_sent[0][1]["type"], "maintenance")
	assert_eq(_sent[0][1]["remaining_seconds"], 300)
	_sent.clear()
	svc.tick(61.0)
	svc.on_login(12)
	assert_eq(_sent.size(), 1)
	assert_eq(_sent[0][0], 12)
	assert_eq(_sent[0][1]["remaining_seconds"], 239)
