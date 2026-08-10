class_name LootOps
extends RefCounted

# T-644 (portal #89): kill-loot grant with party fallback + hold-for-retry — the *Ops-module
# extraction pattern (auction_ops/craft_ops/vendor_ops), keeping master/main.gd under its line cap.
# Mirrors T-609's fail-closed idiom: never destroy a drop on a bag-full grant failure. Tries
# `usernames` in order (killer first, then in-range party fallback candidates world_rpc already
# resolved) and grants to the first one with room. On TOTAL failure the drop is parked in an
# in-memory per-username pending list and retried opportunistically the next time that username is
# a `grant_loot` candidate again (their next kill/loot event) — the smallest honest hold-and-retry
# shape: no new schema/table, same spirit as T-609's retry-on-next-sweep design, scoped down since
# kill loot (unlike an AH lot) has no listing/escrow row to carry state on. Held loot does NOT
# survive a master restart (in-memory only) — an accepted first-cut simplification, same as every
# other `_test_*`-style static store in this module family; a real mailbox (T-613) is the eventual
# durable answer.

const CharacterManager = preload("res://scripts/character_manager.gd")
const _RI = preload("res://scripts/rpc_intake.gd")  # T-754 shape guards

static var _pending: Dictionary = {}  # username -> Array[{item_id:String, count:int}]


# params: {usernames: Array[String], items: Array, item_registry: Dict, quest_defs: Dict}
# Returns {ok, reason, credited, granted_to, held}.
static func grant_or_hold(params: Dictionary) -> Dictionary:
	var usernames: Array = _RI.shaped(params, "usernames", [])
	var items: Array = _RI.shaped(params, "items", [])
	var item_registry: Dictionary = _RI.shaped(params, "item_registry", {})
	var quest_defs: Dictionary = _RI.shaped(params, "quest_defs", {})
	for raw_username in usernames:
		var username := str(raw_username)
		if username == "":
			continue
		var character: Dictionary = CharacterManager.get_character(username)
		if character.is_empty():
			continue
		var character_id: int = int(character.get("id", -1))
		_flush_pending(character_id, username, item_registry)  # T-644: retry any held drop first
		var result: Dictionary = CharacterManager.try_add_items(character_id, items, item_registry)
		if bool(result.get("ok", false)):
			var credited: Array = CharacterManager.refresh_collect_for_character(
				character_id, quest_defs
			)
			return {
				"ok": true,
				"reason": "",
				"credited": credited,
				"granted_to": username,
				"held": false,
			}
	var primary := str(usernames[0]) if not usernames.is_empty() else ""
	if primary != "":
		_hold(primary, items)
	return {"ok": false, "reason": "bag_full", "credited": [], "granted_to": "", "held": true}


static func _hold(username: String, items: Array) -> void:
	var q: Array = _pending.get(username, [])
	q.append_array(items)
	_pending[username] = q


static func _flush_pending(character_id: int, username: String, item_registry: Dictionary) -> void:
	var q: Array = _pending.get(username, [])
	if q.is_empty():
		return
	var result: Dictionary = CharacterManager.try_add_items(character_id, q, item_registry)
	if bool(result.get("ok", false)):
		_pending.erase(username)
	# else: leave parked (untouched, idempotent) — retried again on the next grant_loot call


# Test/introspection hook: peek held items for a username without waiting on a real grant.
static func pending_for(username: String) -> Array:
	return _pending.get(username, []).duplicate()


# Test isolation: GUT reuses one process across test files; static state must not leak between them.
static func _reset_for_tests() -> void:
	_pending.clear()
