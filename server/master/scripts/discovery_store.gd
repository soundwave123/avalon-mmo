class_name DiscoveryStore
extends RefCounted

# T-427: master-owned discovery gate + reward commit. The world supplies only a validated authored
# node after observing an authoritative movement edge; this store resolves character progression,
# applies the gray cutoff/rested split, and persists node+XP+coin in one Postgres statement.

const _CM := preload("res://scripts/character_manager.gd")
const _MX := preload("res://scripts/mob_xp.gd")
const _RP := preload("res://scripts/rested_persist.gd")
const _LV := preload("res://scripts/leveling.gd")
const _SERVICES := preload("res://scripts/services_store.gd")
const _ACH := preload("res://scripts/achievement_store.gd")
const _TEL := preload("res://scripts/telemetry_store.gd")

const MAX_REWARD := 100000

static var _test_discovered: Dictionary = {}  # character_id -> {node_id: true}


static func reset_for_test() -> void:
	_test_discovered.clear()


# Returns the confirmed client-safe result. Re-entry is a successful no-op (`discovered=false`).
static func discover(character_id: int, username: String, node: Dictionary) -> Dictionary:
	if character_id <= 0 or not _valid(node):
		return {"discovered": false, "reason": "invalid_node"}
	var row := _character_row(character_id)
	if row.is_empty():
		return {"discovered": false, "reason": "unknown_character"}
	var node_id := str(node["id"])
	var base_xp := _MX.share(
		int(node.get("xp", 0)), int(node.get("level", 1)), int(row.get("level", 1)), 1
	)
	var split := _RP.split(int(row.get("rested_pool", 0)), base_xp)
	var leveling := _LV.apply_xp(
		int(row.get("level", 1)), int(row.get("xp", 0)), int(split["total"])
	)
	var coins := int(node.get("coins", 0))
	if not _claim_and_reward(character_id, node_id, base_xp, coins, split, leveling):
		return {"discovered": false, "reason": "already_discovered", "node": _view(node)}

	# T-367 first-discovery flag + unique total; T-676 per-zone tally (a fresh node only — the
	# _claim_and_reward gate above already made re-entry a no-op) so a per-zone "find every node here"
	# meta can complete off `discovery_zone:<zone>`.
	var observed := _ACH.observe(character_id, "discovery", node_id)
	var zone_earned: Array = (
		_ACH
		. observe(character_id, "discovery_zone", str(node.get("zone", "")))
		. get("newly_earned", [])
	)
	var result := {
		"discovered": true,
		"reason": "",
		"node": _view(node),
		"xp": base_xp,
		"coins": coins,
		"rested_bonus": int(split["bonus"]),
		"rested_remaining": int(split["pool_after"]),
		"leveling": leveling,
		"achievements": observed.get("newly_earned", []) + zone_earned,
	}
	_TEL.record_discovery(
		username, node_id, str(node.get("zone", "")), base_xp, int(split["bonus"]), coins
	)
	return result


static func _claim_and_reward(
	cid: int, node_id: String, base_xp: int, coins: int, split: Dictionary, leveling: Dictionary
) -> bool:
	if _CM._test_skip_db:
		var mine: Dictionary = _test_discovered.get(cid, {})
		if mine.has(node_id):
			return false
		mine[node_id] = true
		_test_discovered[cid] = mine
		_CM.award_xp_to_character(cid, base_xp, true)
		if coins > 0:
			_SERVICES.adjust_coins(cid, coins, "discovery_reward")
		return true

	# `claimed` is the once-only gate. The XP/rested/coin update and ledger INSERT depend on its
	# returned row, so duplicate entry changes nothing; one SQL statement is one atomic transaction.
	var rows := (
		_CM
		. db_query(
			(
				"WITH claimed AS ("
				+ "INSERT INTO chars.character_discovery "
				+ "(character_id,node_id,xp_granted,rested_bonus,coins_granted) "
				+ "VALUES ($1,$2,$3,$4,$5) ON CONFLICT DO NOTHING RETURNING character_id), "
				+ "updated AS (UPDATE chars.characters SET xp=$6,level=$7,rested_pool=$8,"
				+ "coins=coins+$5 WHERE id=$1 AND EXISTS (SELECT 1 FROM claimed) RETURNING id), "
				+ "ledger AS (INSERT INTO econ.coin_ledger (character_id,delta,reason) "
				+ "SELECT id,$5,'discovery_reward' FROM updated WHERE $5 > 0 RETURNING id) "
				+ "SELECT character_id FROM claimed"
			),
			[
				cid,
				node_id,
				base_xp,
				int(split["bonus"]),
				coins,
				int(leveling["xp"]),
				int(leveling["level"]),
				int(split["pool_after"]),
			]
		)
	)
	return not rows.is_empty()


static func _character_row(cid: int) -> Dictionary:
	if _CM._test_skip_db:
		return _CM.get_character_by_id(cid)
	var rows := _CM.db_query(
		"SELECT id,level,xp,rested_pool FROM chars.characters WHERE id=$1", [cid]
	)
	return rows[0] if not rows.is_empty() else {}


static func _valid(node: Dictionary) -> bool:
	return (
		str(node.get("id", "")) != ""
		and str(node.get("name", "")) != ""
		and str(node.get("zone", "")) != ""
		and int(node.get("level", 0)) >= 1
		and int(node.get("xp", -1)) >= 0
		and int(node.get("xp", -1)) <= MAX_REWARD
		and int(node.get("coins", 0)) >= 0
		and int(node.get("coins", 0)) <= MAX_REWARD
	)


static func _view(node: Dictionary) -> Dictionary:
	return {
		"id": str(node.get("id", "")),
		"name": str(node.get("name", "")),
		"zone": str(node.get("zone", "")),
		"lore": str(node.get("lore", "")),
	}
