extends "res://addons/gut/test.gd"

# T-716: the world half of the in-world NAME step. The step RENAMES the acting character
# mid-session, and on this server `username` IS the character name (T-507) — the key every master
# round-trip addresses (quests, XP, rested, kill credit, durability) and the name other clients see
# on the nameplate broadcast. If the live session doesn't follow the rename, every later call
# addresses a character that no longer exists. Harness style mirrors test_kit_refresh_gender.gd.

const PlayerSessions = preload("res://scripts/player_sessions.gd")
const AbilityRegistry = preload("res://scripts/combat/ability_registry.gd")
const TalentService = preload("res://scripts/talent_service.gd")
const StatConverter = preload("res://scripts/combat/stat_converter.gd")

const PEER := 61
const TOKEN := "dddddddddddddddddddddddddddddd07"  # gitleaks:allow


class _HarnessMain:
	extends "res://scripts/main.gd"
	var sent: Array = []
	var combat_response: Dictionary = {}

	func _send_to_peer(peer_id: int, data: Dictionary) -> void:
		sent.append({"peer_id": peer_id, "data": data})

	func _fetch_combat(_username: String) -> Dictionary:
		return combat_response


func _make() -> _HarnessMain:
	var m := _HarnessMain.new()
	m._ability_registry = AbilityRegistry.new()
	m._ability_registry.load_from_dir("res://data/abilities")
	return m


func before_each() -> void:
	PlayerSessions._reset_for_test()


# ---- PlayerSessions: the authoritative identity ------------------------------------------------


func test_rename_moves_the_live_session_identity() -> void:
	PlayerSessions.add_player(PEER, TOKEN, "steamfresh", Vector3(1, 2, 0), "steamfresh", 7)
	assert_true(PlayerSessions.rename_player(PEER, "aldric"))
	assert_eq(str(PlayerSessions.get_player(PEER).get("username", "")), "aldric")
	# The positions broadcast is where OTHER clients read a nameplate from.
	assert_eq(str(PlayerSessions.get_positions()[PEER]["username"]), "aldric")
	# Everything else about the session survives the rename.
	assert_eq(str(PlayerSessions.get_player(PEER).get("account", "")), "steamfresh")
	assert_eq(int(PlayerSessions.get_player(PEER).get("character_id", -1)), 7)


func test_rename_follows_into_the_preserved_reconnect_record() -> void:
	PlayerSessions.add_player(PEER, TOKEN, "steamfresh", Vector3.ZERO, "steamfresh", 7)
	PlayerSessions.rename_player(PEER, "aldric")
	PlayerSessions.preserve_on_disconnect(PEER)
	assert_eq(
		str(PlayerSessions.restore_session(TOKEN).get("username", "")),
		"aldric",
		"a rename immediately before a drop must not restore the dead name"
	)


func test_rename_refuses_an_unknown_peer_or_an_empty_name() -> void:
	PlayerSessions.add_player(PEER, TOKEN, "steamfresh", Vector3.ZERO)
	assert_false(PlayerSessions.rename_player(PEER, ""), "never blanks a live identity")
	assert_false(PlayerSessions.rename_player(999, "aldric"))
	assert_eq(str(PlayerSessions.get_player(PEER).get("username", "")), "steamfresh")


# ---- world main: the kit-refresh seam resyncs its display/telemetry cache ----------------------


# _refresh_kit_after_training is the post-rename resync seam (talent_service calls it on a
# successful set_name). world main's _connected_players copy feeds combat/death/recap names AND the
# apply_death_wear master call, so a stale copy there is a real bug, not cosmetics.
func test_kit_refresh_resyncs_worlds_connected_player_cache_after_a_rename() -> void:
	PlayerSessions.add_player(PEER, TOKEN, "steamfresh", Vector3.ZERO)
	var m := _make()
	m._connected_players[PEER] = {"username": "steamfresh"}
	m._char_class[PEER] = "warrior"
	m._char_gender[PEER] = "female"
	m.combat_response = {"class_locked": true, "gender": "female"}
	PlayerSessions.rename_player(PEER, "aldric")

	await m._refresh_kit_after_training(PEER)

	assert_eq(str(m._connected_players[PEER]["username"]), "aldric", "the cache follows the rename")
	m.free()


# ---- the wire: set_name is routed, and naming truth rides player_stats -------------------------


func test_set_name_is_a_routed_creation_intent() -> void:
	var svc := TalentService.new()
	assert_true(svc.handles("set_name"), "the world routes the name step like set_class/set_gender")


func test_player_stats_carries_the_name_and_whether_the_step_is_owed() -> void:
	var owed := StatConverter.player_stats_msg({"name": "steamfresh", "name_chosen": false})
	assert_eq(str(owed["name"]), "steamfresh", "seeds the client's default suggestion")
	assert_false(bool(owed["name_chosen"]), "so the client knows to show the name modal")
	var done := StatConverter.player_stats_msg({"name": "aldric", "name_chosen": true})
	assert_true(bool(done["name_chosen"]))
	# A payload with no naming fields must never re-ask an existing character.
	assert_true(bool(StatConverter.player_stats_msg({}).get("name_chosen", false)))
