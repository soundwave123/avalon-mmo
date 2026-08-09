extends "res://addons/gut/test.gd"

const PlayerSessions = preload("res://scripts/player_sessions.gd")

# T-028: Automated reconnect integration test.
#
# Simulates the two-client reconnect scenario at the session layer.
# No live ENet required — all assertions run via PlayerSessions API.
#
# Scenarios covered:
#   §3 — Two-client reconnect: A+B connected, A drops, B sees no ghost, A reconnects.
#   §4 — Expired token: A drops, session ages out, reconnect creates new session.
#
# entity_id in this server == peer_id (there is no separate entity_id in M1).

# 32-char hex tokens — accepted by validate_token_format  # gitleaks:allow
const TOKEN_A := "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa0"  # gitleaks:allow
const TOKEN_B := "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbb01"  # gitleaks:allow

const PEER_A1 := 10  # A's first connection peer_id
const PEER_A2 := 30  # A's peer_id after reconnect (ENet assigns a new id)
const PEER_B := 20


func before_each() -> void:
	PlayerSessions._reset_for_test()


# ---- §3: Two-client reconnect ----


func test_two_client_reconnect_full_cycle() -> void:
	# A and B both connect.
	assert_true(
		PlayerSessions.add_player(PEER_A1, TOKEN_A, "alice", Vector3(10.0, 5.0, 0.0)),
		"A initial connect accepted"
	)
	assert_true(
		PlayerSessions.add_player(PEER_B, TOKEN_B, "bob", Vector3(0.0, 0.0, 0.0)),
		"B connect accepted"
	)
	assert_eq(PlayerSessions.list_players().size(), 2, "2 players active after both connect")

	# A disconnects (simulate network drop — server calls preserve_on_disconnect).
	PlayerSessions.preserve_on_disconnect(PEER_A1)

	# After A drops: exactly 1 active entry (B).
	var after_disconnect := PlayerSessions.list_players()
	assert_eq(after_disconnect.size(), 1, "exactly 1 active player after A drops")
	assert_true(after_disconnect.has(PEER_B), "B is the remaining active player")
	assert_false(after_disconnect.has(PEER_A1), "A's old peer_id is gone")

	# A reconnects with the same token (ENet assigns new peer_id = PEER_A2).
	var saved := PlayerSessions.restore_session(TOKEN_A)
	assert_false(saved.is_empty(), "disconnected session found for A's token")

	var restored_pos: Vector3 = saved.get("last_pos", Vector3(-1.0, -1.0, 0.0))
	assert_eq(restored_pos.x, 10.0, "A's last x position preserved")
	assert_eq(restored_pos.y, 5.0, "A's last y position preserved")

	assert_true(
		PlayerSessions.add_player(PEER_A2, TOKEN_A, saved.get("username", ""), restored_pos),
		"A reconnect accepted under new peer_id"
	)

	# After reconnect: exactly 2 active entries, both unique peer_ids.
	var after_reconnect := PlayerSessions.list_players()
	assert_eq(after_reconnect.size(), 2, "2 players active after A reconnects")
	assert_true(after_reconnect.has(PEER_B), "B is still active")
	assert_true(after_reconnect.has(PEER_A2), "A reconnected under new peer_id")
	assert_false(after_reconnect.has(PEER_A1), "A's old peer_id is gone — no ghost")

	# Peer_ids are unique (no ghost duplicate).
	assert_ne(PEER_A2, PEER_B, "reconnected A has different peer_id from B")

	# A's restored position matches last known.
	var a_data := PlayerSessions.get_player(PEER_A2)
	var a_pos: Vector3 = a_data.get("pos", Vector3.ZERO)
	assert_eq(a_pos.x, 10.0, "A's restored x matches last known")
	assert_eq(a_pos.y, 5.0, "A's restored y matches last known")

	# Username preserved across reconnect.
	assert_eq(a_data.get("username", ""), "alice", "A's username survives reconnect")


func test_b_never_sees_ghost_during_reconnect() -> void:
	# B is a passive observer; A connects, drops, reconnects.
	# B's session must never show A's old peer_id alongside A's new peer_id.
	PlayerSessions.add_player(PEER_A1, TOKEN_A, "alice", Vector3(5.0, 5.0, 0.0))
	PlayerSessions.add_player(PEER_B, TOKEN_B, "bob", Vector3(0.0, 0.0, 0.0))

	# A drops.
	PlayerSessions.preserve_on_disconnect(PEER_A1)

	# At this point: B is the only active player.
	# In a real server, B's client would NOT receive a ghost entity_spawn for PEER_A1
	# because PEER_A1 was removed from active players before any broadcast fires.
	var mid_state := PlayerSessions.list_players()
	assert_false(mid_state.has(PEER_A1), "old A peer not in active set before reconnect")
	assert_eq(mid_state.size(), 1, "only B is active during A's absence")

	# A reconnects.
	var saved := PlayerSessions.restore_session(TOKEN_A)
	PlayerSessions.add_player(
		PEER_A2, TOKEN_A, saved.get("username", ""), saved.get("last_pos", Vector3.ZERO)
	)

	# Now: 2 unique peer_ids. No duplication.
	var final_state := PlayerSessions.list_players()
	assert_eq(final_state.size(), 2, "exactly 2 entries after reconnect, no ghost")
	var peer_ids := final_state.keys()
	assert_ne(peer_ids[0], peer_ids[1], "both peer_ids are unique")


func test_session_token_not_reusable_after_reconnect() -> void:
	# After A reconnects, the token must be locked to the new peer_id.
	# A third peer attempting the same token must be rejected.
	PlayerSessions.add_player(PEER_A1, TOKEN_A, "alice", Vector3.ZERO)
	PlayerSessions.preserve_on_disconnect(PEER_A1)
	var saved := PlayerSessions.restore_session(TOKEN_A)
	PlayerSessions.add_player(
		PEER_A2, TOKEN_A, saved.get("username", ""), saved.get("last_pos", Vector3.ZERO)
	)

	# PEER_A2 is now holding TOKEN_A. A third peer tries to steal it.
	var intruder := PlayerSessions.add_player(99, TOKEN_A, "imposter")
	assert_false(intruder, "same token rejected for a third peer after reconnect")
	assert_eq(
		PlayerSessions.list_players().size(), 1, "session count unchanged after rejected intruder"
	)


# ---- §4: Expired token creates new session ----


func test_expired_token_creates_fresh_session_not_restore() -> void:
	# A connects, moves to a known position, disconnects.
	PlayerSessions.add_player(PEER_A1, TOKEN_A, "alice", Vector3.ZERO)
	PlayerSessions.update_position(PEER_A1, Vector3(77.0, 33.0, 0.0))
	PlayerSessions.preserve_on_disconnect(PEER_A1)

	# Session expires (age the record, then cleanup_expired clears it).
	PlayerSessions._age_session(TOKEN_A, 600.0)
	var cleaned := PlayerSessions.cleanup_expired(300.0)
	assert_eq(cleaned, 1, "one expired session cleaned up")

	# Reconnect attempt: restore_session must return empty (session gone).
	var saved := PlayerSessions.restore_session(TOKEN_A)
	assert_true(saved.is_empty(), "no session to restore after expiry")

	# A joins as a brand new session at spawn.
	var accepted := PlayerSessions.add_player(PEER_A2, TOKEN_A, "alice")
	assert_true(accepted, "add_player accepted after expired session cleaned up")

	var new_data := PlayerSessions.get_player(PEER_A2)
	var new_pos: Vector3 = new_data.get("pos", Vector3(-1.0, -1.0, 0.0))
	assert_eq(new_pos.x, 0.0, "new session spawns at x=0, not at old position")
	assert_eq(new_pos.y, 0.0, "new session spawns at y=0, not at old position")
	assert_eq(new_data.get("username", ""), "alice", "username still set from add_player arg")


func test_cleanup_expired_leaves_fresh_sessions_intact() -> void:
	# A disconnects recently; B's session is expired.
	# cleanup_expired must remove B's session but keep A's.
	PlayerSessions.add_player(PEER_A1, TOKEN_A, "alice", Vector3.ZERO)
	PlayerSessions.preserve_on_disconnect(PEER_A1)

	PlayerSessions.add_player(PEER_B, TOKEN_B, "bob", Vector3.ZERO)
	PlayerSessions.preserve_on_disconnect(PEER_B)

	# Age only B's session past the limit.
	PlayerSessions._age_session(TOKEN_B, 400.0)
	var cleaned := PlayerSessions.cleanup_expired(300.0)
	assert_eq(cleaned, 1, "only the expired session removed")

	# A's session is still restorable.
	var a_session := PlayerSessions.restore_session(TOKEN_A)
	assert_false(a_session.is_empty(), "A's fresh session survived cleanup")

	# B's session is gone.
	var b_session := PlayerSessions.restore_session(TOKEN_B)
	assert_true(b_session.is_empty(), "B's expired session was cleaned up")
