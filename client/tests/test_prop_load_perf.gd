extends "res://addons/gut/test.gd"

# T-695: login load-order optimisations — the CPU half of the T-691 login (~8s measured). Proves,
# headlessly:
#   * MERGE CACHE — a warm user:// merged-mesh cache SHORT-CIRCUITS the ~3.4s of cold-boot
#     SurfaceTool merges (load_manifest's dominant cost) rather than repeating them. Asserted on
#     the mechanism (_extract_pure's `_fresh` flag), never on wall-clock: T-756 removed the old
#     ">= 4x faster" ratio, which measured the machine's load more than it measured the cache;
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


# (T-756 removed _extract_all_usec: its only caller was the wall-clock merge-cache ratio, now
# replaced by a mechanism assert on _extract_pure's `_fresh` flag.)

# ---- headline: a warm merge cache short-circuits the login merge ----


# T-756: this was a wall-clock ratio — `cold_us >= 4 * warm_us` across five heavy GLB merges.
# Two problems. It is not a test of the cache, it is a test of the machine: on a loaded box
# (another lane running its own suite, which is routine here) the cold pass drifts slow enough to
# clear 4x with a cache that never engages, and on a fast quiet box a genuinely broken cache can
# still land under it. And it silently set up the file's order-dependence, because the pass it
# times as "cold" warms Godot's own resource cache for every test after it.
#
# The cache has an exact, observable mechanism, so assert that instead: _extract_pure() reports
# `_fresh` = true when it actually merged and false when it short-circuited on a cache hit. That
# distinction IS the feature, it is deterministic, and it goes red the moment the cache stops
# being written or stops being consulted — which the timing ratio could not reliably do.
func test_merge_cache_short_circuits_the_merge_instead_of_redoing_it() -> void:
	_clear_cache(HEAVY)
	var scene: String = BRAMBLE

	# Cold, cache ON: nothing on disk yet, so this must be a real merge, marked for persisting.
	var cold_pc = PropChunks.new()
	cold_pc._mesh_cache_enabled = true
	var cold: Dictionary = cold_pc._extract_pure(scene)
	assert_true(bool(cold["ok"]), "the cold extract produced a usable merged mesh")
	assert_true(bool(cold["_fresh"]), "a cold extract really merges (nothing on disk to load)")
	assert_ne(str(cold["_cache_path"]), "", "and it knows where that merge belongs on disk")

	# Persist it — the main-thread half of the T-695 split.
	cold_pc._persist_fresh_merge(cold)
	assert_true(
		FileAccess.file_exists(str(cold["_cache_path"])),
		"the fresh merge was written to the mesh cache"
	)

	# Warm, cache ON, brand-new PropChunks (empty _lib): must take the cache branch, which
	# returns before load()/instantiate()/SurfaceTool are ever reached.
	var warm_pc = PropChunks.new()
	warm_pc._mesh_cache_enabled = true
	var warm: Dictionary = warm_pc._extract_pure(scene)
	assert_true(bool(warm["ok"]), "the warm extract produced a usable mesh")
	assert_false(bool(warm["_fresh"]), "a cache HIT skips the merge entirely — this is the win")
	assert_not_null(warm["mesh"], "and it came back holding the cached ArrayMesh")

	# Kill-switch (T-702): with the cache off, the same warm disk state must still re-merge.
	var off_pc = PropChunks.new()
	off_pc._mesh_cache_enabled = false
	var off: Dictionary = off_pc._extract_pure(scene)
	assert_true(bool(off["_fresh"]), "AVALON_MESH_CACHE=0 ignores the cache and merges every time")

	# T-756: leave nothing behind in the developer's real user:// mesh cache. The old test
	# populated it and never cleaned up, so every later run started from different disk state.
	_clear_cache(HEAVY)


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
#
# T-756: the line above claimed "This asserts the mechanism, not a wall-clock budget" — and the
# body then timed two load() passes and asserted `warm_us * 10 < cold_us`. It was precisely the
# wall-clock budget it disclaimed. Worse, its "unpinned" pass is only genuinely cold on the first
# run in a fresh process: any earlier test in this file that loaded these GLBs (the merge-cache
# test above does) leaves them in Godot's resource cache, at which point both passes measure the
# same retained object and the 10x ratio turns on scheduler noise alone. Assert the mechanism.
func test_scene_pin_makes_repeat_loads_free() -> void:
	var scenes := HEAVY
	var layer = autofree(WorldPropsLayer.new())
	for s in scenes:
		var pinned: PackedScene = layer.pinned_scene(s)
		assert_not_null(pinned, "pin resolves %s" % s)
		# The pin IS the mechanism: while the layer holds a reference, the decoded scene cannot
		# fall to refcount zero, so it stays in Godot's resource cache and load() hands back that
		# very object instead of re-decoding the whole GLB.
		assert_true(ResourceLoader.has_cached(s), "%s is retained in the resource cache" % s)
		assert_true(is_same(load(s), pinned), "load() returns the pinned scene, not a re-decode")
	assert_eq(layer._scene_pin.size(), scenes.size(), "one pin held per distinct scene")
	layer._teardown_all()
	assert_eq(layer._scene_pin.size(), 0, "the region seam releases them again")


func test_scene_pin_returns_the_same_instance_and_clears_on_region_teardown() -> void:
	var layer = autofree(WorldPropsLayer.new())
	var a: PackedScene = layer.pinned_scene(BRAMBLE)
	var b: PackedScene = layer.pinned_scene(BRAMBLE)
	assert_true(a == b, "the pin hands back the SAME PackedScene, not a re-decode")
	assert_eq(layer._scene_pin.size(), 1, "one unique scene pinned")
	layer._teardown_all()
	assert_eq(layer._scene_pin.size(), 0, "the region seam releases the old region's GLBs")
	assert_null(layer.pinned_scene(""), "an empty path pins nothing")
