extends GutTest

# T-363/T-361: the world-side social hub — the TRUST BOUNDARY tests. Identity always comes from
# the session, trade requests are proximity/liveness-gated against server positions, every op is
# rate-limited, and master replies fan out to the right peers.

const _SVC = preload("res://scripts/social_service.gd")
const _MENTOR = preload("res://scripts/mentorship_service.gd")
const _PL = preload("res://scripts/party_logic.gd")
const PlayerSessions = preload("res://scripts/player_sessions.gd")

const TOK_A := "aaaaaaaa11111111aaaaaaaa11111111"  # gitleaks:allow
const TOK_B := "bbbbbbbb22222222bbbbbbbb22222222"  # gitleaks:allow
const TOK_C := "cccccccc33333333cccccccc33333333"  # gitleaks:allow

var _sent: Array = []
var _master: StubMaster = null


class StubMaster:
	extends RefCounted
	var calls: Array = []
	var reply: Dictionary = {}

	func call_master(method: String, params: Dictionary) -> Dictionary:
		calls.append({"method": method, "params": params})
		return reply


func before_each() -> void:
	PlayerSessions._reset_for_test()
	_sent = []
	_master = StubMaster.new()


func _svc() -> RefCounted:
	var s = _SVC.new()
	s.setup(
		func(pid: int, msg: Dictionary): _sent.append({"pid": pid, "msg": msg}), {}, _master, null
	)
	return s


func _to(peer_id: int) -> Array:
	var out := []
	for e in _sent:
		if int(e["pid"]) == peer_id:
			out.append(e["msg"])
	return out


func _pair() -> RefCounted:
	PlayerSessions.add_player(1, TOK_A, "Alice", Vector3.ZERO)
	PlayerSessions.add_player(2, TOK_B, "Bob", Vector3(3, 0, 0))
	return _svc()


# ---- routing allow-list ------------------------------------------------------


func test_handles_social_surface_only() -> void:
	var s = _svc()
	for t in [
		"chat",
		"trade_request",
		"trade_confirm",
		"social_add_friend",
		"social_list",
		"guild_create",
		"guild_invite",
		"guild_accept",
		"guild_disband",
	]:
		assert_true(s.handles(t), "'%s' must route" % t)
	# No grant-shaped verb is client-routable — rank/membership is only ever conferred by a
	# master-validated op, never by a verb the client can name.
	for forged in [
		"trade_commit",
		"trade_grant",
		"social_grant",
		"adjust_coins",
		"guild_grant_rank",
		"guild_set_leader",
		"guild_add_member",
	]:
		assert_false(s.handles(forged), "CRIT: '%s' is client-routable" % forged)


# ---- identity + gates ----------------------------------------------------------


func test_unknown_peer_never_reaches_master() -> void:
	var s = _svc()
	s.handle("trade_request", 99, {"target": "Bob"}, 1000)
	assert_eq(_master.calls.size(), 0, "an unhandshaked peer cannot open master round-trips")


func test_identity_comes_from_session_not_wire() -> void:
	var s = _pair()
	_master.reply = {"views": []}
	# The wire CLAIMS to be Mallory; the master op must carry the session identity.
	s.handle("trade_request", 1, {"target": "Bob", "username": "Mallory", "from": "Mallory"}, 1000)
	assert_eq(_master.calls.size(), 1)
	assert_eq(
		str(_master.calls[0]["params"]["username"]),
		"Alice",
		"CRIT: the wire's username claim reached the master"
	)


func test_trade_request_gates_offline_self_and_range() -> void:
	var s = _pair()
	PlayerSessions.add_player(3, TOK_C, "Carol", Vector3(500, 0, 0))
	s.handle("trade_request", 1, {"target": "Ghost"}, 1000)
	assert_eq(str(_to(1)[0]["reason"]), "target_offline")
	s.handle("trade_request", 1, {"target": "Alice"}, 1000)
	assert_eq(str(_to(1)[1]["reason"]), "bad_target", "self-trade dies at the world edge too")
	s.handle("trade_request", 1, {"target": "Carol"}, 1000)
	assert_eq(str(_to(1)[2]["reason"]), "too_far", "trade is face-to-face")
	assert_eq(_master.calls.size(), 0, "no gated request reaches the master")


func test_trade_request_blocked_across_instances() -> void:
	var s = _pair()
	PlayerSessions.set_instance(2, 7)  # Bob is inside a crypt instance at the same coords
	s.handle("trade_request", 1, {"target": "Bob"}, 1000)
	assert_eq(str(_to(1)[0]["reason"]), "too_far", "instance boundary blocks trade")


func test_rate_limit_cuts_off_op_spam() -> void:
	var s = _pair()
	_master.reply = {"views": []}
	for i in range(_SVC.OP_MAX):
		s.handle("trade_offer_coins", 1, {"amount": 1}, 1000)
	s.handle("trade_offer_coins", 1, {"amount": 1}, 1000)
	assert_eq(_master.calls.size(), _SVC.OP_MAX, "over-budget ops never reach the master")
	var last: Dictionary = _to(1).back()
	assert_eq(str(last["reason"]), "rate_limited")


# ---- fan-out ---------------------------------------------------------------------


func test_views_fan_out_to_both_parties() -> void:
	var s = _pair()
	_master.reply = {
		"views":
		[
			{"username": "Alice", "view": {"partner": "Bob"}},
			{"username": "Bob", "view": {"partner": "Alice"}},
		]
	}
	s.handle("trade_request", 1, {"target": "Bob"}, 1000)
	assert_eq(_to(1).size(), 1, "Alice gets her view")
	assert_eq(_to(2).size(), 1, "Bob gets his view")
	assert_eq(str(_to(2)[0]["type"]), "trade_update")
	assert_eq(str(_to(2)[0]["view"]["partner"]), "Alice")


func test_error_goes_only_to_actor() -> void:
	var s = _pair()
	_master.reply = {"error": "target_busy"}
	s.handle("trade_request", 1, {"target": "Bob"}, 1000)
	assert_eq(_to(1).size(), 1)
	assert_eq(str(_to(1)[0]["reason"]), "target_busy")
	assert_eq(_to(2).size(), 0, "the other party never sees the actor's rejection")


func test_disconnect_mid_trade_cancels_serverside() -> void:
	var s = _pair()
	_master.reply = {"views": [{"username": "Alice", "view": {}}, {"username": "Bob", "view": {}}]}
	s.handle("trade_request", 1, {"target": "Bob"}, 1000)
	_master.calls = []
	_master.reply = {"ended": true, "reason": "cancelled", "views": []}
	s.forget(1)
	assert_eq(_master.calls.size(), 1, "a mid-trade disconnect fires a server-side cancel")
	assert_eq(str(_master.calls[0]["params"]["action"]), "cancel")
	assert_eq(str(_master.calls[0]["params"]["username"]), "Alice")


# ---- friends/ignore ---------------------------------------------------------------


func test_social_list_decorates_online_status() -> void:
	var s = _pair()
	_master.reply = {"friends": ["Bob", "Zed"], "ignored": ["Troll"]}
	s.handle("social_list", 1, {}, 1000)
	var msg: Dictionary = _to(1)[0]
	assert_eq(str(msg["type"]), "social_list")
	var by_name := {}
	for f in msg["friends"]:
		by_name[str(f["name"])] = bool(f["online"])
	assert_true(by_name["Bob"], "online friend flagged from live sessions")
	assert_false(by_name["Zed"], "offline friend flagged offline")
	assert_eq(msg["ignored"], ["Troll"])


func test_social_target_name_forwarded_but_identity_sessioned() -> void:
	var s = _pair()
	_master.reply = {"friends": [], "ignored": []}
	s.handle("social_add_ignore", 1, {"name": "Troll", "username": "Mallory"}, 1000)
	assert_eq(str(_master.calls[0]["method"]), "social_op")
	assert_eq(str(_master.calls[0]["params"]["username"]), "Alice")
	assert_eq(str(_master.calls[0]["params"]["target_name"]), "Troll")


# ---- guilds (T-362) ---------------------------------------------------------------


func test_guild_op_identity_is_sessioned_not_wire() -> void:
	var s = _pair()
	_master.reply = {"error": "not_in_guild"}
	# The wire claims to be the leader "Zolt"; the master op must carry the SESSION identity.
	s.handle("guild_create", 1, {"name": "Knights", "username": "Zolt"}, 1000)
	assert_eq(str(_master.calls[0]["method"]), "guild_op")
	assert_eq(
		str(_master.calls[0]["params"]["username"]), "Alice", "CRIT: wire identity reached master"
	)
	assert_eq(str(_master.calls[0]["params"]["action"]), "create")
	assert_eq(str(_master.calls[0]["params"]["name"]), "Knights")


func test_guild_invite_prompts_target_and_acks_actor() -> void:
	var s = _pair()
	_master.reply = {"invited": "Bob", "target_id": 2, "guild_id": 5, "guild_name": "Knights"}
	s.handle("guild_invite", 1, {"name": "Bob"}, 1000)
	# The forwarded target is the wire NAME (master resolves the id, never the client).
	assert_eq(str(_master.calls[0]["params"]["target_name"]), "Bob")
	var bob_msgs := _to(2)
	assert_eq(str(bob_msgs[0]["type"]), "guild_invite", "the invitee is prompted")
	assert_eq(str(bob_msgs[0]["from"]), "Alice")
	assert_eq(str(_to(1)[0]["type"]), "guild_result", "the inviter gets an ack")


func test_guild_roster_broadcasts_and_wires_guild_chat() -> void:
	var s = _pair()
	_master.reply = {
		"ok": true,
		"guild_id": 7,
		"guild_name": "Knights",
		"members":
		[
			{"name": "Alice", "rank": 0, "rank_name": "Leader", "is_leader": true},
			{"name": "Bob", "rank": 2, "rank_name": "Member", "is_leader": false},
		],
	}
	s.handle("guild_roster", 1, {}, 1000)
	# Roster fans out to every ONLINE member, decorated with presence.
	assert_eq(str(_to(1)[0]["type"]), "guild_roster")
	assert_eq(_to(1)[0]["members"].size(), 2)
	assert_eq(str(_to(2)[0]["type"]), "guild_roster", "Bob gets the roster too")
	var alice_online := false
	for m in _to(1)[0]["members"]:
		if str(m["name"]) == "Alice":
			alice_online = bool(m["online"])
	assert_true(alice_online, "a live member is flagged online")
	# The broadcast seeded the shared guild-chat cache: a guild line now reaches BOTH members.
	_sent = []
	s.handle("chat", 1, {"channel": "guild", "text": "hail"}, 2000)
	assert_eq(_to(1).size(), 1, "sender hears the guild line")
	assert_eq(str(_to(2)[0]["channel"]), "guild", "the guildmate hears it (shared cache wired)")


func test_guild_chat_rejected_when_guildless() -> void:
	var s = _pair()
	s.handle("chat", 1, {"channel": "guild", "text": "anyone?"}, 1000)
	assert_eq(str(_to(1)[0]["type"]), "chat_rejected")
	assert_eq(str(_to(1)[0]["reason"]), "not_in_guild")


func test_guild_error_goes_only_to_actor() -> void:
	var s = _pair()
	_master.reply = {"error": "no_permission"}
	s.handle("guild_kick", 1, {"name": "Bob"}, 1000)
	assert_eq(str(_to(1)[0]["type"]), "guild_result")
	assert_false(bool(_to(1)[0]["ok"]))
	assert_eq(str(_to(1)[0]["reason"]), "no_permission")
	assert_eq(_to(2).size(), 0, "a rejected management verb never touches the target")


# ---- discovery (T-451) -----------------------------------------------------------


func test_seeking_board_uses_truth_and_is_officer_browsable() -> void:
	var s = _pair()
	s.setup_discovery({1: 17, 2: 22}, {1: "mage", 2: "warrior"})
	s.seed_login(1, {"guild_id": 0, "help_subscribed": true})
	(
		s
		. seed_login(
			2,
			{
				"guild_id": 9,
				"guild_name": "Knights",
				"guild_rank": 1,
				"help_subscribed": true,
			}
		)
	)
	# Alice forges her display truth on the wire; only the note is player-authored.
	s.handle(
		"guild_seek",
		1,
		{"level": 99, "role": "tank", "guild": "Admins", "note": "Weeknight quests"},
		1000
	)
	s.handle("guild_seek_list", 2, {}, 1100)
	var board: Array = _to(2)[0]["players"]
	assert_eq(board.size(), 1, "an officer can browse a guildless seeker's signal")
	assert_eq(str(board[0]["name"]), "Alice")
	assert_eq(int(board[0]["level"]), 17, "level comes from the world truth map")
	assert_eq(str(board[0]["role"]), "dps", "role derives from the session class")
	assert_eq(str(board[0]["note"]), "Weeknight quests")


func test_seeking_board_clears_on_join_and_disconnect() -> void:
	var s = _pair()
	s.setup_discovery({1: 17}, {1: "mage"})
	s.seed_login(1, {"guild_id": 0, "help_subscribed": true})
	s.handle("guild_seek", 1, {"note": "Social guild"}, 1000)
	assert_eq(s.seeking_board().size(), 1)
	_master.reply = {
		"ok": true,
		"joined": true,
		"guild_id": 7,
		"guild_name": "Knights",
		"members":
		[
			{"name": "Alice", "rank": 2, "rank_name": "Member", "is_leader": false},
		],
	}
	s.handle("guild_accept", 1, {}, 1100)
	assert_eq(s.seeking_board().size(), 0, "accepting an invite clears the board immediately")
	# A later guildless signal is also cleared by the disconnect lifecycle.
	s.set_guild(1, 0)
	s.handle("guild_seek", 1, {"note": "Try again"}, 1200)
	assert_eq(s.seeking_board().size(), 1)
	s.forget(1)
	assert_eq(s.seeking_board().size(), 0, "disconnect clears the seeking signal")


func test_player_who_uses_server_truth_and_is_rate_limited() -> void:
	var s = _pair()
	s.setup_discovery({1: 17, 2: 22}, {1: "mage", 2: "warrior"})
	(
		s
		. seed_login(
			1,
			{
				"guild_id": 7,
				"guild_name": "Knights",
				"guild_rank": 2,
				"help_subscribed": true,
			}
		)
	)
	s.seed_login(2, {"guild_id": 0, "help_subscribed": true})
	s.handle(
		"player_who",
		1,
		{"level": 99, "role": "tank", "guild": "Forged", "filters": {"name": "Ali"}},
		1000
	)
	var rows: Array = _to(1)[0]["players"]
	assert_eq(rows.size(), 1)
	assert_eq(int(rows[0]["level"]), 17, "client-supplied level is ignored")
	assert_eq(str(rows[0]["role"]), "dps", "client-supplied role is ignored")
	assert_eq(str(rows[0]["guild"]), "Knights", "guild is the server cache")
	# The shared social-op budget bounds the global online scan.
	_sent = []
	for i in range(_SVC.OP_MAX - 1):
		s.handle("player_who", 1, {"filters": {}}, 1000)
	s.handle("player_who", 1, {"filters": {}}, 1000)
	assert_eq(str(_to(1).back()["reason"]), "rate_limited")


func test_help_subscription_defaults_from_master_and_opt_out_updates_router() -> void:
	var s = _pair()
	s.seed_login(1, {"guild_id": 0, "help_subscribed": true})
	s.seed_login(2, {"guild_id": 0, "help_subscribed": true})
	assert_true(s.help_subscribed(1), "master's new-character default seeds the world cache")
	_master.reply = {"friends": [], "ignored": [], "help_subscribed": false}
	s.handle("help_subscription", 1, {"subscribed": false}, 1000)
	assert_false(s.help_subscribed(1), "successful opt-out updates the routing cache")
	_sent = []
	s.handle("chat", 1, {"channel": "help", "text": "can anyone hear me?"}, 1100)
	assert_eq(str(_to(1)[0]["reason"]), "not_subscribed")


# ---- mentorship discovery (T-477) -------------------------------------------


func test_mentee_signal_is_browsable_and_uses_only_server_truth() -> void:
	var s = _pair()
	s.setup_discovery({1: 8, 2: 30}, {1: "mage", 2: "warrior"})
	s.seed_login(1, {"guild_id": 0, "help_subscribed": true})
	s.seed_login(2, {"guild_id": 0, "help_subscribed": true})
	(
		s
		. handle(
			"mentor_flag",
			1,
			{"kind": "mentee", "level": 60, "role": "tank", "zone": "Admin", "note": "Hale"},
			1000,
		)
	)
	s.handle("mentor_list", 2, {"kind": "mentee"}, 1100)
	var board: Array = _to(2).back()["players"]
	assert_eq(board.size(), 1, "a willing mentor can discover an unrelated solo newcomer")
	assert_eq(str(board[0]["name"]), "Alice")
	assert_eq(int(board[0]["level"]), 8, "level comes from world truth")
	assert_eq(str(board[0]["role"]), "dps", "role comes from authoritative class")
	assert_eq(str(board[0]["zone"]), "Starter Vale", "zone comes from session position")


func test_mentor_flags_clear_on_party_join_disconnect_and_level_change() -> void:
	var party_store := _PL.new_store()
	var s = _SVC.new()
	s.setup(
		func(pid: int, msg: Dictionary): _sent.append({"pid": pid, "msg": msg}),
		party_store,
		_master,
		null,
	)
	PlayerSessions.add_player(1, TOK_A, "Alice", Vector3.ZERO)
	PlayerSessions.add_player(2, TOK_B, "Bob", Vector3.ZERO)
	var levels := {1: 30, 2: 8}
	s.setup_discovery(levels, {1: "warrior", 2: "mage"})
	s.handle("mentor_flag", 1, {"kind": "mentor"}, 1000)
	_PL.invite(party_store, 2, 1)
	_PL.accept(party_store, 1)
	assert_eq(s.mentorship_board().size(), 0, "party join prunes the signal")
	_PL.leave(party_store, 1)
	s.handle("mentor_flag", 1, {"kind": "mentor"}, 1100)
	levels[1] = 10
	assert_eq(s.mentorship_board().size(), 0, "falling below the mentor bar prunes the signal")
	levels[1] = 30
	s.handle("mentor_flag", 1, {"kind": "mentor"}, 1200)
	s.forget(1)
	assert_eq(s.mentorship_board().size(), 0, "disconnect clears the signal")


func test_discovery_invite_composes_with_party_and_cap_only_sync() -> void:
	var party_store := _PL.new_store()
	var social = _SVC.new()
	social.setup(
		func(pid: int, msg: Dictionary): _sent.append({"pid": pid, "msg": msg}),
		party_store,
		_master,
		null,
	)
	PlayerSessions.add_player(1, TOK_A, "Newcomer", Vector3.ZERO)
	PlayerSessions.add_player(2, TOK_B, "Veteran", Vector3.ZERO)
	var levels := {1: 5, 2: 30}
	social.setup_discovery(levels, {1: "mage", 2: "warrior"})
	social.handle("mentor_flag", 1, {"kind": "mentee"}, 1000)
	social.handle("mentor_list", 2, {"kind": "mentee"}, 1100)
	assert_eq(str(_to(2).back()["players"][0]["name"]), "Newcomer")
	var mentor = _MENTOR.new()
	mentor.setup(
		party_store,
		levels,
		func(_peer, _class, _stats, _talents, _level, _preserve): pass,
		func(pid: int, msg: Dictionary): _sent.append({"pid": pid, "msg": msg}),
	)
	mentor.record_authoritative(1, "mage", {"int": 20}, {}, 5)
	mentor.record_authoritative(2, "warrior", {"str": 120}, {}, 30)
	mentor.handle_party("party_invite", 2, {"username": "Veteran"}, {"target": "Newcomer"})
	mentor.handle_party("party_accept", 1, {"username": "Newcomer"}, {})
	var sync := mentor.toggle(2, {"level": 60, "stats": {"str": 9999}})
	assert_true(bool(sync["ok"]), "the existing T-452 toggle activates after ordinary party accept")
	assert_eq(mentor.reward_level(2), 5, "ceiling is the party's true newcomer level")
	assert_lt(mentor.reward_level(2), levels[2], "pairing grants no power; it only caps the mentor")


func test_flagged_mentor_is_server_annotated_in_help_channel() -> void:
	var s = _pair()
	s.setup_discovery({1: 30, 2: 8}, {1: "warrior", 2: "mage"})
	s.seed_login(1, {"guild_id": 0, "help_subscribed": true})
	s.seed_login(2, {"guild_id": 0, "help_subscribed": true})
	s.handle("mentor_flag", 1, {"kind": "mentor", "mentor": false}, 1000)
	_sent = []
	s.handle(
		"chat", 1, {"channel": "help", "text": "Happy to run Hale's quests", "mentor": false}, 1100
	)
	assert_true(bool(_to(2)[0]["mentor"]), "annotation comes from the server flag, not packet")


# ---- duels (T-381) -----------------------------------------------------------


class ResStub:
	extends RefCounted
	var hp: int
	var max_hp: int

	func _init(h: int, m: int) -> void:
		hp = h
		max_hp = m


func _match_reply() -> Dictionary:
	return {
		"ok": true,
		"winner": {"name": "Alice", "delta": 16},
		"loser": {"name": "Bob", "delta": -13},
		"honor": {"winner_honor": 18, "loser_honor": 10},
	}


func test_handles_duel_surface_and_no_result_verb() -> void:
	var s = _svc()
	for t in ["duel_request", "duel_accept", "duel_decline", "duel_cancel"]:
		assert_true(s.handles(t), "'%s' must route" % t)
	# There is NO client verb that reports a win / records a match — that path is server-observed.
	for forged in ["duel_result", "record_match", "duel_win", "duel_flag"]:
		assert_false(s.handles(forged), "CRIT: '%s' is client-routable" % forged)


func test_duel_request_relays_offer_and_ack() -> void:
	var s = _pair()  # Alice(1) at origin, Bob(2) three units away — within DUEL_RADIUS
	s.handle("duel_request", 1, {"target": "Bob"}, 1000)
	assert_eq(str(_to(2)[0]["channel"]), "system", "the target gets a system-line offer")
	assert_true(
		str(_to(2)[0]["text"]).to_lower().contains("challenge"), "offer names the challenge"
	)
	assert_true(str(_to(1)[0]["text"]).to_lower().contains("bob"), "the challenger gets an ack")
	assert_eq(_master.calls.size(), 0, "a mere challenge never reaches the master")


func test_duel_request_is_proximity_gated() -> void:
	var s = _pair()
	PlayerSessions.add_player(3, TOK_C, "Carol", Vector3(500, 0, 0))  # far away
	s.handle("duel_request", 1, {"target": "Carol"}, 1000)
	assert_true(str(_to(1)[0]["text"]).to_lower().contains("cannot"), "a far target is rejected")
	assert_false(s.pvp_eligible(1, 3), "no duel formed with an out-of-range target")


func test_forged_duel_accept_without_request_rejected() -> void:
	var s = _pair()
	s.handle("duel_accept", 2, {}, 1000)  # Bob accepts a duel nobody offered
	assert_true(str(_to(2)[0]["text"]).to_lower().contains("no duel"), "forged accept is refused")
	assert_false(
		s.pvp_eligible(1, 2), "CRIT: a forged accept flagged a duel that was never offered"
	)


func test_duel_accept_makes_pair_eligible() -> void:
	var s = _pair()
	s.handle("duel_request", 1, {"target": "Bob"}, 1000)
	assert_false(s.pvp_eligible(1, 2), "a pending offer is not yet consent")
	s.handle("duel_accept", 2, {}, 1100)
	assert_true(
		s.pvp_eligible(1, 2) and s.pvp_eligible(2, 1), "an accepted duel makes the pair eligible"
	)


func test_on_duel_hit_at_floor_records_match_and_keeps_loser_alive() -> void:
	var s = _pair()
	s.handle("duel_request", 1, {"target": "Bob"}, 1000)
	s.handle("duel_accept", 2, {}, 1100)
	_master.reply = _match_reply()
	var res := {1: ResStub.new(80, 100), 2: ResStub.new(5, 100)}  # Bob at 5% — at the floor
	var ended: bool = s.on_duel_hit(2, res, 1200)
	assert_true(ended, "a floor hit ends the duel and the caller SKIPS the death check")
	assert_true(res[2].hp >= 10, "the loser is clamped to the HP floor (>0) — no death, no penalty")
	assert_eq(_master.calls.size(), 1, "the duel end is the live caller of record_match")
	assert_eq(str(_master.calls[0]["method"]), "record_match")
	assert_eq(str(_master.calls[0]["params"]["winner"]), "Alice", "winner is server-resolved")
	assert_eq(str(_master.calls[0]["params"]["loser"]), "Bob")
	assert_eq(str(_master.calls[0]["params"]["bracket"]), "duel")
	assert_false(s.pvp_eligible(1, 2), "the pair is cleared once the duel ends")
	assert_true(str(_to(1)[-1]["text"]).to_lower().contains("won"), "winner is told they won")


func test_on_duel_hit_above_floor_continues() -> void:
	var s = _pair()
	s.handle("duel_request", 1, {"target": "Bob"}, 1000)
	s.handle("duel_accept", 2, {}, 1100)
	var res := {1: ResStub.new(80, 100), 2: ResStub.new(60, 100)}
	assert_false(s.on_duel_hit(2, res, 1200), "60/100 is above the floor — the duel continues")
	assert_eq(_master.calls.size(), 0, "no match recorded while the duel is live")
	assert_true(s.pvp_eligible(1, 2), "still dueling")


func test_on_duel_hit_ignores_non_duelist() -> void:
	var s = _pair()
	var res := {2: ResStub.new(1, 100)}
	assert_false(s.on_duel_hit(2, res, 1200), "a non-dueling player's hit is not a duel end")
	assert_eq(_master.calls.size(), 0)


func test_disconnect_forfeits_and_records() -> void:
	var s = _pair()
	s.handle("duel_request", 1, {"target": "Bob"}, 1000)
	s.handle("duel_accept", 2, {}, 1100)
	_master.reply = _match_reply()
	s.forget(1)  # Alice disconnects mid-duel
	assert_eq(_master.calls.size(), 1, "a mid-duel disconnect records the forfeit")
	assert_eq(str(_master.calls[0]["params"]["winner"]), "Bob", "the survivor wins the forfeit")
	assert_eq(str(_master.calls[0]["params"]["loser"]), "Alice")
	assert_false(s.pvp_eligible(1, 2), "the pair store is cleaned up on disconnect")
