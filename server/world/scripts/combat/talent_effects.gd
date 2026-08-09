# T-064: pure talent effect resolver (world side) — a character's spent talents become
# ability modifiers that layer onto T-063 execution. Stat effects (stat_add) are resolved
# MASTER-side (the character authority) before stats reach the world; this module owns the
# ability-level verbs:
#   ability_damage_pct — % damage/healing per rank on one ability (ability_id 0 = all)
#   ability_cost_pct   — % cost reduction per rank on one ability (ability_id 0 = all)
#
# Pure/deterministic — no OS time, no RNG, no side effects.

extends RefCounted

const ALL_ABILITIES := 0  # effect.ability_id 0 targets every ability


# spent: {talent_id: ranks}; defs: {talent_id: talent def dict}.
# Returns {"damage_pct": {ability_id: total_pct}, "cost_pct": {ability_id: total_pct}}.
static func ability_mods(spent: Dictionary, defs: Dictionary) -> Dictionary:
	var mods := {"damage_pct": {}, "cost_pct": {}}
	for talent_id in spent:
		var ranks: int = int(spent[talent_id])
		if ranks < 1 or not defs.has(talent_id):
			continue
		var effect: Dictionary = defs[talent_id].get("effect", {})
		var kind: String = str(effect.get("kind", ""))
		if kind != "ability_damage_pct" and kind != "ability_cost_pct":
			continue
		var bucket: String = "damage_pct" if kind == "ability_damage_pct" else "cost_pct"
		var ability_id: int = int(effect.get("ability_id", ALL_ABILITIES))
		var total: float = float(effect.get("pct_per_rank", 0.0)) * ranks
		mods[bucket][ability_id] = float(mods[bucket].get(ability_id, 0.0)) + total
	return mods


# Damage/healing multiplier for one ability: specific + all-ability bonuses are additive.
static func damage_multiplier(mods: Dictionary, ability_id: int) -> float:
	var pct: Dictionary = mods.get("damage_pct", {})
	var total: float = float(pct.get(ability_id, 0.0)) + float(pct.get(ALL_ABILITIES, 0.0))
	return 1.0 + total / 100.0


# Cost multiplier for one ability — reductions are additive, floored at 0 (never negative).
static func cost_multiplier(mods: Dictionary, ability_id: int) -> float:
	var pct: Dictionary = mods.get("cost_pct", {})
	var total: float = float(pct.get(ability_id, 0.0)) + float(pct.get(ALL_ABILITIES, 0.0))
	return maxf(0.0, 1.0 - total / 100.0)


# Effective integer cost after talent reductions (ceil — a nonzero base never rounds free).
static func effective_cost(base: int, mods: Dictionary, ability_id: int) -> int:
	if base <= 0 or mods.is_empty():
		return base
	return int(ceil(float(base) * cost_multiplier(mods, ability_id)))
