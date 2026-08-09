extends "res://addons/gut/test.gd"

# T-507: world-side session identity — the handshake binds BOTH the account (dup-login kicks)
# and the master-resolved character (id + name, the gameplay identity), and the master_client
# translation passes the resolved character through to the handshake.

const PlayerSessions = preload("res://scripts/player_sessions.gd")
const MasterClient = preload("res://scripts/master_client.gd")

const TOKEN_A := "abcdef0123456789abcdef0123456789"  # gitleaks:allow
const TOKEN_B := "1234567890abcdef1234567890abcdef"  # gitleaks:allow


func before_each() -> void:
	PlayerSessions._reset_for_test()


func test_session_stores_account_and_character_id() -> void:
	PlayerSessions.add_player(1, TOKEN_A, "shrekmage", Vector3.ZERO, "shrek", 42)
	var player := PlayerSessions.get_player(1)
	assert_eq(str(player["username"]), "shrekmage", "session identity is the character name")
	assert_eq(str(player["account"]), "shrek", "owning account rides the session")
	assert_eq(int(player["character_id"]), 42, "master-resolved character id rides the session")


func test_account_defaults_to_username_for_legacy_sessions() -> void:
	PlayerSessions.add_player(1, TOKEN_A, "solo")
	assert_eq(
		str(PlayerSessions.get_player(1)["account"]),
		"solo",
		"pre-T-507 call shape keeps account == username"
	)


func test_find_live_peers_by_account_matches_across_alts() -> void:
	PlayerSessions.add_player(1, TOKEN_A, "shrekwar", Vector3.ZERO, "shrek", 41)
	PlayerSessions.add_player(2, TOKEN_B, "donkey_hero", Vector3.ZERO, "donkey", 7)
	var peers := PlayerSessions.find_live_peers_by_account("shrek", 99)
	assert_eq(peers.size(), 1, "the account's live peer is found even under an alt name")
	assert_eq(peers[0], 1)
	assert_eq(
		PlayerSessions.find_live_peers_by_account("shrek", 1).size(),
		0,
		"the new peer itself is excluded (kick the OLDER peer only)"
	)
	assert_eq(
		PlayerSessions.find_live_peers_by_account("", 99).size(), 0, "empty account matches nothing"
	)


func test_preserve_and_restore_keep_account_and_character() -> void:
	PlayerSessions.add_player(1, TOKEN_A, "shrekmage", Vector3(3, 4, 0), "shrek", 42)
	PlayerSessions.preserve_on_disconnect(1)
	var restored := PlayerSessions.restore_session(TOKEN_A)
	assert_eq(str(restored["username"]), "shrekmage", "reconnect restores the character name")
	assert_eq(str(restored["account"]), "shrek", "reconnect restores the owning account")
	assert_eq(int(restored["character_id"]), 42, "reconnect restores the character id")


func test_master_translation_passes_resolved_character_through() -> void:
	var client = MasterClient.new()
	var translated: Dictionary = client._translate_master_response(
		{"success": true, "username": "shrek", "character_id": 42, "character_name": "shrekmage"}
	)
	assert_true(bool(translated["valid"]))
	assert_eq(str(translated["username"]), "shrek", "account still rides `username`")
	assert_eq(int(translated["character_id"]), 42, "handshake carries the character id")
	assert_eq(str(translated["character_name"]), "shrekmage", "and the character name")
	client.free()


func test_master_translation_surfaces_select_required() -> void:
	var client = MasterClient.new()
	var translated: Dictionary = client._translate_master_response(
		{"success": false, "reason": "character_select_required"}
	)
	assert_false(bool(translated["valid"]))
	assert_eq(
		str(translated["error"]),
		"character_select_required",
		"the world can tell the client WHY the handshake was refused"
	)
	client.free()
