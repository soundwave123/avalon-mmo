class_name WorldPropsLayer
# T-081: data-driven world dressing — places generated/vendored GLB scenes (houses, trees,
# clutter) from assets/props.json. Coordinates use server ground coords (x, y) -> Godot
# (x, 0, y), same mapping as entities. Purely cosmetic (no collision yet — T-079 phase 2).
#
# props.json shape: {"props": [{"scene": "res://assets/models/prop_pine.glb",
#                               "x": 26.0, "y": 27.0, "rot_deg": 40, "scale": 1.1}, ...]}

extends Node3D

# T-691: fired once, when the FIRST populate finishes (inline) or its queue first drains (queued)
# — the loading screen's dismiss gate, so the player never spawns into a half-dressed world.
signal initial_populate_done

const _CW = preload("res://scripts/world/critter_wander.gd")
const EntityVisuals = preload("res://scripts/world/entity_visuals.gd")
const InteriorZones = preload("res://scripts/world/interior_zones.gd")
# T-120: distance-LOD + impostor swap policy (cull ranges, impostor thresholds, hysteresis).
const LodPolicy = preload("res://scripts/world/lod_policy.gd")
# T-594: prop-streaming policy (region residency + per-class draw ring). Pure decision maker;
# THIS layer owns the node lifecycle (place/teardown/unload) it plans.
const PropStreamer = preload("res://scripts/world/prop_streamer.gd")
# T-693: chunked-MultiMesh batching for the repeated flora/decorative carpet — mesh library,
# (scene x 64 m chunk) pools, collision-only bodies, shared instanced weathering. Batched
# placements never take the individual _place path; chunk builds/frees ride THIS layer's region +
# ring streaming and the T-688 load queue (one chunk build = one queue item).
const PropChunks = preload("res://scripts/world/prop_chunks.gd")
# T-594: region-origin mirror (nearest-origin membership for the streamer). Shared client/server.
const TerrainField = preload("res://scripts/world/terrain_field.gd")
# T-120: render-stats formatter for the qa-tour FPS-budget hook (draw calls / primitives / impostor
# split). Env-gated so it costs nothing in normal play.
const RenderStats = preload("res://scripts/world/render_stats.gd")
# T-290: sun-keyed weathering (moss/lichen/damp-stain) applied as a per-prop material_overlay pass.
const PropWeathering = preload("res://scripts/world/prop_weathering.gd")
# T-688 H2: budgeted region teardown — the free-side mirror of LOAD_BUDGET_PER_FRAME below. The
# outgoing region moves into a hidden dying container at the seam and frees a few roots per frame.
const PropReaper = preload("res://scripts/world/prop_reaper.gd")
# T-688 H4: in-flight cap for the threaded GLB preload (fires on every LIVE boot since T-691).
const PreloadThrottle = preload("res://scripts/world/preload_throttle.gd")
# T-691: login-phase bus — the initial populate is the biggest phase of the loading screen's bar,
# and the T-688 queue gives it REAL per-item progress (placed vs queued).
const LoadPhases = preload("res://scripts/ui/load_phases.gd")

# T-187: buildings whose generator predates the socket_chimney convention (T-209) — a plain child
# node name instead of a socket_chimney empty. Headlessly verified against the committed GLBs
# (prop_farmhouse.glb has a "chimney" node, no socket); documented here rather than silently
# dropping their smoke. Buildings with neither a socket nor a legacy node (house_b/inn/smithy
# among the checked set) genuinely have no chimney marker to hook — no fallback fabricates one.
const _CHIMNEY_FALLBACK := {
	"prop_farmhouse.glb": "chimney",
}

# T-298: outdoor street lighting. These props carry only emissive glass/coals in the GLB; the
# engine attaches a warm OmniLight (local offset = the lantern/fire-bowl height) that joins the
# "night_lights" group. WorldView's day/night tick fades their energy in as the sun drops, so the
# capital glows at dusk/night without burning in daylight. (Interior hearth/candle sockets stay
# always-on — those are a separate path above, since interiors are dark at all hours.)
const _NIGHT_LIGHTS := {
	"prop_lamppost_v2.glb":
	{"pos": Vector3(0.45, 2.5, 0.0), "color": Color(1.0, 0.72, 0.34), "energy": 3.2, "range": 9.0},
	"prop_brazier.glb":
	{"pos": Vector3(0.0, 0.9, 0.0), "color": Color(1.0, 0.5, 0.2), "energy": 4.0, "range": 8.0},
}

# T-310: species behaviour table for ambient wildlife (livestock + small critters). Radii are
# metres from each animal's PLACED position (its "home") — small on purpose: the farmstead pen
# (T-313) and dooryards are tight, and a bounds-clamp on the home point is the honest fallback for
# "stay inside the fence" with no polygon fence geometry to test against (see critter_wander.gd).
const _CRITTER_CFG := {
	"mob_sheep.glb":
	{
		"comfort_radius": 4.0,
		"max_radius": 3.0,
		"wander_radius": 1.6,
		"speed": 0.35,
		"flee_speed": 1.9,
		"flee_dist": 2.6,
	},
	"critter_cow.glb":
	{
		"comfort_radius": 4.5,
		"max_radius": 3.5,
		"wander_radius": 1.3,
		"speed": 0.3,
		"flee_speed": 1.6,
		"flee_dist": 2.4,
	},
	"critter_pig.glb":
	{
		"comfort_radius": 4.0,
		"max_radius": 3.0,
		"wander_radius": 1.4,
		"speed": 0.35,
		"flee_speed": 1.8,
		"flee_dist": 2.4,
	},
	"critter_chicken.glb":
	{
		"comfort_radius": 3.0,
		"max_radius": 2.5,
		"wander_radius": 1.0,
		"speed": 0.45,
		"flee_speed": 2.4,
		"flee_dist": 2.0,
	},
	"critter_rabbit.glb":
	{
		"comfort_radius": 5.0,
		"max_radius": 3.5,
		"wander_radius": 1.5,
		"speed": 0.4,
		"flee_speed": 3.0,
		"flee_dist": 3.2,
	},
}
const _CRITTER_TICK_HZ := 10.0  # T-210: grazing math doesn't need per-frame precision
const _IMPOSTOR_TICK_HZ := 5.0  # T-120/T-210: LOD swaps don't need per-frame precision
const _STREAM_TICK_HZ := 4.0  # T-594: streaming re-evaluation rate (chunky rings; not per-frame)
# T-688: max props INSTANTIATED per frame. The region-change swap (a rift crossing into Ashmoor)
# would otherwise `_place` the whole ~148-prop dressing set — 9 ~2MB building GLBs + boulders +
# trees, each with a GLB decode + mesh/texture GPU upload + trimesh-collision bake — in ONE frame.
# That single-frame upload burst is exactly what SIGSEGV'd the client mid-BLIT on the fragile
# NVIDIA 595.84 driver (Portal Bug #102). Draining a small budget per frame spreads the upload
# across ~0.8 s (a rift crossing is already a loading moment), so the GPU never sees the spike.
const LOAD_BUDGET_PER_FRAME := 3
# T-696: single-sourced with the batched path (must match bake_impostor.py's square ortho padding).
const _IMPOSTOR_FRAME_MARGIN := PropChunks.IMPOSTOR_FRAME_MARGIN

var prop_count: int = 0  # headless-test accessor
var critter_count: int = 0  # T-310 headless-test accessor
# T-187: interior volumes for every ENTERABLE placed building — derived from placement (position/
# rotation/scale, already known from props.json) + the instanced GLB's own mesh bounds, so no
# building layout change ever needs a hand-typed interior box. See interior_zones.gd for the
# oriented-box shape and InteriorZones.resolve_indoors() for the door-threshold hysteresis.
var interior_volumes: Array = []  # [{id, center, half_extents, height, rot_y}] — test accessor
var _critters: Array = []  # [{node, home, cfg, state, has_anim, anim_state}]
var _critter_tick_accum: float = 0.0
# T-120: props that own a baked billboard impostor. Each entry {mesh, impostor, imp_dist, active};
# the throttled _tick_impostors swap toggles `visible` on mesh vs impostor by camera distance with
# LodPolicy hysteresis. Empty until a prop_*_impostor.glb exists on disk (graceful no-op otherwise).
var _impostors: Array = []
var _impostor_tick_accum: float = 0.0
# T-120: AVALON_LOD_STATS=1 makes the layer print a periodic [lod] line the orchestrator greps out
# of the qa-tour client log — the cheap FPS-budget instrumentation (T-210). Off by default.
var _lod_stats := false
var _stats_accum := 0.0
var _rng := RandomNumberGenerator.new()  # T-310: graze-target/pause picks; seeded per-session
# T-594: streaming state. _manifest = raw props.json rows; _meta = per-prop {i, ground, tier,
# region, streamable}; _placed = manifest_index -> the resident root Node3D. _active_region is the
# terrain region whose dressing is loaded (-999 = none yet, so the first stream never tears
# down). Region changes tear the whole set down + rebuild (leak-safe, no per-building bookkeeping);
# within a region only FLORA streams by distance ring.
var _manifest: Array = []
var _meta: Array = []  # only well-formed props (carries "i" = manifest index)
var _meta_stream: Array = []  # T-693: the individually streamed subset of _meta (batched excluded)
var _meta_of: Dictionary = {}  # manifest_index -> meta (for the unload streamable check)
var _origins: Array = []  # region origins (Vector2), from terrain_field.region_origins()
var _placed: Dictionary = {}  # manifest_index -> root Node3D
var _cfg: Dictionary = {}  # ring overrides (empty = PropStreamer defaults)
var _active_region: int = -999
var _streaming: bool = false
var _stream_accum: float = 0.0
# T-688: manifest indices awaiting placement. stream_to enqueues the resident-but-not-yet-placed
# set here rather than instantiating it inline; _drain_load_queue places LOAD_BUDGET_PER_FRAME of
# them each frame, so a region swap never uploads the whole new region to the GPU in one frame.
var _load_queue: Array = []  # T-693: int = individual manifest index, Vector3i = chunk build
# T-693: chunked-MultiMesh batching of the repeated dressing. AVALON_PROP_BATCHING=0 is the
# diagnostic escape hatch (everything reverts to the per-node _place path) mirroring the
# AVALON_PROP_STREAMING kill-switch. Read at construction so tests that inject a manifest before
# entering the tree still plan under the right mode.
var _batching := OS.get_environment("AVALON_PROP_BATCHING") != "0"
# T-694: critter-flatten kill-switch (diagnostic A/B lever, mirrors AVALON_PROP_BATCHING). On by
# default; =0 restores the raw deep-GLB critter scenes for a before/after node-count measurement.
var _flatten := OS.get_environment("AVALON_CRITTER_FLATTEN") != "0"
# T-695: master kill-switch for the login load-order optimisations — threaded/cached mesh extraction
# (prop_chunks), threaded GLB preload, and the queued first populate below. AVALON_THREADED_LOAD=0
# restores the pre-T-695 synchronous path. Read at construction, mirroring _batching/_flatten.
var _threaded_load := OS.get_environment("AVALON_THREADED_LOAD") == "1"
# T-695: whether the FIRST populate defers into the T-688 frame budget (live, behind the T-691
# loading screen — login spreads over frames instead of one synchronous burst) or places inline.
# Set in _ready: inline under headless / the kill-switch so the T-693 suite stays deterministic
# and never hits the dummy-renderer threaded-load hazard. Tests may force it on to drive the path.
var _queue_initial := false
var _initial_pending := false  # T-691: a queued FIRST populate is still draining
var _initial_total := 0  # T-691: items that first populate queued (the progress denominator)
# T-702: scene_path -> PackedScene, held for the life of the resident region. Godot frees a resource
# the instant its refcount hits zero, and `_place` used a LOCAL `load()` per prop — so the SAME GLB
# was fully re-decoded once per placed instance (hundreds of times across a login), and again by
# warm_library, and again per impostor. Measured headless over the 187-scene manifest: 4,665 ms to
# load them all, repeatable to the millisecond on the 2nd and 3rd pass (no retention) vs 0.3 ms with
# references held. Pinning is what makes the ResourceLoader cache actually cache. Cleared on the
# region seam (_teardown_all) so a crossing drops the old region's GLBs instead of growing forever.
var _scene_pin: Dictionary = {}
# T-702: scene_path -> true for every path _preload_scenes fired a load_threaded_request for. The
# preload was fire-and-forget: it never called load_threaded_get, and since Godot frees a resource
# the moment its refcount hits zero, the background decode was thrown away and then re-done
# synchronously on first sight. Collecting via load_threaded_get returns instantly if the background
# load finished (and blocks only if it is still in flight — still cheaper than a fresh decode).
var _requested: Dictionary = {}
var _chunks = PropChunks.new()
var _reaper = PropReaper.new()
var _preload_throttle = PreloadThrottle.new()


func _ready() -> void:
	_lod_stats = OS.get_environment("AVALON_LOD_STATS") == "1"  # T-120: qa-tour FPS-budget hook
	_rng.randomize()  # T-310: organic graze timing/spread — not server truth, doesn't need a seed
	if _manifest.is_empty():  # T-594: a test may inject a manifest via load_manifest() before _ready
		var file := FileAccess.open("res://assets/props.json", FileAccess.READ)
		if file == null:
			return
		var data = JSON.parse_string(file.get_as_text())
		file.close()
		if not (data is Dictionary):
			push_warning("[props] assets/props.json is malformed")
			return
		load_manifest(data.get("props", []))
	# T-594: stream the player's starting region only; the _process tick swaps regions + carpets flora
	# as the player moves. AVALON_PROP_STREAMING=0 restores the pre-T-594 place-everything boot.
	_streaming = OS.get_environment("AVALON_PROP_STREAMING") != "0"
	# T-695/T-691: behind the loading screen, spread the first populate over frames via the T-688
	# queue instead of the one-frame inline burst, and warm the ResourceLoader cache for every unique
	# GLB so first-sight load()s aren't synchronous hitches. T-691 DECOUPLED both from
	# _threaded_load: the queue + the engine's threaded ResourceLoader are exactly the asynchrony
	# T-702 §5 endorses (the live deadlock lived in the WorkerThreadPool merge path, which stays
	# opt-in behind AVALON_THREADED_LOAD). HEADLESS keeps the inline path (the T-693 suite runs
	# headless — deterministic, and threaded GLB loads corrupt the dummy renderer, the T-697
	# hazard), so the batching/streaming behaviour is byte-unchanged there.
	var live := DisplayServer.get_name() != "headless"
	_queue_initial = live
	if live:
		_preload_scenes()
	if _streaming:
		stream_to(_player_ground())
	else:
		# T-594 place-everything boot; T-693 batched placements build as chunk pools instead.
		LoadPhases.begin("populate")  # T-691: one inline populate — mark it so the gate can end
		for i in _manifest.size():
			if not _chunks.is_batched(i):
				_place(_manifest[i], i)
		for key in _chunks.assigned_keys():
			_chunks.build_chunk(key, self)
		_finish_initial_populate()
	print(
		(
			"[client] world props placed: %d + %d batched in %d chunks (streaming=%s batching=%s)"
			% [
				prop_count,
				_chunks.instance_total(),
				_chunks.built_keys().size(),
				str(_streaming),
				str(_batching)
			]
		)
	)


# T-594: build the streaming manifest + per-prop metadata (tier/region/streamable) from props.json
# rows. Public so a headless test can inject a small synthetic manifest before the layer enters the
# tree (then _ready skips the real props.json). Malformed rows are dropped from _meta but keep their
# manifest slot so indices stay stable.
func load_manifest(props: Array) -> void:
	_manifest = props
	_meta = []
	_meta_of = {}
	if _origins.is_empty():
		_origins = TerrainField.new().region_origins()
	# T-693: bases the layer bolts satellite state onto by name — never batchable (name-level gate;
	# the GLB content gate lives in prop_chunks._extract).
	var special := {}
	for b in _CRITTER_CFG:
		special[b] = true
	for b in _NIGHT_LIGHTS:
		special[b] = true
	for b in _CHIMNEY_FALLBACK:
		special[b] = true
	for i in props.size():
		var p = props[i]
		if not (p is Dictionary):
			continue
		var base := str(p.get("scene", "")).get_file()
		var tag := str(p.get("tag", ""))
		var tier := PropStreamer.classify(base, tag)
		# T-692 Part B: preset flora-density thinning. Dropped placements never enter _meta, so
		# they exit BOTH the batch plan and the individual stream path. Pure + deterministic.
		if PropStreamer.density_drops(tier, base, i, _cfg, special):
			continue
		var ground := Vector2(float(p.get("x", 0.0)), float(p.get("y", 0.0)))
		var streamable := (
			tier == PropStreamer.TIER_FLORA and PropStreamer.flora_streamable(base, _CRITTER_CFG)
		)
		var meta := {
			"i": i,
			"ground": ground,
			"tier": tier,
			"region": PropStreamer.region_of(ground, _origins),
			"streamable": streamable,
			"batch_stem": _batching and PropStreamer.batchable_stem(base, tag, special),
			# T-693 residual #2: tag-promoted hero placements whose scene is plain flora render
			# via always-resident hero chunk pools (residency semantics preserved; see streamer).
			"hero_stem": _batching and PropStreamer.hero_batchable_stem(base, tag, special),
		}
		_meta.append(meta)
		_meta_of[i] = meta
	# T-693: plan the batched set + chunk assignments; batched placements leave the individual
	# streaming pool (_meta_stream) — they render via chunk pools instead.
	if _batching:
		var weather := {}
		var batch_scenes: Array = []  # T-695: unique batchable scenes to warm (cache/thread) up front
		for m in _meta:
			if bool(m["batch_stem"]) or bool(m["hero_stem"]):
				var scene := str((props[int(m["i"])] as Dictionary).get("scene", ""))
				var b := scene.get_file()
				if not weather.has(b):
					weather[b] = PropWeathering.weathering_for(b)
				batch_scenes.append(scene)
		# T-695: extract every batchable mesh via the user:// merge cache (and, live, across worker
		# threads) BEFORE plan assignment — this is where the ~3.4s of login merges lived. plan_manifest
		# then re-hits _lib for free. T-702: the cache is NOT gated here any more — it owns
		# AVALON_MESH_CACHE (default ON) so the threading kill-switch can't take the cache down with it.
		# T-702: pin the batchables BEFORE warming. warm_library's _extract_pure does its own
		# `load()`, drops the PackedScene on return, and `_place`/impostors then re-decode the same
		# GLB from scratch. Pinning first means every one of those later loads is a cache hit.
		# Threaded warm skips it — the pin is a main-thread structure and the worker path owns its
		# own loads (ResourceLoader is internally locked; the pin Dictionary is not).
		if not _threaded_load:
			for s in batch_scenes:
				pinned_scene(str(s))
		_chunks.warm_library(batch_scenes, _threaded_load)
		_chunks.plan_manifest(_manifest, _meta, weather)
	_meta_stream = []
	for m in _meta:
		if not _chunks.is_batched(int(m["i"])):
			_meta_stream.append(m)


# T-695: warm the ResourceLoader cache for every unique GLB the manifest places (~187 live) with
# threaded background requests, so a first-sight load() (individual _place, chunk build, or
# impostor) hits an already-decoded resource instead of a synchronous main-thread decode hitch under
# the loading screen. A later load() blocks only if the request is still in flight.
# HEADLESS-GUARDED at the call site (threaded GLB loads corrupt the dummy renderer — T-697 hazard).
func _preload_scenes() -> void:
	var seen := {}
	for p in _manifest:
		if not (p is Dictionary):
			continue
		var sp := str(p.get("scene", ""))
		if sp == "" or seen.has(sp):
			continue
		seen[sp] = true
		if ResourceLoader.exists(sp):
			# T-688 H4: queued, not fired — the throttle keeps ≤ MAX_IN_FLIGHT requests
			# outstanding (187-at-once is the godot#111202 crash shape) and refills per frame.
			_preload_throttle.queue(sp)
	_pump_preload()


# T-688 H4: fire more preload requests only as earlier ones finish. Backlog paths the pin already
# loaded synchronously are dropped; fired paths are marked collectable (_requested) so
# pinned_scene() reuses the background decode instead of re-decoding.
func _pump_preload() -> void:
	for sp in _preload_throttle.pump(_scene_pin):
		_requested[sp] = true


# T-594: override the ring radii ({flora_ring, building_ring}) — the test seam + P2 per-zone tuning
# hook. Empty restores PropStreamer defaults. T-692 Part B: the same dict carries the preset knobs
# (flora_density, lod_mult); the chunk pools read the mult at build time, so it syncs here.
func set_stream_cfg(cfg: Dictionary) -> void:
	_cfg = cfg
	_chunks.lod_mult = PropStreamer.lod_mult(cfg)


# T-692 Part B: live preset re-apply — store the new cfg, rebuild the manifest metadata (the
# density filter runs at meta build), tear the resident set down whole (the leak-safe region-seam
# path) and repopulate through the T-688 budgeted queue, so a preset change mid-session never
# rebuilds the world in a one-frame burst.
func apply_quality_cfg(cfg: Dictionary) -> void:
	set_stream_cfg(cfg)
	if _manifest.is_empty():
		return
	load_manifest(_manifest)
	_teardown_all()
	_active_region = -999
	var was_queued := _queue_initial
	_queue_initial = true
	stream_to(_player_ground())
	_queue_initial = was_queued


# T-594: run ONE streaming pass for a player at `player_ground` (server x,y plane). Region change ->
# full teardown + rebuild of the new region; within a region -> load missing in-ring prop, unload
# any streamable (flora) prop that left its ring. Deterministic: the resident set is a pure function
# of `player_ground`.
func stream_to(player_ground: Vector2) -> void:
	if _meta.is_empty():
		if _active_region == -999:
			_finish_initial_populate()  # T-691: nothing to place — never wedge the loading gate
		return
	var region := PropStreamer.region_of(player_ground, _origins)
	var initial := _active_region == -999  # very first populate (login / first spawn)
	if initial:
		LoadPhases.begin("populate")  # T-691 (bus-deduped; a preset re-apply is not a login)
	if region != _active_region and not initial:
		_teardown_all()  # crossed a region seam — swap the whole dressing set (leak-safe)
	_active_region = region
	var target: Dictionary = PropStreamer.resident_target(_meta_stream, player_ground, region, _cfg)
	# T-688: (target - placed) is what still needs loading. On the FIRST populate we place it inline
	# (login already tolerates that burst and a deferred boot would pop props in for seconds); on a
	# REGION CHANGE (a rift crossing into Ashmoor) or ongoing stream we enqueue it and let
	# _drain_load_queue place LOAD_BUDGET_PER_FRAME per frame — spreading the ~148-prop Ashmoor
	# upload across frames instead of spiking the GPU in one, which is what SIGSEGV'd the 595.84
	# driver mid-BLIT (Bug #102). The queue is rebuilt each pass, so an already-resident or now-out-
	# of-ring prop drops out; a queued prop from a region we just left was cleared in teardown.
	# T-695: the first populate places inline UNLESS _queue_initial (live behind the loading screen),
	# in which case it rides the same T-688 budget as a region change — login spreads over frames.
	var inline_initial := initial and not _queue_initial
	_load_queue.clear()
	for i in target:
		if not _placed.has(i):
			if inline_initial:
				_place(_manifest[i], i)
			else:
				_load_queue.append(i)
	var to_unload: Array = []
	for i in _placed:
		if not target.has(i) and bool(_meta_of.get(i, {}).get("streamable", false)):
			to_unload.append(i)
	for i in to_unload:
		_unload(i)
	# T-693: chunk residency rides the same pass — a chunk is wanted iff its ground rect touches
	# the flora ring (pure function of player_ground, so the border-walk determinism holds). Builds
	# go inline on the first populate (login tolerates the burst, same as individual props) and
	# through the T-688 budgeted queue otherwise (ONE chunk build per queue item); chunks that left
	# the ring free whole. The region seam was already handled by _teardown_all + _chunks.reset().
	if _batching:
		var ring: float = PropStreamer.ring_for(PropStreamer.TIER_FLORA, _cfg)
		var want: Dictionary = _chunks.target_chunks(player_ground, region, ring)
		for key in want:
			if not _chunks.is_built(key):
				if inline_initial:
					_chunks.build_chunk(key, self)
				else:
					_load_queue.append(key)
		for key in _chunks.built_keys():
			if not want.has(key):
				_chunks.free_chunk(key)
	# T-691: initial-populate bookkeeping. Inline (headless) finishes right here; a queued first
	# populate finishes when the T-688 queue first drains (see _drain_load_queue). A later stream
	# pass rebuilding the queue while the drain is pending keeps the larger denominator so the
	# bar's per-item progress never lurches.
	if initial or _initial_pending:
		if _load_queue.is_empty():
			_finish_initial_populate()
		else:
			_initial_pending = true
			_initial_total = maxi(_initial_total, _load_queue.size())


# T-594: the player's ground position (server x,y) from the LocalPlayer sibling, or ZERO (headless /
# pre-spawn) — which resolves to the Wold origin region, the correct default start zone.
func _player_ground() -> Vector2:
	var world := get_parent()
	if world != null:
		var player := world.get_node_or_null("LocalPlayer") as Node3D
		if player != null:
			return Vector2(player.global_position.x, player.global_position.z)
	return Vector2.ZERO


# T-594: individual unload of a STREAMABLE (flora) prop — frees its root + any impostor satellite,
# drops all tracking, so nothing leaks. Only ever called on flora (buildings/hero ride the region
# teardown), so there is no interior-volume / critter bookkeeping to unwind here.
func _unload(idx: int) -> void:
	var node = _placed.get(idx)
	if node == null:
		return
	for j in range(_impostors.size() - 1, -1, -1):
		if _impostors[j]["mesh"] == node:
			var imp = _impostors[j]["impostor"]
			if is_instance_valid(imp):
				imp.queue_free()
			_impostors.remove_at(j)
	if is_instance_valid(node):
		node.queue_free()
	_placed.erase(idx)
	prop_count -= 1


# T-594: retire EVERY placed prop + satellite and reset all tracking — the region-change swap.
# Retiring all children (not just tracked roots) is the bulletproof leak guard; the arrays are
# cleared so the critter/impostor ticks see the new region only. T-688 H2: retirement is BUDGETED —
# children move into the reaper's hidden dying container at the seam (invisible + collision-off
# immediately) and free a few per frame from _process, with the _scene_pin refs releasing through
# the same budget, so the old region's RIDs never free in one seam-frame burst.
func _teardown_all() -> void:
	_reaper.retire(self, _scene_pin)
	_placed.clear()
	_load_queue.clear()  # T-688: drop pending loads for the region we're tearing down
	_scene_pin.clear()  # T-702: the pin is per-resident-region; the reaper drains the refs
	_requested.clear()  # and drop uncollected preload requests for the region we're leaving
	_preload_throttle.clear()
	_chunks.reset(false)  # T-693: the reaper now owns the chunk nodes; just re-sync bookkeeping
	_impostors.clear()
	_critters.clear()
	interior_volumes.clear()
	prop_count = 0
	critter_count = 0


# T-688: place up to LOAD_BUDGET_PER_FRAME queued props this frame — the throttle that turns a
# region-change swap from a one-frame GPU-upload burst into a gentle multi-frame stream. Already-
# resident indices (a prior drain reached them) are skipped without spending budget. Runs every
# frame (independent of the _STREAM_TICK_HZ re-evaluation) so the backlog clears promptly.
func _drain_load_queue() -> void:
	var placed_this_frame := 0
	while placed_this_frame < LOAD_BUDGET_PER_FRAME and not _load_queue.is_empty():
		var item = _load_queue.pop_front()
		# T-693: a chunk build (Vector3i = flora chunk, Vector4i = always-resident hero pool) —
		# one whole chunk is one budget unit.
		if item is Vector3i or item is Vector4i:
			if _chunks.is_built(item):
				continue  # already built by a prior drain — skip cheaply
			_chunks.build_chunk(item, self)
			placed_this_frame += 1
			continue
		var i: int = item
		if _placed.has(i) or i < 0 or i >= _manifest.size():
			continue  # already resident or a stale index — skip cheaply, don't spend budget
		_place(_manifest[i], i)
		placed_this_frame += 1
	# T-691: real per-item progress for the loading bar's populate phase, and its end mark the
	# first time the initial queue drains — the screen's dismiss gate (with the first snapshot).
	if _initial_pending:
		LoadPhases.progress("populate", _initial_total - _load_queue.size(), _initial_total)
		if _load_queue.is_empty():
			_finish_initial_populate()


# T-691: the initial populate is complete — end the bus phase (begin() first covers the degenerate
# nothing-to-place path, so end() always has its mark) and fire the dismiss-gate signal. The bus
# dedupes, so a preset re-apply or a later region pass can call this again harmlessly.
func _finish_initial_populate() -> void:
	if _initial_pending:
		LoadPhases.progress("populate", _initial_total, _initial_total)
	_initial_pending = false
	LoadPhases.begin("populate")
	LoadPhases.end("populate")
	initial_populate_done.emit()


# T-594: the manifest indices currently resident (test accessor for the determinism/leak check).
func placed_indices() -> Array:
	return _placed.keys()


# T-702: load a manifest scene ONCE per resident region and keep the reference (see _scene_pin).
# Every caller must come through here — a bare `load()` anywhere on the populate path silently
# reintroduces the full re-decode, and nothing in the logs would say so.
func pinned_scene(scene_path: String) -> PackedScene:
	if scene_path == "":
		return null  # a manifest row with no scene — `load("")` would push an engine error
	if _scene_pin.has(scene_path):
		return _scene_pin[scene_path]
	var scene: PackedScene = null
	if _requested.has(scene_path):
		# Collect the background load _preload_scenes started. T-758: gate on the status FIRST
		# (the visual_preload.load_scene model). LOADED hands it over instantly; IN_PROGRESS blocks
		# only for the decode's remainder — either way it REUSES that work. On FAILED/INVALID we must
		# NOT call load_threaded_get (it pushes an engine error and returns null); fall to load().
		_requested.erase(scene_path)
		var status := ResourceLoader.load_threaded_get_status(scene_path)
		if (
			status == ResourceLoader.THREAD_LOAD_LOADED
			or status == ResourceLoader.THREAD_LOAD_IN_PROGRESS
		):
			scene = ResourceLoader.load_threaded_get(scene_path) as PackedScene
	if scene == null:
		scene = load(scene_path) as PackedScene
	if scene != null:
		_scene_pin[scene_path] = scene
	return scene


# T-758: socket name -> OmniLight spec, or an EMPTY dictionary for "no light". This replaced the
# always-on `else` catch-all in _place that lit EVERY unmatched socket: 67 unintended lights, 55
# of them glowing signboards. Only the fire/candle/lamp families get an emitter; a socket used for
# anything ELSE (socket_sign, socket_sigil, socket_service, socket_cellar_stair, socket_url)
# resolves to {} and is skipped. Spec keys: color, range, energy (steady interior fill),
# base_energy (>0 means DUSK-GATED: WorldView's night_lights tick drives it from the sun, and it
# starts dark), night (add to the night_lights group). socket_rift stays inline in _place (it seeds
# an fx group too), so it is deliberately absent here.
static func socket_light_spec(sock_name: String) -> Dictionary:
	if sock_name.begins_with("socket_gaslamp"):
		# T-346/T-619: era-2 gas lamp — an omnidirectional amber pool, dusk-gated.
		return {"color": Color(1.0, 0.66, 0.3), "range": 8.5, "base_energy": 3.0, "night": true}
	if sock_name.begins_with("socket_brazier"):
		# Exterior fire on wall walks / gates / keep roofs — amber, and DUSK-GATED like the standalone
		# prop_brazier.glb (_NIGHT_LIGHTS). The old catch-all lit these as a soft always-on candle, so
		# a wall brazier blazed at noon; the fire now lights at dusk, matching the brazier prop.
		return {"color": Color(1.0, 0.5, 0.2), "range": 8.0, "base_energy": 3.5, "night": true}
	if sock_name.begins_with("socket_hearth"):
		# Interior firelight — always-on so the room reads by day (owner: interiors were too dark).
		return {"color": Color(1.0, 0.62, 0.32), "range": 7.0, "energy": 3.5, "night": false}
	if sock_name.begins_with("socket_candles"):
		# Interior candle/altar glow — always-on. omni_range 8 is load-bearing: the T-632 cathedral
		# nave chain relies on the pools overlapping, so DO NOT shrink it without re-spacing sockets.
		return {"color": Color(1.0, 0.78, 0.5), "range": 8.0, "energy": 2.2, "night": false}
	return {}


func _place(p: Dictionary, track_index: int = -1) -> bool:
	var scene_path := str(p.get("scene", ""))
	var base := scene_path.get_file()
	var scene := pinned_scene(scene_path)
	if scene == null:
		push_warning("[props] missing scene: %s" % scene_path)
		return false
	var node := scene.instantiate()
	if not (node is Node3D):
		return false
	# T-694: critter GLBs are pathological deep RIGID scenes (rabbit = 3,527 nodes / 1,175
	# MeshInstances, no AnimationPlayer) that wander as a unit — collapse the subtree to one
	# merged MeshInstance before it ever enters the tree (the cached merge means only the first
	# placement of each species pays the SurfaceTool cost). mob_sheep's animated rig makes
	# flatten_rigid refuse it, so the sheep keeps its AnimationPlayer path untouched.
	if _flatten and _CRITTER_CFG.has(base):
		_chunks.flatten_rigid(node as Node3D, scene_path)
	add_child(node)
	# T-594: when streaming, record the resident root by manifest index + count it here (the pre-T-594
	# caller-side count is gone). track_index < 0 keeps the bare-fixture path (tests) untouched.
	if track_index >= 0:
		_placed[track_index] = node
		prop_count += 1
	var n3d := node as Node3D
	# T-693: the placement transform is shared with the chunked-MultiMesh path — one source of
	# truth, so a batched instance and an individual node land byte-identically.
	n3d.transform = PropChunks.placement_transform(p)
	# T-164: solid collision so the player can't clip through buildings/props. Trimesh (concave)
	# from the mesh means walls collide but door OPENINGS stay passable (walk-in). Trees are
	# skipped for now (their canopy would block walking under them; trunk-only comes with tree v2).
	# T-210/T-120: distance culling budgets by prop class — a hundred-building city cannot draw
	# every fern at 400m. Buildings/walls never cull (silhouette = navigation); mid flora
	# and furniture fade beyond their read distance. The class->distance table now lives in
	# LodPolicy.cull_distance (shared with the impostor policy). Override per placement with "vis".
	var vis := float(p.get("vis", 0.0))
	if vis == 0.0:
		vis = LodPolicy.cull_distance(scene_path.get_file(), PropStreamer.lod_mult(_cfg))
	if vis > 0.0:
		for vi in node.find_children("*", "VisualInstance3D", true, false):
			(vi as VisualInstance3D).visibility_range_end = vis
		if node is VisualInstance3D:
			(node as VisualInstance3D).visibility_range_end = vis
	# T-120: swap big trees to a flat billboard past LodPolicy.impostor_distance (no-op unless a
	# baked prop_*_impostor.glb exists — no faked coverage).
	_register_impostor(n3d, scene_path)
	# T-693: the solid + not-a-tree policy is shared with the chunked collision-only bodies.
	if PropChunks.blocks(p, scene_path):
		_add_trimesh_collision(node)
	# T-290: age-graded moss/lichen/damp weathering, biased to the shaded (north/NE) & damp faces
	# per the T-289 sun convention. A material_overlay pass — never touches the GLB.
	PropWeathering.apply(node, base, n3d.position.y)
	# T-187 sockets: named empties in the GLB drive engine attachments (no hardcoded coords).
	# socket_hearth -> warm fire light; socket_candles -> soft altar glow. Owner: interiors
	# were too dark to see into; the hearths now carry the room.
	for sock in node.find_children("socket_*", "Node3D", true, false):
		var sname := str(sock.name)
		if sname.begins_with("socket_door"):
			continue  # T-210: door markers feed the walk-in audit, not the light pass
		if sname.begins_with("socket_chimney"):
			sock.add_to_group("chimney_sockets")  # T-209: AmbientFxLayer smokes these
			continue
		if sname.begins_with("socket_rift"):
			# T-407: the era-rift aperture. AmbientFxLayer hangs the shimmer plane + drifting
			# motes off the grouped socket (the socket_chimney discovery pattern); here we attach
			# the cold rift glow that lights the surrounding ground after dusk — DUSK-GATED via
			# the T-298 night_lights group like the gaslamps, so the plaza cobble catches the
			# "wrong" cyan-violet light at night (the stone's own emissive seams are baked into
			# the GLB material and carry the read by day). Kept inline: it seeds an fx group too.
			sock.add_to_group("rift_sockets")
			var omni_rift := OmniLight3D.new()
			omni_rift.omni_range = 9.0
			omni_rift.light_color = Color(0.45, 0.75, 1.0)
			omni_rift.light_energy = 0.0
			omni_rift.set_meta("base_energy", 3.4)
			omni_rift.add_to_group("night_lights")
			omni_rift.shadow_enabled = false
			sock.add_child(omni_rift)
			continue
		# T-758: an EXPLICIT allow-list (socket_light_spec) replaced the old `else` catch-all that
		# attached an always-on OmniLight to every unmatched socket — that lit 67 sockets the world
		# never meant to glow, 55 of them shop signboards (socket_sign) reading as lanterns by day.
		# Anything the spec doesn't recognize (sign/sigil/service/cellar_stair/url) now gets NO light.
		var spec := socket_light_spec(sname)
		if spec.is_empty():
			continue
		var light := OmniLight3D.new()
		light.light_color = spec["color"]
		light.omni_range = float(spec["range"])
		light.light_energy = float(spec.get("energy", 0.0))
		light.shadow_enabled = false  # many small lights; SDFGI carries the bounce
		if bool(spec.get("night", false)):
			# Dusk-gated: starts dark, WorldView's night_lights tick drives energy from the sun.
			light.set_meta("base_energy", float(spec["base_energy"]))
			light.add_to_group("night_lights")
		sock.add_child(light)
	# T-298: attach the dusk-gated street light for lampposts/braziers (see _NIGHT_LIGHTS).
	if _NIGHT_LIGHTS.has(base):
		var cfg: Dictionary = _NIGHT_LIGHTS[base]
		var nlight := OmniLight3D.new()
		nlight.light_color = cfg["color"]
		nlight.omni_range = float(cfg["range"])
		nlight.shadow_enabled = false
		nlight.position = cfg["pos"]
		nlight.light_energy = 0.0  # WorldView day/night tick drives this from the sun elevation
		nlight.set_meta("base_energy", float(cfg["energy"]))
		nlight.add_to_group("night_lights")
		node.add_child(nlight)
	# T-187: legacy chimney fallback — a GLB predating the socket_chimney convention with a
	# plain child node instead. Same group as the real sockets, so AmbientFxLayer's existing
	# discovery (chimney_sockets group) smokes it without any change on that side.
	if _CHIMNEY_FALLBACK.has(base):
		var legacy := node.find_child(str(_CHIMNEY_FALLBACK[base]), true, false)
		if legacy is Node3D:
			(legacy as Node3D).add_to_group("chimney_sockets")
	# T-187: interior volumes — any placed building with a door marker (socket_door* or a
	# plain "door" node, the two conventions seen across the socket-era and legacy procedural
	# GLBs) is enterable; its footprint box comes from the instanced mesh bounds, never a
	# hand-typed coordinate.
	if _has_door_marker(node):
		var vol := _build_interior_volume(node, n3d, base)
		if not vol.is_empty():
			interior_volumes.append(vol)
	# T-117: auto-rigged props (e.g. the sheep flock) carry an AnimationPlayer — loop-play its
	# idle so ambient creatures breathe. Static props have no player and are left untouched.
	if _CRITTER_CFG.has(base):
		_register_critter(n3d, base)
	else:
		var ap := node.find_child("AnimationPlayer", true, false) as AnimationPlayer
		if ap != null:
			var clip := "idle" if ap.has_animation("idle") else ""
			if clip == "" and ap.get_animation_list().size() > 0:
				clip = ap.get_animation_list()[0]
			if clip != "":
				var anim := ap.get_animation(clip)
				if anim != null:
					anim.loop_mode = Animation.LOOP_LINEAR
				ap.play(clip)
	return true


# T-310: track one placed animal for the wander/flee tick. `home` is its placed position (already
# inside whatever pen/dooryard the layout put it in) -- the bounds-clamp in critter_wander.gd never
# lets it wander/flee past `max_radius` of that point, so it can't cross a fence line or wall.
func _register_critter(n3d: Node3D, base: String) -> void:
	var ap := n3d.find_child("AnimationPlayer", true, false) as AnimationPlayer
	EntityVisuals.play_state(n3d, "idle")  # no-op if there's no AnimationPlayer (T-310: most don't)
	(
		_critters
		. append(
			{
				"node": n3d,
				"home": n3d.position,
				"cfg": _CRITTER_CFG[base],
				"state": _CW.new_state(n3d.position),
				"has_anim": ap != null,
				"anim_state": "idle",
			}
		)
	)
	critter_count += 1


# T-310: threat positions gathered ONCE per tick and shared across every critter -- the local
# player and RemoteEntitiesLayer's mob bodies are siblings of this layer under WorldView (both are
# added at the same origin in main.gd), found by name/prefix rather than a new cross-layer API so
# this stays a read-only lookup from files already owned here.
func _gather_threats() -> Array:
	var threats: Array = []
	var world := get_parent()
	if world == null:
		return threats
	var player := world.get_node_or_null("LocalPlayer") as Node3D
	if player != null:
		threats.append(player.global_position)
	var remote := world.get_node_or_null("RemoteEntities")
	if remote != null:
		for child in remote.get_children():
			if child is Node3D and str(child.name).begins_with("mob_"):
				threats.append((child as Node3D).global_position)
	return threats


func _process(delta: float) -> void:
	# T-688: drain a budget of pending prop loads every frame (spreads the region-swap GPU upload).
	# Independent of _streaming so a test driving stream_to() by hand still gets its loads placed.
	if not _load_queue.is_empty():
		_drain_load_queue()
	if _reaper.active():  # T-688 H2: budgeted teardown drain — same pacing, free side
		_reaper.drain()
	if _preload_throttle.pending() > 0:  # T-688 H4: refill the capped preload as requests finish
		_pump_preload()
	if _streaming:  # T-594: throttled region/flora streaming from the live player position
		_stream_accum += delta
		if _stream_accum >= 1.0 / _STREAM_TICK_HZ:
			_stream_accum = 0.0
			stream_to(_player_ground())
	if _lod_stats:
		_stats_accum += delta
		if _stats_accum >= 2.0:  # every 2s — a log line, not a per-frame spam
			_stats_accum = 0.0
			print(RenderStats.snapshot(self))
	if not _impostors.is_empty():
		_tick_impostors(delta)
	if _critters.is_empty():
		return
	_critter_tick_accum += delta
	var interval := 1.0 / _CRITTER_TICK_HZ
	if _critter_tick_accum < interval:
		return
	var dt := _critter_tick_accum
	_critter_tick_accum = 0.0
	var threats := _gather_threats()
	var now := Time.get_ticks_msec()
	for c: Dictionary in _critters:
		var st: Dictionary = _CW.tick(c["state"], c["cfg"], c["home"], threats, now, dt, _rng)
		c["state"] = st
		var node: Node3D = c["node"]
		node.position = st["pos"]
		if c["has_anim"]:
			var wanted := "walk" if bool(st["moving"]) else "idle"
			if c["anim_state"] != wanted:
				c["anim_state"] = wanted
				EntityVisuals.play_state(node, wanted)


# T-120: if this prop class impostors AND a baked prop_*_impostor.png exists, build a Y-billboard
# quad (sized to the tree's own mesh bounds) as a sibling at the same placement and hide it; the
# swap tick reveals it past range. No baked texture -> return silently (range-culling still applies;
# nothing faked). The quad, not a GLB, is the right primitive for a distant cardboard tree.
func _register_impostor(n3d: Node3D, scene_path: String) -> void:
	var mult := PropStreamer.lod_mult(_cfg)  # T-692 Part B: preset-scaled swap + cull
	var imp_dist := LodPolicy.impostor_distance(scene_path.get_file(), mult)
	if imp_dist <= 0.0:
		return
	var tex_path := LodPolicy.impostor_texture_path(scene_path)
	if tex_path == "" or not ResourceLoader.exists(tex_path):
		return
	var tex := load(tex_path) as Texture2D
	if tex == null:
		return
	# Tree footprint in n3d's own frame (pre-placement-scale); the billboard matches its silhouette.
	var aabb := _mesh_bounds_local(n3d)
	if aabb.size == Vector3.ZERO:
		return
	var scl := n3d.scale.x
	# SQUARE quad sized to the same margin-padded max extent the baker framed its square ortho to
	# (bake_impostor.py uses 1.06) — so the rendered silhouette maps 1:1 onto the quad regardless of
	# the tree's width/height/depth aspect. Centred at the mesh's mid-height over the trunk.
	var span := maxf(aabb.size.x, maxf(aabb.size.y, aabb.size.z)) * _IMPOSTOR_FRAME_MARGIN * scl
	var mid_y := (aabb.position.y + aabb.size.y * 0.5) * scl
	var quad := QuadMesh.new()
	quad.size = Vector2(span, span)
	# T-696: shared with the batched-tree impostor pool (prop_chunks) — single material idiom.
	quad.material = PropChunks.make_impostor_material(tex)
	var mi := MeshInstance3D.new()
	mi.mesh = quad
	mi.position = n3d.position + Vector3(0.0, mid_y, 0.0)
	mi.visible = false
	var cull := LodPolicy.cull_distance(scene_path.get_file(), mult)
	if cull > 0.0:
		mi.visibility_range_end = cull
	add_child(mi)
	_impostors.append({"mesh": n3d, "impostor": mi, "imp_dist": imp_dist, "active": false})


# T-120: union AABB of a placed prop's MeshInstance3D bounds in its OWN local frame (before its
# placement scale) — reuses the tree-independent local-transform walk so it works off-tree in
# fixtures. Vector3.ZERO size = no mesh found.
func _mesh_bounds_local(n3d: Node3D) -> AABB:
	var out := AABB()
	var first := true
	for child in n3d.find_children("*", "MeshInstance3D", true, false):
		var mi := child as MeshInstance3D
		var rel := PropChunks.local_transform_to_ancestor(mi, n3d)
		var box := PropChunks.transform_aabb(mi.get_aabb(), rel)
		out = box if first else out.merge(box)
		first = false
	return out if not first else AABB()


# T-120: throttled mesh<->impostor swap by camera distance with LodPolicy hysteresis. Runs off the
# active 3D camera; no camera (headless test/loading) -> hold current state. O(impostor props) at
# 5 Hz, so a forest of billboards costs a handful of distance checks a second, not per frame.
func _tick_impostors(delta: float) -> void:
	_impostor_tick_accum += delta
	if _impostor_tick_accum < 1.0 / _IMPOSTOR_TICK_HZ:
		return
	_impostor_tick_accum = 0.0
	var vp := get_viewport()
	var cam := vp.get_camera_3d() if vp != null else null
	if cam == null:
		return
	var eye := cam.global_position
	var hyst := LodPolicy.impostor_hysteresis()
	for e: Dictionary in _impostors:
		var mesh: Node3D = e["mesh"]
		if not is_instance_valid(mesh):
			continue
		var dist := eye.distance_to(mesh.global_position)
		var now_active := LodPolicy.impostor_active(dist, float(e["imp_dist"]), hyst, e["active"])
		if now_active == e["active"]:
			continue
		e["active"] = now_active
		mesh.visible = not now_active
		var imp: Node3D = e["impostor"]
		if is_instance_valid(imp):
			imp.visible = now_active


# T-120: live impostor/mesh split for the render-stats instrumentation the orchestrator reads
# during qa-tour. Counts only impostorable props: how many are currently drawn as a billboard vs
# the full mesh. render_stats.gd formats this into the one-line [lod] snapshot.
func impostor_split() -> Dictionary:
	var impostor := 0
	for e: Dictionary in _impostors:
		if bool(e["active"]):
			impostor += 1
	return {"impostor": impostor, "mesh": _impostors.size() - impostor}


# T-164: give every MeshInstance3D in a placed prop a concave (trimesh) static collision, so the
# player collides with walls/props but door openings remain passable.
func _add_trimesh_collision(root: Node) -> void:
	for child in root.find_children("*", "MeshInstance3D", true, false):
		var mi := child as MeshInstance3D
		mi.create_trimesh_collision()
		# AAA-spec pass: static props must feed the GI volumes (SDFGI) — enforce rather than
		# trust import defaults, so buildings bounce light and shadow interiors correctly.
		mi.gi_mode = GeometryInstance3D.GI_MODE_STATIC


# T-187: a placed building is ENTERABLE if it carries a door marker — either the socket
# convention (socket_door / socket_door2 / …) or a legacy plain "door" node (the procedural
# gen_*_real.py kit, e.g. prop_farmhouse.glb). Buildings with neither (barn/watchtower/watermill/
# forge in the committed set) are decorative silhouettes only — no interior volume is fabricated
# for them.
func _has_door_marker(node: Node) -> bool:
	if not node.find_children("socket_door*", "Node3D", true, false).is_empty():
		return true
	var legacy := node.find_child("door", true, false)
	return legacy is Node3D


# T-187: derive an interior footprint box from the instanced building's own mesh bounds — the
# union of every MeshInstance3D's AABB, transformed into the BUILDING's own local frame (i.e.
# before its placement position/rotation/scale are applied), then re-projected into world space
# via interior_zones.gd using that same placement. No per-building coordinate is ever hand-typed;
# a village-layout change (new x/y/rot_deg in props.json) moves the volume for free.
#
# Uses LOCAL transforms walked up the parent chain (not global_transform) so this works whether
# or not the layer/building is actually inside a running SceneTree — global_transform requires
# is_inside_tree() and world-prop fixtures in tests are deliberately built off-tree (T-310's
# autofree pattern, so _place() doesn't reload the real props.json via _ready()).
func _build_interior_volume(node: Node, n3d: Node3D, base: String) -> Dictionary:
	var local_aabb := AABB()
	var first := true
	for child in node.find_children("*", "MeshInstance3D", true, false):
		var mi := child as MeshInstance3D
		var rel := PropChunks.local_transform_to_ancestor(mi, n3d)
		var mesh_aabb := PropChunks.transform_aabb(mi.get_aabb(), rel)
		local_aabb = mesh_aabb if first else local_aabb.merge(mesh_aabb)
		first = false
	if first:
		return {}
	return InteriorZones.volume_from_local_aabb(
		base, local_aabb, n3d.position, n3d.rotation.y, n3d.scale.x
	)
