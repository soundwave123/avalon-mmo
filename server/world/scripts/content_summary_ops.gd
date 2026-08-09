extends RefCounted

# T-613 file-cap carve: content-summary/loot-roll query helpers moved out of world_rpc.gd. All
# synchronous, pure reads of the already-loaded content dictionaries — no `self` fire-and-forget
# async state (unlike kill-credit, which turned out to be too timing-sensitive to safely relocate:
# a test_world_rpc.gd suite ordering regression surfaced when that carve was tried, so it was
# reverted). T-705: the thin world_rpc wrappers are gone — external callers reach these directly
# through the public `world_rpc.content_ops` handle (the file-cap carve idiom).

const _CQ = preload("res://scripts/content/content_query.gd")
const _LOOT = preload("res://scripts/combat/loot_table.gd")  # T-232: rarity weight table
const _DUNGEON_LOOT = preload("res://scripts/combat/dungeon_loot.gd")  # T-333
const _SESSIONS = preload("res://scripts/player_sessions.gd")  # T-709: cid for the pity ledger

var _wr = null  # the owning WorldRpc instance
# T-709: quest-critical loot state. _collect_index: item_id -> true for every collect target any
# quest references (lazy — built on first kill, after the content load). _pity: per-character
# bad-luck ledgers, cid -> {item_id: misses}. In-memory like the threat table (a restart forfeits
# at most 2 banked misses on a starter quest; the rift floor persists because its droughts span
# sessions — these don't).
var _collect_index: Dictionary = {}
var _pity: Dictionary = {}


func setup(world_rpc) -> void:
	_wr = world_rpc


# T-058: which quests can change THIS NPC's indicator — giver, turn-in, talk targets.
func build_npc_quest_index() -> Dictionary:
	var index: Dictionary = {}
	for quest_id in _wr._content_quests:
		var quest: Dictionary = _CQ.quest_to_dict(_wr._content_quests[quest_id])
		var npc_ids: Dictionary = {}
		npc_ids[str(quest.get("giver_npc", ""))] = true
		npc_ids[str(quest.get("turnin_npc", quest.get("giver_npc", "")))] = true
		for obj: Dictionary in quest.get("objectives", []):
			if str(obj.get("type", "")) == "talk":
				npc_ids[str(obj.get("target", ""))] = true
		for npc_id in npc_ids:
			if npc_id == "":
				continue
			var defs: Dictionary = index.get(npc_id, {})
			defs[quest_id] = quest
			index[npc_id] = defs
	return index


func content_summary() -> String:
	var counts := [_wr._content_quests.size(), _wr._content_npcs.size(), _wr._content_items.size()]
	return "%d quests, %d npcs, %d items" % counts


# T-232: item_id -> rarity, for the weighted loot roll below.
func item_rarities() -> Dictionary:
	var out: Dictionary = {}
	for item_id: String in _wr._content_items:
		out[item_id] = _wr._content_items[item_id].rarity
	return out


# T-232: rarity-weighted loot roll for a mob kill; loot content authority stays here.
func roll_mob_loot(loot_entries: Array, difficulty: int, rng: RandomNumberGenerator) -> Array:
	return _LOOT.roll_weighted(
		loot_entries, item_rarities(), _wr._content_rarity_weights, difficulty, rng
	)


# T-709: the kill-loot path — roll with the quest-critical bypass, then hand to loot delivery.
# Async fire-and-forget (mirrors on_mob_kill): when the mob's table touches an item some quest
# collects, ONE quest-log read resolves the killer's live needs so the roll can exempt them from
# the tier gate + apply the bad-luck floor. Mobs whose loot no quest needs skip the master round
# trip entirely and roll exactly as before (the pre-filter keeps the common path synchronous-cheap).
func roll_and_deliver_mob_loot(
	peer_id: int, loot_entries: Array, difficulty: int, rng: RandomNumberGenerator
) -> void:
	var drops: Array
	if not _touches_quest_item(loot_entries):
		drops = roll_mob_loot(loot_entries, difficulty, rng)
	else:
		var view: Dictionary = _SESSIONS.get_player_view(peer_id)
		var log: Dictionary = await _wr._master.call_master(
			"get_quest_log", {"username": str(view.get("username", ""))}
		)
		# A degraded master ({error}) yields no needs — the roll falls back to plain T-232.
		var needs: Dictionary = _LOOT.quest_collect_needs(
			log.get("quests", []), _wr._all_quest_defs_cache
		)
		drops = _LOOT.roll_weighted_quest_bypass(
			loot_entries,
			item_rarities(),
			_wr._content_rarity_weights,
			difficulty,
			needs,
			_pity_for(int(view.get("character_id", 0))),
			rng
		)
	if not drops.is_empty():
		_wr.on_mob_loot(peer_id, drops)


func _touches_quest_item(loot_entries: Array) -> bool:
	if _collect_index.is_empty():
		_collect_index = _LOOT.collect_item_index(_wr._all_quest_defs_cache)
	for entry in loot_entries:
		if entry is Dictionary and _collect_index.has(str(entry.get("item_id", ""))):
			return true
	return false


func _pity_for(cid: int) -> Dictionary:
	if not _pity.has(cid):
		_pity[cid] = {}
	return _pity[cid]


func has_dungeon_schedule(boss_id: String) -> bool:
	return _wr._dungeon_schedule.has(boss_id)


func roll_dungeon_loot(boss_id: String, rng: RandomNumberGenerator) -> Dictionary:
	return _DUNGEON_LOOT.roll_boss(_wr._dungeon_schedule.get(boss_id, {}), rng)
