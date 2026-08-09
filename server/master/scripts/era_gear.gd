# T-353: Era gear-carry — pure, deterministic re-scale-on-crossing (era-direction.md S4, Rule A).
#
# The owner's binding carry rule: at the rift, each held EPIC/LEGENDARY re-scales exactly ONE hop —
# landing above the new era's rare and below its epic — while everything common-through-rare is
# RETIRED (flagged vendor-only, never deleted without consent). This is the "visible trophy + real
# head-start, chase stays intact" resolution the ledger argued for (S4.3 "Why A wins").
#
# Mirrors the pure-module idiom of inventory_logic.gd / npc_wander.gd: no DB, no OS time, no global
# state; inputs are NEVER mutated (works on a deep copy); same inputs -> identical output. The item
# rarity map is INJECTED ({item_id -> rarity}) because rarities live in server/world's items.json
# (T-031) and master cannot preload it cross-project — the same seam inventory_logic uses.
#
# WHAT THIS RETURNS, AND WHY IT'S AN INDEX NOT A STAT: S4.1 indexes item power to the Era-1 top rare
# (Gravetide, attack 19) = index 100, and states the index "maps back to real stats through the
# existing schema ... no new combat math, just authored numbers on items.json per era". Era-2's
# epic-tier stats are not authored yet (S4.1 caps the Era-1 demo at rare; the balance pass authors
# Era-2 in data, S4.4). So the carry stamps the row with `era_scaled_to` (the item's NEW home era)
# and `era_index` (its re-scaled abstract power, e.g. 660) — the number the S4.3 truth table pins.
# Effective stats derive from the Era-2 authored item at that index when the balance pass lands.
#
# THE ONE-HOP GUARD (S4.3): "exactly one era" is measured from where the item CURRENTLY lives. A
# row already stamped `era_scaled_to` was CARRIED into its current era (a spent relic) and does NOT
# carry again — at the next rift it retires with everything else. Only epics/legendaries a player
# holds as NATIVE items of the source era (no stamp) cross. One hop, always.

extends RefCounted

# S4.1 within-era rarity power index (fit to the shipped stat spread). Anything not listed (e.g.
# "junk") is below common and never carries.
const RARITY_INDEX := {
	"common": 45,
	"uncommon": 65,
	"rare": 100,
	"epic": 150,
	"legendary": 190,
}

# S4.1 era scale S = 6 ("massive upgrade" per era): Era 1 x1, Era 2 x6, Era 3 x36 = pow(S, era-1).
const ERA_SCALE := 6

# S4.3 carry multipliers on the NEW era's rare: epic lands x1.10, legendary x1.25 — both strictly
# inside (new-era rare, new-era epic). These are the balance pass's to tune (S4.4); the CONSTRAINT
# the tuning must hold is asserted by the tests (carried piece in that open interval).
const CARRY_MULT := {
	"epic": 1.10,
	"legendary": 1.25,
}

# Only these rarities carry; common-through-rare retire at the crossing (S4.3).
const CARRY_RARITIES := ["epic", "legendary"]


# The whole-band multiplier for an era (Era 1 -> 1, Era 2 -> 6, Era 3 -> 36).
static func era_band(era: int) -> int:
	return int(pow(ERA_SCALE, max(era - 1, 0)))


static func carries(rarity: String) -> bool:
	return rarity in CARRY_RARITIES


# The re-scaled abstract power index a carried piece lands at in `target_era`: the new era's rare
# times the rarity's carry multiplier. Epic into Era 2 -> 600 * 1.10 = 660; legendary -> 750.
static func rescaled_index(rarity: String, target_era: int) -> int:
	if not carries(rarity):
		return 0
	var new_era_rare: int = RARITY_INDEX["rare"] * era_band(target_era)
	return int(round(new_era_rare * float(CARRY_MULT[rarity])))


# The re-scale pass over a whole inventory at a rift crossing INTO `target_era`.
#   slots     : Array of {slot_type, slot_index, item_id, item_count[, era_scaled_to]} rows
#               (exactly what character_manager.get_inventory returns).
#   target_era: the era being entered (Ashmoor = 2).
#   rarities  : injected {item_id -> rarity} map (server/world content).
# Returns { slots, carried, retired } — a NEW slots array (input untouched); each surviving row is
# stamped either `era_scaled_to`+`era_index` (a carried relic) or `retired = true` (vendor-only).
# `carried`/`retired` are the item_id lists, for the crossing summary + tests.
static func carry(slots: Array, target_era: int, rarities: Dictionary) -> Dictionary:
	var out: Array = []
	var carried: Array = []
	var retired: Array = []
	for row: Dictionary in slots:
		var new_row: Dictionary = row.duplicate(true)
		var item_id: String = str(new_row.get("item_id", ""))
		var rarity: String = str(rarities.get(item_id, ""))
		# Already stamped => it was carried into its current era (a spent relic). One hop: it does
		# NOT re-scale again — it retires like everything sub-epic (S4.3).
		var already_carried: bool = new_row.has("era_scaled_to")
		if carries(rarity) and not already_carried:
			new_row["era_scaled_to"] = target_era
			new_row["era_index"] = rescaled_index(rarity, target_era)
			new_row.erase("retired")
			carried.append(item_id)
		else:
			new_row["retired"] = true
			retired.append(item_id)
		out.append(new_row)
	return {"slots": out, "carried": carried, "retired": retired}
