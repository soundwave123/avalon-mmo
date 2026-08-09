# T-073: pure loot roll — mob JSON "loot" entries -> the items a kill drops.
#
# Entry shape (data-driven, from data/mobs/*.json):
#   {"item_id": String, "chance": float 0..1, "count_min": int, "count_max": int}
# Output shape matches the master's try_add_items reward contract: [{"item", "count"}].
#
# HARD CONSTRAINTS: no OS time, no global RNG — the caller's seeded rng threads through.

extends RefCounted

# T-709: the qualifying kill by which a quest-critical entry is GUARANTEED (see the quest-critical
# section below): chance rises linearly from the authored base to 1.0 across this many kills
# (chance-1.0 items — the token — hit on kill 1 by construction; the 0.6 pelt runs
# 0.6 -> 0.8 -> 1.0, guaranteed by kill 3).
const QUEST_BLP_GUARANTEE_KILLS := 3


static func roll(loot_entries: Array, rng: RandomNumberGenerator) -> Array:
	var out: Array = []
	for entry in loot_entries:
		if not (entry is Dictionary):
			continue
		var item_id: String = str(entry.get("item_id", ""))
		if item_id == "":
			continue
		var chance: float = clampf(float(entry.get("chance", 1.0)), 0.0, 1.0)
		if chance < 1.0 and rng.randf() > chance:
			continue
		var count_min: int = maxi(1, int(entry.get("count_min", 1)))
		var count_max: int = maxi(count_min, int(entry.get("count_max", count_min)))
		out.append({"item": item_id, "count": rng.randi_range(count_min, count_max)})
	return out


# T-232: read data/loot/rarity_weights.json -> {"1".."5": {rarity: weight}}. Returns {} (loud
# printerr) on a missing/malformed file — callers fall back to the legacy flat roll() above.
static func load_rarity_weights(path: String = "res://data/loot/rarity_weights.json") -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		printerr("[loot_table] cannot open %s" % path)
		return {}
	var parsed = JSON.parse_string(file.get_as_text())
	file.close()
	if parsed == null or not (parsed.get("difficulty_weights", null) is Dictionary):
		printerr('[loot_table] rarity_weights.json malformed (need {"difficulty_weights": {...}})')
		return {}
	return parsed["difficulty_weights"]


# T-232: variable-ratio drop — roll ONE rarity tier from the mob difficulty's weight table,
# then apply the legacy chance/count mechanism (above) to only the loot entries whose item is
# that tier. A kill can land zero drops if the mob has no loot at the rolled tier — that miss
# IS the variable-ratio schedule, not a bug.
#
# Falls back to the legacy flat roll() (every entry considered, ignoring rarity) whenever the
# weight table or the item-rarity registry isn't available — additive, no regression for
# mobs/tests that don't thread rarity data through.
static func roll_weighted(
	loot_entries: Array,
	item_rarities: Dictionary,
	rarity_weights: Dictionary,
	difficulty: int,
	rng: RandomNumberGenerator
) -> Array:
	var tier_weights: Dictionary = rarity_weights.get(str(difficulty), {})
	if tier_weights.is_empty() or item_rarities.is_empty():
		return roll(loot_entries, rng)
	var picked_tier: String = _pick_tier(tier_weights, rng)
	var tier_entries: Array = []
	for entry in loot_entries:
		if not (entry is Dictionary):
			continue
		var item_id: String = str(entry.get("item_id", ""))
		var rarity: String = str(item_rarities.get(item_id, "common"))
		if rarity == picked_tier:
			tier_entries.append(entry)
	return roll(tier_entries, rng)


# --- T-709: quest-critical drops -----------------------------------------------------------
# spawn-loot-reference.md §3 (adopted): an item a player's ACTIVE quest still needs for a collect
# objective must never be tier-gated. The T-232 rarity roll made P(dummy drops the q_tut_01 token)
# 0.90 — 1-in-10 brand-new players saw NOTHING and stared at "Recover a practice token" at the most
# fragile moment. Quest-critical entries skip the tier roll (their authored chance rolls directly)
# and carry bad-luck protection, mirroring the rift bad-luck floor (rift_ladder.gd: honest,
# monotonic, resets on a hit — published fairness, not a hidden buff).


# The bad-luck-protected chance after `misses` qualifying kills without the drop.
static func blp_chance(base_chance: float, misses: int) -> float:
	var base := clampf(base_chance, 0.0, 1.0)
	var step := (1.0 - base) / float(QUEST_BLP_GUARANTEE_KILLS - 1)
	return clampf(base + step * float(maxi(misses, 0)), 0.0, 1.0)


# item_id -> true for every collect objective of an ACTIVE quest in the raw master log
# ({quest_id, state, progress:[int]}) that is still short of its required count. quest_defs is the
# quest_to_dict cache (world_rpc._all_quest_defs_cache). A completed objective drops back to the
# normal tier roll, so the guarantee can't be farmed past the quest's own need.
static func quest_collect_needs(raw_quests: Array, quest_defs: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for rq in raw_quests:
		if not (rq is Dictionary) or str(rq.get("state", "")) != "active":
			continue
		var quest: Dictionary = quest_defs.get(str(rq.get("quest_id", "")), {})
		var progress: Array = rq.get("progress", [])
		var objectives: Array = quest.get("objectives", [])
		for i in range(objectives.size()):
			var obj: Dictionary = objectives[i]
			if str(obj.get("type", "")) != "collect":
				continue
			var cur: int = int(progress[i]) if i < progress.size() else 0
			if cur < int(obj.get("count", 0)):
				out[str(obj.get("target", ""))] = true
	return out


# item_id -> true for every collect target ANY quest references — the cheap pre-filter that lets
# the kill path skip the quest-log fetch entirely for mobs whose loot no quest ever needs.
static func collect_item_index(quest_defs: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for quest_id in quest_defs:
		for obj in quest_defs[quest_id].get("objectives", []):
			if obj is Dictionary and str(obj.get("type", "")) == "collect":
				out[str(obj.get("target", ""))] = true
	return out


# T-709 roll: quest-critical entries (item in `needs`) bypass the tier roll — authored chance +
# bad-luck floor — while everything else keeps the exact T-232 weighted behaviour. `pity` is the
# caller's per-character miss ledger {item_id: misses}; it is MUTATED here (incremented on a miss,
# cleared on a hit) — the one deliberate in-out param, so the ledger and the roll can't drift.
static func roll_weighted_quest_bypass(
	loot_entries: Array,
	item_rarities: Dictionary,
	rarity_weights: Dictionary,
	difficulty: int,
	needs: Dictionary,
	pity: Dictionary,
	rng: RandomNumberGenerator
) -> Array:
	var quest_entries: Array = []
	var rest: Array = []
	for entry in loot_entries:
		if entry is Dictionary and needs.has(str(entry.get("item_id", ""))):
			quest_entries.append(entry)
		else:
			rest.append(entry)
	var out: Array = roll_weighted(rest, item_rarities, rarity_weights, difficulty, rng)
	for entry: Dictionary in quest_entries:
		var item_id := str(entry.get("item_id", ""))
		var chance := blp_chance(float(entry.get("chance", 1.0)), int(pity.get(item_id, 0)))
		if chance >= 1.0 or rng.randf() <= chance:
			var count_min: int = maxi(1, int(entry.get("count_min", 1)))
			var count_max: int = maxi(count_min, int(entry.get("count_max", count_min)))
			out.append({"item": item_id, "count": rng.randi_range(count_min, count_max)})
			pity.erase(item_id)  # the floor resets on a hit, rift-style
		else:
			pity[item_id] = int(pity.get(item_id, 0)) + 1
	return out


# Weighted-random tier pick. Zero/negative-sum weights (or an empty table) fall back to "common"
# so a malformed row never hard-fails a kill.
static func _pick_tier(tier_weights: Dictionary, rng: RandomNumberGenerator) -> String:
	var total: float = 0.0
	for tier in tier_weights:
		total += maxf(0.0, float(tier_weights[tier]))
	if total <= 0.0:
		return "common"
	var roll_point: float = rng.randf() * total
	var acc: float = 0.0
	for tier in tier_weights:
		acc += maxf(0.0, float(tier_weights[tier]))
		if roll_point < acc:
			return str(tier)
	return str(tier_weights.keys()[-1])
