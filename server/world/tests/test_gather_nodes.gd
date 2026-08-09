extends GutTest

# T-414: gathering nodes + the world-side craft service seam.
# Covers: the SHARED respawn math (spawn_respawn.gd == mob_loader parity — generalize, don't
# duplicate), real content loading (recipes.json / gather/nodes.json validate against the live
# item/npc registries), the gather proximity/depletion/respawn cycle, and the trust boundary:
# yields/outputs/effects are named by SERVER registries; forged ids and out-of-range gathers are
# rejected WITHOUT a master round-trip.

const _SRESP = preload("res://scripts/spawn_respawn.gd")
const _ML = preload("res://scripts/combat/mob_loader.gd")
const _MD = preload("res://scripts/combat/mob_data.gd")
const _CRAFT = preload("res://scripts/craft_service.gd")
const _CONTENT = preload("res://scripts/content/content_registry.gd")
const _CQ = preload("res://scripts/content/content_query.gd")


# Records world→master calls; replies with a canned response (no master in unit scope).
class StubMaster:
	var calls: Array = []
	var response: Dictionary = {"ok": true}

	func call_master(method: String, params: Dictionary) -> Dictionary:
		calls.append({"method": method, "params": params})
		return response


# T-641: a master call that SUSPENDS until the test manually resolves it via `go.emit()` — lets a
# test observe the window between the node claim and the master round-trip actually finishing,
# which StubMaster's synchronous reply can never produce (needed to prove the TOCTOU race closes).
class DeferredStubMaster:
	signal go
	var calls: Array = []
	var response: Dictionary = {"ok": true}

	func call_master(method: String, params: Dictionary) -> Dictionary:
		calls.append({"method": method, "params": params})
		await go
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


func _rng(seed_val: int = 7) -> RandomNumberGenerator:
	var r := RandomNumberGenerator.new()
	r.seed = seed_val
	return r


func _player_at(x: float, y: float) -> Dictionary:
	return {"username": "alice", "pos": Vector3(x, y, 0.0)}


func _last() -> Dictionary:
	return _replies[-1] if not _replies.is_empty() else {}


# ---- shared respawn math (T-411 reuse) -------------------------------------


func test_spawn_respawn_matches_mob_loader() -> void:
	var mob = _MD.new()
	mob.respawn_ticks = 50
	mob.spawn_chance = 0.3
	for seed_val in range(20):
		var a: int = _ML.next_respawn_ticks(mob, _rng(seed_val))
		var b: int = _SRESP.next_ticks(50, 0.3, _rng(seed_val), 12)
		assert_eq(a, b, "mob_loader delegates to the SAME math (seed %d)" % seed_val)


func test_spawn_respawn_common_and_floor_and_cap() -> void:
	assert_eq(_SRESP.next_ticks(600, 1.0, _rng()), 600, "always-present source = exact dwell")
	assert_eq(_SRESP.next_ticks(0, 1.0, _rng()), 1, "dwell floor")
	assert_eq(_SRESP.next_ticks(10, 0.0, _rng(), 12), 120, "chance 0 hits the cycle cap, not never")


# ---- gather cycle -----------------------------------------------------------


func test_gather_in_range_yields_and_depletes() -> void:
	_svc.tick(_rng())  # seed the injected rng
	await _svc.handle("gather", 1, _player_at(2.0, 28.0), {"node_id": "gn_meadow_bloodthorn_1"})
	assert_eq(_stub.calls.size(), 1, "one master round-trip")
	assert_eq(str(_stub.calls[0]["method"]), "gather_op")
	var params: Dictionary = _stub.calls[0]["params"]
	assert_eq(str(params["item_id"]), "itm_herb_bloodthorn", "yield named by the NODE registry")
	assert_true(bool(_last().get("ok", false)), "gather acked")
	# depleted now — a second gather is rejected with NO master call
	await _svc.handle("gather", 1, _player_at(2.0, 28.0), {"node_id": "gn_meadow_bloodthorn_1"})
	assert_eq(_stub.calls.size(), 1, "no second round-trip while depleted")
	assert_eq(str(_last().get("reason", "")), "depleted")


func test_depleted_node_respawns_after_its_dwell() -> void:
	_svc.tick(_rng())
	await _svc.handle("gather", 1, _player_at(2.0, 28.0), {"node_id": "gn_meadow_bloodthorn_1"})
	for i in range(600):  # nodes.json dwell for this node
		_svc.tick(_rng())
	await _svc.handle("gather", 1, _player_at(2.0, 28.0), {"node_id": "gn_meadow_bloodthorn_1"})
	assert_eq(_stub.calls.size(), 2, "respawned node gathers again")
	assert_true(bool(_last().get("ok", false)))


# T-641 (portal #87): the TOCTOU fix — two gathers racing the SAME node must yield exactly once.
func test_simultaneous_gathers_on_one_node_yield_exactly_once() -> void:
	var stub := DeferredStubMaster.new()
	var svc := _CRAFT.new()
	var loaded: Dictionary = _CONTENT.load_all("res://data")
	var replies: Array = []
	var err: String = svc.setup(
		stub,
		func(_pid: int, msg: Dictionary) -> void: replies.append(msg),
		"res://data",
		_CQ.item_registry(loaded["items"]),
		loaded["npcs"]
	)
	assert_eq(err, "", "content loads clean")
	svc.tick(_rng())
	# Gather #1 starts and suspends INSIDE the master round-trip (deliberately not resolved yet).
	svc.handle("gather", 1, _player_at(2.0, 28.0), {"node_id": "gn_meadow_bloodthorn_1"})
	assert_eq(stub.calls.size(), 1, "gather #1 reached the master and is now suspended mid-flight")
	# Gather #2 races the SAME node while #1 is still in flight.
	svc.handle("gather", 2, _player_at(2.0, 28.0), {"node_id": "gn_meadow_bloodthorn_1"})
	assert_eq(
		stub.calls.size(), 1, "gather #2 never reaches the master — the node is already claimed"
	)
	assert_eq(
		str(replies[-1].get("reason", "")), "depleted", "the racing gather is honestly rejected"
	)
	# Let gather #1 resolve — it should be the ONLY one that actually minted.
	stub.go.emit()
	assert_eq(stub.calls.size(), 1, "still exactly one master round-trip total")
	var oks: Array = replies.filter(func(r): return bool(r.get("ok", false)))
	assert_eq(oks.size(), 1, "exactly one yield across both racing requests")


# The rollback half: if the ONE in-flight gather's master call fails, the node must become
# gatherable again immediately — nothing was actually minted, so the claim must release.
func test_gather_master_failure_releases_the_claim_for_a_retry() -> void:
	var stub := DeferredStubMaster.new()
	stub.response = {"ok": false, "reason": "bag_full"}
	var svc := _CRAFT.new()
	var loaded: Dictionary = _CONTENT.load_all("res://data")
	var replies: Array = []
	var err: String = svc.setup(
		stub,
		func(_pid: int, msg: Dictionary) -> void: replies.append(msg),
		"res://data",
		_CQ.item_registry(loaded["items"]),
		loaded["npcs"]
	)
	assert_eq(err, "", "content loads clean")
	svc.tick(_rng())
	svc.handle("gather", 1, _player_at(2.0, 28.0), {"node_id": "gn_meadow_bloodthorn_1"})
	stub.go.emit()  # resolves the failed gather_op
	assert_false(bool(replies[-1].get("ok", true)), "the failed gather is acked as a failure")
	# A fresh gather on the SAME node must be allowed now — the claim released, nothing was lost.
	svc.handle("gather", 1, _player_at(2.0, 28.0), {"node_id": "gn_meadow_bloodthorn_1"})
	assert_eq(
		stub.calls.size(), 2, "the retry reached the master — the node was NOT stuck depleted"
	)
	stub.go.emit()  # let the retry finish cleanly (no dangling suspended coroutine)


func test_gather_forged_node_id_rejected_without_master_call() -> void:
	await _svc.handle("gather", 1, _player_at(2.0, 28.0), {"node_id": "gn_forged"})
	assert_eq(_stub.calls.size(), 0, "no master round-trip for a forged node id")
	assert_false(bool(_last().get("ok", true)))
	assert_eq(str(_last().get("reason", "")), "unknown_node")


func test_gather_out_of_range_rejected() -> void:
	await _svc.handle("gather", 1, _player_at(50.0, 50.0), {"node_id": "gn_meadow_bloodthorn_1"})
	assert_eq(_stub.calls.size(), 0, "no master round-trip when out of range")
	assert_eq(str(_last().get("reason", "")), "too_far")


func test_gather_nodes_read_feed_lists_availability() -> void:
	await _svc.handle("gather_nodes", 1, _player_at(0.0, 0.0), {})
	var msg := _last()
	assert_eq(str(msg.get("type", "")), "gather_nodes")
	# 5 slice-1 herb nodes + 5 slice-2 smithing nodes (ore/timber) + 2 T-602 starter coppervein
	# nodes (day-one itm_copper_ore source near the village smith) + 3 Crystal Lake fishing spots +
	# T-595 the Heartwold per-zone gather POOL (gn_hw_*: 5 min + 6 bonus + 1 rare = 12 pool nodes,
	# emitted by tools/zonegen/zonegen.py from data/zones/heartwold.json).
	assert_eq(
		msg.get("nodes", []).size(), 27, "the 15 seeded + 12 Heartwold pool nodes are advertised"
	)
	var kinds: Dictionary = {}
	for node: Dictionary in msg.get("nodes", []):
		assert_true(bool(node["available"]), "all available at boot")
		kinds[str(node.get("kind", ""))] = true
	assert_true(kinds.has("herb"), "feed surfaces the server-authored herb visual kind")
	assert_true(kinds.has("ore"), "feed surfaces the server-authored ore visual kind")
	assert_true(kinds.has("timber"), "feed surfaces the server-authored timber visual kind")
	assert_true(kinds.has("fishing"), "feed surfaces the server-authored fishing visual kind")


func test_feed_carries_a_clean_verb_free_display_name() -> void:
	# Report #16: the bloodthorn node's world label must read "Bloodthorn", NOT "Gather herb ...".
	await _svc.handle("gather_nodes", 1, _player_at(0.0, 0.0), {})
	var rows: Array = _last().get("nodes", [])
	var bloodthorn: Dictionary = {}
	for node: Dictionary in rows:
		if str(node.get("item_id", "")) == "itm_herb_bloodthorn":
			bloodthorn = node
			break
	assert_false(bloodthorn.is_empty(), "the bloodthorn node is advertised")
	assert_eq(str(bloodthorn.get("display_name", "")), "Bloodthorn", "clean, verb-free label")
	for node: Dictionary in rows:
		assert_true(node.has("display_name"), "every node carries a server-authored label")
		assert_false(
			str(node["display_name"]).contains("Gather"), "the verb never leaks into names"
		)


# ---- craft + learn routing (server-named defs) -------------------------------


func test_craft_sends_registry_recipe_never_client_output() -> void:
	_stub.response = {"ok": true, "slots": []}
	await (
		_svc
		. handle(
			"craft",
			1,
			_player_at(0.0, 0.0),
			{
				"recipe_id": "rec_minor_healing",
				"output": {"item": "itm_riftward_blade", "count": 99},  # forged — must be ignored
			}
		)
	)
	assert_eq(_stub.calls.size(), 1)
	var recipe: Dictionary = _stub.calls[0]["params"]["recipe"]
	assert_eq(str(recipe["output"]["item"]), "itm_potion_minor_healing", "output is REGISTRY-named")
	assert_eq(str(_last().get("type", "")), "craft_result")


func test_craft_unknown_recipe_rejected_without_master_call() -> void:
	await _svc.handle("craft", 1, _player_at(0.0, 0.0), {"recipe_id": "rec_forged"})
	assert_eq(_stub.calls.size(), 0)
	assert_eq(str(_last().get("reason", "")), "unknown_recipe")


func test_learn_recipe_gated_by_trainer_proximity() -> void:
	# npc_alchemist stands at (-20, 20); far away → too_far, no master call
	await (_svc.handle(
		"learn_recipe",
		1,
		_player_at(0.0, 0.0),
		{"npc_id": "npc_alchemist", "recipe_id": "rec_minor_healing"}
	))
	assert_eq(_stub.calls.size(), 0)
	assert_eq(str(_last().get("reason", "")), "too_far")
	# in range → routed to the master recipe_op with the learn action
	_stub.response = {"known": ["rec_minor_healing"], "coins": 60}
	await (_svc.handle(
		"learn_recipe",
		1,
		_player_at(-20.0, 20.0),
		{"npc_id": "npc_alchemist", "recipe_id": "rec_minor_healing"}
	))
	assert_eq(_stub.calls.size(), 1)
	assert_eq(str(_stub.calls[0]["method"]), "recipe_op")
	assert_true(bool(_last().get("ok", false)))


func test_learn_recipe_wrong_trainer_rejected() -> void:
	# npc_blacksmith (or any non-teaching NPC) must not teach alchemy: not_taught_here
	await (_svc.handle(
		"learn_recipe",
		1,
		_player_at(-20.0, 20.0),
		{"npc_id": "npc_elder", "recipe_id": "rec_minor_healing"}
	))
	assert_eq(_stub.calls.size(), 0)


# ---- smithing (T-414 slice 2 — data-additive on the same validation) --------


# T-570 (report #30): a successful gather must push an inventory update through the injected
# hook, mirroring equip/unequip/drop — before this fix the bag panel looked frozen after a gather
# until it was closed/reopened, because "gather_result" isn't a type the client renders bag state
# from.
func test_gather_pushes_inventory_update_via_injected_hook() -> void:
	var pushed: Array = []
	_svc.set_inventory_push(func(pid: int, slots: Array) -> void: pushed.append([pid, slots]))
	_stub.response = {"ok": true, "slots": [{"item_id": "itm_herb_bloodthorn", "count": 1}]}
	_svc.tick(_rng())
	await _svc.handle("gather", 3, _player_at(2.0, 28.0), {"node_id": "gn_meadow_bloodthorn_1"})
	assert_eq(pushed.size(), 1, "inventory push hook fired once")
	assert_eq(pushed[0][0], 3, "pushed to the gathering peer")
	assert_eq(
		str(pushed[0][1][0]["item_id"]), "itm_herb_bloodthorn", "carries the master-returned slots"
	)


# The push must never fire on a rejected gather (no master-confirmed slots to show).
func test_gather_failure_does_not_push_inventory_update() -> void:
	var pushed: Array = []
	_svc.set_inventory_push(func(pid: int, slots: Array) -> void: pushed.append([pid, slots]))
	await _svc.handle("gather", 3, _player_at(50.0, 50.0), {"node_id": "gn_meadow_bloodthorn_1"})
	assert_eq(pushed.size(), 0, "out-of-range gather never reaches the master, never pushes")


func test_gather_ore_node_yields_server_named_iron() -> void:
	_svc.tick(_rng())
	await _svc.handle("gather", 1, _player_at(-32.0, -36.0), {"node_id": "gn_rocks_ironvein_1"})
	assert_eq(_stub.calls.size(), 1, "one master round-trip")
	var params: Dictionary = _stub.calls[0]["params"]
	assert_eq(str(params["item_id"]), "itm_ore_iron", "yield named by the NODE registry")
	assert_true(bool(_last().get("ok", false)))


func test_smithing_recipe_wrong_trainer_rejected() -> void:
	# The alchemist must NOT teach smithing: in range of Vell, asking for a smith recipe.
	await (_svc.handle(
		"learn_recipe",
		1,
		_player_at(-20.0, 20.0),
		{"npc_id": "npc_alchemist", "recipe_id": "rec_forgehand_broadsword"}
	))
	assert_eq(_stub.calls.size(), 0, "no master round-trip for a wrong-trainer learn")
	assert_eq(str(_last().get("reason", "")), "not_taught_here")


func test_smithing_recipe_learned_at_blacksmith() -> void:
	# Smith Dorrun stands at (12.3, -1.6); in range the learn routes to the master recipe_op.
	_stub.response = {"known": ["rec_forgehand_broadsword"], "coins": 40}
	await (_svc.handle(
		"learn_recipe",
		1,
		_player_at(12.3, -1.6),
		{"npc_id": "npc_blacksmith", "recipe_id": "rec_forgehand_broadsword"}
	))
	assert_eq(_stub.calls.size(), 1)
	assert_eq(str(_stub.calls[0]["method"]), "recipe_op")
	assert_true(bool(_last().get("ok", false)))


func test_forged_smithing_recipe_id_rejected_without_master_call() -> void:
	await _svc.handle("craft", 1, _player_at(0.0, 0.0), {"recipe_id": "rec_forged_smithing"})
	assert_eq(_stub.calls.size(), 0, "no master round-trip for a forged smithing recipe id")
	assert_eq(str(_last().get("reason", "")), "unknown_recipe")


func test_smithing_data_integrity_trainers_and_capstone_effect() -> void:
	# Every smithing recipe is taught by a real smith, and the capstone repair kit's output
	# carries the T-412 partial-repair use_effect (the hook slice 1 added — reused, not rebuilt).
	var loaded: Dictionary = _CONTENT.load_all("res://data")
	var items: Dictionary = _CQ.item_registry(loaded["items"])
	var smith_recipes := 0
	for recipe_id in _svc._recipes:
		var recipe: Dictionary = _svc._recipes[recipe_id]
		if str(recipe.get("profession", "")) != "smithing":
			continue
		smith_recipes += 1
		var trainer := str(recipe.get("trainer_id", ""))
		assert_true(
			trainer in ["npc_blacksmith", "npc_hk_smith"],
			"smithing recipe %s taught by a smith, got %s" % [recipe_id, trainer]
		)
	# T-685: + rec_gemset_charm + rec_heartwood_longbow — the two smithing sinks for the gem/heartwood
	# rare gather procs (both taught by npc_blacksmith) -> 5.
	assert_eq(smith_recipes, 5, "5 smithing recipes seeded")
	var effect: Dictionary = items["itm_smiths_repair_kit"].get("use_effect", {})
	assert_eq(str(effect.get("kind", "")), "repair", "capstone kit rides the repair effect hook")
	assert_eq(float(effect.get("pct", 0.0)), 0.5, "partial (0.5) — never the vendor's full restore")


func test_use_item_heal_applies_via_injected_hook() -> void:
	var healed: Array = []
	_svc.set_heal(func(pid: int, amount: int) -> void: healed.append([pid, amount]))
	_stub.response = {"ok": true, "slots": [], "effect": {"kind": "heal", "amount": 120}}
	await _svc.handle("use_item", 7, _player_at(0.0, 0.0), {"slot_index": 0})
	assert_eq(healed.size(), 1, "heal hook fired once")
	assert_eq(healed[0][0], 7)
	assert_eq(healed[0][1], 120, "amount is the master-returned ITEM DATA amount")
	assert_true(bool(_last().get("ok", false)))
