# T-361: the stateful chat coordinator — identity-from-session (anti-spoof), rate limiting, length
# cap, profanity mask, and the not_in_party guard. Drives it against a real PlayerSessions store
# with a capturing reply Callable (no live peer).

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


func test_identity_comes_from_session_not_wire() -> void:
	PlayerSessions.add_player(1, TOK_A, "Alice", Vector3.ZERO)
	var s = _svc()
	# The client CLAIMS to be Mallory; the relayed line must carry the session username.
	s.handle("chat", 1, {"channel": "say", "text": "hi", "from": "Mallory"}, 1000)
	var got := _to(1)
	assert_eq(got.size(), 1, "sender receives their own say")
	assert_eq(str(got[0]["from"]), "Alice", "from is the session identity, never the wire's claim")


func test_unknown_peer_is_dropped() -> void:
	var s = _svc()
	s.handle("chat", 99, {"channel": "say", "text": "hi"}, 1000)
	assert_eq(_sent.size(), 0, "a peer with no session cannot chat")


func test_say_fans_out_to_nearby_only() -> void:
	PlayerSessions.add_player(1, TOK_A, "Alice", Vector3.ZERO)
	PlayerSessions.add_player(2, TOK_B, "Bob", Vector3(5, 0, 0))
	var s = _svc()
	s.handle("chat", 1, {"channel": "say", "text": "hello"}, 1000)
	assert_eq(_to(1).size(), 1, "Alice hears herself")
	assert_eq(_to(2).size(), 1, "nearby Bob hears the say")


func test_length_is_capped() -> void:
	PlayerSessions.add_player(1, TOK_A, "Alice", Vector3.ZERO)
	var s = _svc()
	s.handle("chat", 1, {"channel": "say", "text": "x".repeat(500)}, 1000)
	assert_true(str(_to(1)[0]["text"]).length() <= 256, "relayed text is clamped to the cap")


func test_blank_message_dropped() -> void:
	PlayerSessions.add_player(1, TOK_A, "Alice", Vector3.ZERO)
	var s = _svc()
	s.handle("chat", 1, {"channel": "say", "text": "   "}, 1000)
	assert_eq(_sent.size(), 0, "whitespace-only lines never relay")


func test_profanity_is_masked() -> void:
	PlayerSessions.add_player(1, TOK_A, "Alice", Vector3.ZERO)
	var s = _svc()
	s.handle("chat", 1, {"channel": "say", "text": "oh damn it"}, 1000)
	assert_eq(str(_to(1)[0]["text"]), "oh **** it", "listed words mask to same-length asterisks")


func test_rate_limited_after_budget() -> void:
	PlayerSessions.add_player(1, TOK_A, "Alice", Vector3.ZERO)
	var s = _svc()
	var max_msgs: int = _CHAT.NORMAL_MAX_MSGS
	for i in max_msgs:
		s.handle("chat", 1, {"channel": "say", "text": "spam"}, 1000)
	_sent = []  # clear the allowed burst; the NEXT one must be rejected
	s.handle("chat", 1, {"channel": "say", "text": "spam"}, 1000)
	var got := _to(1)
	assert_eq(got.size(), 1, "the over-budget message yields exactly one reply (the rejection)")
	assert_eq(str(got[0]["type"]), "chat_rejected")
	assert_eq(str(got[0]["reason"]), "rate_limited")


func test_rate_window_resets() -> void:
	PlayerSessions.add_player(1, TOK_A, "Alice", Vector3.ZERO)
	var s = _svc()
	for i in _CHAT.NORMAL_MAX_MSGS:
		s.handle("chat", 1, {"channel": "say", "text": "spam"}, 1000)
	_sent = []
	# A full window later, the budget is restored.
	s.handle("chat", 1, {"channel": "say", "text": "ok now"}, 1000 + _CHAT.NORMAL_WINDOW_MS)
	assert_eq(str(_to(1)[0]["type"]), "chat", "a fresh window relays again")


# T-361 item 2: ignore suppression — the ignorer never hears the ignored sender; everyone else
# (including the sender's own echo) is unaffected. The ignore store is peer_id -> {username:true}.
func test_ignored_sender_suppressed_for_ignorer_only() -> void:
	PlayerSessions.add_player(1, TOK_A, "Alice", Vector3.ZERO)
	PlayerSessions.add_player(2, TOK_B, "Bob", Vector3(5, 0, 0))
	var s = _CHAT.new()
	s.setup(
		func(pid: int, msg: Dictionary): _sent.append({"pid": pid, "msg": msg}),
		{},
		{2: {"Alice": true}}  # Bob ignores Alice
	)
	s.handle("chat", 1, {"channel": "say", "text": "hello bob"}, 1000)
	assert_eq(_to(1).size(), 1, "the ignored sender still sees their own echo (no tell)")
	assert_eq(_to(2).size(), 0, "CRIT: the ignorer received a line from an ignored sender")
	# The reverse direction is NOT ignored: Bob's line still reaches Alice.
	s.handle("chat", 2, {"channel": "say", "text": "..."}, 1000)
	assert_eq(_to(1).size(), 2, "ignore is one-directional")


# T-361 item 3: an emote is validated against the data-driven catalog, resolves the actor from the
# SESSION, and fans out like `say` — the actor sees the first-person line, nearby peers the third.
func test_emote_fans_out_with_per_recipient_lines() -> void:
	PlayerSessions.add_player(1, TOK_A, "Alice", Vector3.ZERO)
	PlayerSessions.add_player(2, TOK_B, "Bob", Vector3(5, 0, 0))
	var s = _svc()
	s.handle("emote", 1, {"id": "wave", "from": "Mallory"}, 1000)
	var mine := _to(1)
	assert_eq(mine.size(), 1, "the actor sees their own emote")
	assert_eq(str(mine[0]["type"]), "emote")
	assert_eq(str(mine[0]["from"]), "Alice", "identity is the session's, never the wire's 'from'")
	assert_eq(str(mine[0]["text"]), "You wave.", "the actor gets the first-person line")
	assert_eq(str(_to(2)[0]["text"]), "Alice waves.", "nearby Bob gets the third-person line")


func test_emote_unknown_id_is_rejected() -> void:
	PlayerSessions.add_player(1, TOK_A, "Alice", Vector3.ZERO)
	PlayerSessions.add_player(2, TOK_B, "Bob", Vector3(5, 0, 0))
	var s = _svc()
	s.handle("emote", 1, {"id": "__not_an_emote__"}, 1000)
	var got := _to(1)
	assert_eq(got.size(), 1, "the forged emote yields exactly one reply (the rejection)")
	assert_eq(str(got[0]["type"]), "chat_rejected")
	assert_eq(str(got[0]["reason"]), "unknown_emote")
	assert_eq(_to(2).size(), 0, "an unknown emote is never broadcast to anyone")


func test_emote_out_of_range_peer_does_not_receive() -> void:
	PlayerSessions.add_player(1, TOK_A, "Alice", Vector3.ZERO)
	PlayerSessions.add_player(2, TOK_B, "Bob", Vector3(500, 0, 0))
	var s = _svc()
	s.handle("emote", 1, {"id": "cheer"}, 1000)
	assert_eq(_to(1).size(), 1, "the actor always sees their own emote")
	assert_eq(_to(2).size(), 0, "an emote is local — a far peer never hears it (say-range routing)")


func test_emote_from_ignored_sender_suppressed_for_ignorer() -> void:
	PlayerSessions.add_player(1, TOK_A, "Alice", Vector3.ZERO)
	PlayerSessions.add_player(2, TOK_B, "Bob", Vector3(5, 0, 0))
	var s = _CHAT.new()
	s.setup(
		func(pid: int, msg: Dictionary): _sent.append({"pid": pid, "msg": msg}),
		{},
		{2: {"Alice": true}}  # Bob ignores Alice
	)
	s.handle("emote", 1, {"id": "wave"}, 1000)
	assert_eq(_to(1).size(), 1, "the actor still sees their own emote echo")
	assert_eq(_to(2).size(), 0, "CRIT: the ignorer received an emote from an ignored sender")


func test_emote_shares_the_say_rate_budget() -> void:
	PlayerSessions.add_player(1, TOK_A, "Alice", Vector3.ZERO)
	var s = _svc()
	for i in _CHAT.NORMAL_MAX_MSGS:
		s.handle("emote", 1, {"id": "wave"}, 1000)
	_sent = []  # exhaust the shared normal budget, then the next emote must be rejected
	s.handle("emote", 1, {"id": "wave"}, 1000)
	var got := _to(1)
	assert_eq(str(got[0]["type"]), "chat_rejected")
	assert_eq(str(got[0]["reason"]), "rate_limited")


func test_party_channel_without_party_is_rejected() -> void:
	PlayerSessions.add_player(1, TOK_A, "Alice", Vector3.ZERO)
	var s = _svc()
	s.handle("chat", 1, {"channel": "party", "text": "anyone?"}, 1000)
	var got := _to(1)
	assert_eq(str(got[0]["type"]), "chat_rejected")
	assert_eq(str(got[0]["reason"]), "not_in_party")


func test_help_channel_reuses_moderation_and_server_subscription() -> void:
	PlayerSessions.add_player(1, TOK_A, "Alice", Vector3.ZERO)
	PlayerSessions.add_player(2, TOK_B, "Bob", Vector3(500, 0, 0))
	var s = _CHAT.new()
	s.setup(
		func(pid: int, msg: Dictionary): _sent.append({"pid": pid, "msg": msg}),
		{},
		{},
		{},
		{1: true, 2: true}
	)
	s.handle("chat", 1, {"channel": "help", "text": "damn, where is Hale?"}, 1000)
	assert_eq(str(_to(2)[0]["channel"]), "help", "help reaches distant subscribers")
	assert_eq(str(_to(2)[0]["text"]), "****, where is Hale?", "chat_filter still moderates help")


func test_opted_out_sender_cannot_broadcast_help() -> void:
	PlayerSessions.add_player(1, TOK_A, "Alice", Vector3.ZERO)
	var s = _CHAT.new()
	s.setup(func(pid, msg): _sent.append({"pid": pid, "msg": msg}), {}, {}, {}, {})
	s.handle("chat", 1, {"channel": "help", "text": "hello"}, 1000)
	assert_eq(str(_to(1)[0]["reason"]), "not_subscribed")
