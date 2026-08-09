# T-693: chunked-MultiMesh batching for the repeated world dressing. The T-692 profile showed the
# client CPU-bound on ~15,800 draw calls + 95k scene nodes because every dressing prop (3,498
# placements, only 187 unique models — brambles/oaks are 200-300-node GLB scenes EACH) instantiates
# as a full multi-node GLB scene. This module collapses the repeated FLORA-tier dressing into
# one MultiMesh per (unique scene x 64 m world chunk):
#
#   * MESH LIBRARY — each batchable GLB is flattened ONCE into a single Mesh: a lone MeshInstance3D
#     contributes its mesh directly (+ its local transform); multi-MeshInstance GLBs (the 326-part
#     bramble, the 231-part oak) are MERGED into one ArrayMesh, surfaces grouped by material via
#     SurfaceTool, so a whole bramble patch is ONE draw per material instead of 326.
#   * CHUNKED POOLS — placements grid into (region, 64 m cell) chunks; one MultiMeshInstance3D per
#     (scene x chunk) draws all its instances in one call per surface and frustum-culls per chunk.
#     Per-class distance culling rides visibility_range_end (padded by the chunk half-diagonal, the
#     range is measured from the chunk origin) with a self-fade margin. Instances are sorted
#     largest-scale-first so a future density preset (T-692 Part B) can cut visible_instance_count
#     to a prefix and keep the most salient props.
#   * COLLISION SPLIT — MultiMesh has no per-instance collision, so blocking instances (same
#     T-164 policy as the individual path: solid + not-a-tree) get a CollisionShape3D under one
#     chunk StaticBody3D, sharing a single trimesh shape per scene. No visual children.
#   * WEATHERING — the T-290 overlay is ONE shared ShaderMaterial per batched scene
#     (moss_overlay_instanced.gdshader); the only per-prop parameter (ground_y) rides per-instance
#     INSTANCE_CUSTOM data, so weathering never re-splits the batch.
#
# Ownership: world_props_layer.gd owns the lifecycle (plan at manifest load, build/free through its
# region + ring streaming and the T-688 frame-budgeted load queue — one chunk build is one queue
# item); this module owns the mesh library, the chunk bookkeeping and the chunk node contents.
# Chunk nodes are direct children of the layer, so the layer's _teardown_all leak guard (free every
# child) covers them; reset() re-syncs the bookkeeping. Hero-STEM landmarks/buildings/interactive
# props (lights, sockets, critters, doors) NEVER batch — they keep the layer's individual _place
# path.
#
# T-693 residual #2 — HERO POOLS: placements TAG-promoted to TIER_HERO ("highkeep" dressing:
# fences, barrels, banner poles — 216 in the live manifest) whose SCENE is otherwise plain
# batchable flora batch into hero chunk pools keyed Vector4i(region, cx, cz, 1) (the 4th lane
# keeps them from colliding with the flora key Vector3i(region, cx, cz)). Hero pools mirror the
# tag's residency semantics exactly: target_chunks returns them for the whole active region
# (never ring-streamed), so they persist across flora-ring exits and tear down only at the region
# seam — only the RENDERING changed, from ~30 nodes/placement to a MultiMesh instance.
#
# T-694 — RIGID-SCENE FLATTEN: critter GLBs are pathological deep scenes (rabbit = 3,527
# instantiated nodes / 1,175 MeshInstances, NO AnimationPlayer) that wander as a rigid unit (root
# transform only). flatten_rigid() collapses such a scene in place to ONE merged MeshInstance3D
# under the same root via the same SurfaceTool material-content merge, cached per scene path so
# every placed rabbit shares one ArrayMesh. Scenes with engine attachments (mob_sheep's
# AnimationPlayer rig) are refused — they are not rigid decor.

extends RefCounted

const LodPolicy = preload("res://scripts/world/lod_policy.gd")
const INSTANCED_WEATHER_SHADER := preload("res://shaders/moss_overlay_instanced.gdshader")

const CHUNK_SIZE := 64.0  # m; the documented start point (T-693 design §2)
# Minimum placements for a scene to batch. 1 — i.e. EVERY content-eligible flora/decorative scene
# batches: measured on the real manifest, the low-count tail is where the heaviest GLBs hide
# (prop_forge ~2,400 nodes x3, prop_market_stall ~1,770 x2, prop_scarecrow 3,233 x1 — hundreds of
# MeshInstances each), and a MultiMesh of even ONE merged instance collapses that to a single node
# and one draw per material. Kept as a constant because it is the obvious tuning knob if
# mesh-library extraction cost ever shows up at login.
const BATCH_MIN_COUNT := 1
# visibility_range_end is measured from the chunk node origin (the chunk centre), not from each
# instance — pad the per-class cull distance by the chunk half-diagonal so no instance ever culls
# EARLIER than its old per-node range.
const CHUNK_MARGIN := 46.0  # 64 * sqrt(2) / 2, rounded up
const FADE_MARGIN := 12.0  # visibility fade band (m) — chunk pops become a soft dither
# T-695: persist merged ArrayMeshes to user:// so the ~3.4s of cold-boot SurfaceTool merges runs
# ONCE (ever, per GLB revision) instead of every login. The cache key folds the GLB on-disk mtime +
# format version, so any asset edit (or a merge-format bump via MESH_CACHE_VERSION) invalidates the
# stale mesh automatically. Gated by its own AVALON_MESH_CACHE kill-switch (T-702; see below) —
# independent of AVALON_THREADED_LOAD, which gates threading only.
const MESH_CACHE_DIR := "user://mesh_cache/"
# T-696: bumped 1 -> 2 — merged meshes now carry auto-generated surface LODs baked in (see
# _with_generated_lods), so every v1 cache (LOD-less) must miss + regenerate WITH LODs.
const MESH_CACHE_VERSION := 2  # bump to invalidate every cached merge across the fleet
# T-696: ImporterMesh.generate_lods weld angles — the engine's own import defaults, so a runtime
# merge LODs exactly like an import-time mesh would. Verified headless: real bramble/oak merges
# retain LODs (RenderingServer.mesh_get_surface(...).lods) through the user:// cache round-trip.
const LOD_NORMAL_MERGE_ANGLE := 25.0
const LOD_NORMAL_SPLIT_ANGLE := 60.0
# T-696: batched-tree impostor billboard framing — MUST match world_props_layer's individual path
# and bake_impostor.py's square ortho frame padding so the batched billboard reads identically.
const IMPOSTOR_FRAME_MARGIN := 1.06

# T-692 Part B: the preset distance multiplier (Low 0.55 … Ultra 1.25) applied to every LodPolicy
# range a pool bakes into visibility_range_*. The layer syncs it in set_stream_cfg; a preset
# change rebuilds the pools (apply_quality_cfg), so already-built chunks never go stale.
var lod_mult := 1.0
var _manifest: Array = []  # the layer's props.json rows (shared reference, never mutated)
# scene_path -> {ok, mesh: Mesh, xform: Transform3D, tangentless: bool, shape: Shape3D-or-null}.
# Cache survives region swaps: the mesh library is region-independent.
var _lib: Dictionary = {}
var _overlays: Dictionary = {}  # scene_path -> shared weathering ShaderMaterial
# Chunk key -> Array[manifest index]. Flora keys are Vector3i(region, cx, cz); hero-pool keys are
# Vector4i(region, cx, cz, 1) — same grid, distinct namespace (see header). key.x/.y/.z accessors
# agree across both, so the shared build/free machinery never branches on the type.
var _assign: Dictionary = {}
var _batched: Dictionary = {}  # manifest index -> true (the layer's individual-path exclusion set)
var _built: Dictionary = {}  # chunk key -> {node: Node3D, instances: int}
# T-694: scene_path -> {ok, mesh, xform} flatten cache for deep rigid scenes (critters). Region-
# independent like _lib; the merged ArrayMesh is shared by every placed instance of the scene.
var _flat: Dictionary = {}
# T-702: merge-cache on/off — its OWN kill-switch, default ON. It used to ride
# AVALON_THREADED_LOAD, so shipping threading off (the T-702 deadlock mitigation) also killed the
# cache and put login back at ~8s. The cache is NOT thread-dependent: ResourceLoader.load /
# ResourceSaver.save are synchronous, and the save is main-thread-by-contract either way.
# AVALON_MESH_CACHE=0 => always merge, never touch disk (the escape hatch for a poisoned cache).
var _mesh_cache_enabled := OS.get_environment("AVALON_MESH_CACHE") != "0"
var _warm_mutex := Mutex.new()  # guards the results collection when warm_library runs threaded
# T-696: scene_path -> {ok, tex, span, mid_y} billboard-impostor spec for batched trees (the far
# MultiMesh quad each chunk swaps to past the LodPolicy impostor threshold). Region-independent
# like _lib; ok=false marks a scene with no baked *_impostor.png (real mesh carries the full range).
var _impostor_lib: Dictionary = {}

# ---- shared placement math (the individual _place path uses these too — single source) ---------


# The exact node transform _place has always produced: position (x, terrain_y, y), yaw = rot_deg,
# uniform scale. Batched instances and individual nodes MUST agree byte-for-byte on this.
static func placement_transform(p: Dictionary) -> Transform3D:
	var basis := Basis(Vector3.UP, deg_to_rad(float(p.get("rot_deg", 0.0))))
	basis = basis.scaled(Vector3.ONE * float(p.get("scale", 1.0)))  # uniform, so order is moot
	var origin := Vector3(
		float(p.get("x", 0.0)), float(p.get("terrain_y", 0.0)), float(p.get("y", 0.0))
	)
	return Transform3D(basis, origin)


# T-164 collision policy, verbatim from the individual path: solid placements collide EXCEPT trees
# (their canopy trimesh would block walking under them; trunk-only comes with tree v2).
static func blocks(p: Dictionary, scene_path: String) -> bool:
	if not bool(p.get("solid", true)):
		return false
	return not ("oak" in scene_path or "pine" in scene_path or "tree" in scene_path)


# World-grid cell of a ground position (server x,y plane).
static func chunk_coords(ground: Vector2) -> Vector2i:
	return Vector2i(int(floor(ground.x / CHUNK_SIZE)), int(floor(ground.y / CHUNK_SIZE)))


# Accumulates LOCAL (Node3D.transform) matrices from `node` up to (not including) `ancestor` —
# tree-independent, so it works on freshly instantiated (off-tree) GLB scenes. Moved here from
# world_props_layer.gd (T-693) so both the mesh library and the layer share one implementation.
static func local_transform_to_ancestor(node: Node3D, ancestor: Node3D) -> Transform3D:
	var t := node.transform
	var cur := node.get_parent()
	while cur != null and cur != ancestor:
		if cur is Node3D:
			t = (cur as Node3D).transform * t
		cur = cur.get_parent()
	return t


# ---- planning ---------------------------------------------------------------------------------


# Decide the batched set + chunk assignments for a loaded manifest. `metas` are the layer's
# per-prop records ({i, ground, region, batch_stem, hero_stem, ...}); only metas whose
# "batch_stem" (flora) or "hero_stem" (tag-promoted, T-693 residual #2) passed the pure
# name-level predicates (PropStreamer.batchable_stem / hero_batchable_stem) are considered, then
# repetition (>= BATCH_MIN_COUNT), a per-placement "vis" override (stays individual), and the GLB
# CONTENT check in _extract (lights/sockets/AnimationPlayer/door marker -> never batched) gate the
# rest. Hero metas assign to Vector4i hero-pool keys, flora to Vector3i keys — same 64 m grid.
# `weather` maps scene BASENAME -> the T-290 grading dict ({} = clean). Returns {index: true}.
func plan_manifest(manifest: Array, metas: Array, weather: Dictionary) -> Dictionary:
	_manifest = manifest
	reset()
	_assign.clear()
	_batched.clear()
	var counts: Dictionary = {}
	for m in metas:
		if not (bool(m.get("batch_stem", false)) or bool(m.get("hero_stem", false))):
			continue
		var scene := str((manifest[int(m["i"])] as Dictionary).get("scene", ""))
		counts[scene] = int(counts.get(scene, 0)) + 1
	for m in metas:
		var hero := bool(m.get("hero_stem", false))
		if not (bool(m.get("batch_stem", false)) or hero):
			continue
		var i := int(m["i"])
		var p: Dictionary = manifest[i]
		var scene := str(p.get("scene", ""))
		if int(counts.get(scene, 0)) < BATCH_MIN_COUNT:
			continue
		if p.has("vis"):
			continue  # a hand-tuned per-placement cull distance keeps the individual path
		var lib := _extract(scene)
		if not bool(lib["ok"]):
			continue
		_ensure_overlay(scene, weather.get(scene.get_file(), {}) as Dictionary, lib)
		var cc := chunk_coords(m["ground"] as Vector2)
		var key: Variant = (
			Vector4i(int(m["region"]), cc.x, cc.y, 1)
			if hero
			else Vector3i(int(m["region"]), cc.x, cc.y)
		)
		if not _assign.has(key):
			_assign[key] = []
		(_assign[key] as Array).append(i)
		_batched[i] = true
	return _batched


# The chunk keys that should be resident for a player at `player` in `region`. Flora chunks
# (Vector3i) are resident iff the nearest point of the chunk's ground rect is within `ring` (the
# flora ring); HERO pools (Vector4i) are resident for the whole active region — the tag's
# never-stream-out residency, ring-independent. Pure function of the inputs (no hysteresis/
# history): the 10x-border-walk determinism invariant holds chunk-wise.
func target_chunks(player: Vector2, region: int, ring: float) -> Dictionary:
	var out: Dictionary = {}
	for key in _assign:
		if int(key.x) != region:
			continue
		if key is Vector4i:  # hero pool: always resident within its region
			out[key] = true
			continue
		var min_x := float(key.y) * CHUNK_SIZE
		var min_z := float(key.z) * CHUNK_SIZE
		var nearest := Vector2(
			clampf(player.x, min_x, min_x + CHUNK_SIZE), clampf(player.y, min_z, min_z + CHUNK_SIZE)
		)
		if nearest.distance_to(player) <= ring:
			out[key] = true
	return out


# ---- chunk lifecycle --------------------------------------------------------------------------


# Build ONE chunk's pools under `parent` (the props layer). One call = one T-688 queue item, so a
# region swap never builds every chunk in a single frame. Idempotent (already-built keys no-op).
# `key` is Vector3i (flora) or Vector4i (hero pool) — .x/.y/.z mean the same in both.
func build_chunk(key: Variant, parent: Node3D) -> void:
	if _built.has(key):
		return
	var idxs: Array = _assign.get(key, [])
	if idxs.is_empty():
		return
	var origin := Vector3((float(key.y) + 0.5) * CHUNK_SIZE, 0.0, (float(key.z) + 0.5) * CHUNK_SIZE)
	var chunk := Node3D.new()
	var stem := "herochunk" if key is Vector4i else "chunk"
	chunk.name = "%s_%d_%d_%d" % [stem, key.x, key.y, key.z]
	chunk.position = origin
	parent.add_child(chunk)
	var by_scene: Dictionary = {}
	for i in idxs:
		var scene := str((_manifest[i] as Dictionary).get("scene", ""))
		if not by_scene.has(scene):
			by_scene[scene] = []
		(by_scene[scene] as Array).append(i)
	var body: StaticBody3D = null
	var total := 0
	for scene: String in by_scene:
		var rows: Array = by_scene[scene]
		body = _build_pool(chunk, origin, scene, rows, body)
		total += rows.size()
	_built[key] = {"node": chunk, "instances": total}


# Free ONE chunk (ring stream-out / region seam). Leak-safe: the chunk node owns every child.
func free_chunk(key: Variant) -> void:
	if not _built.has(key):
		return
	var node: Node3D = _built[key]["node"]
	if is_instance_valid(node):
		node.queue_free()
	_built.erase(key)


# Drop ALL chunk bookkeeping (region teardown / re-plan). free_nodes=false is the T-688 budgeted
# seam: the layer's _teardown_all has moved the chunk nodes into the reaper's dying container and
# frees them a few per frame — queue_freeing them here too would put the whole chunk set back into
# one seam frame. Callers that reset without a layer teardown keep the default (free everything
# now). The mesh library + overlay caches survive on purpose — they are region-independent and
# expensive to rebuild.
func reset(free_nodes: bool = true) -> void:
	if free_nodes:
		for key in _built:
			var node: Node3D = _built[key]["node"]
			if is_instance_valid(node):
				node.queue_free()
	_built.clear()


# ---- T-694: rigid-scene flatten (critters) ----------------------------------------------------


# Collapse a deep RIGID GLB scene in place: every MeshInstance3D under `root` is replaced by ONE
# merged MeshInstance3D child (same SurfaceTool material-content merge as the chunk mesh library,
# node transforms baked into vertices), so a 3,527-node rabbit becomes root + 1 node with
# byte-identical geometry/materials. Only valid for scenes that move as a unit (critter_wander
# ticks the root transform; the subtree is static) — scenes with engine attachments (an
# AnimationPlayer, lights, sockets, a door marker) are refused untouched (returns false), which
# keeps mob_sheep's animated rig on the old path. The merged mesh (+ its root-relative transform)
# is cached per `scene_path`, so all placed instances of a critter share one ArrayMesh.
func flatten_rigid(root: Node3D, scene_path: String) -> bool:
	var entry: Dictionary
	if _flat.has(scene_path):
		entry = _flat[scene_path]
	else:
		entry = {"ok": false, "mesh": null, "xform": Transform3D.IDENTITY}
		_flat[scene_path] = entry
		if not _has_engine_attachments(root):
			var parts: Array = []
			for child in root.find_children("*", "MeshInstance3D", true, false):
				if (child as MeshInstance3D).mesh != null:
					parts.append(child)
			if parts.size() == 1:
				var mi := parts[0] as MeshInstance3D
				entry["mesh"] = mi.mesh
				entry["xform"] = local_transform_to_ancestor(mi, root)
			elif parts.size() > 1:
				entry["mesh"] = _merge_parts(root, parts)
			entry["ok"] = entry["mesh"] != null
	if not bool(entry["ok"]):
		return false
	for c in root.get_children():
		root.remove_child(c)
		c.free()
	var merged := MeshInstance3D.new()
	merged.name = "merged"
	merged.mesh = entry["mesh"]
	merged.transform = entry["xform"]
	root.add_child(merged)
	return true


# ---- accessors (layer + tests) ----------------------------------------------------------------


func is_batched(manifest_index: int) -> bool:
	return _batched.has(manifest_index)


func is_built(key: Variant) -> bool:
	return _built.has(key)


func built_keys() -> Array:
	return _built.keys()


func assigned_keys() -> Array:
	return _assign.keys()


func batched_count() -> int:
	return _batched.size()


# Sum of resident MultiMesh instance counts — the placement-parity accessor: every batched
# placement of a resident chunk renders exactly once.
func instance_total() -> int:
	var total := 0
	for key in _built:
		total += int(_built[key]["instances"])
	return total


func chunk_instances(key: Variant) -> int:
	return int(_built.get(key, {}).get("instances", 0))


# Sum of resident instance counts in HERO pools only (Vector4i keys) — the tag-parity accessor:
# every batchable tag-promoted placement of the active region renders exactly once, always.
func hero_instance_total() -> int:
	var total := 0
	for key in _built:
		if key is Vector4i:
			total += int(_built[key]["instances"])
	return total


func hero_built_keys() -> Array:
	var out: Array = []
	for key in _built:
		if key is Vector4i:
			out.append(key)
	return out


# Decode instance `k`'s chunk-LOCAL transform from a pool's bulk buffer (see _build_pool for the
# layout). Works headlessly — the dummy renderer drops per-instance getter reads but round-trips
# the buffer property — so the transform-parity tests read the real uploaded data.
static func buffer_transform(mm: MultiMesh, k: int) -> Transform3D:
	var stride := 16 if mm.use_custom_data else 12
	var d := mm.buffer
	var o := k * stride
	var bx := Vector3(d[o + 0], d[o + 4], d[o + 8])
	var by := Vector3(d[o + 1], d[o + 5], d[o + 9])
	var bz := Vector3(d[o + 2], d[o + 6], d[o + 10])
	var org := Vector3(d[o + 3], d[o + 7], d[o + 11])
	return Transform3D(Basis(bx, by, bz), org)


# Decode instance `k`'s INSTANCE_CUSTOM data (x = ground_y) from a pool's bulk buffer.
static func buffer_custom(mm: MultiMesh, k: int) -> Color:
	if not mm.use_custom_data:
		return Color()
	var d := mm.buffer
	var o := k * 16 + 12
	return Color(d[o], d[o + 1], d[o + 2], d[o + 3])


# ---- internals --------------------------------------------------------------------------------


# One (scene x chunk) pool: a MultiMeshInstance3D for the visuals + collision-only shapes for the
# blocking instances. Returns the (possibly newly created) chunk collider body.
func _build_pool(
	chunk: Node3D, origin: Vector3, scene: String, rows: Array, body: StaticBody3D
) -> StaticBody3D:
	var lib: Dictionary = _lib[scene]
	# Largest-scale-first: the sorted prefix a future visible_instance_count density cut keeps.
	rows.sort_custom(
		func(a: int, b: int) -> bool:
			return (
				float((_manifest[a] as Dictionary).get("scale", 1.0))
				> float((_manifest[b] as Dictionary).get("scale", 1.0))
			)
	)
	var overlay: ShaderMaterial = _overlays.get(scene)
	var part_xf: Transform3D = lib["xform"]
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = overlay != null  # per-instance ground_y for the weathering overlay
	mm.mesh = lib["mesh"]
	mm.instance_count = rows.size()
	# Instance data goes through the BULK buffer (one RenderingServer upload, and — unlike the
	# per-instance setters — readable back headlessly, which the parity tests use). Layout per
	# instance: 12 floats = the 3x4 transform in ROWS of (basis.x[c], basis.y[c], basis.z[c],
	# origin[c]), then 4 floats INSTANCE_CUSTOM when use_custom_data (colors are never enabled).
	var stride := 16 if mm.use_custom_data else 12
	var data := PackedFloat32Array()
	data.resize(rows.size() * stride)
	for k in rows.size():
		var p: Dictionary = _manifest[rows[k]]
		var xf := placement_transform(p) * part_xf
		xf.origin -= origin  # instance transforms are chunk-local (chunk node sits at the centre)
		var o := k * stride
		for c in 3:
			data[o + c * 4 + 0] = xf.basis.x[c]
			data[o + c * 4 + 1] = xf.basis.y[c]
			data[o + c * 4 + 2] = xf.basis.z[c]
			data[o + c * 4 + 3] = xf.origin[c]
		if mm.use_custom_data:
			data[o + 12] = float(p.get("terrain_y", 0.0))  # ground_y for the weathering overlay
	mm.buffer = data
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	# Static dressing feeds the GI volumes (SDFGI) — same enforcement as the individual path.
	mmi.gi_mode = GeometryInstance3D.GI_MODE_STATIC
	if overlay != null:
		mmi.material_overlay = overlay
	# T-696: when a batched-tree impostor pool will carry the far band, the REAL mesh only draws to
	# the impostor swap distance (~90 m); otherwise it draws to its full class cull distance. Restores
	# the pre-T-693 individual-path read (near = full mesh, far = billboard).
	var imp: Dictionary = _impostor_spec(scene)
	var base := scene.get_file()
	var viz := (
		LodPolicy.impostor_distance(base, lod_mult)
		if bool(imp["ok"])
		else LodPolicy.cull_distance(base, lod_mult)
	)
	if viz > 0.0:
		mmi.visibility_range_end = viz + CHUNK_MARGIN
		mmi.visibility_range_end_margin = FADE_MARGIN
		mmi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	chunk.add_child(mmi)
	if bool(imp["ok"]):
		_add_impostor_pool(chunk, origin, scene, rows, imp)
	for k in rows.size():
		var p: Dictionary = _manifest[rows[k]]
		if not blocks(p, scene):
			continue
		if body == null:
			body = StaticBody3D.new()
			body.name = "chunk_colliders"
			chunk.add_child(body)
		var cs := CollisionShape3D.new()
		cs.shape = _shape_for(scene)
		var cxf := placement_transform(p) * part_xf
		cxf.origin -= origin
		cs.transform = cxf
		body.add_child(cs)
	return body


# T-696: the billboard-impostor spec for a batched scene, memoised in _impostor_lib. ok=false unless
# the class impostors (LodPolicy) AND a baked *_impostor.png exists AND the merged mesh has bounds.
# span/mid_y are the UNSCALED square-quad size + mid-height offset (in the prop's own frame); each
# instance's own uniform placement scale multiplies both via the transform (billboard_keep_scale
# reads it back). Mirrors world_props_layer._register_impostor's per-node sizing, batch-wide.
func _impostor_spec(scene: String) -> Dictionary:
	if not _impostor_lib.has(scene):
		_impostor_lib[scene] = _compute_impostor_spec(scene)
	return _impostor_lib[scene]


# T-696: the pure spec computation (memoised by _impostor_spec). Kept separate so the failure exits
# stay a handful of guards without tripping the caller's memo bookkeeping.
func _compute_impostor_spec(scene: String) -> Dictionary:
	var spec := {"ok": false}
	if LodPolicy.impostor_distance(scene.get_file()) <= 0.0:
		return spec
	var tex_path := LodPolicy.impostor_texture_path(scene)
	if tex_path == "" or not ResourceLoader.exists(tex_path):
		return spec
	var tex := load(tex_path) as Texture2D
	var lib: Dictionary = _lib.get(scene, {})
	var mesh: Mesh = lib.get("mesh")
	if tex == null or mesh == null:
		return spec
	# Merged-mesh bounds in the prop's placement frame (lib.xform = the part offset; IDENTITY for the
	# multi-part merges trees actually are) — the same union the individual path's _mesh_bounds_local
	# builds from the live nodes.
	var aabb := transform_aabb(mesh.get_aabb(), lib.get("xform", Transform3D.IDENTITY))
	if aabb.size == Vector3.ZERO:
		return spec
	spec["ok"] = true
	spec["tex"] = tex
	spec["span"] = maxf(aabb.size.x, maxf(aabb.size.y, aabb.size.z)) * IMPOSTOR_FRAME_MARGIN
	spec["mid_y"] = aabb.position.y + aabb.size.y * 0.5
	return spec


# T-696: one far billboard-quad MultiMesh for a (tree-scene x chunk) pool. A single shared QuadMesh
# (the impostor material's alpha-scissor billboard, same idiom as the individual path) instanced at
# every tree's placement, lifted to the tree's mid-height. Visible only in the [impostor_dist,
# tree_cull] band (chunk-origin measured, so padded by CHUNK_MARGIN like the real pool), fading at
# both ends — so it takes over exactly where the real-mesh pool culls out. NOT counted in the pool's
# instance total (that stays the real-placement parity number); it is pure LOD substitution.
func _add_impostor_pool(
	chunk: Node3D, origin: Vector3, scene: String, rows: Array, spec: Dictionary
) -> void:
	var span: float = spec["span"]
	var quad := QuadMesh.new()
	quad.size = Vector2(span, span)
	quad.material = make_impostor_material(spec["tex"] as Texture2D)
	var mid_y: float = spec["mid_y"]
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = quad
	mm.instance_count = rows.size()
	var data := PackedFloat32Array()
	data.resize(rows.size() * 12)
	for k in rows.size():
		var p: Dictionary = _manifest[rows[k]]
		var scl := float(p.get("scale", 1.0))
		# Identity basis scaled uniformly: the billboard shader overrides orientation, and
		# billboard_keep_scale reads the column length back to size the quad to this instance.
		var b := Basis.IDENTITY.scaled(Vector3.ONE * scl)
		var org := Vector3(
			float(p.get("x", 0.0)), float(p.get("terrain_y", 0.0)), float(p.get("y", 0.0))
		)
		org += Vector3(0.0, mid_y * scl, 0.0)  # centre the quad on the tree's mid-height
		org -= origin  # chunk-local
		var o := k * 12
		for c in 3:
			data[o + c * 4 + 0] = b.x[c]
			data[o + c * 4 + 1] = b.y[c]
			data[o + c * 4 + 2] = b.z[c]
			data[o + c * 4 + 3] = org[c]
	mm.buffer = data
	var mmi := MultiMeshInstance3D.new()
	mmi.name = "impostors"
	mmi.multimesh = mm
	mmi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED  # flat billboards never feed SDFGI
	var base := scene.get_file()
	mmi.visibility_range_begin = LodPolicy.impostor_distance(base, lod_mult) + CHUNK_MARGIN
	mmi.visibility_range_begin_margin = FADE_MARGIN
	mmi.visibility_range_end = LodPolicy.cull_distance(base, lod_mult) + CHUNK_MARGIN
	mmi.visibility_range_end_margin = FADE_MARGIN
	mmi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	chunk.add_child(mmi)


# T-696: the shared billboard-impostor material — SINGLE SOURCE for both the batched pool and the
# individual path (world_props_layer._register_impostor), so a distant tree reads the same whether
# it batched or not: an alpha-scissor Y-billboard quad, double-sided, keeping the instance scale.
static func make_impostor_material(tex: Texture2D) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = tex
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
	mat.alpha_scissor_threshold = 0.5
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_FIXED_Y  # spin around Y only (a standing tree)
	mat.billboard_keep_scale = true
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED  # visible from both faces
	return mat


# T-696: axis-aligned bounds of `a` after `t` (rotation included) — the 8-corner expand. Public
# (T-692 Part B): world_props_layer's bounds/interior-volume walks share this single copy now.
static func transform_aabb(a: AABB, t: Transform3D) -> AABB:
	var result := AABB(t * a.position, Vector3.ZERO)
	for i in range(8):
		var corner := (
			a.position
			+ Vector3(
				a.size.x if i & 1 else 0.0, a.size.y if i & 2 else 0.0, a.size.z if i & 4 else 0.0
			)
		)
		result = result.expand(t * corner)
	return result


# The scene's flattened Mesh (+ the transform that places it relative to the prop root), cached.
# ok=false marks a scene NOT batchable: engine attachments (lights, socket_* empties, an
# AnimationPlayer) or a door marker mean the individual _place path owns it, and a mesh-less scene
# has nothing to batch. Main-thread entry: computes via _extract_pure, persists any fresh merge to
# the user:// cache, and memoises in _lib. (warm_library runs the pure half on workers, then folds
# results into _lib on the main thread the same way — see below.)
func _extract(scene_path: String) -> Dictionary:
	if _lib.has(scene_path):
		return _lib[scene_path]
	var out := _extract_pure(scene_path)
	_persist_fresh_merge(out)
	_lib[scene_path] = out
	return out


# T-695: the PURE half of extraction — no _lib mutation, no ResourceSaver — so it is safe to run on
# a WorkerThreadPool worker (only mesh/data building + the internally-locked ResourceLoader).
# Returns the library entry PLUS two transient keys the main thread reads: "_fresh" (a fresh merge
# that should be persisted) and "_cache_path" (where). A warm-cache HIT skips load+instantiate+merge
# entirely: only multi-mesh merges are ever cached, and the mtime-keyed path means a cached mesh
# implies the scene passed the content gate when written, so ok=true / xform=IDENTITY hold.
func _extract_pure(scene_path: String) -> Dictionary:
	var out := {
		"ok": false,
		"mesh": null,
		"xform": Transform3D.IDENTITY,
		"tangentless": false,
		"shape": null,
		"_fresh": false,
		"_cache_path": _mesh_cache_path(scene_path),
	}
	var cache_path: String = out["_cache_path"]
	if _mesh_cache_enabled and cache_path != "" and ResourceLoader.exists(cache_path):
		var cached := ResourceLoader.load(cache_path) as ArrayMesh
		if cached != null:
			out["mesh"] = cached
			out["tangentless"] = _mesh_tangentless(cached)
			out["ok"] = true
			return out
	var packed := load(scene_path) as PackedScene
	if packed == null:
		return out
	var node := packed.instantiate()
	if not (node is Node3D):
		if node != null:
			node.free()
		return out
	var root := node as Node3D
	if _has_engine_attachments(root):
		root.free()
		return out
	var parts: Array = []
	var tangentless := false
	for child in root.find_children("*", "MeshInstance3D", true, false):
		var mi := child as MeshInstance3D
		if mi.mesh == null:
			continue
		parts.append(mi)
		if _mesh_tangentless(mi.mesh):
			tangentless = true
	if parts.is_empty():
		root.free()
		return out
	if parts.size() == 1:
		# Single-mesh GLB (rocks, firs, bushes): reference the imported mesh directly — zero copy,
		# the .glb's own Mesh resource stays shared. Its node-local transform bakes into instances.
		# Never cached: there is nothing to merge and the shared mesh is already on disk in the GLB.
		var mi := parts[0] as MeshInstance3D
		out["mesh"] = mi.mesh
		out["xform"] = local_transform_to_ancestor(mi, root)
	else:
		# Multi-mesh GLB (326-part brambles, 76-part oaks): merge into ONE ArrayMesh, one surface
		# per distinct material, node transforms baked into the vertices. Root-space, so IDENTITY.
		# This is the expensive path the user:// cache exists to skip on the next boot.
		out["mesh"] = _merge_parts(root, parts)
		out["_fresh"] = out["mesh"] != null
	out["tangentless"] = tangentless
	out["ok"] = out["mesh"] != null
	root.free()
	return out


# T-695: extract (cache-load or merge) every unique batchable scene AHEAD of plan assignment, so the
# cold-boot merges parallelise across WorkerThreadPool workers instead of blocking the login thread.
# SYNCHRONOUS + inline under headless (the dummy renderer aborts on threaded GLB work — the T-697
# hazard) or when threading is off; only the pure mesh/data build runs on a worker, and results are
# folded into _lib (+ persisted) on the MAIN thread after the join — no shared-state race.
# Idempotent: already-extracted scenes are skipped.
func warm_library(scene_paths: Array, threaded: bool) -> void:
	var todo: Array = []
	var seen := {}
	for s in scene_paths:
		var sp := str(s)
		if sp == "" or _lib.has(sp) or seen.has(sp):
			continue
		seen[sp] = true
		todo.append(sp)
	if todo.is_empty():
		return
	if not threaded or DisplayServer.get_name() == "headless":
		for sp in todo:
			_extract(sp)
		return
	var results: Array = []
	results.resize(todo.size())
	var worker := func(i: int) -> void:
		var entry := _extract_pure(todo[i])
		_warm_mutex.lock()
		results[i] = entry
		_warm_mutex.unlock()
	var group := WorkerThreadPool.add_group_task(worker, todo.size(), -1, false)
	WorkerThreadPool.wait_for_group_task_completion(group)
	for i in todo.size():
		var entry: Dictionary = results[i]
		_persist_fresh_merge(entry)
		_lib[todo[i]] = entry


# T-695: the user:// cache file for a scene's merged mesh, keyed on the GLB's on-disk mtime + a
# format version so any GLB edit (or a merge-format bump) invalidates the stale mesh. Empty string =
# uncacheable (non-res:// path or unstattable source) -> always re-extract.
func _mesh_cache_path(scene_path: String) -> String:
	if not scene_path.begins_with("res://"):
		return ""
	var mtime := FileAccess.get_modified_time(scene_path)
	if mtime == 0:
		return ""
	return (
		"%s%s_%d_v%d.res"
		% [MESH_CACHE_DIR, scene_path.get_file().get_basename(), mtime, MESH_CACHE_VERSION]
	)


# T-695 (MAIN THREAD ONLY): persist a freshly merged ArrayMesh so the next boot loads it instead of
# re-merging. ResourceSaver runs on the main thread by contract (workers only READ, via the
# internally-locked ResourceLoader). A save failure is non-fatal — the merge still works this boot.
func _persist_fresh_merge(entry: Dictionary) -> void:
	if not bool(entry.get("_fresh", false)) or not _mesh_cache_enabled:
		return
	var path := str(entry.get("_cache_path", ""))
	if path == "" or entry["mesh"] == null:
		return
	DirAccess.make_dir_recursive_absolute(MESH_CACHE_DIR)
	ResourceSaver.save(entry["mesh"] as ArrayMesh, path)


# The shared "not rigid decor" content gate: engine attachments (lights, socket_* empties, an
# AnimationPlayer) or a door marker mean world_props_layer bolts behavior onto the subtree — such
# a scene may neither batch (_extract) nor flatten (flatten_rigid).
static func _has_engine_attachments(root: Node3D) -> bool:
	return (
		not root.find_children("*", "Light3D", true, false).is_empty()
		or not root.find_children("socket_*", "Node3D", true, false).is_empty()
		or not root.find_children("*", "AnimationPlayer", true, false).is_empty()
		or root.find_child("door", true, false) != null
	)


# Merge every MeshInstance3D of a GLB into one ArrayMesh, grouping surfaces by material CONTENT
# (their ACTIVE material: override > surface override > mesh surface). Content, not object
# identity: generator GLBs ship visually identical materials under unique names (the bramble's 95
# one-off thorn materials), and grouping by object would re-split the merge into ~97 draws. Two
# materials merge only when every stored property matches (_materials_match), so the merged look
# is exactly the per-node look.
func _merge_parts(root: Node3D, parts: Array) -> ArrayMesh:
	var reps: Array = []  # group representative materials, index = group id (deterministic order)
	var rep_hashes: Array = []  # T-695: parallel content hashes — the cheap reject before the walk
	var groups: Array = []  # SurfaceTool per group
	for part in parts:
		var mi := part as MeshInstance3D
		var rel := local_transform_to_ancestor(mi, root)
		for s in mi.mesh.get_surface_count():
			if (
				mi.mesh is ArrayMesh
				and (mi.mesh as ArrayMesh).surface_get_primitive_type(s) != Mesh.PRIMITIVE_TRIANGLES
			):
				continue  # SurfaceTool merge is triangles-only; GLB imports always are
			var mat := mi.get_active_material(s)
			# T-695: hash the material's content ONCE, then reject non-matches with an int compare
			# instead of the full get_property_list() walk _materials_match does. The exact walk
			# still confirms every hash HIT, so grouping stays byte-identical to the pre-T-695 merge
			# (a hash collision can't wrongly merge; a hash miss can't wrongly split) — only faster:
			# the bramble's 95 one-off materials went from O(reps) property walks per part to O(reps)
			# int compares + one hash build.
			var mh := _material_hash(mat)
			var gid := -1
			for r in reps.size():
				if rep_hashes[r] == mh and _materials_match(reps[r], mat):
					gid = r
					break
			if gid == -1:
				reps.append(mat)
				rep_hashes.append(mh)
				var st := SurfaceTool.new()
				st.begin(Mesh.PRIMITIVE_TRIANGLES)
				groups.append(st)
				gid = reps.size() - 1
			(groups[gid] as SurfaceTool).append_from(mi.mesh, s, rel)
	if reps.is_empty():
		return null
	var merged := ArrayMesh.new()
	for r in reps.size():
		var st := groups[r] as SurfaceTool
		if reps[r] != null:
			st.set_material(reps[r])
		st.commit(merged)
	return _with_generated_lods(merged)


# T-696: give a runtime-built merged ArrayMesh the auto-LODs an import-time mesh gets for free.
# SurfaceTool.commit() produces only LOD0, so a merged bramble/oak drew FULL triangles to its whole
# 320 m range (the T-693 regression). Route every triangle surface through ImporterMesh (its
# generate_lods runs meshoptimizer identically to the GLB importer), then get_mesh() folds the
# generated LOD index arrays back into ONE ArrayMesh. LOD0 stays byte-identical (near = unchanged),
# and the LODs serialize with the ArrayMesh, so the user:// merge cache carries them across boots
# (why MESH_CACHE_VERSION bumped). Verified headless: RenderingServer.mesh_get_surface(rid,s).lods
# is non-empty on the real merges and survives ResourceSaver round-trip. Non-triangle/empty surfaces
# (none in GLB imports) or a null get_mesh fall back to the un-LODded merge — never worse than now.
func _with_generated_lods(mesh: ArrayMesh) -> ArrayMesh:
	if mesh == null:
		return mesh
	var im := ImporterMesh.new()
	for s in mesh.get_surface_count():
		if mesh.surface_get_primitive_type(s) != Mesh.PRIMITIVE_TRIANGLES:
			continue
		im.add_surface(
			Mesh.PRIMITIVE_TRIANGLES,
			mesh.surface_get_arrays(s),
			[],
			{},
			mesh.surface_get_material(s),
			mesh.surface_get_name(s),
			mesh.surface_get_format(s)
		)
	if im.get_surface_count() == 0:
		return mesh
	im.generate_lods(LOD_NORMAL_MERGE_ANGLE, LOD_NORMAL_SPLIT_ANGLE, [])
	var out := im.get_mesh()
	return out if out != null else mesh


# T-696 (tests): total generated LOD count across a mesh's surfaces, read from the live renderer
# resource (there is no GDScript ArrayMesh LOD getter). > 0 proves the merge carries auto-LODs.
static func surface_lod_total(mesh: Mesh) -> int:
	if mesh == null:
		return 0
	var total := 0
	for s in mesh.get_surface_count():
		var info: Dictionary = RenderingServer.mesh_get_surface(mesh.get_rid(), s)
		var lods: Variant = info.get("lods", null)
		if lods is Array:
			total += (lods as Array).size()
		elif lods is Dictionary:
			total += (lods as Dictionary).size()
	return total


# Do two materials render identically? Same class + every STORAGE property equal (textures compare
# by identity; resource_* metadata like the name/path is ignored — it's exactly what generator
# GLBs vary while the look stays the same).
static func _materials_match(a: Material, b: Material) -> bool:
	if a == b:
		return true
	if a == null or b == null:
		return false
	if a.get_class() != b.get_class():
		return false
	for prop in a.get_property_list():
		if not (int(prop["usage"]) & PROPERTY_USAGE_STORAGE):
			continue
		var pname := str(prop["name"])
		if pname.begins_with("resource_"):
			continue
		if a.get(pname) != b.get(pname):
			return false
	return true


# T-695: a content hash over the SAME storage properties _materials_match compares (class + every
# non-resource_* storage property; textures fold in by instance identity, exactly as the equality
# check treats them). Materials that render identically hash identically; the merge grouping loop
# uses it as a cheap reject so the O(reps x props) per-candidate scan becomes O(reps) int compares.
static func _material_hash(mat: Material) -> int:
	if mat == null:
		return 0
	var acc := hash(mat.get_class())
	for prop in mat.get_property_list():
		if not (int(prop["usage"]) & PROPERTY_USAGE_STORAGE):
			continue
		var pname := str(prop["name"])
		if pname.begins_with("resource_"):
			continue
		acc = hash([acc, pname, mat.get(pname)])
	return acc


# T-290/T-312: a tangent-less surface (leaf-card GLBs under the 3MB cap) would trip Godot's
# per-frame tangent warning under the overlay — the same honest skip as the individual path.
static func _mesh_tangentless(mesh: Mesh) -> bool:
	for s in mesh.get_surface_count():
		var arrays: Array = mesh.surface_get_arrays(s)
		if arrays.size() > Mesh.ARRAY_TANGENT and arrays[Mesh.ARRAY_TANGENT] == null:
			return true
	return false


# ONE shared weathering overlay material per batched scene (never per instance/chunk — per-prop
# materials are exactly what re-breaks batching). No-op for clean classes and tangent-less meshes.
func _ensure_overlay(scene_path: String, cfg: Dictionary, lib: Dictionary) -> void:
	if cfg.is_empty() or bool(lib["tangentless"]) or _overlays.has(scene_path):
		return
	var mat := ShaderMaterial.new()
	mat.shader = INSTANCED_WEATHER_SHADER
	mat.set_shader_parameter("moss_amount", float(cfg["amount"]))
	mat.set_shader_parameter("roof_weight", float(cfg["roof"]))
	mat.set_shader_parameter("climb_h", float(cfg["climb"]))
	_overlays[scene_path] = mat


# The shared per-scene trimesh collision shape (lazy — built on the first blocking instance).
func _shape_for(scene: String) -> Shape3D:
	var lib: Dictionary = _lib[scene]
	if lib["shape"] == null:
		lib["shape"] = (lib["mesh"] as Mesh).create_trimesh_shape()
	return lib["shape"]
