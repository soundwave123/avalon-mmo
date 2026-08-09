extends "res://addons/gut/test.gd"

# T-694: critter GLBs are pathological deep scenes (rabbit = thousands of instantiated nodes /
# 1,175 MeshInstances, NO AnimationPlayer) that wander as a RIGID unit. Proves, headlessly:
#   * flatten — every placed _CRITTER_CFG critter collapses to <= 10 nodes under its root (vs
#     hundreds-to-thousands raw), with the honest raw count measured in the same test;
#   * cache — all placed instances of a species share ONE merged mesh resource;
#   * the animated-rig guard — mob_sheep (AnimationPlayer) is refused and keeps its rig;
#   * behavior parity — a flattened critter still registers with the wander tick and flees a
#     threat by ROOT transform, exactly as before (the subtree was never behavioral);
#   * the kill-switch A/B — AVALON_CRITTER_FLATTEN=0 semantics restore the raw deep scenes, and
#     the flattened layer is >= 10x fewer total nodes on a critter-heavy manifest.

const WorldPropsLayer = preload("res://scripts/world/world_props_layer.gd")
const PropChunks = preload("res://scripts/world/prop_chunks.gd")

# The deep-tree offenders (no AnimationPlayer; raw node counts measured in the assert).
const DEEP_CRITTERS := [
	"res://assets/models/critter_rabbit.glb",
	"res://assets/models/critter_chicken.glb",
	"res://assets/models/critter_cow.glb",
	"res://assets/models/critter_pig.glb",
]
const SHEEP := "res://assets/models/mob_sheep.glb"  # animated rig — must NOT flatten


func _make_layer(manifest: Array, flatten: bool = true) -> WorldPropsLayer:
	var layer := WorldPropsLayer.new()
	layer._flatten = flatten  # the AVALON_CRITTER_FLATTEN switch, driven directly
	layer.load_manifest(manifest)
	layer.set_stream_cfg({"flora_ring": 100.0, "building_ring": 900.0})
	add_child_autofree(layer)
	layer._streaming = false
	return layer


func _count_nodes(n: Node) -> int:
	var c := 1
	for ch in n.get_children():
		c += _count_nodes(ch)
	return c


func _critter_row(scene: String, x: float, y: float = 0.0) -> Dictionary:
	return {"scene": scene, "x": x, "y": y, "rot_deg": 15.0, "scale": 1.0, "solid": false}


# ---- flatten: node counts before/after ---------------------------------------------------------


func test_each_deep_critter_flattens_to_at_most_10_nodes() -> void:
	var manifest: Array = []
	for k in DEEP_CRITTERS.size():
		manifest.append(_critter_row(DEEP_CRITTERS[k], float(k * 6)))
	var layer := _make_layer(manifest)
	layer.stream_to(Vector2.ZERO)
	await wait_process_frames(2)
	assert_eq(layer.critter_count, DEEP_CRITTERS.size(), "every critter registered for the tick")
	for k in DEEP_CRITTERS.size():
		var scene := str(DEEP_CRITTERS[k])
		# The honest before: the raw GLB scene really is a deep tree (this is what shipped).
		var raw := (load(scene) as PackedScene).instantiate()
		var raw_nodes := _count_nodes(raw)
		raw.free()
		assert_gt(raw_nodes, 100, "%s raw scene is genuinely deep (%d nodes)" % [scene, raw_nodes])
		var root: Node3D = layer._placed[k]
		var flat_nodes := _count_nodes(root)
		assert_true(
			flat_nodes <= 10,
			"%s: %d raw nodes -> %d placed nodes (<= 10)" % [scene, raw_nodes, flat_nodes]
		)


func test_placed_instances_share_one_cached_merged_mesh() -> void:
	var manifest: Array = [
		_critter_row(DEEP_CRITTERS[0], 0.0),
		_critter_row(DEEP_CRITTERS[0], 8.0),
	]
	var layer := _make_layer(manifest)
	layer.stream_to(Vector2.ZERO)
	await wait_process_frames(2)
	var mesh_a := (layer._placed[0] as Node3D).find_child("merged", true, false) as MeshInstance3D
	var mesh_b := (layer._placed[1] as Node3D).find_child("merged", true, false) as MeshInstance3D
	assert_not_null(mesh_a, "first rabbit carries the merged MeshInstance")
	assert_not_null(mesh_b, "second rabbit carries the merged MeshInstance")
	assert_true(mesh_a.mesh == mesh_b.mesh, "both rabbits share ONE cached merged Mesh resource")


# ---- the animated-rig guard --------------------------------------------------------------------


func test_sheep_with_animation_player_is_refused_and_keeps_its_rig() -> void:
	var layer := _make_layer([_critter_row(SHEEP, 0.0)])
	layer.stream_to(Vector2.ZERO)
	await wait_process_frames(2)
	var root: Node3D = layer._placed[0]
	assert_not_null(
		root.find_child("AnimationPlayer", true, false), "the sheep keeps its AnimationPlayer rig"
	)
	assert_null(root.find_child("merged", true, false), "no merge was applied to the animated rig")
	assert_true(bool(layer._critters[0]["has_anim"]), "the wander tick still drives its clips")


# ---- behavior parity: flattened critters wander/flee by root transform ------------------------


func test_flattened_critter_still_flees_a_threat_by_root_transform() -> void:
	var world := Node3D.new()
	add_child_autofree(world)
	var player := Node3D.new()
	player.name = "LocalPlayer"
	world.add_child(player)
	var layer := WorldPropsLayer.new()
	layer._flatten = true
	layer.load_manifest([_critter_row(DEEP_CRITTERS[0], 0.0)])
	world.add_child(layer)
	layer._streaming = false
	layer.stream_to(Vector2.ZERO)
	await wait_process_frames(2)
	var root: Node3D = layer._placed[0]
	var home := root.position
	player.position = home  # a threat inside comfort_radius -> flee
	layer._process(0.2)  # one >= tick-interval step drives the 10 Hz wander tick
	assert_gt(root.position.distance_to(home), 0.05, "the flattened rabbit fled its home point")
	assert_eq(root.get_child_count(), 1, "flee moved the ROOT only — the merged child is inert")


# ---- kill-switch A/B: the dressing-layer node-count claim --------------------------------------


func test_flatten_cuts_a_critter_heavy_layer_at_least_10x() -> void:
	var manifest: Array = []
	for k in DEEP_CRITTERS.size():
		manifest.append(_critter_row(DEEP_CRITTERS[k], float(k * 6)))
	var old_layer := _make_layer(manifest, false)  # AVALON_CRITTER_FLATTEN=0 semantics
	old_layer.stream_to(Vector2.ZERO)
	await wait_process_frames(2)
	var new_layer := _make_layer(manifest, true)
	new_layer.stream_to(Vector2.ZERO)
	await wait_process_frames(2)
	var old_nodes := _count_nodes(old_layer)
	var new_nodes := _count_nodes(new_layer)
	assert_true(
		old_nodes >= 10 * new_nodes,
		"flatten cuts the critter dressing >= 10x: raw=%d flattened=%d" % [old_nodes, new_nodes]
	)
