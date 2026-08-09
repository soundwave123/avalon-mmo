# T-626: whisper (targeted 1:1) — resolution, self/unknown/offline rejection, ignore suppression,
# and rate-limit sharing. Split from test_chat_service.gd (already at GUT's 20-public-method class
# cap) — the same per-feature split as test_chat_panel_party.gd on the client side.

extends GutTest

const _CHAT = preload("res://scripts/chat_service.gd")
const PlayerSessions = preload("res://scripts/player_sessions.gd")

const TOK_A := "aaaaaaaa11111111aaaaaaaa11111111"  # gitleaks:allow
const TOK_B := "bbbbbbbb22222222bbbbbbbb22222222"  # gitleaks:allow

var _sent: Array = []


func before_each() -> void:
	PlayerSessions._reset_for_test()
	_sent = []


func _svc() -> RefCounted:
	var s = _CHAT.new()
	s.setup(func(pid: int, msg: Dictionary): _sent.append({"pid": pid, "msg": msg}), {})
	return s


func _to(peer_id: int) -> Array:
	var out := []
	for e in _sent:
		if int(e["pid"]) == peer_id:
			out.append(e["msg"])
	return out


# Whisper has no range/instance check (cross-zone by design) and is server-labeled per recipient
# ("out" for the sender's own echo, "in" for the target's copy) so the client can render
# "[To X]" / "[From Y]" without needing to know its own username.
func test_whisper_delivers_to_online_target_and_echoes_sender() -> void:
	PlayerSessions.add_player(1, TOK_A, "Alice", Vector3.ZERO)
	PlayerSessions.add_player(2, TOK_B, "Bob", Vector3(999, 999, 0))  # far + irrelevant to whisper
	var s = _svc()
	s.handle("chat", 1, {"channel": "whisper", "target": "Bob", "text": "hey"}, 1000)
	var mine := _to(1)
	assert_eq(mine.size(), 1, "the sender sees their own echo")
	assert_eq(str(mine[0]["channel"]), "whisper")
	assert_eq(str(mine[0]["direction"]), "out", "the sender's copy is marked outgoing")
	assert_eq(str(mine[0]["to"]), "Bob")
	var theirs := _to(2)
	assert_eq(theirs.size(), 1, "the target receives the whisper despite range/instance")
	assert_eq(str(theirs[0]["direction"]), "in", "the target's copy is marked incoming")
	assert_eq(str(theirs[0]["from"]), "Alice", "identity is the session's, never the wire's claim")
	assert_eq(str(theirs[0]["text"]), "hey")


func test_whisper_unknown_name_is_rejected_not_silent() -> void:
	PlayerSessions.add_player(1, TOK_A, "Alice", Vector3.ZERO)
	var s = _svc()
	s.handle("chat", 1, {"channel": "whisper", "target": "Ghost", "text": "hey"}, 1000)
	var got := _to(1)
	assert_eq(got.size(), 1, "an unknown target yields exactly one reply (the rejection)")
	assert_eq(str(got[0]["type"]), "chat_rejected")
	assert_eq(str(got[0]["reason"]), "unknown_player")


func test_whisper_offline_name_is_rejected_same_as_unknown() -> void:
	PlayerSessions.add_player(1, TOK_A, "Alice", Vector3.ZERO)
	PlayerSessions.add_player(2, TOK_B, "Bob", Vector3.ZERO)
	PlayerSessions.remove_player(2)  # Bob logs out — no longer in the online snapshot
	var s = _svc()
	s.handle("chat", 1, {"channel": "whisper", "target": "Bob", "text": "hey"}, 1000)
	assert_eq(
		str(_to(1)[0]["reason"]), "unknown_player", "an offline name reads the same as unknown"
	)


func test_whisper_to_self_is_rejected() -> void:
	PlayerSessions.add_player(1, TOK_A, "Alice", Vector3.ZERO)
	var s = _svc()
	s.handle("chat", 1, {"channel": "whisper", "target": "Alice", "text": "hey"}, 1000)
	var got := _to(1)
	assert_eq(got.size(), 1, "a self-whisper yields exactly one reply (the rejection)")
	assert_eq(str(got[0]["type"]), "chat_rejected")
	assert_eq(str(got[0]["reason"]), "cannot_whisper_self")


func test_whisper_ignored_by_target_is_suppressed_for_the_target_only() -> void:
	PlayerSessions.add_player(1, TOK_A, "Alice", Vector3.ZERO)
	PlayerSessions.add_player(2, TOK_B, "Bob", Vector3.ZERO)
	var s = _CHAT.new()
	s.setup(
		func(pid: int, msg: Dictionary): _sent.append({"pid": pid, "msg": msg}),
		{},
		{2: {"Alice": true}}  # Bob ignores Alice
	)
	s.handle("chat", 1, {"channel": "whisper", "target": "Bob", "text": "hey"}, 1000)
	assert_eq(_to(1).size(), 1, "the sender still sees their own echo")
	assert_eq(_to(2).size(), 0, "CRIT: the ignorer received a whisper from an ignored sender")


func test_whisper_shares_the_normal_rate_budget() -> void:
	PlayerSessions.add_player(1, TOK_A, "Alice", Vector3.ZERO)
	PlayerSessions.add_player(2, TOK_B, "Bob", Vector3.ZERO)
	var s = _svc()
	for i in _CHAT.NORMAL_MAX_MSGS:
		s.handle("chat", 1, {"channel": "whisper", "target": "Bob", "text": "spam"}, 1000)
	_sent = []  # clear the allowed burst; the NEXT one must be rejected
	s.handle("chat", 1, {"channel": "whisper", "target": "Bob", "text": "spam"}, 1000)
	var got := _to(1)
	assert_eq(got.size(), 1, "the over-budget whisper yields exactly one reply (the rejection)")
	assert_eq(str(got[0]["type"]), "chat_rejected")
	assert_eq(str(got[0]["reason"]), "rate_limited")
