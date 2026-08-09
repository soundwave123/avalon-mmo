# T-064: pure talent spend validation + stat modifiers (master side — the character
# authority). The world supplies talent defs (content authority) with each RPC, mirroring
# the quest_defs pattern; nothing here trusts the client.
#
# Pure/deterministic — no DB, no OS time. CharacterManager persists the decisions.

extends RefCounted

# Points in the same tree required per tier above 1 (tier 2 needs 5 points in tree, etc.).
# T-523: 2 -> 5 for the L60-cap tree shape — 7 tiers, so a tier-7 capstone needs 30 points
# in ONE tree; two capstones (62 pts) exceed even the L60 budget (59), forcing a spec choice.
const POINTS_PER_TIER := 5

# T-475 (T-525 fold-in): the reroll coin sink. Cost doubles per prior reroll from a cheap
# first correction up to a hard cap, so experimentation stays affordable while serial
# rebuilds burn real coin. Numbers are grounded in the tools/coin_ledger.py --project
# arithmetic: 150 is ~one mid-band quest reward; the 1000 cap is ~one big Era-2 quest.
const REROLL_BASE_COST := 150
const REROLL_COST_CAP := 1000


static func points_available(level: int) -> int:
	return maxi(0, level - 1)  # 1 talent point per level from L2 (T-035 leveling)


static func points_spent(spent: Dictionary) -> int:
	var total: int = 0
	for talent_id in spent:
		total += int(spent[talent_id])
	return total


static func points_in_tree(spent: Dictionary, defs: Dictionary, tree: String) -> int:
	var total: int = 0
	for talent_id in spent:
		if defs.has(talent_id) and str(defs[talent_id].get("tree", "")) == tree:
			total += int(spent[talent_id])
	return total


# Validate spending ONE point in `talent` given the character's current state.
# Returns {"ok": bool, "reason": String}.
static func validate_spend(
	talent: Dictionary, spent: Dictionary, defs: Dictionary, char_class: String, level: int
) -> Dictionary:
	if str(talent.get("class", "")) != char_class:
		return {"ok": false, "reason": "wrong_class"}
	if points_spent(spent) >= points_available(level):
		return {"ok": false, "reason": "no_points"}
	var talent_id: String = str(talent.get("id", ""))
	if int(spent.get(talent_id, 0)) >= int(talent.get("max_ranks", 1)):
		return {"ok": false, "reason": "max_ranks"}
	var tier: int = int(talent.get("tier", 1))
	var tree: String = str(talent.get("tree", ""))
	if points_in_tree(spent, defs, tree) < (tier - 1) * POINTS_PER_TIER:
		return {"ok": false, "reason": "tier_locked"}
	var prereq: String = str(talent.get("prereq", "")) if talent.get("prereq") != null else ""
	if prereq != "":
		var prereq_max: int = int(defs.get(prereq, {}).get("max_ranks", 1))
		if int(spent.get(prereq, 0)) < prereq_max:
			return {"ok": false, "reason": "prereq_unmet"}
	return {"ok": true, "reason": ""}


# Coin cost of the NEXT reroll given how many the character has already performed.
# 0 prior -> 150, then 300, 600, capped at 1000. Shift bounded so the int math
# can never overflow regardless of the persisted counter.
static func reroll_cost(prior_rerolls: int) -> int:
	var doublings: int = clampi(prior_rerolls, 0, 8)
	return mini(REROLL_BASE_COST * (1 << doublings), REROLL_COST_CAP)


# Apply every spent stat_add talent to a stat vector (flat per-rank adds; % on our small
# integer stats rounds to zero, so flat adds are the tuning currency).
static func apply_stat_mods(
	stat_vec: Dictionary, spent: Dictionary, defs: Dictionary
) -> Dictionary:
	var out: Dictionary = stat_vec.duplicate()
	for talent_id in spent:
		var ranks: int = int(spent[talent_id])
		if ranks < 1 or not defs.has(talent_id):
			continue
		var effect: Dictionary = defs[talent_id].get("effect", {})
		if str(effect.get("kind", "")) != "stat_add":
			continue
		var stat: String = str(effect.get("stat", ""))
		if out.has(stat):
			out[stat] = int(out[stat]) + int(effect.get("per_rank", 0)) * ranks
	return out
