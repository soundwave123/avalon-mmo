extends "res://addons/gut/test.gd"

# Unit tests for server/world/scripts/player_sessions.gd.
# Pure-function tests; no network or server state required.

const PlayerSessions = preload("res://scripts/player_sessions.gd")

# Valid 32-char lowercase hex tokens for testing (validated by _is_hex_format).
# Previously used JWT-like placeholders ("eyJhbG...f456") which were never valid.
const VALID_TOKEN := "abcdef0123456789abcdef0123456789"  # gitleaks:allow
const VALID_TOKEN_2 := "1234567890abcdef1234567890abcdef"  # gitleaks:allow


func before_each() -> void:
	PlayerSessions._reset_for_test()


func test_validate_token_format_accepts_jwt() -> void:
	assert_true(PlayerSessions.validate_token_format(VALID_TOKEN), "JWT format should be valid")


func test_validate_token_format_rejects_short_token() -> void:
	assert_false(
		PlayerSessions.validate_token_format("abcdef01"), "token shorter than JWT must be invalid"
	)


func test_validate_token_format_accepts_hex_token() -> void:
	# 32-char lowercase hex tokens are valid
	assert_true(
		PlayerSessions.validate_token_format("abcdef0123456789abcdef0123456789"),
		"32-char hex must be valid"
	)


func test_validate_token_format_rejects_uppercase_hex() -> void:
	assert_false(
		PlayerSessions.validate_token_format("ABCDEF0123456789ABCDEF0123456789"),
		"uppercase hex must be invalid"
	)


func test_validate_token_format_rejects_wrong_length_hex() -> void:
	assert_false(
		PlayerSessions.validate_token_format("abcdef01234567890"), "31-char hex must be invalid"  # 31 chars
	)


func test_validate_token_format_rejects_garbage() -> void:
	# Not JWT, not 32-char hex -> rejected
	assert_false(
		PlayerSessions.validate_token_format("not.a.valid.jwt.token.five.parts"),
		"garbage token must be invalid"
	)


func test_validate_token_format_rejects_non_jwt() -> void:
	assert_false(
		PlayerSessions.validate_token_format("ghijkl0123456789ghijkl0123456789"),
		"non-JWT must be invalid"
	)


func test_validate_token_format_rejects_empty() -> void:
	assert_false(PlayerSessions.validate_token_format(""), "empty string must be invalid")


func test_add_player_with_valid_token() -> void:
	var result := PlayerSessions.add_player(1, VALID_TOKEN)
	assert_true(result, "add_player should return true for valid JWT")


func test_add_player_rejects_invalid_token() -> void:
	var result := PlayerSessions.add_player(1, "invalid")
	assert_false(result, "add_player should reject non-JWT")


func test_add_player_rejects_duplicate_token() -> void:
	PlayerSessions.add_player(1, VALID_TOKEN)
	var result := PlayerSessions.add_player(2, VALID_TOKEN)
	assert_false(result, "add_player should reject duplicate token even with different peer_id")


func test_get_player_returns_data_after_add() -> void:
	PlayerSessions.add_player(42, VALID_TOKEN)
	var player: Dictionary = PlayerSessions.get_player(42)
	assert_false(player.is_empty(), "get_player should return data for known peer_id")
	assert_eq(player.get("token", ""), VALID_TOKEN, "token should match")
	assert_true(player.has("connected_at"), "should have connected_at timestamp")


func test_get_player_returns_empty_for_unknown() -> void:
	var player: Dictionary = PlayerSessions.get_player(999)
	assert_true(player.is_empty(), "get_player for unknown peer_id should return empty dict")


func test_remove_player_clears_data() -> void:
	PlayerSessions.add_player(1, VALID_TOKEN)
	PlayerSessions.remove_player(1)
	var player: Dictionary = PlayerSessions.get_player(1)
	assert_true(player.is_empty(), "get_player should return empty after remove")


func test_list_players_returns_all() -> void:
	PlayerSessions.add_player(1, VALID_TOKEN)
	PlayerSessions.add_player(2, VALID_TOKEN_2)
	var players: Dictionary = PlayerSessions.list_players()
	assert_eq(players.size(), 2, "should list both players")


func test_add_player_sets_stub_username() -> void:
	PlayerSessions.add_player(1, VALID_TOKEN)
	var player: Dictionary = PlayerSessions.get_player(1)
	assert_eq(
		player.get("username", ""),
		VALID_TOKEN.substr(0, 8),
		"stub username should be first 8 chars of token"
	)


func test_add_player_with_username() -> void:
	PlayerSessions.add_player(1, VALID_TOKEN, "testuser")
	var player: Dictionary = PlayerSessions.get_player(1)
	assert_eq(player.get("username", ""), "testuser", "username should come from master validation")


func test_add_player_defaults_to_stub_when_no_username() -> void:
	PlayerSessions.add_player(1, VALID_TOKEN, "")
	var player: Dictionary = PlayerSessions.get_player(1)
	assert_eq(
		player.get("username", ""), VALID_TOKEN.substr(0, 8), "should fall back to stub username"
	)


# ---- T-011: Position tracking tests ----


func test_add_player_defaults_position_to_zero() -> void:
	PlayerSessions.add_player(1, VALID_TOKEN, "alice")
	var positions: Dictionary = PlayerSessions.get_positions()
	assert_true(positions.has(1), "positions should include new player")
	var p1: Dictionary = positions.get(1) as Dictionary
	assert_eq(p1.get("x", -9999), 0.0, "default x should be 0.0")
	assert_eq(p1.get("y", -9999), 0.0, "default y should be 0.0")


func test_add_player_with_custom_position() -> void:
	var start_pos := Vector3(100.0, 200.0, 0.0)
	PlayerSessions.add_player(1, VALID_TOKEN, "alice", start_pos)
	var positions: Dictionary = PlayerSessions.get_positions()
	var p1: Dictionary = positions.get(1) as Dictionary
	assert_eq(p1.get("x", -9999), 100.0, "x should match provided position")
	assert_eq(p1.get("y", -9999), 200.0, "y should match provided position")


func test_update_position_updates_coordinates() -> void:
	PlayerSessions.add_player(1, VALID_TOKEN, "alice")
	PlayerSessions.update_position(1, Vector3(50.0, 75.0, 0.0))
	var positions: Dictionary = PlayerSessions.get_positions()
	var p1: Dictionary = positions.get(1) as Dictionary
	assert_eq(p1.get("x", -9999), 50.0, "x should be updated")
	assert_eq(p1.get("y", -9999), 75.0, "y should be updated")


func test_update_position_on_unknown_peer_no_crash() -> void:
	# Should not crash or raise error for unknown peer
	PlayerSessions.update_position(999, Vector3(10.0, 20.0, 0.0))
	var positions: Dictionary = PlayerSessions.get_positions()
	assert_eq(
		positions.size(), 0, "get_positions should still be empty after updating unknown peer"
	)


func test_get_positions_empty_when_no_players() -> void:
	var positions: Dictionary = PlayerSessions.get_positions()
	assert_true(positions.is_empty(), "get_positions should return empty dict with no players")


func test_get_positions_multiple_players() -> void:
	var r1 := PlayerSessions.add_player(1, VALID_TOKEN, "alice", Vector3(10.0, 20.0, 0.0))
	var r2 := PlayerSessions.add_player(2, VALID_TOKEN_2, "bob", Vector3(30.0, 40.0, 0.0))
	var positions: Dictionary = PlayerSessions.get_positions()
	assert_true(r1, "add player 1 should succeed")
	assert_true(r2, "add player 2 should succeed")
	assert_true(positions.has(1), "should have player 1")
	assert_true(positions.has(2), "should have player 2")
	var p1: Dictionary = positions.get(1) as Dictionary
	var p2: Dictionary = positions.get(2) as Dictionary
	assert_eq(p1.get("username", ""), "alice", "alice should have correct username")
	assert_eq(p1.get("x", -9999), 10.0, "alice x should be 10.0")
	assert_eq(p1.get("y", -9999), 20.0, "alice y should be 20.0")
	assert_eq(p2.get("username", ""), "bob", "bob should have correct username")
	assert_eq(p2.get("x", -9999), 30.0, "bob x should be 30.0")
	assert_eq(p2.get("y", -9999), 40.0, "bob y should be 40.0")


func test_update_position_does_not_affect_other_players() -> void:
	PlayerSessions.add_player(1, VALID_TOKEN, "alice", Vector3(0.0, 0.0, 0.0))
	PlayerSessions.add_player(2, VALID_TOKEN_2, "bob", Vector3(0.0, 0.0, 0.0))
	PlayerSessions.update_position(1, Vector3(100.0, 200.0, 0.0))
	var positions: Dictionary = PlayerSessions.get_positions()
	var p1: Dictionary = positions.get(1) as Dictionary
	var p2: Dictionary = positions.get(2) as Dictionary
	assert_eq(p1.get("x", -9999), 100.0, "alice x updated")
	assert_eq(p2.get("x", -9999), 0.0, "bob x unchanged")


func test_remove_player_clears_position() -> void:
	PlayerSessions.add_player(1, VALID_TOKEN, "alice", Vector3(5.0, 10.0, 0.0))
	PlayerSessions.remove_player(1)
	var positions: Dictionary = PlayerSessions.get_positions()
	assert_eq(positions.size(), 0, "positions should be empty after remove")


func test_update_position_repeated_updates() -> void:
	PlayerSessions.add_player(1, VALID_TOKEN, "alice")
	PlayerSessions.update_position(1, Vector3(10.0, 10.0, 0.0))
	PlayerSessions.update_position(1, Vector3(20.0, 20.0, 0.0))
	PlayerSessions.update_position(1, Vector3(30.0, 30.0, 0.0))
	var positions: Dictionary = PlayerSessions.get_positions()
	var p1: Dictionary = positions.get(1) as Dictionary
	assert_eq(p1.get("x", -9999), 30.0, "x should reflect last update")
	assert_eq(p1.get("y", -9999), 30.0, "y should reflect last update")


# ---- T-015: Disconnect/Reconnect / Session Lifecycle tests ----


func test_preserve_on_disconnect_saves_session_data() -> void:
	PlayerSessions.add_player(1, VALID_TOKEN, "alice", Vector3(10.0, 20.0, 0.0))
	PlayerSessions.update_position(1, Vector3(100.0, 200.0, 0.0))
	PlayerSessions.preserve_on_disconnect(1)

	# Active player should be removed
	var active: Dictionary = PlayerSessions.get_player(1)
	assert_true(active.is_empty(), "active player should be cleared after preserve")

	# Should be retrievable from disconnected sessions
	var restored: Dictionary = PlayerSessions.restore_session(VALID_TOKEN)
	assert_false(restored.is_empty(), "restore should return data for preserved token")
	assert_eq(restored.get("username", ""), "alice", "username should be preserved")
	var pos: Vector3 = restored.get("last_pos", Vector3(-9999, -9999, 0.0))
	assert_eq(pos.x, 100.0, "last_pos.x should match final position")
	assert_eq(pos.y, 200.0, "last_pos.y should match final position")


func test_preserve_on_disconnect_noop_unknown_peer() -> void:
	# Should not crash for unknown peer_id
	PlayerSessions.preserve_on_disconnect(999)
	var restored: Dictionary = PlayerSessions.restore_session(VALID_TOKEN)
	assert_true(restored.is_empty(), "restore should be empty when no session was preserved")


func test_restore_session_consumes_entry() -> void:
	PlayerSessions.add_player(1, VALID_TOKEN, "alice", Vector3(10.0, 20.0, 0.0))
	PlayerSessions.preserve_on_disconnect(1)

	var first: Dictionary = PlayerSessions.restore_session(VALID_TOKEN)
	assert_false(first.is_empty(), "first restore should return data")

	var second: Dictionary = PlayerSessions.restore_session(VALID_TOKEN)
	assert_true(second.is_empty(), "second restore should return empty (consumed)")


func test_restore_session_unknown_token() -> void:
	var restored: Dictionary = PlayerSessions.restore_session("nonexistent_token")
	assert_true(restored.is_empty(), "restore for unknown token should return empty")


func test_cleanup_expired_removes_old_sessions() -> void:
	PlayerSessions.add_player(1, VALID_TOKEN, "alice", Vector3(10.0, 20.0, 0.0))
	PlayerSessions.preserve_on_disconnect(1)

	# Manually age the session beyond max age
	PlayerSessions._age_session(VALID_TOKEN, 600.0)  # 10 minutes ago

	var cleaned = PlayerSessions.cleanup_expired(300.0)
	assert_eq(cleaned, 1, "should have cleaned 1 expired session")

	var restored: Dictionary = PlayerSessions.restore_session(VALID_TOKEN)
	assert_true(restored.is_empty(), "expired session should be gone after cleanup")


func test_cleanup_expired_keeps_fresh_sessions() -> void:
	PlayerSessions.add_player(1, VALID_TOKEN, "alice", Vector3(10.0, 20.0, 0.0))
	PlayerSessions.preserve_on_disconnect(1)

	# Session is fresh (just created), should survive
	var cleaned = PlayerSessions.cleanup_expired(300.0)
	assert_eq(cleaned, 0, "should not clean fresh session")

	var restored: Dictionary = PlayerSessions.restore_session(VALID_TOKEN)
	assert_false(restored.is_empty(), "fresh session should still be restorable")


func test_cleanup_expired_noop_empty() -> void:
	var cleaned = PlayerSessions.cleanup_expired(300.0)
	assert_eq(cleaned, 0, "cleanup should return 0 when no disconnected sessions")


func test_cleanup_expired_multiple_mixed() -> void:
	# Add and preserve two sessions
	PlayerSessions.add_player(1, VALID_TOKEN, "alice", Vector3(10.0, 20.0, 0.0))
	PlayerSessions.preserve_on_disconnect(1)

	PlayerSessions.add_player(2, VALID_TOKEN_2, "bob", Vector3(30.0, 40.0, 0.0))
	PlayerSessions.preserve_on_disconnect(2)

	# Age only alice's session
	PlayerSessions._age_session(VALID_TOKEN, 600.0)

	var cleaned = PlayerSessions.cleanup_expired(300.0)
	assert_eq(cleaned, 1, "should clean only the old session")

	# Alice gone, bob still there
	assert_true(PlayerSessions.restore_session(VALID_TOKEN).is_empty(), "alice should be cleaned")
	assert_false(PlayerSessions.restore_session(VALID_TOKEN_2).is_empty(), "bob should remain")


func test_restore_returns_position_for_reconnect() -> void:
	PlayerSessions.add_player(1, VALID_TOKEN, "alice", Vector3(50.0, 60.0, 0.0))
	PlayerSessions.update_position(1, Vector3(100.0, 200.0, 0.0))
	PlayerSessions.preserve_on_disconnect(1)

	var restored: Dictionary = PlayerSessions.restore_session(VALID_TOKEN)
	assert_eq(restored.get("username", ""), "alice", "should have username")
	var pos: Vector3 = restored.get("last_pos", Vector3(-1, -1, 0.0))
	assert_eq(pos.x, 100.0, "last_pos x should reflect last update")
	assert_eq(pos.y, 200.0, "last_pos y should reflect last update")


func test_preserve_clears_token_reuse_guard() -> void:
	# After preserve, the token should NOT be in _tokens_used (so it can be reused)
	PlayerSessions.add_player(1, VALID_TOKEN, "alice")
	PlayerSessions.preserve_on_disconnect(1)

	# Adding a new player with the same token should succeed
	var result: bool = PlayerSessions.add_player(2, VALID_TOKEN, "alice", Vector3(10.0, 20.0, 0.0))
	assert_true(result, "token should be reusable after preserve (reconnect)")


func test_reconnect_session_with_position() -> void:
	# Full flow: add -> move -> preserve -> restore -> re-add with restored position
	PlayerSessions.add_player(1, VALID_TOKEN, "alice", Vector3.ZERO)
	PlayerSessions.update_position(1, Vector3(100.0, 200.0, 0.0))
	PlayerSessions.preserve_on_disconnect(1)

	var restored: Dictionary = PlayerSessions.restore_session(VALID_TOKEN)
	assert_false(restored.is_empty(), "should have restored data")

	var last_pos: Vector3 = restored.get("last_pos", Vector3.ZERO)
	var result: bool = PlayerSessions.add_player(
		3, VALID_TOKEN, restored.get("username", ""), last_pos
	)
	assert_true(result, "re-add with restored token should succeed")

	var player: Dictionary = PlayerSessions.get_player(3)
	assert_eq(player.get("username", ""), "alice", "reconnected player has same username")
	var pos: Vector3 = player.get("pos", Vector3(-1, -1, 0.0))
	assert_eq(pos.x, 100.0, "reconnected player has restored position x")
	assert_eq(pos.y, 200.0, "reconnected player has restored position y")


# ---- T-028: Automated reconnect test scenarios ----


func test_no_ghost_session_after_reconnect() -> void:
	# Ghost prevention: preserve + restore + re-add must result in exactly 1 active player.
	# The preserved session is consumed by restore_session (one-shot).
	PlayerSessions.add_player(1, VALID_TOKEN, "alice", Vector3(10.0, 20.0, 0.0))
	PlayerSessions.preserve_on_disconnect(1)
	PlayerSessions.restore_session(VALID_TOKEN)
	PlayerSessions.add_player(2, VALID_TOKEN, "alice", Vector3(10.0, 20.0, 0.0))

	var players: Dictionary = PlayerSessions.list_players()
	assert_eq(players.size(), 1, "only 1 active player after reconnect, no ghost")
	assert_true(players.has(2), "active player is the new peer_id")
	assert_false(players.has(1), "old peer_id must be gone")

	# Disconnected sessions must be empty after restore consumed it
	var restored_again: Dictionary = PlayerSessions.restore_session(VALID_TOKEN)
	assert_true(
		restored_again.is_empty(), "no residual disconnected session after restore consumed it"
	)


func test_expired_token_creates_new_session() -> void:
	# T-028 scenario 3: cleanup_expired removes the session, reconnecting with same token
	# creates a brand new session at default position, not restoring old position.
	PlayerSessions.add_player(1, VALID_TOKEN, "alice", Vector3(100.0, 200.0, 0.0))
	PlayerSessions.preserve_on_disconnect(1)

	# Age the session so cleanup removes it
	PlayerSessions._age_session(VALID_TOKEN, 600.0)
	var cleaned = PlayerSessions.cleanup_expired(300.0)
	assert_eq(cleaned, 1, "expired session was cleaned up")

	# Reconnect with same token — should succeed as a NEW session
	var result: bool = PlayerSessions.add_player(3, VALID_TOKEN, "alice")
	assert_true(result, "add_player must succeed after cleanup (token released)")

	var player: Dictionary = PlayerSessions.get_player(3)
	assert_eq(player.get("username", ""), "alice", "username from add_player param")
	var pos: Vector3 = player.get("pos", Vector3.ZERO)
	assert_eq(pos.x, 0.0, "new session starts at default position (not old position)")
	assert_eq(pos.y, 0.0, "new session starts at default position (not old position)")


func test_ghost_prevention_with_two_clients() -> void:
	# Simulate two peers using the same token — only one should be active.
	# Peer A connects, disconnects (preserved), peer B connects with same token.
	PlayerSessions.add_player(1, VALID_TOKEN, "alice", Vector3(10.0, 10.0, 0.0))
	PlayerSessions.preserve_on_disconnect(1)

	# Peer B connects with same token (reconnect)
	PlayerSessions.add_player(2, VALID_TOKEN, "alice")
	var players: Dictionary = PlayerSessions.list_players()
	assert_eq(players.size(), 1, "only 1 player active — no ghost from old peer")

	# Now simulate a NEW different peer trying same token — must be rejected
	var duplicate: bool = PlayerSessions.add_player(5, VALID_TOKEN, "imposter")
	assert_false(duplicate, "third peer with same token must be rejected")

	# Active count still 1
	assert_eq(PlayerSessions.list_players().size(), 1, "still exactly 1 active player")


func test_reconnect_preserves_username_across_cycles() -> void:
	# Reconnect multiple times, username must remain stable.
	PlayerSessions.add_player(1, VALID_TOKEN, "alice", Vector3.ZERO)
	PlayerSessions.update_position(1, Vector3(50.0, 60.0, 0.0))

	# Cycle 1: disconnect -> restore -> reconnect
	PlayerSessions.preserve_on_disconnect(1)
	var r1: Dictionary = PlayerSessions.restore_session(VALID_TOKEN)
	PlayerSessions.add_player(
		2, VALID_TOKEN, r1.get("username", ""), r1.get("last_pos", Vector3.ZERO)
	)

	var p2: Dictionary = PlayerSessions.get_player(2)
	assert_eq(p2.get("username", ""), "alice", "username preserved in cycle 1")

	# Cycle 2: disconnect -> restore -> reconnect
	PlayerSessions.preserve_on_disconnect(2)
	var r2: Dictionary = PlayerSessions.restore_session(VALID_TOKEN)
	PlayerSessions.add_player(
		3, VALID_TOKEN, r2.get("username", ""), r2.get("last_pos", Vector3.ZERO)
	)

	var p3: Dictionary = PlayerSessions.get_player(3)
	assert_eq(p3.get("username", ""), "alice", "username preserved in cycle 2")
	var pos3: Vector3 = p3.get("pos", Vector3.ZERO)
	assert_eq(pos3.x, 50.0, "position preserved through 2 reconnect cycles")
	assert_eq(pos3.y, 60.0, "position preserved through 2 reconnect cycles")


func test_positions_broadcast_after_reconnect() -> void:
	# After reconnect, get_positions must reflect restored position.
	PlayerSessions.add_player(1, VALID_TOKEN, "alice", Vector3.ZERO)
	PlayerSessions.update_position(1, Vector3(99.0, 88.0, 0.0))
	PlayerSessions.preserve_on_disconnect(1)

	var restored: Dictionary = PlayerSessions.restore_session(VALID_TOKEN)
	var last_pos: Vector3 = restored.get("last_pos", Vector3.ZERO)
	PlayerSessions.add_player(2, VALID_TOKEN, "alice", last_pos)

	var positions: Dictionary = PlayerSessions.get_positions()
	assert_true(positions.has(2), "positions dict has reconnected peer")
	var p: Dictionary = positions.get(2) as Dictionary
	assert_eq(p.get("username", ""), "alice", "broadcast has correct username")
	assert_eq(p.get("x", -9999), 99.0, "broadcast has restored x position")
	assert_eq(p.get("y", -9999), 88.0, "broadcast has restored y position")
