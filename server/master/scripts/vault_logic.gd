class_name VaultLogic
extends RefCounted

# T-208: PURE bank-vault decisions — deposit/withdraw moves between bag and vault slot
# arrays. No I/O: callers pass the inventory rows (character_manager persists the plan).
# Capacity tiers: base 12 vault slots (T-412 turns the "later pass" tier upgrades into a real
# non-punitive coin sink — buy capacity, zero power; all pure math here, coin/persist in the ops).

const VAULT_SLOTS := 12
const BAG_SLOTS := 16


static func _used(inventory: Array, slot_type: String) -> Dictionary:
	var used := {}
	for entry in inventory:
		if str(entry.get("slot_type", "")) == slot_type:
			used[int(entry.get("slot_index", -1))] = entry
	return used


static func _first_free(used: Dictionary, cap: int) -> int:
	for index in range(cap):
		if not used.has(index):
			return index
	return -1


## Plan a move of the stack at (from_type, from_index) to the other side. `vault_cap` is the
## character's CURRENT vault capacity (T-412 tier ladder); it defaults to the tier-0 base so every
## existing caller/test is unchanged.
## Returns {ok, reason?, plan?: {from_type, from_index, to_type, to_index, item_id, item_count}}
static func plan_move(
	inventory: Array, from_type: String, from_index: int, vault_cap: int = VAULT_SLOTS
) -> Dictionary:
	if from_type != "bag" and from_type != "vault":
		return {"ok": false, "reason": "bad_slot_type"}
	var to_type := "vault" if from_type == "bag" else "bag"
	var cap := vault_cap if to_type == "vault" else BAG_SLOTS
	var source: Dictionary = _used(inventory, from_type).get(from_index, {})
	if source.is_empty():
		return {"ok": false, "reason": "empty_slot"}
	var to_index := _first_free(_used(inventory, to_type), cap)
	if to_index < 0:
		return {"ok": false, "reason": "vault_full" if to_type == "vault" else "bag_full"}
	return {
		"ok": true,
		"plan":
		{
			"from_type": from_type,
			"from_index": from_index,
			"to_type": to_type,
			"to_index": to_index,
			"item_id": str(source.get("item_id", "")),
			"item_count": int(source.get("item_count", 1)),
		}
	}


# T-412 tier ladder (all PURE; the op module owns the coin debit + persistence) -----------------


## Vault capacity at a given tier: base + tier * per. Tier 0 == base (identity with shipped cap).
static func capacity_for_tier(tier: int, base: int = VAULT_SLOTS, per: int = 6) -> int:
	return base + maxi(0, tier) * per


## Cost to advance FROM current_tier TO current_tier+1, from the data ladder. -1 == no further tier.
static func next_tier_cost(current_tier: int, costs: Array) -> int:
	if current_tier < 0 or current_tier >= costs.size():
		return -1
	return int(costs[current_tier])


## Plan a tier PURCHASE. Server-authoritative: the target tier + cost are DERIVED from the persisted
## current tier and the data ladder — the client never names the tier or the price. Returns
## {ok, reason?, new_tier, cost}. cost is validated against `coins` (overdraft fails closed).
static func plan_upgrade(current_tier: int, coins: int, costs: Array) -> Dictionary:
	var cost := next_tier_cost(current_tier, costs)
	if cost < 0:
		return {"ok": false, "reason": "max_tier"}
	if coins < cost:
		return {"ok": false, "reason": "insufficient_coins"}
	return {"ok": true, "new_tier": current_tier + 1, "cost": cost}


## The vault rows only, shaped for the client panel grid.
static func vault_view(inventory: Array) -> Array:
	var rows: Array = []
	for entry in inventory:
		if str(entry.get("slot_type", "")) == "vault":
			(
				rows
				. append(
					{
						"slot_index": int(entry.get("slot_index", 0)),
						"item_id": str(entry.get("item_id", "")),
						"item_count": int(entry.get("item_count", 1)),
					}
				)
			)
	rows.sort_custom(func(a, b): return int(a["slot_index"]) < int(b["slot_index"]))
	return rows
