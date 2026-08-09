extends GutTest

# T-657: T-650 credited collect-quest progress master-side (gather_op/craft_op's
# result["collect_refreshed"], a list of quest ids) on a successful gather/craft, but
# craft_service.gd never forwarded it to the client — the live quest-tracker HUD stayed stuck at a
# stale count until turn-in. craft_service.gd now has a set_quest_delta_push(cb: Callable) seam
# (mirrors set_inventory_push/T-570) that fires once per credited quest id, the same shape as
# world_rpc.gd:707-712's equip-credit push. Split into its own file — same "one gap, one file"
# precedent as test_craft_inventory_push.gd (T-583).

const _CRAFT = preload("res://scripts/craft_service.gd")
const _CONTENT = preload("res://scripts/content/content_registry.gd")
const _CQ = preload("res://scripts/content/content_query.gd")


# Records world->master calls; replies with a canned response (no master in unit scope). Mirrors
# test_craft_inventory_push.gd's own local stub (each test file owns its stub).
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
	# T-677: gather nodes now carry a weighted yield, so the gather-grant path draws from the
	# injected rng (the same T-411 seam fishing already used) — seed it before any gather here.
	var rng := RandomNumberGenerator.new()
	rng.seed = 657
	_svc.tick(rng)


func _player_at(x: float, y: float) -> Dictionary:
	return {"username": "alice", "pos": Vector3(x, y, 0.0)}


# A successful gather that credited a collect objective (gather_op's collect_refreshed) must push
# a quest_delta for every credited quest id, via the injected callback — the exact gap the ticket
# found live (DB progress climbed, HUD tracker stayed at "0/5" until turn-in).
func test_gather_pushes_quest_delta_for_each_credited_collect_quest() -> void:
	var pushed: Array = []
	_svc.set_quest_delta_push(
		func(pid: int, uname: String, qid: String) -> void: pushed.append([pid, uname, qid])
	)
	_stub.response = {
		"ok": true,
		"slots": [{"item_id": "itm_herb_bloodthorn", "count": 1}],
		"collect_refreshed": ["q005"],
	}
	await _svc.handle("gather", 7, _player_at(2.0, 28.0), {"node_id": "gn_meadow_bloodthorn_1"})
	assert_eq(pushed.size(), 1, "quest-delta push fired once for the one credited quest")
	assert_eq(pushed[0][0], 7, "pushed to the gathering peer")
	assert_eq(pushed[0][1], "alice", "carries the gathering player's username")
	assert_eq(pushed[0][2], "q005", "carries the credited quest id")


# Same gap, the craft path (craft_op's collect_refreshed) — mirrors the equip-credit shape too.
func test_craft_pushes_quest_delta_for_each_credited_collect_quest() -> void:
	var pushed: Array = []
	_svc.set_quest_delta_push(
		func(pid: int, uname: String, qid: String) -> void: pushed.append([pid, uname, qid])
	)
	_stub.response = {
		"ok": true,
		"slots": [{"item_id": "itm_potion_minor_healing", "count": 1}],
		"collect_refreshed": ["q005", "q009"],
	}
	await _svc.handle("craft", 8, _player_at(0.0, 0.0), {"recipe_id": "rec_minor_healing"})
	assert_eq(pushed.size(), 2, "one push per credited quest id")
	assert_eq(pushed[0][2], "q005")
	assert_eq(pushed[1][2], "q009")


# A successful gather/craft that credited NOTHING (no active collect quest touched) must not push.
func test_gather_with_no_collect_refreshed_pushes_nothing() -> void:
	var pushed: Array = []
	_svc.set_quest_delta_push(
		func(pid: int, uname: String, qid: String) -> void: pushed.append([pid, uname, qid])
	)
	_stub.response = {"ok": true, "slots": [{"item_id": "itm_herb_bloodthorn", "count": 1}]}
	await _svc.handle("gather", 7, _player_at(2.0, 28.0), {"node_id": "gn_meadow_bloodthorn_1"})
	assert_eq(pushed.size(), 0, "no collect_refreshed in the master result -> no push")


# A rejected gather/craft must never push — no master-confirmed credit to relay.
func test_craft_failure_never_pushes_quest_delta() -> void:
	var pushed: Array = []
	_svc.set_quest_delta_push(
		func(pid: int, uname: String, qid: String) -> void: pushed.append([pid, uname, qid])
	)
	_stub.response = {"error": "missing_materials"}
	await _svc.handle("craft", 8, _player_at(0.0, 0.0), {"recipe_id": "rec_minor_healing"})
	assert_eq(pushed.size(), 0, "a rejected craft never pushes a quest delta")
