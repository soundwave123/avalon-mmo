extends GutTest

# T-583 (report #39): craft/use-item never pushed the client bag — the T-570 "server state correct,
# client never pushed" pattern found again on the crafting/consumable paths. craft_service.gd has a
# set_inventory_push(inv_push: Callable) seam (T-570 wired it for _gather only), but _craft and
# _use_item never called it, so a successful craft or item use left the bag panel stale until a
# manual reopen even though craft_op/use_item_op already return the fresh post-op slots
# master-side. Split into its own file (mirrors why test_hud_handlers_result.gd exists) because
# test_gather_nodes.gd is already at the gdlint max-public-methods cap.

const _CRAFT = preload("res://scripts/craft_service.gd")
const _CONTENT = preload("res://scripts/content/content_registry.gd")
const _CQ = preload("res://scripts/content/content_query.gd")


# Records world->master calls; replies with a canned response (no master in unit scope). Mirrors
# test_gather_nodes.gd's own local stub (each test file owns its stub — test_social_service.gd /
# test_battleground_service.gd precedent).
class StubMaster:
	var calls: Array = []
	var response: Dictionary = {"ok": true}

	func call_master(method: String, params: Dictionary) -> Dictionary:
		calls.append({"method": method, "params": params})
		return response


var _replies: Array = []
var _stub: StubMaster
var _svc


func before_each() -> void:
	_replies = []
	_stub = StubMaster.new()
	_svc = _CRAFT.new()
	var loaded: Dictionary = _CONTENT.load_all("res://data")
	assert_eq(str(loaded["errors"]), "[]", "content loads clean")
	var err: String = _svc.setup(
		_stub,
		func(_pid: int, msg: Dictionary) -> void: _replies.append(msg),
		"res://data",
		_CQ.item_registry(loaded["items"]),
		loaded["npcs"]
	)
	assert_eq(err, "", "craft service loads recipes + nodes clean")


func _player_at(x: float, y: float) -> Dictionary:
	return {"username": "alice", "pos": Vector3(x, y, 0.0)}


func _last() -> Dictionary:
	return _replies[-1] if not _replies.is_empty() else {}


# A successful craft consumes inputs + grants the output master-side (craft_op's "slots"), but
# "craft_result" isn't a type client_net.gd renders bag state from — mirrors the T-570 gather push
# so the bag panel doesn't go stale until the panel is manually reopened.
func test_craft_pushes_inventory_update_via_injected_hook() -> void:
	var pushed: Array = []
	_svc.set_inventory_push(func(pid: int, slots: Array) -> void: pushed.append([pid, slots]))
	_stub.response = {"ok": true, "slots": [{"item_id": "itm_potion_minor_healing", "count": 1}]}
	await _svc.handle("craft", 5, _player_at(0.0, 0.0), {"recipe_id": "rec_minor_healing"})
	assert_eq(pushed.size(), 1, "inventory push hook fired once")
	assert_eq(pushed[0][0], 5, "pushed to the crafting peer")
	assert_eq(
		str(pushed[0][1][0]["item_id"]),
		"itm_potion_minor_healing",
		"carries the master-returned slots"
	)
	assert_eq(
		str(_last().get("type", "")), "craft_result", "craft_result reply also still went out"
	)


# A rejected craft (missing materials, unknown recipe, etc.) must never push — no master-confirmed
# slots to show.
func test_craft_failure_does_not_push_inventory_update() -> void:
	var pushed: Array = []
	_svc.set_inventory_push(func(pid: int, slots: Array) -> void: pushed.append([pid, slots]))
	_stub.response = {"error": "missing_materials"}
	await _svc.handle("craft", 5, _player_at(0.0, 0.0), {"recipe_id": "rec_minor_healing"})
	assert_eq(pushed.size(), 0, "a rejected craft never pushes an inventory update")


# A successful use-item consumes the item master-side (use_item_op's "slots") — same gap as craft.
func test_use_item_pushes_inventory_update_via_injected_hook() -> void:
	var pushed: Array = []
	_svc.set_inventory_push(func(pid: int, slots: Array) -> void: pushed.append([pid, slots]))
	_stub.response = {"ok": true, "slots": [], "effect": {"kind": "heal", "amount": 40}}
	await _svc.handle("use_item", 9, _player_at(0.0, 0.0), {"slot_index": 2})
	assert_eq(pushed.size(), 1, "inventory push hook fired once")
	assert_eq(pushed[0][0], 9, "pushed to the item-using peer")
	assert_eq(pushed[0][1], [], "carries the master-returned (now-consumed) slots")
	assert_eq(
		str(_last().get("type", "")), "use_item_result", "use_item_result reply also still went out"
	)


# A rejected use-item (empty slot, non-usable item) must never push.
func test_use_item_failure_does_not_push_inventory_update() -> void:
	var pushed: Array = []
	_svc.set_inventory_push(func(pid: int, slots: Array) -> void: pushed.append([pid, slots]))
	_stub.response = {"error": "empty_slot"}
	await _svc.handle("use_item", 9, _player_at(0.0, 0.0), {"slot_index": 2})
	assert_eq(pushed.size(), 0, "a rejected use-item never pushes an inventory update")
