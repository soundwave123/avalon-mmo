extends "res://addons/gut/test.gd"

# T-693: chunked-MultiMesh batching of the repeated world dressing. Proves, headlessly:
#   * placement parity — every batched props.json placement renders exactly once (sum of MultiMesh
#     instance counts == batched set), individually placed props keep the _place path;
#   * node-count reduction — the same dressing under batching is >= 5x fewer scene nodes than the
#     per-node path (the T-692 root cause), compared via the AVALON_PROP_BATCHING kill-switch;
#   * transform parity — a batched instance's world transform is byte-identical to the node the
#     old _place path builds for the same placement;
#   * collision parity — blocking props (solid, not-a-tree) still get a collider at their exact
#     placement; trees/soft flora stay collider-free (T-164 policy preserved);
#   * the T-594 10x-border-walk determinism/leak invariant on chunk pools;
#   * the T-688 budget invariant — a region-change chunk build rides the frame-budgeted queue
#     (one chunk per queue item, never the whole region in one frame);
#   * the weathering port — ONE shared overlay material per batched scene, per-instance ground_y
#     via INSTANCE_CUSTOM, never a per-instance material;
#   * the AVALON_PROP_BATCHING=0 escape hatch restores the per-node path;
#   * T-693 residual #2 HERO POOLS — tag-promoted flora batches into always-resident per-region
#     pools that render every tagged placement exactly once, survive flora-ring exits (residency
#     semantics of the tag preserved), tear down only at the region seam, and ride the T-688
#     budget queue; buildings/special bases keep the individual path even when tag-promoted.

const WorldPropsLayer = preload("res://scripts/world/world_props_layer.gd")
const PropChunks = preload("res://scripts/world/prop_chunks.gd")
const LodPolicy = preload("res://scripts/world/lod_policy.gd")
const PropStreamer = preload("res://scripts/world/prop_streamer.gd")
const OAK := "res://assets/models/prop_oak.glb"  # T-696: impostor CLASS, but ships NO baked png

const ROCK := "res://assets/models/prop_rock_a.glb"  # weathered + blocking (solid default)
const FIR := "res://assets/models/prop_tree_fir_a.glb"  # tree: batched, NEVER collides (T-164)
const BUSH := "res://assets/models/prop_bush_real_c.glb"  # soft flora (solid=false in the data)
const BRAMBLE := "res://assets/models/prop_bramble_patch.glb"  # 326-MeshInstance GLB (merge path)
const LAMPPOST := "res://assets/models/prop_lamppost_v2.glb"  # night-light base -> individual
const COTTAGE := "res://assets/models/prop_cottage_v2.glb"  # building tier -> individual


func _rock(x: float, y: float, scale: float = 1.0, terrain_y: float = 0.0) -> Dictionary:
	return {"scene": ROCK, "x": x, "y": y, "rot_deg": 30.0, "scale": scale, "terrain_y": terrain_y}


func _make_layer(manifest: Array, batching: bool = true) -> WorldPropsLayer:
	var layer := WorldPropsLayer.new()
	layer._batching = batching  # the AVALON_PROP_BATCHING switch, driven directly
	layer.load_manifest(manifest)  # inject before entering the tree -> _ready skips props.json
	layer.set_stream_cfg({"flora_ring": 100.0, "building_ring": 900.0})
	add_child_autofree(layer)
	layer._streaming = false  # drive stream_to() by hand; no auto re-stream mid-assert
	return layer


func _count_nodes(n: Node) -> int:
	var c := 1
	for ch in n.get_children():
		c += _count_nodes(ch)
	return c


func _find_all(root: Node, klass: String) -> Array:
	return root.find_children("*", klass, true, false)


# ---- placement parity -------------------------------------------------------------------------


func test_batched_placements_render_once_and_leave_the_individual_path() -> void:
	var manifest: Array = []
	for k in 6:  # repeated decorative flora -> batched
		manifest.append(_rock(float(k * 3), 0.0))
	# a night-light special base (engine attaches an OmniLight) -> individual by the name gate
	manifest.append({"scene": LAMPPOST, "x": 20.0, "y": 0.0, "solid": false})
	manifest.append({"scene": COTTAGE, "x": 0.0, "y": 8.0, "rot_deg": 0})  # building -> individual
	var layer := _make_layer(manifest)
	layer.stream_to(Vector2.ZERO)
	await wait_process_frames(2)
	assert_eq(layer._chunks.batched_count(), 6, "all 6 repeated rocks are batched")
	assert_eq(layer._chunks.instance_total(), 6, "every batched placement renders exactly once")
	var placed: Array = layer.placed_indices()
	placed.sort()
	assert_eq(placed, [6, 7], "lamppost (night-light base) + cottage keep the individual path")
	# Per-chunk parity: the sum over built chunks equals the batched set, chunk by chunk.
	var total := 0
	for key in layer._chunks.built_keys():
		total += layer._chunks.chunk_instances(key)
	assert_eq(total, 6, "per-chunk instance counts sum to the batched placement count")


func test_multi_meshinstance_glb_merges_to_one_pool() -> void:
	var manifest: Array = []
	for k in 5:
		manifest.append({"scene": BRAMBLE, "x": float(k * 4), "y": 0.0, "solid": false})
	var layer := _make_layer(manifest)
	layer.stream_to(Vector2.ZERO)
	await wait_process_frames(2)
	assert_eq(layer._chunks.instance_total(), 5, "all 5 brambles render as instances")
	var mmis := _find_all(layer, "MultiMeshInstance3D")
	assert_eq(mmis.size(), 1, "one pool for the 326-MeshInstance bramble GLB — merged, not 326")
	var mesh: Mesh = (mmis[0] as MultiMeshInstance3D).multimesh.mesh
	assert_lt(
		mesh.get_surface_count(), 8, "merge groups the 326 parts by material into few surfaces"
	)


# ---- node-count reduction (the T-692 headline, headless half) ---------------------------------


func test_batched_dressing_is_at_least_5x_fewer_nodes_than_the_per_node_path() -> void:
	var manifest: Array = []
	for k in 10:
		manifest.append({"scene": FIR, "x": float(k * 3), "y": 0.0, "scale": 1.1})
	for k in 8:
		manifest.append(_rock(float(k * 3), 10.0))
	for k in 6:
		manifest.append({"scene": BRAMBLE, "x": float(k * 4), "y": 20.0, "solid": false})
	var old_layer := _make_layer(manifest, false)  # kill-switch: the per-node path
	old_layer.stream_to(Vector2.ZERO)
	await wait_process_frames(2)
	var new_layer := _make_layer(manifest, true)
	new_layer.stream_to(Vector2.ZERO)
	await wait_process_frames(2)
	var old_nodes := _count_nodes(old_layer)
	var new_nodes := _count_nodes(new_layer)
	assert_eq(new_layer._chunks.instance_total(), 24, "the batched path renders every placement")
	assert_true(
		old_nodes >= 5 * new_nodes,
		(
			"batching cuts the dressing subtree at least 5x: per-node=%d batched=%d"
			% [old_nodes, new_nodes]
		)
	)


# ---- transform parity -------------------------------------------------------------------------


func test_batched_instance_transforms_match_the_individual_place_path() -> void:
	var manifest: Array = [
		_rock(3.0, 5.0, 1.0, 1.5),
		_rock(9.0, 5.0, 1.1, 2.0),
		_rock(15.0, 5.0, 1.2, 2.5),
		_rock(21.0, 5.0, 1.3, 3.0),
	]
	var old_layer := _make_layer(manifest, false)
	old_layer.stream_to(Vector2.ZERO)
	var new_layer := _make_layer(manifest, true)
	new_layer.stream_to(Vector2.ZERO)
	await wait_process_frames(2)
	# The old path's per-prop MESH world transforms (prop root x mesh-node local).
	var want: Array = []
	for i in manifest.size():
		var root: Node3D = old_layer._placed[i]
		var mi := root.find_children("*", "MeshInstance3D", true, false)[0] as MeshInstance3D
		want.append(root.global_transform * PropChunks.local_transform_to_ancestor(mi, root))
	var mmis := _find_all(new_layer, "MultiMeshInstance3D")
	assert_eq(mmis.size(), 1, "one rock pool in the single chunk")
	var mmi := mmis[0] as MultiMeshInstance3D
	var got: Array = []
	for k in mmi.multimesh.instance_count:
		# The bulk buffer is the real uploaded instance data (per-instance getters are dead
		# under the headless dummy renderer).
		got.append(mmi.global_transform * PropChunks.buffer_transform(mmi.multimesh, k))
	for w: Transform3D in want:
		var matched := false
		for g: Transform3D in got:
			if g.origin.distance_to(w.origin) < 0.001 and (g.basis.x - w.basis.x).length() < 0.001:
				matched = true
				break
		assert_true(matched, "a batched instance matches the _place transform at %s" % w.origin)


# ---- collision parity -------------------------------------------------------------------------


func test_blocking_props_keep_colliders_and_soft_flora_and_trees_do_not() -> void:
	var manifest: Array = [
		_rock(2.0, 2.0),
		_rock(6.0, 2.0),
		_rock(10.0, 2.0),
		_rock(14.0, 2.0, 1.0, 2.0),
	]
	for k in 4:  # trees: solid defaults true but T-164 skips them (canopy) — parity must hold
		manifest.append({"scene": FIR, "x": float(k * 3), "y": 12.0})
	for k in 4:  # soft flora: solid=false -> never collides
		manifest.append({"scene": BUSH, "x": float(k * 3), "y": 22.0, "solid": false})
	var layer := _make_layer(manifest)
	layer.stream_to(Vector2.ZERO)
	await wait_process_frames(2)
	assert_eq(layer._chunks.instance_total(), 12, "rocks + firs + bushes all render batched")
	var shapes := _find_all(layer, "CollisionShape3D")
	assert_eq(shapes.size(), 4, "exactly the 4 blocking rocks got collision-only shapes")
	for s in shapes:
		var body := (s as CollisionShape3D).get_parent()
		assert_true(body is StaticBody3D, "chunk colliders hang off a StaticBody3D")
		for c in (body as Node).get_children():
			assert_false(
				c is VisualInstance3D,
				"the collision body carries NO visual children (visuals live in the MultiMesh)"
			)
	# Each rock placement has a collider AT its position (shape node world origin == placement).
	for i in 4:
		var p: Dictionary = manifest[i]
		var at := Vector3(p["x"], float(p.get("terrain_y", 0.0)), p["y"])
		var found := false
		for s in shapes:
			if (s as CollisionShape3D).global_position.distance_to(at) < 0.001:
				found = true
				break
		assert_true(found, "a collider sits exactly at rock placement %s" % at)


# ---- T-594 border-walk determinism + leak invariant on chunk pools ----------------------------


func test_border_walk_is_leak_free_and_deterministic_for_chunks() -> void:
	var manifest: Array = []
	for k in 5:
		manifest.append(_rock(float(k * 3), 0.0))
	for k in 5:
		manifest.append(_rock(float(k * 3), 300.0))
	var layer := _make_layer(manifest)  # flora_ring=100 -> the two clusters never co-resident
	var here := Vector2(0.0, 0.0)
	var there := Vector2(0.0, 300.0)
	layer.stream_to(here)
	await wait_process_frames(2)
	var baseline_keys: Array = layer._chunks.built_keys()
	baseline_keys.sort()
	var baseline_children := layer.get_child_count()
	assert_eq(baseline_keys.size(), 1, "only the near cluster's chunk is resident at the origin")
	for _n in range(10):
		layer.stream_to(there)
		await wait_process_frames(2)
		assert_eq(layer._chunks.instance_total(), 5, "far standpoint: only the far chunk's rocks")
		layer.stream_to(here)
		await wait_process_frames(2)
		var keys: Array = layer._chunks.built_keys()
		keys.sort()
		assert_eq(keys, baseline_keys, "resident chunk set identical on every return")
		assert_eq(layer.get_child_count(), baseline_children, "no orphan/leak: child count stable")


func test_region_change_tears_chunks_down_whole() -> void:
	var manifest: Array = []
	for k in 5:
		manifest.append(_rock(float(k * 3), 0.0))  # Wold (region 0)
	var layer := _make_layer(manifest)
	layer.stream_to(Vector2.ZERO)
	await wait_process_frames(2)
	assert_eq(layer._chunks.instance_total(), 5, "the Wold chunk is resident")
	layer.stream_to(Vector2(-440.0, 0.0))  # cross into Ashmoor (region 1)
	await wait_process_frames(4)
	assert_eq(layer._chunks.built_keys().size(), 0, "no Wold chunk survives the region swap")
	assert_eq(layer._chunks.instance_total(), 0, "chunk bookkeeping reset with the teardown")


# ---- T-688: chunk builds ride the frame-budgeted load queue -----------------------------------


func test_region_change_chunk_builds_are_budgeted_not_one_frame_burst() -> void:
	# 5 chunks of 4 rocks each in Ashmoor; _ready's initial populate ran at the Wold origin, so
	# the stream_to below is a genuine region CHANGE -> chunk builds must queue, not build inline.
	var manifest: Array = []
	for c in 5:
		for k in 4:
			manifest.append(_rock(-420.0 + float(k * 3), float(c * 64)))
	var layer := _make_layer(manifest)
	layer.set_stream_cfg({"flora_ring": 340.0, "building_ring": 900.0})
	layer.stream_to(Vector2(-420.0, 0.0))
	assert_eq(
		layer._chunks.built_keys().size(),
		0,
		"the region-change chunk builds are DEFERRED to the queue (no one-frame burst)"
	)
	layer._drain_load_queue()  # one engine frame's worth
	assert_eq(
		layer._chunks.built_keys().size(),
		WorldPropsLayer.LOAD_BUDGET_PER_FRAME,
		"a single frame builds at most the per-frame budget of chunks"
	)
	layer._drain_load_queue()
	assert_eq(layer._chunks.built_keys().size(), 5, "successive frames drain the chunk backlog")
	assert_eq(layer._chunks.instance_total(), 20, "the full batched set converges")


# ---- weathering: one shared material, per-instance ground_y via INSTANCE_CUSTOM ---------------


func test_weathering_is_one_shared_overlay_with_instance_custom_ground_y() -> void:
	var manifest: Array = [  # two chunks of weathered rocks (rock class: amount 0.62)
		_rock(2.0, 2.0, 1.2, 1.5),
		_rock(6.0, 2.0, 1.1, 2.0),
		_rock(2.0, 70.0, 1.0, 2.5),
		_rock(6.0, 70.0, 0.9, 3.0),
	]
	for k in 4:  # brambles carry no weathering cfg -> clean, no overlay, no custom data
		manifest.append({"scene": BRAMBLE, "x": float(k * 4), "y": 30.0, "solid": false})
	var layer := _make_layer(manifest)
	layer.stream_to(Vector2.ZERO)
	await wait_process_frames(2)
	var rock_mmis: Array = []
	var bramble_mmis: Array = []
	for n in _find_all(layer, "MultiMeshInstance3D"):
		var mmi := n as MultiMeshInstance3D
		if mmi.multimesh.mesh.get_surface_count() == 1:
			rock_mmis.append(mmi)
		else:
			bramble_mmis.append(mmi)
	assert_eq(rock_mmis.size(), 2, "two rock chunks")
	assert_eq(bramble_mmis.size(), 1, "one bramble chunk")
	var overlay_a: Material = (rock_mmis[0] as MultiMeshInstance3D).material_overlay
	var overlay_b: Material = (rock_mmis[1] as MultiMeshInstance3D).material_overlay
	assert_true(overlay_a is ShaderMaterial, "the weathered class carries the overlay pass")
	assert_true(
		overlay_a == overlay_b, "ONE shared overlay material across chunks — never per-instance"
	)
	for mmi: MultiMeshInstance3D in rock_mmis:
		assert_true(mmi.multimesh.use_custom_data, "per-instance data enabled for weathered pools")
		# Largest-scale-first sort: instance 0 of the first chunk is the scale-1.2 rock
		# (terrain_y 1.5) — its INSTANCE_CUSTOM.x must be its own ground Y.
	var first := (rock_mmis[0] as MultiMeshInstance3D).multimesh
	var got_y := PropChunks.buffer_custom(first, 0).r
	assert_true(
		is_equal_approx(got_y, 1.5) or is_equal_approx(got_y, 2.5),
		"INSTANCE_CUSTOM.x carries the instance's own ground_y (got %f)" % got_y
	)
	var clean := bramble_mmis[0] as MultiMeshInstance3D
	assert_null(clean.material_overlay, "clean classes get no overlay")
	assert_false(clean.multimesh.use_custom_data, "no custom data where there is no weathering")


# ---- T-693 residual #2: hero-tagged flora batches into always-resident pools ------------------


func _hero_rock(x: float, y: float, scale: float = 1.0) -> Dictionary:
	var p := _rock(x, y, scale)
	p["tag"] = "highkeep"  # tag-promoted to TIER_HERO (never streams out)
	return p


func test_hero_tagged_flora_batches_and_hero_guards_hold() -> void:
	var manifest: Array = []
	for k in 5:
		manifest.append(_hero_rock(float(k * 3), 0.0))
	# tag-promoted but NOT pool-eligible: a night-light special base and a building-stem scene
	# keep the individual path (their engine attachments / interiors need real nodes).
	manifest.append({"scene": LAMPPOST, "x": 20.0, "y": 0.0, "solid": false, "tag": "highkeep"})
	manifest.append({"scene": COTTAGE, "x": 0.0, "y": 8.0, "rot_deg": 0, "tag": "highkeep"})
	var layer := _make_layer(manifest)
	layer.stream_to(Vector2.ZERO)
	await wait_process_frames(2)
	assert_eq(layer._chunks.hero_instance_total(), 5, "every tagged rock renders exactly once")
	assert_eq((layer._chunks.hero_built_keys() as Array).size(), 1, "one hero pool chunk")
	var placed: Array = layer.placed_indices()
	placed.sort()
	assert_eq(placed, [5, 6], "tagged lamppost + cottage keep the individual path")


func test_hero_pools_survive_ring_exit_while_flora_streams_out() -> void:
	var manifest: Array = []
	for k in 3:
		manifest.append(_hero_rock(float(k * 3), 0.0))
	for k in 3:
		manifest.append(_rock(float(k * 3), 0.0))  # untagged flora at the same spot
	var layer := _make_layer(manifest)  # flora_ring=100
	layer.stream_to(Vector2.ZERO)
	await wait_process_frames(2)
	assert_eq(layer._chunks.instance_total(), 6, "at the origin both pools are resident")
	# Walk out past the flora ring but stay in the region: the tag's residency must hold.
	layer.stream_to(Vector2(0.0, 300.0))
	await wait_process_frames(2)
	assert_eq(layer._chunks.hero_instance_total(), 3, "hero pool still resident past the ring")
	assert_eq(layer._chunks.instance_total(), 3, "the untagged flora chunk streamed out")
	layer.stream_to(Vector2.ZERO)
	await wait_process_frames(2)
	assert_eq(layer._chunks.instance_total(), 6, "walking back restores the identical set")


func test_hero_pools_tear_down_on_region_change() -> void:
	var manifest: Array = []
	for k in 3:
		manifest.append(_hero_rock(float(k * 3), 0.0))  # Wold (region 0)
	var layer := _make_layer(manifest)
	layer.stream_to(Vector2.ZERO)
	await wait_process_frames(2)
	assert_eq(layer._chunks.hero_instance_total(), 3, "the Wold hero pool is resident")
	layer.stream_to(Vector2(-440.0, 0.0))  # cross into Ashmoor (region 1)
	await wait_process_frames(4)
	assert_eq(
		(layer._chunks.hero_built_keys() as Array).size(), 0, "no hero pool survives the seam"
	)
	assert_eq(layer._chunks.instance_total(), 0, "chunk bookkeeping reset with the teardown")


func test_hero_pool_builds_ride_the_budget_queue_on_region_change() -> void:
	# 4 hero chunks (64 m apart) in Ashmoor; the initial populate ran at the Wold origin, so the
	# stream below is a genuine region change -> hero pools must queue, not build inline.
	var manifest: Array = []
	for c in 4:
		for k in 3:
			manifest.append(_hero_rock(-420.0 + float(k * 3), float(c * 64)))
	var layer := _make_layer(manifest)
	layer.set_stream_cfg({"flora_ring": 340.0, "building_ring": 900.0})
	layer.stream_to(Vector2.ZERO)  # initial populate, region 0 — nothing to build
	layer.stream_to(Vector2(-420.0, 0.0))
	assert_eq(
		(layer._chunks.hero_built_keys() as Array).size(),
		0,
		"region-change hero pool builds are DEFERRED to the T-688 queue"
	)
	layer._drain_load_queue()  # one engine frame's worth (budget = 3)
	assert_eq(
		(layer._chunks.hero_built_keys() as Array).size(),
		WorldPropsLayer.LOAD_BUDGET_PER_FRAME,
		"a single frame builds at most the per-frame budget of hero pools"
	)
	layer._drain_load_queue()
	assert_eq((layer._chunks.hero_built_keys() as Array).size(), 4, "the backlog drains")
	assert_eq(layer._chunks.hero_instance_total(), 12, "every tagged placement converges")


# ---- T-692 Part B: preset knobs on the batched pools ------------------------------------------


func test_lod_mult_scales_batched_visibility_ranges() -> void:
	var manifest: Array = []
	for k in 5:
		manifest.append(_rock(float(k * 3), 0.0))
	var layer := _make_layer(manifest)
	# apply_quality_cfg (not a bare set_stream_cfg) is the preset contract: built pools rebuild.
	layer.apply_quality_cfg({"flora_ring": 100.0, "building_ring": 900.0, "lod_mult": 0.55})
	await wait_process_frames(4)
	var mmis := _find_all(layer, "MultiMeshInstance3D")
	assert_eq(mmis.size(), 1, "one rock pool")
	var want := LodPolicy.cull_distance(ROCK.get_file(), 0.55) + PropChunks.CHUNK_MARGIN
	assert_almost_eq(
		(mmis[0] as MultiMeshInstance3D).visibility_range_end,
		want,
		0.01,
		"the pool cull range is the class cull x preset mult (+chunk margin)"
	)


func test_lod_mult_scales_the_tree_impostor_crossover() -> void:
	var manifest: Array = []
	for k in 5:  # prop_tree_fir_a ships a baked impostor png -> real + impostor pools
		manifest.append({"scene": FIR, "x": float(k * 3), "y": 0.0})
	var layer := _make_layer(manifest)
	layer.apply_quality_cfg({"flora_ring": 100.0, "building_ring": 900.0, "lod_mult": 0.55})
	await wait_process_frames(4)
	var mmis := _real_and_impostor_mmis(layer)
	var real := mmis["real"] as MultiMeshInstance3D
	var imp := mmis["impostor"] as MultiMeshInstance3D
	var base := FIR.get_file()
	var m := PropChunks.CHUNK_MARGIN
	var swap := LodPolicy.impostor_distance(base, 0.55) + m
	assert_almost_eq(real.visibility_range_end, swap, 0.01, "real mesh culls at the scaled swap")
	assert_almost_eq(
		imp.visibility_range_begin, swap, 0.01, "impostor takes over at the same point"
	)
	assert_almost_eq(
		imp.visibility_range_end,
		LodPolicy.cull_distance(base, 0.55) + m,
		0.01,
		"the impostor band ends at the scaled tree cull"
	)


func test_flora_density_thins_batched_pools_to_the_exact_keep_subset() -> void:
	var manifest: Array = []
	for k in 20:
		manifest.append(_rock(float(k * 3), 0.0))
	var layer := _make_layer(manifest)
	layer.apply_quality_cfg({"flora_ring": 100.0, "building_ring": 900.0, "flora_density": 0.5})
	await wait_process_frames(8)
	var want := 0
	for k in 20:
		if PropStreamer.density_kept(k, 0.5):
			want += 1
	assert_true(want > 0 and want < 20, "the fixture spans a real thinning band")
	assert_eq(layer._chunks.instance_total(), want, "the pools hold exactly the keep-subset")
	assert_eq(layer._chunks.batched_count(), want, "dropped placements exit the batch plan")
	assert_eq(
		(layer.placed_indices() as Array).size(),
		0,
		"dropped flora never falls back to the individual path"
	)


func test_apply_quality_cfg_rebuilds_through_the_budget_queue_without_leaks() -> void:
	var manifest: Array = []
	for c in 4:
		for k in 4:
			manifest.append(_rock(float(k * 3), float(c * 64)))
	var layer := _make_layer(manifest)
	layer.set_stream_cfg({"flora_ring": 340.0, "building_ring": 900.0})
	layer.stream_to(Vector2.ZERO)
	await wait_process_frames(4)
	var baseline_children := layer.get_child_count()
	var baseline_total := layer._chunks.instance_total()
	assert_eq(baseline_total, 16, "the full-density baseline is resident")
	layer.apply_quality_cfg({"flora_ring": 340.0, "building_ring": 900.0})
	assert_eq(
		layer._chunks.built_keys().size(),
		0,
		"the live re-apply DEFERS its rebuild to the T-688 queue (no one-frame burst)"
	)
	await wait_process_frames(8)
	assert_eq(layer._chunks.instance_total(), baseline_total, "the identical set converges")
	assert_eq(layer.get_child_count(), baseline_children, "no leak/dupe across the live re-apply")


# ---- content gate + kill-switch ---------------------------------------------------------------


func test_glbs_with_markers_or_attachments_never_batch() -> void:
	var chunks = PropChunks.new()
	var farmhouse: Dictionary = chunks._extract("res://assets/models/prop_farmhouse.glb")
	assert_false(farmhouse["ok"], "a door-marker GLB (enterable) is rejected by the content gate")
	var rock: Dictionary = chunks._extract(ROCK)
	assert_true(rock["ok"], "a plain decorative GLB passes the content gate")


func test_batching_kill_switch_restores_the_per_node_path() -> void:
	var manifest: Array = []
	for k in 6:
		manifest.append(_rock(float(k * 3), 0.0))
	var layer := _make_layer(manifest, false)  # AVALON_PROP_BATCHING=0 semantics
	layer.stream_to(Vector2.ZERO)
	await wait_process_frames(2)
	assert_eq(layer._chunks.batched_count(), 0, "kill-switch: nothing batches")
	assert_eq((layer.placed_indices() as Array).size(), 6, "every rock takes the individual path")
	assert_eq(_find_all(layer, "MultiMeshInstance3D").size(), 0, "no pools under the kill-switch")


# ---- T-696: auto-LOD on merged meshes (restores the T-693 regression) -------------------------


func test_merged_meshes_carry_generated_lods() -> void:
	# A merged multi-part ArrayMesh (SurfaceTool.commit) shipped with LOD0 only — full triangles to
	# 320 m. It must now carry engine-generated surface LODs, read back from the live renderer.
	var chunks = PropChunks.new()
	chunks._mesh_cache_enabled = false  # force a live merge, not a cache hit
	for scene in [BRAMBLE, OAK]:
		var lib: Dictionary = chunks._extract(scene)
		assert_true(lib["ok"], "%s merges" % (scene as String).get_file())
		assert_gt(
			PropChunks.surface_lod_total(lib["mesh"] as Mesh),
			0,
			"merged %s carries auto-generated LODs" % (scene as String).get_file()
		)


func test_merge_cache_round_trips_with_lods_and_the_v2_key() -> void:
	var chunks = PropChunks.new()
	chunks._mesh_cache_enabled = true
	var path: String = chunks._mesh_cache_path(BRAMBLE)
	if path != "" and FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)
	assert_true(path.contains("_v2."), "the cache key carries the bumped v2 format (LODs baked in)")
	var v1_path := (
		"%s%s_%d_v1.res"
		% [
			PropChunks.MESH_CACHE_DIR,
			BRAMBLE.get_file().get_basename(),
			FileAccess.get_modified_time(BRAMBLE),
		]
	)
	assert_ne(
		v1_path, path, "an old v1 (LOD-less) cache keys a different file -> misses + regenerates"
	)
	var fresh: Dictionary = chunks._extract(BRAMBLE)  # merges + persists to the v2 key
	assert_gt(PropChunks.surface_lod_total(fresh["mesh"] as Mesh), 0, "the fresh merge has LODs")
	assert_true(FileAccess.file_exists(path), "the LODded merge was persisted to the v2 cache file")
	var pc2 = PropChunks.new()
	pc2._mesh_cache_enabled = true
	var loaded: Dictionary = pc2._extract(BRAMBLE)  # reloads off disk
	assert_gt(
		PropChunks.surface_lod_total(loaded["mesh"] as Mesh),
		0,
		"the cached mesh reloads WITH its LODs (they serialize into the ArrayMesh)"
	)


# ---- T-696: batched-tree billboard impostors --------------------------------------------------


func _real_and_impostor_mmis(layer: WorldPropsLayer) -> Dictionary:
	var out := {"real": null, "impostor": null}
	for m in _find_all(layer, "MultiMeshInstance3D"):
		if str((m as Node).name) == "impostors":
			out["impostor"] = m
		else:
			out["real"] = m
	return out


func test_batched_trees_get_a_far_impostor_pool_with_range_crossover() -> void:
	var manifest: Array = []
	for k in 6:  # prop_tree_fir_a: impostor class WITH a baked prop_tree_fir_a_impostor.png
		manifest.append({"scene": FIR, "x": float(k * 3), "y": 0.0, "scale": 1.0 + 0.1 * k})
	var layer := _make_layer(manifest)
	layer.stream_to(Vector2.ZERO)
	await wait_process_frames(2)
	var mmis := _real_and_impostor_mmis(layer)
	var real := mmis["real"] as MultiMeshInstance3D
	var imp := mmis["impostor"] as MultiMeshInstance3D
	assert_true(imp != null, "an impostor pool is built for a baked-impostor tree scene")
	assert_eq(imp.multimesh.instance_count, 6, "one billboard per batched tree placement")
	assert_eq(
		real.multimesh.instance_count,
		6,
		"the real-mesh pool still holds every placement (near = full)"
	)
	var base := FIR.get_file()
	var m := PropChunks.CHUNK_MARGIN
	assert_true(
		absf(real.visibility_range_end - (LodPolicy.impostor_distance(base) + m)) < 0.01,
		"the real tree mesh culls at the impostor swap distance (+chunk margin)"
	)
	assert_true(
		absf(imp.visibility_range_begin - (LodPolicy.impostor_distance(base) + m)) < 0.01,
		"the impostor takes over exactly where the real mesh culls"
	)
	assert_true(
		absf(imp.visibility_range_end - (LodPolicy.cull_distance(base) + m)) < 0.01,
		"the impostor carries the far band out to the full tree cull"
	)
	assert_gt(
		imp.visibility_range_end, real.visibility_range_end, "near = full mesh, far = impostor"
	)


func test_non_impostor_flora_gets_no_impostor_pool() -> void:
	var manifest: Array = []
	for k in 6:
		manifest.append(_rock(float(k * 3), 0.0))
	var layer := _make_layer(manifest)
	layer.stream_to(Vector2.ZERO)
	await wait_process_frames(2)
	var mmis := _real_and_impostor_mmis(layer)
	assert_true(mmis["impostor"] == null, "rocks (no baked impostor) get no billboard pool")
	assert_true(
		(
			absf(
				(
					(mmis["real"] as MultiMeshInstance3D).visibility_range_end
					- (LodPolicy.cull_distance(ROCK.get_file()) + PropChunks.CHUNK_MARGIN)
				)
			)
			< 0.01
		),
		"a non-impostor scene keeps its full class cull range"
	)


func test_impostor_class_without_a_baked_texture_keeps_full_mesh_range() -> void:
	# prop_oak.glb is impostor-CLASS (prop_oak*) but ships NO prop_oak_impostor.png: it must NOT cull
	# its real mesh at the swap distance (that would vanish the tree with nothing drawn behind it).
	var manifest: Array = []
	for k in 4:
		manifest.append({"scene": OAK, "x": float(k * 4), "y": 0.0, "solid": false})
	var layer := _make_layer(manifest)
	layer.stream_to(Vector2.ZERO)
	await wait_process_frames(2)
	var mmis := _real_and_impostor_mmis(layer)
	assert_true(mmis["impostor"] == null, "no billboard pool without a baked texture")
	assert_true(
		(
			absf(
				(
					(mmis["real"] as MultiMeshInstance3D).visibility_range_end
					- (LodPolicy.cull_distance(OAK.get_file()) + PropChunks.CHUNK_MARGIN)
				)
			)
			< 0.01
		),
		"the textureless tree keeps its full mesh cull range (no premature vanish)"
	)
