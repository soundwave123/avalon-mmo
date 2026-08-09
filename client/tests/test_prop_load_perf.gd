extends "res://addons/gut/test.gd"

# T-695: login load-order optimisations — the CPU half of the T-691 login (~8s measured). Proves,
# headlessly:
#   * MERGE CACHE — the ~3.4s of cold-boot SurfaceTool merges (load_manifest's dominant cost) drops
#     >= 4x when a user:// merged-mesh cache is warm vs the cold merge (AVALON_MESH_CACHE A/B);
#   * CACHE ROUND-TRIP — a saved merge reloads to an identical mesh; the key is GLB-mtime + version
#     keyed, so a changed asset (or a format bump) keys a different file and regenerates on miss;
#   * QUEUED FIRST POPULATE — behind the loading screen the first populate defers into the T-688
#     frame budget (nothing placed inline; the queue drains to byte-parity with the inline path);
#   * KILL-SWITCH — AVALON_MESH_CACHE=0 restores the uncached merge path (no disk writes). T-702
#     split this from AVALON_THREADED_LOAD: threading off must NOT take the cache down with it.
#
# The threaded WorkerThreadPool merge/preload/terrain paths are LIVE-only (headless keeps the
# synchronous path — the dummy-renderer threaded-load hazard, T-697); this suite exercises the
# cached-synchronous path + the queue routing — the deterministic, headless-verifiable half.

const WorldPropsLayer = preload("res://scripts/world/world_props_layer.gd")
const PropChunks = preload("res://scripts/world/prop_chunks.gd")
const TerrainField = preload("res://scripts/world/terrain_field.gd")
const TerrainSampler = preload("res://scripts/world/terrain_sampler.gd")

# Merge-heavy multi-MeshInstance GLBs — the SurfaceTool merges that dominated the login CPU chain.
const HEAVY := [
	"res://assets/models/prop_bramble_patch.glb",  # 326 parts
	"res://assets/models/prop_oak.glb",  # 76 parts
	"res://assets/models/prop_scarecrow.glb",  # 1077 parts
	"res://assets/models/prop_forge.glb",  # 807 parts
	"res://assets/models/prop_market_stall.glb",  # 589 parts
]
const BRAMBLE := "res://assets/models/prop_bramble_patch.glb"


func _clear_cache(scenes: Array) -> void:
	var pc = PropChunks.new()
	for s in scenes:
		var p: String = pc._mesh_cache_path(s)
		if p != "" and FileAccess.file_exists(p):
			DirAccess.remove_absolute(p)


func _extract_all_usec(cache_enabled: bool) -> int:
	# Fresh PropChunks (empty _lib) so every scene is genuinely (re)extracted; warm_library is the
	# exact extraction/merge work load_manifest front-loads. Sync under headless regardless of the
	# `threaded` arg, so this measures MAIN-THREAD cost — a fair A/B of the cache alone.
	var pc = PropChunks.new()
	pc._mesh_cache_enabled = cache_enabled
	var t0 := Time.get_ticks_usec()
	pc.warm_library(HEAVY, false)
	return Time.get_ticks_usec() - t0


# ---- headline: the merge cache cuts the login merge cost >= 4x ----


func test_merge_cache_cuts_login_merge_cost_at_least_4x() -> void:
	_clear_cache(HEAVY)
	# Cold: cache OFF — the full SurfaceTool merges (the pre-T-695 synchronous login path).
	var cold_us := _extract_all_usec(false)
	# Populate the cache once (cache ON, cold _lib -> merges + ResourceSaver.save).
	var warm_pc = PropChunks.new()
	warm_pc._mesh_cache_enabled = true
	warm_pc.warm_library(HEAVY, false)
	# Warm: a brand-new PropChunks with the cache present -> loads the merged meshes off disk.
	var warm_us := _extract_all_usec(true)
	assert_gt(cold_us, 0, "cold merge path did real work")
	assert_true(
		cold_us >= 4 * warm_us,
		(
			"warm merge cache >= 4x faster than the cold merge: cold=%d us warm=%d us (%.1fx)"
			% [cold_us, warm_us, float(cold_us) / maxf(float(warm_us), 1.0)]
		)
	)


# ---- cache round-trip + mtime/version invalidation ----


func test_merge_cache_round_trips_and_is_mtime_keyed() -> void:
	_clear_cache([BRAMBLE])
	var mtime := FileAccess.get_modified_time(BRAMBLE)
	var pc = PropChunks.new()
	pc._mesh_cache_enabled = true
	var cache_path: String = pc._mesh_cache_path(BRAMBLE)
	assert_true(
		cache_path.contains(str(mtime)),
		"cache key folds the GLB mtime (%s) so a changed asset misses + regenerates" % str(mtime)
	)
	assert_true(
		cache_path.contains("_v%d." % PropChunks.MESH_CACHE_VERSION), "and a format version"
	)
	# First extract merges + persists.
	var fresh: Dictionary = pc._extract(BRAMBLE)
	assert_true(fresh["ok"], "the bramble merges")
	assert_true(FileAccess.file_exists(cache_path), "the merge was persisted to the user:// cache")
	var fresh_mesh := fresh["mesh"] as ArrayMesh
	# A brand-new PropChunks loads the SAME mesh off disk (identical surfaces + geometry).
	var pc2 = PropChunks.new()
	pc2._mesh_cache_enabled = true
	var loaded: Dictionary = pc2._extract(BRAMBLE)
	assert_true(loaded["ok"], "the cached bramble loads")
	var loaded_mesh := loaded["mesh"] as ArrayMesh
	assert_eq(
		loaded_mesh.get_surface_count(),
		fresh_mesh.get_surface_count(),
		"cached mesh has the same surface groups as the fresh merge",
	)
	for s in fresh_mesh.get_surface_count():
		assert_eq(
			loaded_mesh.surface_get_array_len(s),
			fresh_mesh.surface_get_array_len(s),
			"cached surface %d has the identical vertex count" % s,
		)
	assert_true(
		loaded_mesh.get_aabb().size.distance_to(fresh_mesh.get_aabb().size) < 0.001,
		"cached mesh bounds match the fresh merge",
	)
	# mtime invalidation: a DIFFERENT on-disk mtime yields a DIFFERENT cache path, so a changed asset
	# can never read a stale merge — it misses and regenerates (the first-extract-persists path above).
	var stale_path := (
		"%s%s_%d_v%d.res"
		% [
			PropChunks.MESH_CACHE_DIR,
			BRAMBLE.get_file().get_basename(),
			mtime + 1,
			PropChunks.MESH_CACHE_VERSION,
		]
	)
	assert_ne(stale_path, cache_path, "a changed mtime keys a different cache file")
	assert_false(
		FileAccess.file_exists(stale_path),
		"the changed-asset key has no (stale) cache -> regenerates"
	)


# ---- queued first populate defers over frames, drains to inline parity ----


func _offtree_layer(manifest: Array) -> WorldPropsLayer:
	# Off-tree (like test_world_props): _ready never fires, so _active_region stays -999 and the next
	# stream_to is a genuine INITIAL populate we can steer with _queue_initial.
	var layer = autofree(WorldPropsLayer.new())
	layer.load_manifest(manifest)
	layer.set_stream_cfg({"flora_ring": 100.0, "building_ring": 900.0})
	return layer


func test_queued_first_populate_defers_then_drains_to_inline_parity() -> void:
	var manifest: Array = []
	for k in 6:  # repeated rocks -> one batched chunk
		manifest.append(
			{"scene": "res://assets/models/prop_rock_a.glb", "x": float(k * 3), "y": 0.0}
		)
	# a night-light base + a building keep the individual _place path (two queued int items).
	manifest.append({"scene": "res://assets/models/prop_lamppost_v2.glb", "x": 20.0, "y": 0.0})
	manifest.append({"scene": "res://assets/models/prop_cottage_v2.glb", "x": 0.0, "y": 8.0})

	# Inline baseline (the pre-T-695 first-populate burst).
	var inline := _offtree_layer(manifest)
	inline.stream_to(Vector2.ZERO)  # initial + _queue_initial false -> places inline
	var want_instances := inline._chunks.instance_total()
	var want_placed := (inline.placed_indices() as Array).size()
	assert_eq(want_instances, 6, "inline path places the batched rocks immediately")
	assert_eq(want_placed, 2, "inline path places the two individual props immediately")

	# Queued path: the SAME first populate deferred behind the loading screen.
	var queued := _offtree_layer(manifest)
	queued._queue_initial = true
	queued.stream_to(Vector2.ZERO)
	assert_eq(queued._chunks.instance_total(), 0, "queued first populate builds NOTHING inline")
	assert_eq((queued.placed_indices() as Array).size(), 0, "no individual props placed inline")
	assert_false(queued._load_queue.is_empty(), "the first populate went onto the T-688 queue")

	var guard := 0
	while not queued._load_queue.is_empty() and guard < 50:
		queued._drain_load_queue()
		guard += 1
	assert_eq(
		queued._chunks.instance_total(), want_instances, "the drained queue reaches batched parity"
	)
	assert_eq(
		(queued.placed_indices() as Array).size(), want_placed, "and individual-placement parity"
	)


# ---- kill-switch: AVALON_THREADED_LOAD off -> uncached synchronous path ----

# ---- terrain: threaded sampling == inline sampling == direct height() ----


func test_terrain_threaded_sampling_matches_inline_and_direct() -> void:
	# height() is renderer-free pure math, so the WorkerThreadPool path (the shared-buffer write) is
	# safe to exercise headless here — the parity check validates the threading mechanics live-off.
	var tf = TerrainField.new()
	var xs := PackedFloat32Array()
	var zs := PackedFloat32Array()
	for i in range(64):
		xs.append(-205.0 + i * 6.37)
	for i in range(48):
		zs.append(-405.0 + i * 9.11)
	var nx := xs.size()
	var inline := TerrainSampler.new().sample(tf, xs, zs, false)
	var threaded := TerrainSampler.new().sample(tf, xs, zs, true)
	assert_eq(inline.size(), nx * zs.size(), "sampler returns a full row-major grid")
	assert_eq(threaded.size(), inline.size(), "threaded grid is the same shape")
	var thread_diffs := 0
	var placement_diffs := 0
	var nonzero := 0
	for iz in range(zs.size()):
		for ix in range(nx):
			var idx := iz * nx + ix
			if threaded[idx] != inline[idx]:
				thread_diffs += 1
			# The buffer stores float32; compare row-major placement to direct height() within the
			# float32 rounding tolerance (an exact == would be float32-vs-float64 noise).
			if not is_equal_approx(inline[idx], tf.height(xs[ix], zs[iz])):
				placement_diffs += 1
			if absf(inline[idx]) > 0.0001:
				nonzero += 1
	assert_eq(thread_diffs, 0, "threaded sampling is byte-identical to the inline sampling")
	assert_eq(placement_diffs, 0, "every grid cell carries height() at its own (x,z)")
	assert_gt(nonzero, 0, "the grid carries a real displaced field, not all zero")


func test_kill_switch_disables_the_cache_and_leaves_disk_untouched() -> void:
	_clear_cache([BRAMBLE])
	var pc = PropChunks.new()
	pc._mesh_cache_enabled = false  # T-702: AVALON_MESH_CACHE=0 semantics (its own switch now)
	var cache_path: String = pc._mesh_cache_path(BRAMBLE)
	var e: Dictionary = pc._extract(BRAMBLE)
	assert_true(e["ok"], "the merge still works with the cache off")
	assert_false(
		FileAccess.file_exists(cache_path), "kill-switch writes nothing to the user:// cache"
	)


# T-702 regression guard: the mesh cache must default ON and must NOT ride AVALON_THREADED_LOAD.
# The original defect was silent — threading was switched off to stop the live login deadlock, and
# the cache went down with it, putting login back at ~8s with nothing in the logs to say so.
func test_mesh_cache_defaults_on_and_is_independent_of_threaded_load() -> void:
	if OS.get_environment("AVALON_MESH_CACHE") == "0":
		pass_test("AVALON_MESH_CACHE=0 in this environment — default-on is not observable here")
		return
	var pc = PropChunks.new()
	assert_true(
		pc._mesh_cache_enabled,
		"the merge cache defaults ON (AVALON_MESH_CACHE unset) regardless of AVALON_THREADED_LOAD"
	)


# T-702: the scene pin. Godot frees a resource the instant its refcount hits zero, so a bare
# `load()` per placed prop re-decodes the WHOLE GLB every time. Measured over the 187-scene
# manifest: 4,665 ms to load them all, repeatable to the millisecond on passes 2 and 3 (no
# retention) vs 0.3 ms with references held. This asserts the mechanism, not a wall-clock budget.
func test_scene_pin_makes_repeat_loads_free() -> void:
	var scenes := HEAVY
	# Unpinned: each load() is a fresh decode because nothing holds the previous one.
	var cold_us := 0
	for s in scenes:
		var t := Time.get_ticks_usec()
		var _p = load(s)
		cold_us += Time.get_ticks_usec() - t
	# Pinned via the layer: the second pass must be dramatically cheaper.
	var layer = autofree(WorldPropsLayer.new())
	for s in scenes:
		assert_not_null(layer.pinned_scene(s), "pin resolves %s" % s)
	var warm_us := 0
	for s in scenes:
		var t := Time.get_ticks_usec()
		var _p = load(s)
		warm_us += Time.get_ticks_usec() - t
	assert_gt(cold_us, 0, "the unpinned pass did real decode work")
	assert_true(
		warm_us * 10 < cold_us,
		"pinned repeat-load is >10x cheaper: unpinned=%d us pinned=%d us" % [cold_us, warm_us]
	)


func test_scene_pin_returns_the_same_instance_and_clears_on_region_teardown() -> void:
	var layer = autofree(WorldPropsLayer.new())
	var a: PackedScene = layer.pinned_scene(BRAMBLE)
	var b: PackedScene = layer.pinned_scene(BRAMBLE)
	assert_true(a == b, "the pin hands back the SAME PackedScene, not a re-decode")
	assert_eq(layer._scene_pin.size(), 1, "one unique scene pinned")
	layer._teardown_all()
	assert_eq(layer._scene_pin.size(), 0, "the region seam releases the old region's GLBs")
	assert_null(layer.pinned_scene(""), "an empty path pins nothing")
