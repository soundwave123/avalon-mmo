class_name VendorOps
extends RefCounted
const _RI = preload("res://scripts/rpc_intake.gd")  # T-754 shape guards

# T-430: master-owned vendor coordinator. The world supplies SERVER content (this NPC's wares
# and the item registry) after its proximity gate; the client supplies only a desire. This module
# resolves the character from the session-derived username and re-validates ownership, stock,
# price, bag room, and balance. Item + coin + ledger changes commit atomically.

const _CM := preload("res://scripts/character_manager.gd")
const _IL := preload("res://scripts/inventory_logic.gd")
const _IP := preload("res://scripts/inventory_persist.gd")  # T-567: wearable-unlock derivation
const _CL := preload("res://scripts/coin_ledger.gd")

const MAX_BUYBACK := 8

# T-475: the vendor spread — buying costs full `vendor_value`, selling pays this percentage
# of it (floored, never below 1 for a sellable item). The classic passive coin sink: every
# vendor round-trip burns the spread, per the owner's option (a) ruling on the T-475 row.
const SELL_RATE_PCT := 25

# Per-character, master-process state. A client can only name an index into its own list;
# item/count/sale price are saved by a successful sale and never accepted from the request.
var _buyback: Dictionary = {}  # character_id -> Array[{item_id,count,price,name}]


func op(params: Dictionary) -> Dictionary:
	var cid := _char_id(str(params.get("username", "")))
	if cid < 0:
		return {"error": "unknown_character"}
	var registry: Dictionary = _RI.shaped(params, "item_registry", {})
	var wares: Array = _RI.shaped(params, "wares", [])
	match str(params.get("action", "browse")):
		"browse":
			return _view(cid, wares, registry)
		"sell":
			return _sell(cid, params, wares, registry)
		"buy":
			return _buy(cid, str(params.get("item_id", "")), wares, registry)
		"buyback":
			return _rebuy(cid, int(params.get("buyback_index", -1)), wares, registry)
	return {"error": "unknown_action"}


# Guard-heavy trust boundary: each early return is a distinct fail-closed authority check.
# gdlint: disable=max-returns
func _sell(cid: int, params: Dictionary, wares: Array, registry: Dictionary) -> Dictionary:
	var slots: Array = _CM.get_inventory(cid)
	var slot_index := int(params.get("slot_index", -1))
	var owned: Dictionary = {}
	for row: Dictionary in slots:
		if str(row.get("slot_type", "")) == "bag" and int(row.get("slot_index", -1)) == slot_index:
			owned = row
			break
	if owned.is_empty():
		# Equipped gear is deliberately not a sell surface: return it to a bag first so the normal
		# T-399 unequip path refreshes stats and durability/gear state stays coherent.
		for row: Dictionary in slots:
			if (
				str(row.get("slot_type", "")) in _IL.EQUIP_SLOTS
				and int(row.get("slot_index", -1)) == slot_index
			):
				return {"error": "must_unequip"}
		return {"error": "empty_slot"}
	var requested := int(params.get("count", 1))
	if requested < 1:
		return {"error": "bad_count"}
	var count := mini(requested, int(owned.get("item_count", 0)))
	var item_id := str(owned.get("item_id", ""))
	if not registry.has(item_id):
		return {"error": "unknown_item"}
	var item_def: Dictionary = registry[item_id]
	var unit_value := int(item_def.get("vendor_value", 0))
	if unit_value <= 0:
		return {"error": "no_vendor_value"}
	var removed := _IL.remove(slots, "bag", slot_index, count)
	if not bool(removed.get("ok", false)):
		return {"error": str(removed.get("reason", "remove_failed"))}
	var price := sell_unit_price(unit_value) * count
	if not ServicesStore.commit_inventory_coins(
		cid, removed["slots"], price, _CL.REASON_VENDOR_SELL
	):
		return {"error": "persist_failed"}
	var rows: Array = _buyback.get(cid, [])
	(
		rows
		. push_front(
			{
				"item_id": item_id,
				"count": count,
				"price": price,
				"name": str(item_def.get("name", item_id)),
			}
		)
	)
	if rows.size() > MAX_BUYBACK:
		rows.resize(MAX_BUYBACK)
	_buyback[cid] = rows
	var out := _view(cid, wares, registry)
	out.merge({"sold": item_id, "count": count, "price": price})
	return out


func _buy(cid: int, item_id: String, wares: Array, registry: Dictionary) -> Dictionary:
	if not item_id in _stock_ids(wares, registry):
		return {"error": "not_stocked"}
	var item_def: Dictionary = registry[item_id]
	var price := int(item_def.get("vendor_value", 0))
	if price <= 0:
		return {"error": "not_for_sale"}
	if ServicesStore.get_coins(cid) < price:
		return {"error": "insufficient_coins"}
	var added := _IL.add_items(_CM.get_inventory(cid), [{"item_id": item_id, "count": 1}], registry)
	if not bool(added.get("ok", false)):
		return {"error": str(added.get("reason", "grant_failed"))}
	var unlocks := _IP.wearable_appearance_ids([{"item_id": item_id, "count": 1}], registry)
	if not ServicesStore.commit_inventory_coins(
		cid, added["slots"], -price, _CL.REASON_VENDOR_BUY, unlocks
	):
		return {"error": "persist_failed"}
	var out := _view(cid, wares, registry)
	out.merge({"bought": item_id, "count": 1, "price": price})
	return out


func _rebuy(cid: int, index: int, wares: Array, registry: Dictionary) -> Dictionary:
	var rows: Array = _buyback.get(cid, [])
	if index < 0 or index >= rows.size():
		return {"error": "invalid_buyback"}
	var saved: Dictionary = rows[index]
	var item_id := str(saved.get("item_id", ""))
	var count := int(saved.get("count", 0))
	var price := int(saved.get("price", 0))
	if not registry.has(item_id) or count < 1 or price < 1:
		return {"error": "invalid_buyback"}
	if ServicesStore.get_coins(cid) < price:
		return {"error": "insufficient_coins"}
	var added := _IL.add_items(
		_CM.get_inventory(cid), [{"item_id": item_id, "count": count}], registry
	)
	if not bool(added.get("ok", false)):
		return {"error": str(added.get("reason", "grant_failed"))}
	var unlocks := _IP.wearable_appearance_ids([saved], registry)
	if not ServicesStore.commit_inventory_coins(
		cid, added["slots"], -price, _CL.REASON_VENDOR_BUY, unlocks
	):
		return {"error": "persist_failed"}
	rows.remove_at(index)
	_buyback[cid] = rows
	var out := _view(cid, wares, registry)
	out.merge({"bought": item_id, "count": count, "price": price, "buyback_purchase": true})
	return out


func _view(cid: int, wares: Array, registry: Dictionary) -> Dictionary:
	var bag: Array = []
	for row: Dictionary in _CM.get_inventory(cid):
		if str(row.get("slot_type", "")) != "bag":
			continue
		var item_id := str(row.get("item_id", ""))
		var item_def: Dictionary = registry.get(item_id, {})
		var value := int(item_def.get("vendor_value", 0))
		if value <= 0:
			continue
		(
			bag
			. append(
				{
					"slot_index": int(row.get("slot_index", -1)),
					"item_id": item_id,
					"item_count": int(row.get("item_count", 0)),
					"name": str(item_def.get("name", item_id)),
					# T-475: the bag view quotes what the vendor PAYS (the spread sell
					# price), so the client renders honest proceeds, not list price.
					"vendor_value": sell_unit_price(value),
				}
			)
		)
	var saved_view: Array = []
	var saved: Array = _buyback.get(cid, [])
	for index in range(saved.size()):
		var row: Dictionary = saved[index]
		(
			saved_view
			. append(
				{
					"index": index,
					"item_id": str(row.get("item_id", "")),
					"count": int(row.get("count", 0)),
					"price": int(row.get("price", 0)),
					"name": str(row.get("name", row.get("item_id", ""))),
				}
			)
		)
	return {
		"ok": true,
		"coins": ServicesStore.get_coins(cid),
		"wares": _stock_view(wares, registry),
		"bag": bag,
		"buyback": saved_view,
	}


func _stock_ids(wares: Array, registry: Dictionary) -> Array:
	var ids: Array = []
	for raw in wares:
		var item_id := str(raw)
		if registry.has(item_id) and not item_id in ids:
			ids.append(item_id)
	return ids


func _stock_view(wares: Array, registry: Dictionary) -> Array:
	var out: Array = []
	for item_id: String in _stock_ids(wares, registry):
		var item_def: Dictionary = registry[item_id]
		var price := int(item_def.get("vendor_value", 0))
		if price > 0:
			(
				out
				. append(
					{
						"item_id": item_id,
						"name": str(item_def.get("name", item_id)),
						"price": price,
					}
				)
			)
	return out


# T-475: what the vendor pays per unit for an item listed at `unit_value`. Integer floor of
# SELL_RATE_PCT, but never below 1: anything sellable at all is worth at least one copper.
func sell_unit_price(unit_value: int) -> int:
	return maxi(1, int(unit_value * SELL_RATE_PCT / 100.0))


func _char_id(username: String) -> int:
	if username == "":
		return -1
	_CM.ensure_character(username)
	var character := _CM.get_character(username)
	return int(character.get("id", -1)) if not character.is_empty() else -1
