class_name DurabilityOps
extends RefCounted

# T-364: the two master-owned durability ops — SERVER-OBSERVED (the world calls them; there is NO
# client verb reaching either). Extracted from master/main.gd to keep it under the 1000-line cap.
# Pure of Node state: all persistence rides ServicesStore, all math rides Durability, all tunables
# ride ServerConfig — so a test drives these statics directly.

const CharacterManager := preload("res://scripts/character_manager.gd")
const ServerConfig := preload("res://scripts/server_config.gd")


# Wear every equipped item once for one death. Once-per-death is the WORLD's job (it only calls this
# on the alive→dead edge); the master applies one wear step, lazily seeding a row at DURABILITY_MAX
# the first time an item is worn, then knocking off DURABILITY_WEAR_PCT.
static func apply_death_wear(params: Dictionary) -> Dictionary:
	var cid := _char_id(params)
	if cid < 0:
		return {"error": "unknown_character"}
	var dur: Dictionary = ServicesStore.get_durability(cid)
	var seed: Dictionary = {
		"current": ServerConfig.DURABILITY_MAX, "max": ServerConfig.DURABILITY_MAX
	}
	for entry: Dictionary in Durability.equipped_rows(CharacterManager.get_inventory(cid)):
		var st := str(entry["slot_type"])
		var si := int(entry.get("slot_index", 0))
		var row: Dictionary = dur.get(Durability.slot_key(st, si), seed)
		var mx := int(row["max"])
		var new_cur := Durability.wear(int(row["current"]), mx, ServerConfig.DURABILITY_WEAR_PCT)
		ServicesStore.set_durability(cid, st, si, new_cur, mx)
	return {"ok": true, "durability": ServicesStore.get_durability(cid)}


# Repair ALL worn gear to full. The single coin SINK T-366 held for — the debit rides
# adjust_coins(reason "repair"), which overdraft-guards AND lands the sink in econ.coin_ledger.
# The COST is computed server-side from persisted durability; a client-supplied cost/coins in params
# is ignored (never read). `quote:true` returns the cost with NO side effect (Repair-All preview).
static func repair_op(params: Dictionary) -> Dictionary:
	var cid := _char_id(params)
	if cid < 0:
		return {"error": "unknown_character"}
	var dur: Dictionary = ServicesStore.get_durability(cid)
	# T-412: price each worn slot at ITS item's rarity rate (server-computed; a client-supplied cost is
	# never read). No registry (older callers) → every rarity is "" → base rate → identity with T-364.
	var rarity_by_slot := _rarity_by_slot(cid, params.get("item_registry", {}))
	var cost: int = Durability.repair_cost_scaled(
		dur,
		rarity_by_slot,
		ServerConfig.DURABILITY_REPAIR_RATE_TABLE,
		ServerConfig.DURABILITY_REPAIR_RATE
	)
	if cost <= 0:
		return {"ok": true, "coins": ServicesStore.get_coins(cid), "repaired": 0, "cost": 0}
	if bool(params.get("quote", false)):
		return {"ok": true, "coins": ServicesStore.get_coins(cid), "cost": cost, "quote": true}
	if not ServicesStore.adjust_coins(cid, -cost, "repair"):  # overdraft-guarded; ledgers only on ok
		return {"error": "insufficient_coins", "cost": cost, "coins": ServicesStore.get_coins(cid)}
	for key in dur:
		var parts: PackedStringArray = str(key).split("|")
		ServicesStore.set_durability(
			cid, str(parts[0]), int(parts[1]), int(dur[key]["max"]), int(dur[key]["max"])
		)
	return {"ok": true, "coins": ServicesStore.get_coins(cid), "repaired": dur.size(), "cost": cost}


# T-412: slot_key -> item rarity, from the (world-supplied) item registry. A worn item missing from
# the registry maps to "" (base-rate fallback in repair_cost_scaled). Server-derived from persisted
# inventory — the client never names a slot's rarity or its repair rate.
static func _rarity_by_slot(cid: int, item_registry: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for entry: Dictionary in Durability.equipped_rows(CharacterManager.get_inventory(cid)):
		var key := Durability.slot_key(str(entry["slot_type"]), int(entry.get("slot_index", 0)))
		var idef: Dictionary = item_registry.get(str(entry.get("item_id", "")), {})
		out[key] = str(idef.get("rarity", ""))
	return out


static func _char_id(params: Dictionary) -> int:
	var username := str(params.get("username", ""))
	CharacterManager.ensure_character(username)
	var character := CharacterManager.get_character(username)
	return int(character["id"]) if not character.is_empty() else -1
