class_name WardrobeService
extends RefCounted

# T-428: client-intent boundary. The client names only a slot + catalog ids. This service replaces
# every other field with server-authored catalog definitions and the session username before the
# master checks persisted ownership. Confirmed slots refresh the public paper-doll gear cache.

const _BB := preload("res://scripts/broadcast_builder.gd")
const _CAT := preload("res://scripts/wardrobe_catalog.gd")
const _INTENTS := [
	"wardrobe_list", "wardrobe_apply", "wardrobe_clear", "wardrobe_hide_helm", "wardrobe_buy"
]

var _master = null
var _reply: Callable = Callable()
var _gear_update: Callable = Callable()
var _catalog = _CAT.new()
var _items: Dictionary = {}


func setup(
	master,
	reply: Callable,
	item_registry: Dictionary,
	catalog_path: String,
	gear_update: Callable = Callable()
) -> String:
	_master = master
	_reply = reply
	_items = item_registry
	_gear_update = gear_update
	return _catalog.setup(catalog_path, item_registry)


func handles(msg_type: String) -> bool:
	return msg_type in _INTENTS


func handle(peer_id: int, player: Dictionary, data: Dictionary) -> void:
	var msg_type := str(data.get("type", ""))
	var params := {"username": str(player.get("username", ""))}
	match msg_type:
		"wardrobe_list":
			params["action"] = "list"
		"wardrobe_apply":
			var look := _catalog.appearance(str(data.get("appearance_id", "")))
			if look.is_empty():
				_reject(peer_id, "unknown_appearance")
				return
			var dye_id := str(data.get("dye_id", ""))
			var dye := _catalog.dye(dye_id)
			if dye_id != "" and dye.is_empty():
				_reject(peer_id, "unknown_dye")
				return
			(
				params
				. merge(
					{
						"action": "apply",
						"slot": str(data.get("slot", "")),
						"appearance": look,
						"dye": dye,
					}
				)
			)
		"wardrobe_clear":
			params.merge({"action": "clear", "slot": str(data.get("slot", ""))})
		"wardrobe_hide_helm":
			params["action"] = "toggle_hide_helm"
		"wardrobe_buy":
			# T-476 store spend. The client names only an appearance_id; the server resolves the
			# priced, power-neutral store row (never a client-asserted price), and the master
			# validates the charter + debits the persisted balance before granting the unlock.
			var store_look := _catalog.store_appearance(str(data.get("appearance_id", "")))
			if store_look.is_empty():
				_reject(peer_id, "not_for_sale")
				return
			params.merge({"action": "purchase", "appearance": store_look})
		_:
			_reject(peer_id, "bad_action")
			return
	var result: Dictionary = await _master.call_master("wardrobe_op", params)
	if not bool(result.get("ok", false)):
		_reject(peer_id, str(result.get("reason", result.get("error", "rejected"))))
		return
	var slots: Array = _enrich_slots(result.get("slots", []))
	if _gear_update.is_valid():
		_gear_update.call(peer_id, _BB.equipped_from_slots(slots))
	(
		_reply
		. call(
			peer_id,
			{
				"type": "wardrobe_state",
				"slots": slots,
				"looks": result.get("looks", {}),
				"appearances": _catalog.unlocked_appearances(result.get("unlocks", [])),
				"dyes": _catalog.all_dyes(),
				"store": _catalog.store_appearances(),
				"cosmetic_currency": int(result.get("cosmetic_currency", 0)),
				"purchased": str(result.get("purchased", "")),
			}
		)
	)


func set_gear_update(callback: Callable) -> void:
	_gear_update = callback


func _enrich_slots(raw_slots: Array) -> Array:
	var out: Array = raw_slots.duplicate(true)
	for slot: Dictionary in out:
		var item_id := str(slot.get("item_id", ""))
		if _items.has(item_id):
			var item: Dictionary = _items[item_id]
			slot["name"] = str(item.get("name", item_id))
			slot["rarity"] = str(item.get("rarity", "common"))
			slot["armor_type"] = str(item.get("armor_type", "none"))
		slot["slot_index"] = int(slot.get("slot_index", 0))
		slot["count"] = int(slot.get("item_count", slot.get("count", 1)))
	return out


func _reject(peer_id: int, reason: String) -> void:
	_reply.call(peer_id, {"type": "wardrobe_result", "ok": false, "reason": reason})
