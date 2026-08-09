class_name SocialStore
extends RefCounted

# T-361 item 2: persisted per-character friends + ignore lists (chars.character_social, migration
# 013). Same test-mode discipline as ServicesStore: CharacterManager.reset_for_test() chains into
# reset_for_test() here, and DB plumbing rides character_manager's db_query/db_execute.
#
# Server-authority notes: the WORLD resolves the acting username from the live session; the target
# is resolved HERE against the persisted character table (an unknown name is rejected — the client
# can never inject an id). Rows reference character ids, so a rename-proof list; names are joined
# out at read time.

const _CM := preload("res://scripts/character_manager.gd")

const KINDS := ["friend", "ignore"]
const MAX_LIST := 50  # per kind — an abuse bound, matches classic-WoW-scale lists

static var _test_rows: Dictionary = {}  # cid -> {kind -> {target_id: true}}
static var _test_help: Dictionary = {}  # cid -> bool; absent means schema default TRUE


static func reset_for_test() -> void:
	_test_rows.clear()
	_test_help.clear()


# Single entry point (master main dispatch). params: {username, action, target_name}.
# actions: add_friend|remove_friend|add_ignore|remove_ignore|list. Every mutation returns the
# fresh lists so the world/client never have to guess at state.
static func op(params: Dictionary) -> Dictionary:
	var character := _CM.get_character(str(params.get("username", "")))
	if character.is_empty():
		return {"error": "unknown_character"}
	var cid := int(character["id"])
	var action := str(params.get("action", "list"))
	if action == "set_help":
		_set_help(cid, bool(params.get("subscribed", true)))
		return {
			"friends": names(cid, "friend"),
			"ignored": names(cid, "ignore"),
			"help_subscribed": help_subscribed(cid),
		}
	if action != "list":
		var parts := action.split("_")  # add_friend -> [add, friend]
		if parts.size() != 2 or not KINDS.has(parts[1]):
			return {"error": "unknown_action"}
		var target := _CM.get_character(str(params.get("target_name", "")))
		if target.is_empty():
			return {"error": "unknown_target"}
		var tid := int(target["id"])
		if tid == cid:
			return {"error": "self_target"}
		if parts[0] == "add":
			if names(cid, parts[1]).size() >= MAX_LIST:
				return {"error": "list_full"}
			_add(cid, parts[1], tid)
		elif parts[0] == "remove":
			_remove(cid, parts[1], tid)
		else:
			return {"error": "unknown_action"}
	return {
		"friends": names(cid, "friend"),
		"ignored": names(cid, "ignore"),
		"help_subscribed": help_subscribed(cid),
	}


# New/existing characters inherit the additive DB default TRUE. Opt-out is persisted per character
# and only controls routing membership; it never affects combat/progression state.
static func help_subscribed(cid: int) -> bool:
	if _CM._test_skip_db:
		return bool(_test_help.get(cid, true))
	var rows := _CM.db_query("SELECT help_subscribed FROM chars.characters WHERE id = $1", [cid])
	if rows.is_empty():
		return false
	var value: Variant = rows[0].get("help_subscribed", true)
	return value if value is bool else str(value) in ["t", "true"]


static func _set_help(cid: int, subscribed: bool) -> void:
	if _CM._test_skip_db:
		_test_help[cid] = subscribed
		return
	_CM.db_execute(
		"UPDATE chars.characters SET help_subscribed = $1 WHERE id = $2", [subscribed, cid]
	)


# The target usernames of one list, sorted — also feeds the world's chat-filter cache at login
# (get_character_combat carries ignore_names).
static func names(cid: int, kind: String) -> Array:
	if _CM._test_skip_db:
		var out: Array = []
		for tid in _test_rows.get(cid, {}).get(kind, {}):
			out.append(str(_CM.get_character_by_id(int(tid)).get("name", "")))
		out.sort()
		return out
	var rows: Array = _CM.db_query(
		(
			"SELECT c.name AS username FROM chars.character_social s "
			+ "JOIN chars.characters c ON c.id = s.target_id "
			+ "WHERE s.character_id = $1 AND s.kind = $2 ORDER BY c.name"
		),
		[cid, kind]
	)
	var out: Array = []
	for row in rows:
		out.append(str(row.get("username", "")))
	return out


static func _add(cid: int, kind: String, tid: int) -> void:
	if _CM._test_skip_db:
		var mine: Dictionary = _test_rows.get(cid, {})
		var lst: Dictionary = mine.get(kind, {})
		lst[tid] = true
		mine[kind] = lst
		_test_rows[cid] = mine
		return
	_CM.db_execute(
		(
			"INSERT INTO chars.character_social (character_id, kind, target_id) "
			+ "VALUES ($1, $2, $3) ON CONFLICT DO NOTHING"
		),
		[cid, kind, tid]
	)


static func _remove(cid: int, kind: String, tid: int) -> void:
	if _CM._test_skip_db:
		_test_rows.get(cid, {}).get(kind, {}).erase(tid)
		return
	_CM.db_execute(
		(
			"DELETE FROM chars.character_social "
			+ "WHERE character_id = $1 AND kind = $2 AND target_id = $3"
		),
		[cid, kind, tid]
	)
