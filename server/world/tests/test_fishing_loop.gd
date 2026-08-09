extends GutTest

# T-659: Crystal Lake fishing stays on the existing server-authoritative gather/craft seam.
# The tests use the real item/node/recipe data and a stub master, mirroring test_gather_nodes.gd.

const _CRAFT = preload("res://scripts/craft_service.gd")
const _CONTENT = preload("res://scripts/content/content_registry.gd")
const _CQ = preload("res://scripts/content/content_query.gd")
const _LAKE_CENTER := Vector2(18.0, 22.0)
const _LAKE_RADIUS := 12.0


class StubMaster:
	var calls: Array = []
	var response: Dictionary = {"ok": true}

	func call_master(method: String, params: Dictionary) -> Dictionary:
		calls.append({"method": method, "params": params})
		return response


class DeferredCast:
	signal finished
	var seconds: float = -1.0

	func wait(duration: float) -> void:
		seconds = duration
		await finished


var _replies: Array = []
var _stub: StubMaster
var _svc
var _loaded: Dictionary


func before_each() -> void:
	_replies = []
	_stub = StubMaster.new()
	_svc = _CRAFT.new()
	_loaded = _CONTENT.load_all("res://data")
	assert_eq(str(_loaded["errors"]), "[]", "content loads clean")
	var err: String = _svc.setup(
		_stub,
		func(_pid: int, msg: Dictionary) -> void: _replies.append(msg),
		"res://data",
		_CQ.item_registry(_loaded["items"]),
		_loaded["npcs"]
	)
	assert_eq(err, "", "craft service loads fishing content clean")


func _rng(seed_value: int = 659) -> RandomNumberGenerator:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	return rng


func _player_at(x: float, y: float) -> Dictionary:
	return {"username": "angler", "pos": Vector3(x, y, 0.0)}


func _fishing_nodes() -> Array:
	var out: Array = []
	for node: Dictionary in _loaded.get("gather_nodes", {}).values():
		if str(node.get("kind", "")) == "fishing":
			out.append(node)
	return out


func test_fishing_cast_waits_then_yields_server_rolled_fish() -> void:
	var nodes := _fishing_nodes()
	assert_true(nodes.size() >= 2, "Crystal Lake has multiple fishing spots")
	if nodes.is_empty():
		return
	var node: Dictionary = nodes[0]
	var cast := DeferredCast.new()
	assert_true(_svc.has_method("set_gather_wait"), "gather seam exposes an injected cast wait")
	if not _svc.has_method("set_gather_wait"):
		return
	_svc.set_gather_wait(Callable(cast, "wait"))
	_svc.tick(_rng())
	_svc.handle(
		"gather", 1, _player_at(float(node["x"]), float(node["y"])), {"node_id": node["id"]}
	)
	assert_true(cast.seconds > 2.0, "fishing cast is longer than the instant herb gather")
	assert_eq(_stub.calls.size(), 0, "catch is not minted before the cast finishes")
	cast.finished.emit()
	assert_eq(_stub.calls.size(), 1, "finished cast makes one master round-trip")
	var caught := str(_stub.calls[0]["params"].get("item_id", ""))
	assert_true(caught.begins_with("itm_fish_"), "the server-selected yield is a fish item")
	assert_true(bool(_replies[-1].get("ok", false)), "catch is acknowledged")


func test_fishing_drop_bands_are_honest_and_distribution_is_sane() -> void:
	var nodes := _fishing_nodes()
	assert_true(not nodes.is_empty(), "fishing node data exists")
	if nodes.is_empty():
		return
	var drops: Array = nodes[0].get("drops", [])
	assert_eq(drops.size(), 3, "common variety plus an uncommon catch")
	var total_chance := 0.0
	for drop: Dictionary in drops:
		var chance := float(drop.get("chance", 0.0))
		total_chance += chance
		assert_true(chance > 0.0 and chance < 1.0, "no fishing drop cheats with chance 1.0")
	assert_almost_eq(total_chance, 1.0, 0.0001, "one honest catch per relaxing cast")
	assert_true(_svc.has_method("_roll_node_yield"), "fishing catch uses a server-side roll")
	if not _svc.has_method("_roll_node_yield"):
		return
	var counts: Dictionary = {}
	var rng := _rng(77)
	for _i in range(10000):
		var caught: Dictionary = _svc._roll_node_yield(nodes[0], rng)
		var item_id := str(caught.get("item_id", ""))
		counts[item_id] = int(counts.get(item_id, 0)) + 1
	for drop: Dictionary in drops:
		var item_id := str(drop["item_id"])
		var observed := float(counts.get(item_id, 0)) / 10000.0
		assert_true(
			absf(observed - float(drop["chance"])) < 0.02,
			"%s observed catch rate tracks its authored band" % item_id
		)


func test_cooking_recipe_consumes_fish_into_cooked_output() -> void:
	assert_true(_svc._recipes.has("rec_crystal_lake_fish"), "cooking recipe is registered")
	if not _svc._recipes.has("rec_crystal_lake_fish"):
		return
	var recipe: Dictionary = _svc._recipes["rec_crystal_lake_fish"]
	assert_eq(str(recipe.get("profession", "")), "cooking")
	assert_true(str(recipe["inputs"][0]["item"]).begins_with("itm_fish_"), "recipe consumes fish")
	assert_eq(str(recipe["output"]["item"]), "itm_food_pan_fried_fish")
	await _svc.handle("craft", 1, _player_at(0.0, 0.0), {"recipe_id": recipe["id"]})
	assert_eq(str(_stub.calls[0]["method"]), "craft_op")
	assert_eq(str(_stub.calls[0]["params"]["recipe"]["output"]["item"]), "itm_food_pan_fried_fish")


func test_fishing_node_respawns_after_its_authored_dwell() -> void:
	var nodes := _fishing_nodes()
	assert_true(not nodes.is_empty(), "fishing node data exists")
	if nodes.is_empty():
		return
	var node: Dictionary = nodes[0]
	_svc.tick(_rng())
	await _svc.handle(
		"gather", 1, _player_at(float(node["x"]), float(node["y"])), {"node_id": node["id"]}
	)
	assert_false(bool(_svc._node_state[node["id"]]["available"]), "cast depletes the fishing spot")
	for _i in range(int(node["respawn_ticks"])):
		_svc.tick(_rng())
	assert_true(bool(_svc._node_state[node["id"]]["available"]), "fishing spot respawns")


func test_fishing_spots_are_on_crystal_lake_shore_and_fish_items_exist() -> void:
	var nodes := _fishing_nodes()
	assert_true(nodes.size() >= 2 and nodes.size() <= 3, "two or three shoreline fishing spots")
	var items := _CQ.item_registry(_loaded["items"])
	var rarities: Dictionary = {}
	for node: Dictionary in nodes:
		var distance := Vector2(float(node["x"]), float(node["y"])).distance_to(_LAKE_CENTER)
		assert_true(
			distance >= _LAKE_RADIUS and distance <= _LAKE_RADIUS + 1.0,
			"%s sits on the 12m Crystal Lake water edge" % node["id"]
		)
		for drop: Dictionary in node.get("drops", []):
			var item_id := str(drop.get("item_id", ""))
			assert_true(items.has(item_id), "%s exists in the item registry" % item_id)
			rarities[str(items.get(item_id, {}).get("rarity", ""))] = true
	assert_true(rarities.has("common"), "the lake yields common fish")
	assert_true(rarities.has("uncommon"), "the lake has an uncommon fish catch")
