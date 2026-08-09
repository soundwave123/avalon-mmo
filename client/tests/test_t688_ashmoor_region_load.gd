extends "res://addons/gut/test.gd"

# T-688: the era-rift crossing into Ashmoor SIGSEGV'd the render client mid-BLIT on the NVIDIA
# 595.84 driver. Diagnosis (headless): no Ashmoor asset is malformed/oversized — the trigger is the
# region-change swap placing the WHOLE ~148-prop Ashmoor dressing set (9 ~2MB building GLBs +
# boulders + trees, each a GLB decode + mesh/texture GPU upload + trimesh-collision bake) in ONE
# frame. This guards both halves of the fix:
#   1. every distinct Ashmoor prop scene still loads clean (a future malformed/oversized era-2 asset
#      would surface here headlessly, without ever rendering on the locked GPU); and
#   2. a region-change load is BUDGETED across frames (no one-frame burst) yet still converges on
#      the full resident set.
# H2 (2026-07-28): the TEARDOWN half is the same burst class — the tests below assert the
# mirror-image free budget (see prop_reaper.gd).

const WorldPropsLayer = preload("res://scripts/world/world_props_layer.gd")
const TerrainField = preload("res://scripts/world/terrain_field.gd")
const PropReaper = preload("res://scripts/world/prop_reaper.gd")

const COTTAGE := "res://assets/models/prop_cottage_v2.glb"  # building tier — always resident


# The distinct prop scenes whose nearest region origin is Ashmoor (-420, 0).
func _ashmoor_scenes() -> Array:
	var file := FileAccess.open("res://assets/props.json", FileAccess.READ)
	assert_not_null(file, "assets/props.json is readable")
	var data = JSON.parse_string(file.get_as_text())
	file.close()
	var origins: Array = TerrainField.new().region_origins()
	var ashmoor_idx := 1  # regions = [Wold(0,0), Ashmoor(-420,0), Greyrise(0,-1400)]
	var seen := {}
	var out: Array = []
	for p in data.get("props", []):
		var ground := Vector2(float(p.get("x", 0.0)), float(p.get("y", 0.0)))
		var best := 0
		var best_d2: float = INF
		for i in origins.size():
			var d2: float = ground.distance_squared_to(origins[i])
			if d2 < best_d2:
				best_d2 = d2
				best = i
		if best != ashmoor_idx:
			continue
		var scene := str(p.get("scene", ""))
		if not seen.has(scene):
			seen[scene] = true
			out.append(scene)
	return out


func test_every_ashmoor_scene_loads_clean() -> void:
	var scenes := _ashmoor_scenes()
	assert_gt(scenes.size(), 0, "the Ashmoor region actually has dressing to load")
	for scene in scenes:
		assert_true(ResourceLoader.exists(scene), "Ashmoor asset exists on disk: %s" % scene)
		var packed = load(scene) as PackedScene
		assert_not_null(packed, "Ashmoor scene loads without error: %s" % scene)
		if packed != null:
			var node = packed.instantiate()
			assert_true(node is Node3D, "Ashmoor scene instances a Node3D: %s" % scene)
			node.free()


func _ashmoor_layer(n_buildings: int) -> WorldPropsLayer:
	var manifest: Array = []
	for k in n_buildings:
		manifest.append({"scene": COTTAGE, "x": -420.0, "y": float(k * 4), "rot_deg": 0})
	var layer := WorldPropsLayer.new()
	layer.load_manifest(manifest)  # inject before _ready -> it skips the real props.json
	add_child_autofree(layer)
	layer._streaming = false  # drive stream_to() by hand; only the load-queue drain runs in _process
	return layer


func test_region_change_load_is_budgeted_not_one_frame_burst() -> void:
	# _ready already did the initial populate at the Wold origin (region 0, empty for this Ashmoor-
	# only manifest), so _active_region == 0 — the next stream_to is a genuine region CHANGE.
	# The budget cap is asserted by driving the drain DIRECTLY (GUT's headless frame accounting is
	# loose — a single awaited frame can tick _process several times); one drain call == one engine
	# frame's worth of loads, which is what the live game sees (one _process per rendered frame).
	var budget: int = WorldPropsLayer.LOAD_BUDGET_PER_FRAME
	var n := budget + 2  # more than one frame's budget, so the cap actually bites
	var layer := _ashmoor_layer(n)

	layer.stream_to(Vector2(-420.0, 0.0))  # cross into Ashmoor (region 1)
	assert_eq(
		(layer.placed_indices() as Array).size(),
		0,
		"the region-change load is DEFERRED, not instantiated inline (no one-frame GPU burst)"
	)

	layer._drain_load_queue()  # one engine frame's worth
	assert_eq(
		(layer.placed_indices() as Array).size(),
		budget,
		"a single frame places at most the per-frame budget — the burst is capped"
	)

	layer._drain_load_queue()
	assert_eq(
		(layer.placed_indices() as Array).size(),
		n,
		"successive frames drain the backlog until the whole region is resident"
	)


func test_region_change_load_completes_under_the_live_process_tick() -> void:
	# End-to-end: the drain runs from _process (not just when called by hand), so the swap converges
	# on its own once the player crosses. Uses process-frame waits (the drain lives in _process).
	var n := WorldPropsLayer.LOAD_BUDGET_PER_FRAME + 2
	var layer := _ashmoor_layer(n)
	layer.stream_to(Vector2(-420.0, 0.0))
	await wait_process_frames(n)  # ample frames for the budgeted drain to clear
	assert_eq(
		(layer.placed_indices() as Array).size(),
		n,
		"every resident Ashmoor prop is eventually placed by the live tick — the swap completes"
	)


# ---- T-688 H2: budgeted region TEARDOWN (the free-side mirror of the load budget) --------------


# Off-tree layer (autofree, never added): _ready/_process don't run, so the reaper drains ONLY by
# hand — one drain() == one engine frame of frees, deterministically (frame accounting is loose).
func _resident_ashmoor_layer(n_buildings: int) -> WorldPropsLayer:
	var manifest: Array = []
	for k in n_buildings:
		manifest.append({"scene": COTTAGE, "x": -420.0, "y": float(k * 4), "rot_deg": 0})
	var layer: WorldPropsLayer = autofree(WorldPropsLayer.new())
	layer.load_manifest(manifest)
	layer.stream_to(Vector2(-420.0, 0.0))
	return layer


func test_region_teardown_is_budgeted_and_dying_set_leaves_gameplay_immediately() -> void:
	var budget: int = PropReaper.FREE_BUDGET_PER_FRAME
	var n := budget + 2
	var layer := _resident_ashmoor_layer(n)
	var old_nodes: Array = []
	for i in layer.placed_indices():
		old_nodes.append(layer._placed[i])
	assert_eq(old_nodes.size(), n, "the Ashmoor set is resident before the crossing")

	layer.stream_to(Vector2(0.0, 0.0))  # cross back to the Wold — the Ashmoor set tears down

	var dying: Node3D = layer._reaper._dying
	assert_not_null(dying, "the teardown created the dying container")
	assert_false(dying.visible, "the outgoing region is INVISIBLE from the seam frame")
	var off := dying.process_mode == Node.PROCESS_MODE_DISABLED
	assert_true(off, "the outgoing region leaves processing + physics at the seam (collision off)")
	assert_eq((layer.placed_indices() as Array).size(), 0, "no old prop is tracked as resident")
	for node in old_nodes:
		assert_eq((node as Node).get_parent(), dying, "every old prop moved under the container")
		assert_false((node as Node).is_queued_for_deletion(), "none freed on the seam frame itself")

	layer._reaper.drain()  # one engine frame's worth of frees
	assert_eq(_queued_count(old_nodes), budget, "one frame frees at most the per-frame budget")

	layer._reaper.drain()
	assert_eq(_queued_count(old_nodes), n, "successive frames drain the whole outgoing region")


func _queued_count(nodes: Array) -> int:
	var queued := 0
	for node in nodes:
		if is_instance_valid(node) and (node as Node).is_queued_for_deletion():
			queued += 1
	return queued


func test_scene_pin_release_rides_the_same_budget_after_the_nodes() -> void:
	# Pure reaper drill: node frees and pin releases share ONE per-frame budget, nodes first.
	var budget: int = PropReaper.FREE_BUDGET_PER_FRAME
	var reaper := PropReaper.new()
	var host: Node3D = autofree(Node3D.new())
	for k in 2:
		host.add_child(Node3D.new())
	var pins := {}
	for k in budget + 1:
		pins["res://fake_scene_%d.glb" % k] = RefCounted.new()
	reaper.retire(host, pins)
	assert_eq(reaper.pending(), 2 + budget + 1, "nodes + pins all await the budgeted drain")

	reaper.drain()  # frees the 2 nodes, then releases 1 pin — one shared frame budget
	assert_eq(reaper._free_queue.size(), 0, "the node queue drains before any pin releases")
	assert_eq(reaper._pin_release.size(), budget, "pin releases only spend LEFTOVER node budget")

	reaper.drain()
	assert_eq(reaper.pending(), 0, "the next frame's budget completes the pin release")


func test_reenter_during_drain_places_fresh_nodes_and_the_drain_still_completes() -> void:
	var n := PropReaper.FREE_BUDGET_PER_FRAME + 2
	var layer := _resident_ashmoor_layer(n)
	var old_ids := {}
	for i in layer.placed_indices():
		old_ids[(layer._placed[i] as Node).get_instance_id()] = true

	layer.stream_to(Vector2(0.0, 0.0))  # cross out — the Ashmoor set starts dying…
	var gen_out: int = layer._reaper.generation
	layer.stream_to(Vector2(-420.0, 0.0))  # …and immediately cross back, mid-drain
	assert_gt(layer._reaper.generation, gen_out, "the re-entry is a NEW teardown generation")

	while not layer._load_queue.is_empty():
		layer._drain_load_queue()
	assert_eq((layer.placed_indices() as Array).size(), n, "the re-entered region fully re-places")
	for i in layer.placed_indices():
		var node: Node = layer._placed[i]
		assert_false(
			old_ids.has(node.get_instance_id()),
			"a re-entered region never resurrects a dying node — every placement is fresh"
		)
		assert_false(node.is_queued_for_deletion(), "fresh placements are not on the free queue")

	while layer._reaper.pending() > 0:  # the old generation's drain completes regardless
		layer._reaper.drain()
	for i in layer.placed_indices():
		var fresh: Node = layer._placed[i]
		var untouched := is_instance_valid(fresh) and not fresh.is_queued_for_deletion()
		assert_true(untouched, "completing the old generation's drain never touches fresh nodes")


func test_region_teardown_completes_under_the_live_process_tick() -> void:
	# End-to-end: the free drain runs from _process on its own, so the outgoing region is really
	# gone (deleted, not hidden forever) shortly after a crossing — even with nobody driving it.
	var n := PropReaper.FREE_BUDGET_PER_FRAME + 2
	var layer := _ashmoor_layer(n)
	layer.stream_to(Vector2(-420.0, 0.0))
	await wait_process_frames(n)  # budgeted load drain completes
	assert_eq((layer.placed_indices() as Array).size(), n, "the Ashmoor set is resident")

	layer.stream_to(Vector2(0.0, 0.0))  # cross back out — the teardown drain starts
	await wait_process_frames(n + 4)  # ample frames for the budgeted free drain + container sweep
	assert_false(layer._reaper.active(), "the free drain completes under _process on its own")
	assert_eq(
		layer.get_child_count(),
		0,
		"the outgoing region AND the dying container are really gone — nothing leaked or lingers"
	)
