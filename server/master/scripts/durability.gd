class_name Durability
extends RefCounted

# T-364: PURE durability decisions for the bounded death penalty + repair coin sink. No DB handle,
# no OS time, no global state — the store (ServicesStore) persists; this module is the math and the
# equipped-slot policy. All tunables are DEFAULT_* constants (data-tunable: retune the severity with
# a one-line constant edit, never a logic change) and the ops pass them in so a test can vary them.
#
# FAIL-OPEN: a slot with no durability row is INDESTRUCTIBLE (full-strength). Wear lazily seeds a
# row at max on the first death. At 0 an item is BROKEN — its stats stop contributing (combat reads
# it as unequipped) — but it is NEVER destroyed, unequipped, or dropped (WoW-lite, bounded).

# Slots that carry stats and therefore wear/repair. 'bag' (loose inventory) is excluded.
const EQUIP_SLOTS := ["head", "chest", "legs", "weapon", "offhand", "shoulders"]  # T-420: pauldrons

# T-399: item-stat name -> combat stat-vector key. EXPLICIT whitelist so an authored item stat maps
# deliberately into a CharacterStats field — never string-matched into a UO-era swing-pool name (the
# "stamina" pool vs the Stamina STAT collision, memory 2026-06). WoW primary aliases map onto the
# str/dex/int the leveling table + damage coeffs read; attack/armor are the two direct combat terms
# (flat weapon power / flat mitigation). An UNMAPPED item stat contributes NOTHING (fail-closed).
const ITEM_STAT_TO_COMBAT := {
	"str": "str",
	"strength": "str",
	"int": "int",
	"intellect": "int",
	"dex": "dex",
	"agility": "dex",
	"spirit": "spirit",
	"stamina": "stamina",
	"attack": "attack",
	"armor": "armor",
}

const DEFAULT_MAX_DURABILITY := 100  # a freshly-worn item seeds at this max
const DEFAULT_WEAR_PCT := 0.10  # fraction of MAX lost per death (10%)
const DEFAULT_REPAIR_RATE := 1  # BASE coin cost per missing durability point (identity/base tier)


static func is_equip_slot(slot_type: String) -> bool:
	return slot_type in EQUIP_SLOTS


static func slot_key(slot_type: String, slot_index: int) -> String:
	return "%s|%d" % [slot_type, slot_index]


# Wear applied to ONE item: lose ceil(max * pct), clamped at 0 (never negative, never destroyed).
static func wear(current_dur: int, max_dur: int, pct: float = DEFAULT_WEAR_PCT) -> int:
	var loss: int = int(ceil(float(max_dur) * pct))
	return maxi(0, current_dur - loss)


static func is_broken(current_dur: int) -> bool:
	return current_dur <= 0


# The equipped rows that would take death wear, from a raw inventory slot list.
static func equipped_rows(inventory: Array) -> Array:
	var out: Array = []
	for entry: Dictionary in inventory:
		if is_equip_slot(str(entry.get("slot_type", ""))):
			out.append(entry)
	return out


# Sum of missing durability across a durability map {slot_key: {current, max}}. Drives the repair
# cost; 0 means nothing to repair.
static func missing_total(dur_map: Dictionary) -> int:
	var total := 0
	for key in dur_map:
		var row: Dictionary = dur_map[key]
		total += maxi(0, int(row.get("max", 0)) - int(row.get("current", 0)))
	return total


static func repair_cost(dur_map: Dictionary, rate: int = DEFAULT_REPAIR_RATE) -> int:
	return missing_total(dur_map) * rate


# T-412: rarity → coin-per-point rate. A rarity absent from the table (or "" for an item with no
# registry row) FALLS BACK to base_rate — never free, never a crash (fail-safe scaling).
static func rate_for_rarity(
	rarity: String, rate_table: Dictionary, base_rate: int = DEFAULT_REPAIR_RATE
) -> int:
	return int(rate_table.get(rarity, base_rate))


# T-412: repair cost that tracks the VALUE of what it mends. Each slot's missing durability priced
# at its own item's rarity rate (rate_for_rarity), so a rare/epic set is a felt coin call while a
# common starter kit stays at the base rate. `rarity_by_slot` maps slot_key -> rarity string; a slot
# missing from it prices at base_rate. IDENTITY: when every slot is base-tier this equals
# repair_cost(dur_map, base_rate) — the shipped flat behavior is the base row of the table.
static func repair_cost_scaled(
	dur_map: Dictionary,
	rarity_by_slot: Dictionary,
	rate_table: Dictionary,
	base_rate: int = DEFAULT_REPAIR_RATE
) -> int:
	var total := 0
	for key in dur_map:
		var row: Dictionary = dur_map[key]
		var missing: int = maxi(0, int(row.get("max", 0)) - int(row.get("current", 0)))
		var rate := rate_for_rarity(str(rarity_by_slot.get(key, "")), rate_table, base_rate)
		total += missing * rate
	return total


# Effective (contributing) equipped stats: sum every equipped item's `stats`, but SKIP an item whose
# durability row is present and broken (current <= 0). A slot with no row is full-strength
# (fail-open). `item_stats_for` maps an item_id -> its {stat: amount} dict (from the item registry).
static func effective_stats(
	inventory: Array, dur_map: Dictionary, item_stats_for: Callable
) -> Dictionary:
	var out: Dictionary = {}
	for entry: Dictionary in equipped_rows(inventory):
		var key := slot_key(str(entry["slot_type"]), int(entry.get("slot_index", 0)))
		if dur_map.has(key) and is_broken(int(dur_map[key].get("current", 0))):
			continue  # broken → contributes nothing, but the row/item still exists
		var stats: Dictionary = item_stats_for.call(str(entry.get("item_id", "")))
		for stat in stats:
			# int() coerces DB-string stat amounts at the boundary (858a10e — hydrated rows arrive as
			# strings; NULL='') so a summed number never becomes string concatenation.
			out[stat] = int(out.get(stat, 0)) + int(stats[stat])
	return out


# T-399: merge summed gear stats (from effective_stats) into a COPY of the base class/level/talent
# stat vector, mapping each item stat name through ITEM_STAT_TO_COMBAT. The base is never mutated.
# Gear adds onto existing primaries and introduces `attack`/`armor`; on a naked character gear_stats
# is {} so the returned vector is byte-identical to the ungeared one (pinned naked-stat tests stay
# green). Unmapped item stats are dropped (fail-closed, per the whitelist above).
static func fold_gear_stats(base_stats: Dictionary, gear_stats: Dictionary) -> Dictionary:
	var out: Dictionary = base_stats.duplicate(true)
	for item_stat in gear_stats:
		if not ITEM_STAT_TO_COMBAT.has(item_stat):
			continue
		var key: String = ITEM_STAT_TO_COMBAT[item_stat]
		out[key] = int(out.get(key, 0)) + int(gear_stats[item_stat])
	return out


# T-399: the whole gear fold in one call — sum contributing equipped stats (effective_stats) and
# merge into `base_stats` (fold_gear_stats). Keeps the master one-derivation-point a single line.
static func fold_equipped_into_stats(
	base_stats: Dictionary, inventory: Array, dur_map: Dictionary, item_stats_for: Callable
) -> Dictionary:
	return fold_gear_stats(base_stats, effective_stats(inventory, dur_map, item_stats_for))
