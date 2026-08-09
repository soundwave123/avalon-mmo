extends "res://addons/gut/test.gd"
# T-414 (slice 3): GatherNodesLayer — builds one clickable world marker per gather node from the
# read-only `gather_nodes` feed, prunes nodes that drop out, and sends {type:gather, node_id} on a
# left-click of an AVAILABLE node (never for a depleted one). Mirrors test_npc_markers.

const GatherNodesLayer = preload("res://scripts/world/gather_nodes_layer.gd")
const ReplyRouter = preload("res://scripts/net/reply_router.gd")

var _layer: GatherNodesLayer = null
var _sent: Array = []


func before_each() -> void:
	_layer = GatherNodesLayer.new()
	add_child(_layer)
	await get_tree().process_frame
	_sent = []
	_layer.setup(func(m: Dictionary): _sent.append(m), null)


func after_each() -> void:
	_layer.queue_free()


func _feed() -> Array:
	return [
		{
			"id": "herb_bloodthorn_1",
			"kind": "herb",
			"x": 2.0,
			"y": 28.0,
			"item_id": "itm_herb_bloodthorn",
			"available": true
		},
		{
			"id": "herb_bloodthorn_2",
			"kind": "herb",
			"x": -2.0,
			"y": 30.0,
			"item_id": "itm_herb_bloodthorn",
			"available": false
		},
	]


func test_builds_a_marker_per_node_from_the_feed() -> void:
	_layer.update(_feed())
	assert_eq(_layer.node_count(), 2)
	assert_true(_layer.is_available("herb_bloodthorn_1"), "available node is gatherable")
	assert_false(_layer.is_available("herb_bloodthorn_2"), "depleted node reads spent")


func test_node_positioned_at_server_ground_coords() -> void:
	_layer.update(_feed())
	var pos := _layer.node_position("herb_bloodthorn_1")
	assert_almost_eq(pos.x, 2.0, 0.001)
	assert_almost_eq(pos.z, 28.0, 0.001)  # server (x, y) ground → Godot (x, 0, y)


func test_stale_node_pruned_on_next_feed() -> void:
	_layer.update(_feed())
	assert_eq(_layer.node_count(), 2)
	_layer.update([_feed()[0]])  # second node drops out of the feed
	assert_eq(_layer.node_count(), 1, "a node absent from the feed is pruned")
	assert_true(_layer.is_available("herb_bloodthorn_1"))


func test_depletion_flips_availability_without_rebuild() -> void:
	_layer.update(_feed())
	# the same node, now depleted (server flipped available → false on the poll)
	_layer.update([{"id": "herb_bloodthorn_1", "x": 2.0, "y": 28.0, "available": false}])
	assert_false(_layer.is_available("herb_bloodthorn_1"))


func test_each_resource_kind_uses_a_distinct_textured_prop_without_a_box_placeholder() -> void:
	var kinds := ["herb", "ore", "timber", "fibre"]
	var feed: Array = []
	for i in kinds.size():
		(
			feed
			. append(
				{
					"id": "node_%s" % kinds[i],
					"kind": kinds[i],
					"item_id": "itm_%s_test" % kinds[i],
					"x": float(i),
					"y": 20.0,
					"available": true,
				}
			)
		)
	_layer.update(feed)
	var paths: Array[String] = []
	for kind: String in kinds:
		var entry: Dictionary = _layer._nodes["node_%s" % kind]
		var path := str(entry.get("prop_path", ""))
		paths.append(path)
		assert_true(ResourceLoader.exists(path), "%s maps to a real imported prop" % kind)
		var meshes: Array = entry.get("meshes", [])
		assert_gt(meshes.size(), 0, "%s prop has renderable mesh geometry" % kind)
		for mesh: MeshInstance3D in meshes:
			assert_false(mesh.mesh is BoxMesh, "%s never falls back to the greybox cube" % kind)
	assert_eq(
		(
			paths
			. duplicate()
			. reduce(func(acc, path): return acc if acc.has(path) else acc + [path], [])
			. size()
		),
		4,
		"each kind has a distinct prop"
	)


func test_harvest_hides_the_whole_marker_then_respawn_shows_it() -> void:
	_layer.update(_feed())
	var entry: Dictionary = _layer._nodes["herb_bloodthorn_1"]
	var visual = entry.get("visual")
	assert_true((entry["body"] as Node3D).visible, "an available node is visible")
	var depleted := {
		"id": "herb_bloodthorn_1",
		"kind": "herb",
		"item_id": "itm_herb_bloodthorn",
		"display_name": "Bloodthorn",
		"x": 2.0,
		"y": 28.0,
		"available": false,
	}
	_layer.update([depleted])
	assert_same(
		_layer._nodes["herb_bloodthorn_1"].get("visual"),
		visual,
		"state update keeps the prop instance (no rebuild churn)"
	)
	assert_false(
		(_layer._nodes["herb_bloodthorn_1"]["body"] as Node3D).visible,
		"a harvested node's asset + name vanish entirely until it respawns",
	)
	# Server respawn flips it back available on a later poll — the marker reappears.
	var respawned := depleted.duplicate()
	respawned["available"] = true
	_layer.update([respawned])
	assert_true(
		(_layer._nodes["herb_bloodthorn_1"]["body"] as Node3D).visible,
		"the node reappears on respawn",
	)


func test_label_shows_verb_free_display_name() -> void:
	(
		_layer
		. update(
			[
				{
					"id": "herb_bloodthorn_1",
					"kind": "herb",
					"item_id": "itm_herb_bloodthorn",
					"display_name": "Bloodthorn",
					"x": 2.0,
					"y": 28.0,
					"available": true,
				}
			]
		)
	)
	var label := _layer._nodes["herb_bloodthorn_1"]["label"] as Label3D
	assert_eq(label.text, "Bloodthorn", "the billboard reads the clean name, not 'Gather herb ...'")
	assert_false(label.text.contains("Gather"), "the interaction verb never leaks into the name")


func test_click_available_node_sends_gather_intent() -> void:
	_layer.update(_feed())
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = true
	_layer._on_body_input("herb_bloodthorn_1", ev)
	assert_eq(_sent.size(), 1)
	assert_eq(str(_sent[0]["type"]), "gather")
	assert_eq(str(_sent[0]["node_id"]), "herb_bloodthorn_1")
	assert_false(_sent[0].has("item_id"), "the client never names the yield — server-resolved")


func test_click_depleted_node_sends_nothing() -> void:
	_layer.update(_feed())
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = true
	_layer._on_body_input("herb_bloodthorn_2", ev)
	assert_eq(_sent.size(), 0, "a depleted node is unclickable until it respawns")


func test_feed_routes_through_the_reply_router() -> void:
	var router = ReplyRouter.new()
	var layer := GatherNodesLayer.new()
	add_child_autofree(layer)
	layer.setup(func(_m): pass, router)
	router.route({"type": "gather_nodes", "nodes": _feed()})
	assert_eq(layer.node_count(), 2, "the router fanned the feed into the layer")


func test_all_nodes_share_one_shimmer_overlay_material() -> void:
	# T-697 fix 8: the ready-shimmer is ONE shared material — the per-frame pulse is a single
	# alpha write, not a per-node material sweep.
	_layer.update(_feed())
	var a = _layer._nodes["herb_bloodthorn_1"]["highlight"]
	var b = _layer._nodes["herb_bloodthorn_2"]["highlight"]
	assert_true(is_same(a, b), "both nodes reference the same overlay material instance")
	assert_true(is_same(a, _layer._shimmer_mat), "and it is the layer's single shared material")
	_layer._process(0.5)
	var pulsed: float = (_layer._shimmer_mat as StandardMaterial3D).albedo_color.a
	assert_between(pulsed, 0.05, 0.09, "the shared overlay still pulses in the shimmer band")
