extends "res://addons/gut/test.gd"

const PlayerSessions = preload("res://scripts/player_sessions.gd")

# T-181: Kick the older session on a duplicate login (same account, two peers).
#
# The kick lives world-side (server/world/scripts/main.gd:_kick_duplicate_sessions), which finds
# any LIVE peer for the incoming username via PlayerSessions.find_live_peers_by_username, persists
# it exactly like a disconnect (preserve_on_disconnect), then closes its ENet link. These tests
# exercise that decision + persistence at the PlayerSessions layer (no live ENet), mirroring the
# session-layer style of test_reconnect.gd. entity_id == peer_id in this server.

# 32-char hex tokens — accepted by validate_token_format  # gitleaks:allow
const TOKEN_OLD := "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa1"  # gitleaks:allow
const TOKEN_NEW := "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbb02"  # gitleaks:allow
const TOKEN_OTHER := "cccccccccccccccccccccccccccccc03"  # gitleaks:allow

const PEER_OLD := 11  # account's first (older) peer
const PEER_NEW := 22  # account's second login (ENet assigns a new peer_id)
const PEER_OTHER := 33  # an unrelated account


func before_each() -> void:
	PlayerSessions._reset_for_test()


# The kick sequence as main.gd runs it: find the live peer for the username, preserve it, then add
# the new peer. Mirrors _kick_duplicate_sessions + add_player without needing ENet.
func _simulate_duplicate_login(username: String, new_peer: int, new_token: String) -> void:
	for old_peer in PlayerSessions.find_live_peers_by_username(username, new_peer):
		PlayerSessions.preserve_on_disconnect(old_peer)
	PlayerSessions.add_player(new_peer, new_token, username)


# ---- Required test 1: second login kicks the older peer, exactly one entity ----


func test_duplicate_login_kicks_older_peer_one_entity() -> void:
	PlayerSessions.add_player(PEER_OLD, TOKEN_OLD, "pilot", Vector3(5.0, 5.0, 0.0))
	PlayerSessions.add_player(PEER_OTHER, TOKEN_OTHER, "guest", Vector3.ZERO)

	_simulate_duplicate_login("pilot", PEER_NEW, TOKEN_NEW)

	var active := PlayerSessions.list_players()
	# Exactly one 'pilot' entity, and it is the NEW peer.
	assert_true(active.has(PEER_NEW), "new pilot peer is active")
	assert_false(active.has(PEER_OLD), "old pilot peer was kicked — no ghost")
	assert_true(active.has(PEER_OTHER), "the unrelated account is untouched")
	var pilot_count := 0
	for pid in active:
		if active[pid].get("username", "") == "pilot":
			pilot_count += 1
	assert_eq(pilot_count, 1, "exactly one entity for the pilot account")


func test_duplicate_login_never_rejects_new_peer() -> void:
	# Kick-old, not reject-new: even with the older peer still holding a session, the new login
	# must be accepted.
	PlayerSessions.add_player(PEER_OLD, TOKEN_OLD, "pilot", Vector3.ZERO)
	for old_peer in PlayerSessions.find_live_peers_by_username("pilot", PEER_NEW):
		PlayerSessions.preserve_on_disconnect(old_peer)
	var accepted := PlayerSessions.add_player(PEER_NEW, TOKEN_NEW, "pilot")
	assert_true(accepted, "the new login is accepted (kick-old, never reject-new)")


# ---- Required test 2: old peer's state persists on the kick ----


func test_kick_persists_old_peer_state() -> void:
	PlayerSessions.add_player(PEER_OLD, TOKEN_OLD, "pilot", Vector3.ZERO)
	PlayerSessions.update_position(PEER_OLD, Vector3(123.0, 456.0, 0.0))

	_simulate_duplicate_login("pilot", PEER_NEW, TOKEN_NEW)

	# The kicked peer's position survives into the disconnected-session store, keyed by its token —
	# identical to a normal disconnect, so a later reconnect on the OLD token restores position.
	var stored := PlayerSessions.restore_session(TOKEN_OLD)
	assert_false(stored.is_empty(), "kicked peer's session was preserved")
	assert_eq(stored.get("username", ""), "pilot", "preserved username matches")
	var pos: Vector3 = stored.get("last_pos", Vector3(-1, -1, 0.0))
	assert_eq(pos.x, 123.0, "kicked peer's last x preserved")
	assert_eq(pos.y, 456.0, "kicked peer's last y preserved")


# ---- Required test 3: reconnect-after-crash (stale dead peer) is NOT mis-kicked ----


func test_stale_disconnected_peer_not_matched_as_live() -> void:
	# A crashed peer is preserved (removed from _players). It must not look like a live duplicate,
	# so a reconnect for the same username finds NO live peer to kick.
	PlayerSessions.add_player(PEER_OLD, TOKEN_OLD, "pilot", Vector3(9.0, 9.0, 0.0))
	PlayerSessions.preserve_on_disconnect(PEER_OLD)  # crash → stale disconnected session

	var live := PlayerSessions.find_live_peers_by_username("pilot")
	assert_eq(live.size(), 0, "a stale disconnected peer is never seen as a live session")


func test_reconnect_after_crash_still_restores_cleanly() -> void:
	# Full reconnect regression: crash, then reconnect on the same token. The kick scan finds
	# nothing live, restore_session returns the preserved position, and exactly one entity results.
	PlayerSessions.add_player(PEER_OLD, TOKEN_OLD, "pilot", Vector3.ZERO)
	PlayerSessions.update_position(PEER_OLD, Vector3(42.0, 7.0, 0.0))
	PlayerSessions.preserve_on_disconnect(PEER_OLD)  # crash

	# Reconnect path (same token): no live peer to kick, restore consumes the preserved session.
	assert_eq(
		PlayerSessions.find_live_peers_by_username("pilot", PEER_NEW).size(),
		0,
		"nothing live to kick on a crash reconnect"
	)
	var restored := PlayerSessions.restore_session(TOKEN_OLD)
	assert_false(restored.is_empty(), "preserved session restorable on reconnect")
	var last_pos: Vector3 = restored.get("last_pos", Vector3.ZERO)
	PlayerSessions.add_player(PEER_NEW, TOKEN_OLD, restored.get("username", ""), last_pos)

	var active := PlayerSessions.list_players()
	assert_eq(active.size(), 1, "exactly one entity after crash reconnect — no ghost")
	assert_true(active.has(PEER_NEW), "reconnected under the new peer_id")
	var pos: Vector3 = active[PEER_NEW].get("pos", Vector3.ZERO)
	assert_eq(pos.x, 42.0, "reconnect restored x")
	assert_eq(pos.y, 7.0, "reconnect restored y")


# ---- Lookup helper edge cases ----


func test_find_live_peers_excludes_self_and_other_usernames() -> void:
	PlayerSessions.add_player(PEER_OLD, TOKEN_OLD, "pilot", Vector3.ZERO)
	PlayerSessions.add_player(PEER_OTHER, TOKEN_OTHER, "guest", Vector3.ZERO)

	# Excluding the peer itself yields no self-match (used so a peer never kicks itself).
	assert_eq(
		PlayerSessions.find_live_peers_by_username("pilot", PEER_OLD).size(),
		0,
		"a peer is never returned as its own duplicate"
	)
	# A different username never matches.
	assert_eq(
		PlayerSessions.find_live_peers_by_username("guest", PEER_NEW),
		[PEER_OTHER],
		"only the matching-username live peer is returned"
	)


func test_find_live_peers_empty_username_matches_nothing() -> void:
	# Stub/unresolved logins (empty username) must never collide into a mass kick.
	PlayerSessions.add_player(PEER_OLD, TOKEN_OLD, "", Vector3.ZERO)
	PlayerSessions.add_player(PEER_OTHER, TOKEN_OTHER, "", Vector3.ZERO)
	assert_eq(
		PlayerSessions.find_live_peers_by_username("").size(),
		0,
		"an empty username owns no account and matches nothing"
	)
