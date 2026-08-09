class_name WorldView
extends Node3D

# T-053: the gray-box 3D world — ground + lighting + sky + a third-person camera rig — built in CODE
# (no .tscn: AGENTS bars scene-file edits, and code keeps it headlessly unit-testable). The player
# attaches to the camera rig in T-054; for now the rig sits at a default viewpoint. Visual look is
# verified by play-test (AGENTS bars running the client with a display); structure is unit-tested.

const GROUND_SIZE := 400.0
# T-202: Highkeep street graph — [x0, z0, x1, z1, half_width] per segment, generated from
# client/assets/highkeep_plan.json streets. KEEP IN SYNC with terrain_splat.gdshader
# HK_SEG/HK_HW (world-audit.py reads the plan JSON directly).
const HK_STREET_SEGS: Array = [
	[72.0, -262.0, 83.0, -262.0, 2.25],
	[0.0, -140.0, -2.0, -168.0, 3.00],
	[-2.0, -168.0, 2.0, -197.0, 3.00],
	[-20.0, -215.0, 0.0, -197.0, 2.50],
	[0.0, -197.0, 20.0, -215.0, 2.50],
	[20.0, -215.0, 0.0, -233.0, 2.50],
	[0.0, -233.0, -20.0, -215.0, 2.50],
	[0.0, -233.0, -2.0, -262.0, 3.00],
	[-2.0, -262.0, 0.0, -292.0, 3.00],
	[-20.0, -215.0, -52.0, -222.0, 2.50],
	[-52.0, -222.0, -70.0, -252.0, 2.50],
	[20.0, -215.0, 52.0, -228.0, 2.50],
	[52.0, -228.0, 72.0, -262.0, 2.50],
	[72.0, -262.0, 76.0, -296.0, 2.50],
	[-1.0, -162.0, -56.0, -168.0, 2.25],
	[-56.0, -168.0, -92.0, -190.0, 2.25],
	[-1.0, -162.0, 54.0, -168.0, 2.25],
	[54.0, -168.0, 92.0, -190.0, 2.25],
	[0.0, -292.0, -44.0, -300.0, 2.25],
	[-44.0, -300.0, -60.0, -294.0, 2.25],
	[-52.0, -222.0, -48.0, -212.0, 2.25],
	[-48.0, -212.0, -104.0, -208.5, 2.25],
	[52.0, -228.0, 49.0, -212.3, 2.25],
	[49.0, -212.3, 106.0, -212.3, 2.25],
	[-44.0, -300.0, -38.0, -322.3, 2.25],
	[-38.0, -322.3, -76.0, -322.3, 2.25],
]
const HK_PLAZA_POS := Vector2(0.0, -215.0)
const HK_PLAZA_HALF := Vector2(18.0, 16.0)
# T-491: ward-yard trodden-earth + kitchen-garden bed rects [cx, cz, half_x, half_z]. KEEP IN
# SYNC with terrain_splat.gdshader HK_WARD_RECT / HK_GARDEN_RECT (source pins hold the sync).
const HK_WARD_RECT: Array = [
	[-72.0, -190.0, 38.0, 32.0],
	[74.0, -196.0, 36.0, 30.0],
	[-34.0, -322.0, 46.0, 14.0],
]
const HK_GARDEN_RECT: Array = [
	[-114.0, -200.0, 4.0, 8.0],
	[114.0, -196.0, 4.0, 9.0],
	[-62.0, -336.0, 10.0, 2.6],
]
# T-314: village branch paths — [x0, z0, x1, z1, half_width] per segment. KEEP IN SYNC with
# terrain_splat.gdshader VP_SEG/VP_HW; used here only to keep grass clutter from scattering
# tufts back over the worn paths (same idiom as the HK street/plaza guard below).
const VP_SEGS: Array = [
	[0.0, -9.5, -2.2, -9.8, 0.80],
	[-2.2, -9.8, -4.7, -9.0, 0.95],
	[0.0, 12.5, -2.8, 11.8, 0.80],
	[-2.8, 11.8, -5.6, 13.0, 0.95],
	[0.0, 3.3, -2.6, 3.8, 0.80],
	[-2.6, 3.8, -5.3, 3.0, 0.95],
	[0.0, 23.0, -3.0, 22.0, 0.80],
	[-3.0, 22.0, -6.0, 23.3, 0.90],
	[-6.0, 23.3, -9.0, 24.3, 1.00],
	[2.0, 7.2, 2.6, 8.0, 0.60],
	[0.0, 8.5, 2.6, 9.2, 0.80],
	[2.6, 9.2, 5.4, 9.0, 0.95],
	[0.0, -2.5, 2.3, -3.3, 0.80],
	[2.3, -3.3, 4.7, -3.0, 0.95],
	[0.0, -15.5, 2.6, -16.4, 0.80],
	[2.6, -16.4, 5.1, -16.0, 0.95],
	[0.0, 4.0, 9.0, 2.2, 1.00],
	[9.0, 2.2, 18.0, 5.0, 1.00],
	[18.0, 5.0, 26.0, 3.0, 1.00],
	[26.0, 3.0, 31.0, 4.0, 1.00],
	[31.0, 4.0, 34.0, 4.2, 1.10],
	[34.0, 4.2, 37.0, 8.0, 1.00],
	[37.0, 8.0, 37.8, 8.6, 1.15],
	[37.8, 8.6, 44.0, 6.0, 1.00],
	[44.0, 6.0, 47.0, 12.0, 1.00],
	[47.0, 12.0, 46.0, 17.5, 1.05],
	[-0.9, -30.0, 6.0, -29.0, 0.90],
	[6.0, -29.0, 13.0, -30.5, 0.90],
	[13.0, -30.5, 19.2, -30.0, 1.00],
]
# T-313: eastern farmstead worked-land regions — [cx, cz, half_x, half_z] axis-aligned rects.
# KEEP IN SYNC with terrain_splat.gdshader FIELD_RECT/FIELD_HALF (tilled-earth splat paint) and
# PADDOCK_RECT/PADDOCK_HALF (worn-pen dirt); used here only to keep grass clutter from
# scattering tufts back over plowed earth or the trodden pasture (same idiom as VP_SEGS above).
const FIELD_RECTS: Array = [
	[29.0, 15.0, 4.5, 3.0],  # planted wheat plot
	[29.0, 9.0, 4.5, 3.0],  # fallow plot
]
const PADDOCK_RECT: Array = [26.0, 4.0, 5.0, 4.0]  # fenced sheep pasture (x21-31, z0-8)
# T-347: ASHMOOR era-2 district (offset region at (-420,0)) — [cx,cz,hx,hz]. SYNC with
# terrain_splat.gdshader ASHMOOR_SOOT_RECT (grass-clutter suppression off the paved district).
const ASHMOOR_SOOT_RECT: Array = [-420.0, -2.0, 40.0, 22.0]
# T-079: WoW-like painterly palette — saturated meadow greens, warm sun, blue sky.
# T-169/T-170 (blind-judge round 7/8): "near-white blown sky -> saturated painterly sky". Round 8
# still read it pale/cool, so the zenith + lower sky are pushed DEEPER and more saturated again.
# T-170 round 8c: the eye-level camera sees the LOWER sky band, so it's day_bottom (+horizon glow)
# that must carry saturated cerulean — pushed deep. Sun warmed to amber/gold (was reading neutral-
# white because over-exposure clipped its warm tint away).
const SKY_TOP := Color(0.10, 0.30, 0.86)
const SKY_HORIZON := Color(0.22, 0.46, 0.86)
const SUN_COLOR := Color(1.0, 0.86, 0.58)
const WIND_SHADER := preload("res://shaders/wind_foliage.gdshader")
const GRASS_SHADER := preload("res://shaders/grass.gdshader")  # T-090: lush blade grass
const WATER_SHADER := preload("res://shaders/water.gdshader")  # T-088/T-133: Crystal Lake
const TERRAIN_SHADER := preload("res://shaders/terrain_splat.gdshader")  # T-132: painted splats
const TERRAIN_FIELD := preload("res://scripts/world/terrain_field.gd")  # T-309: shared height field
const TERRAIN_SAMPLER := preload("res://scripts/world/terrain_sampler.gd")  # T-695: threaded height
const GRASS_ALBEDO := preload("res://assets/textures/grass_meadow.png")
const DIRT_ALBEDO := preload("res://assets/textures/dirt_path.png")
# T-185 realism pivot: the meadow/road textures are now ambientCG CC0 scans (Grass004 /
# Ground025, 1K) with matching GL normal maps — the painterly gen_ground_paint set is retired.
const GRASS_NORMAL := preload("res://assets/textures/grass_meadow_nrm.png")
const DIRT_NORMAL := preload("res://assets/textures/dirt_path_nrm.png")
# T-406: Ashmoor High Street cobble — Poly Haven cobblestone_floor_08 (CC0, 1K JPG + GL normal)
const COBBLE_ALBEDO := preload("res://assets/textures/cobble_street.jpg")
const COBBLE_NORMAL := preload("res://assets/textures/cobble_street_nrm.jpg")
# Crystal Lake — a pond in the east meadow (world x,z). Grass is cleared inside its radius.
const LAKE_CENTER := Vector2(18.0, 22.0)
const LAKE_RADIUS := 12.0
# T-185/T-490: dwelling plot centres (interiors clear of tufts; outer ring is the disturbed verge
# where the T-490 density field piles grass against the walls).
const DWELLING_PLOTS: Array = [
	Vector2(8.8, -3.0),
	Vector2(8.8, 9.0),
	Vector2(8.8, -16.0),
	Vector2(8.8, 21.0),
	Vector2(-8.8, 3.0),
	Vector2(-8.8, -9.0),
	Vector2(-6.2, 9.5),
]
const PLOT_RADIUS := 6.2
# T-342: Highkeep's capital river — the real water source the owner chose to BUILD (retiring the
# T-300 plaza cistern). The centerline + water-ribbon build live in RiverView (river_view.gd,
# extracted to keep this file under the 1000-line gdlint cap). v1 is FLAT-BANKED (T-327 keeps every
# walked pocket at y=0; carving the walked channel is deferred): the ribbon sits just above grade,
# the terrain splat paints carved-LOOKING wet banks (terrain_splat river_mask), and the stone bridge
# (prop_bridge_stone, in props.json) gives the King's Road a dry crossing south of the gate.
const MEADOW := preload("res://scripts/world/meadow_clutter.gd")  # T-490 tuft mesh + density field
const RIVER_VIEW := preload("res://scripts/world/river_view.gd")
const WATER_VIEW := preload("res://scripts/world/water_view.gd")  # T-441 lake build + day tick
const ERA_ATMOS := preload("res://scripts/world/era_atmosphere.gd")  # T-408 per-region atmosphere
const NIGHT_SKY := preload("res://scripts/world/night_sky.gd")  # T-404 moon + starfield + moonlight
const RAIN_RIG := preload("res://scripts/world/rain_rig.gd")  # T-614 camera-following rain emitter
const ERA_ATMOS_RATE := 0.4  # T-408: blend units/sec -> ~2.5s smooth rift crossing (no pop)
const ERA_LUT_STEPS := 12  # T-408: throttled LUT rebuilds across a crossing (smog 0 == base grade)
const DAY_SECONDS := 1200.0  # T-137: one in-game day
const SUN_ELEV_PEAK_DEG := 55.0  # T-289: noon elevation for a temperate latitude (45-60 range)
const CLOUD_DECK := preload("res://scripts/world/cloud_deck.gd")  # T-303 (T-734 headroom carve)
# T-417: night cloud albedo dims toward this cool moonlit fog-band grey (~0.2 luma), not day-white.
const CLOUD_NIGHT_TINT := Color(0.22, 0.25, 0.30)
# T-085 weather look bounds — how far rain dims the sky without fighting the T-289 sun arc to black.
const OVERCAST_MAX_AMBIENT_DIP := 0.45  # rain multiplies ambient/sun energy down by at most this
const OVERCAST_MAX_FOG := 0.02  # T-303 base fog is 0.0026; full overcast thickens toward this
const OVERCAST_MAX_SHADOW_FADE := 0.7  # T-614: full overcast softens the hard sun shadow this far

var ground: StaticBody3D = null
var sun: DirectionalLight3D = null
var world_environment: WorldEnvironment = null
var camera_arm: SpringArm3D = null
var camera: Camera3D = null
var rain: GPUParticles3D = null  # T-085 weather emitter (camera-following)
var _rain_wanted := false  # T-187: the outdoor truth set_rain() last asked for
var _rain_suppressed := false  # T-187: true while the player is indoors (InteriorGate)
var _wind_noise_tex: NoiseTexture2D = null
var _clutter_noise: FastNoiseLite = null  # T-490: shared low-freq meadow patch field
# T-085: client-local ambient weather. WeatherController owns the seeded cycle + gust; world_view
# feeds it the grass sway mats and folds the returned overcast darkness into the sun-arc look.
var _weather_ctl: WeatherController = null
var _foliage_wind_mats: Array[ShaderMaterial] = []
# T-132/T-287/T-309 vale height field (shared with the audit oracle), built in _build_ground.
# Untyped on purpose: a `TerrainField` type annotation needs the global class cache, which a
# headless run (world-audit / GUT) may not have populated — that cascades to a 0-tests parse fail.
var _terrain = null
var _clouds: Array[MeshInstance3D] = []  # T-303 cloud cards (drift in _process)
var _water_mats: Array[ShaderMaterial] = []  # T-441: lake + river water (day/night sheen tick)
var _cloud_materials: Array[StandardMaterial3D] = []  # T-303: shared per-variant, tinted by day
# T-137 time-of-day 0..1 (0=sunrise east, 0.25=noon south, 0.5=sunset west, 0.75=midnight,
# below-horizon north — see docs/design/world-conventions.md). T-289: 0.34 keeps the T-170
# MODERATE-afternoon mood (~46deg elevation, sun south-southwest) without the flat high-noon
# look or the hard black shadow slab that a too-low sun threw across the foreground.
var _day_t := 0.34
# QA freeze: AVALON_FREEZE_DAY holds the sun still (optionally at a given 0..1 day_t) so
# screenshot passes can't be cut short by an in-session sunset (the "day-cycle race").
var _day_frozen := false
# T-734: server-clock sync brain (snap on join / big drift, rate-capped slew otherwise).
var _day_sync = preload("res://scripts/world/day_clock_sync.gd").new()
# T-408: per-region atmosphere. set_era_atmosphere flips _era_target (SAME EraSkin resolution the
# VFX re-skin rides); _era_blend tweens toward it in _process, overlaying the lerped ERA_ATMOS
# on the sun-arc + weather base. era 0 == byte-identical home.
var _era_target := 0.0
var _era_blend := 0.0
var _era_lut_step := 0  # throttles the LUT rebuild; 0 == the base zone grade
var _sky_material: PhysicalSkyMaterial = null
# T-404: the night sky layer (moon disc + procedural starfield dome + cool moonlight). Built in
# _ready after the camera exists (the dome anchors to it); driven each _process off the sun arc.
var _night_sky = null
# T-697 fix 4: cached "night_lights" group members. get_nodes_in_group() allocates a fresh Array
# EVERY frame; the members only change when props stream in/out, so the tree's node_added/
# node_removed signals mark the cache dirty and _process rebuilds it on demand.
var _night_lights: Array = []
var _night_lights_dirty := true
var _night_shown := -1.0  # last quantized night factor written to the lamps (-1 = never)
# T-697 fix 4: last quantized (elev, darkness, era) driver signature the slow-moving looks
# (Environment, cloud tint, water sheen) were written for. INF forces the first write.
var _look_sig := Vector3(INF, 0.0, 0.0)
# T-695: AVALON_THREADED_LOAD=0 keeps the ground's ~230k height() samples on main (_build_ground).
var _threaded_load := OS.get_environment("AVALON_THREADED_LOAD") == "1"


func _ready() -> void:
	# T-692: diagnostic perf overlay + per-second [perf] breakdown log (AVALON_PERF=1 only).
	if OS.get_environment("AVALON_PERF") == "1":
		add_child(preload("res://scripts/world/perf_probe.gd").new())
	var freeze := OS.get_environment("AVALON_FREEZE_DAY")
	if freeze != "":
		_day_frozen = true
		if freeze.is_valid_float():
			_day_t = clampf(freeze.to_float(), 0.0, 1.0)
	_wind_noise_tex = _make_noise_texture(0.04, 4, true)  # shared world-space wind field
	preload("res://scripts/ui/load_phases.gd").timed("terrain", _build_ground)  # T-691 sub-mark
	_build_road()
	_build_water()
	_build_river()  # T-342: replaces _build_plaza_cistern() — the capital's real water source
	_build_clutter()
	_build_lighting()
	_build_camera()
	_night_sky = NIGHT_SKY.new()  # T-404: needs the camera (dome anchors to it) — build after it
	_night_sky.build(self)
	_build_weather()
	CLOUD_DECK.build(self)  # T-303 cumulus cards (T-734 headroom carve — populates _clouds)
	_weather_ctl = WeatherController.new()
	_weather_ctl.setup(_foliage_wind_mats)
	# T-697 fix 4: keep the night-lights cache honest across prop streaming — any tree change
	# involving a grouped lamp marks it dirty (a hash check per tree mutation, not a per-frame scan).
	get_tree().node_added.connect(_on_tree_change)
	get_tree().node_removed.connect(_on_tree_change)


# T-697 fix 4: a lamp entered/left the tree (prop streaming, region swap) — rebuild the cache on
# the next tick. Group membership is set before add_child throughout world_props_layer.gd, so the
# node_added check sees it; on node_removed the membership is still present.
func _on_tree_change(node: Node) -> void:
	if node.is_in_group("night_lights"):
		_night_lights_dirty = true


# T-088/T-133/T-179: Crystal Lake — build delegated to WaterView (water_view.gd, T-441). The lake
# and the T-342 river share ONE water shader with its default palette; the shader's true depth
# read does the shallow/deep work. Both materials are kept in _water_mats for the day/night tick.
func _build_water() -> void:
	var ripple := _make_noise_texture(0.08, 7, true)
	var shore := _make_noise_texture(0.005, 91, true)
	var water := WATER_VIEW.build_lake(WATER_SHADER, LAKE_CENTER, LAKE_RADIUS, ripple, shore)
	_water_mats.append(water.material_override as ShaderMaterial)
	add_child(water)


# T-342: the capital river — delegated to RiverView (river_view.gd). world_view supplies the shared
# water shader + the two noise textures (ripple shimmer + static bank-wobble field); RiverView owns
# the centerline and the ribbon-mesh build. This RETIRES the T-300 plaza cistern (no longer built).
func _build_river() -> void:
	var ripple := _make_noise_texture(0.08, 53, true)
	var shore := _make_noise_texture(0.02, 71, true)
	var river := RIVER_VIEW.build(WATER_SHADER, ripple, shore)
	_water_mats.append(river.material_override as ShaderMaterial)
	add_child(river)


# T-146: the dirt road village -> Highkeep gatehouse. Blind-judge round 3: the flat brown
# ribbon mesh failed ("razor-straight geometric edges"); the road is now painted INTO the
# terrain splat shader (see terrain_splat.gdshader road_mask) with a wobbling, dithered edge.
func _build_road() -> void:
	pass  # corridor is painted by the ground's splat shader


# A seamless FBM noise texture (used for wind flow and cloud layers). Async-generated by
# Godot on a worker thread; fills in within a frame or two of load.
func _make_noise_texture(freq: float, seed_val: int, seamless: bool) -> NoiseTexture2D:
	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise.fractal_octaves = 4
	noise.frequency = freq
	noise.seed = seed_val
	var tex := NoiseTexture2D.new()
	tex.width = 512
	tex.height = 512
	tex.seamless = seamless
	tex.noise = noise
	return tex


# Owner mandate (forest buildout): the dirt road WINDS through the forest stretch and
# straightens through the village street and at the gatehouse approach.
# KEEP IN SYNC with terrain_splat.gdshader road_center_x() and world-audit.py road_center_x().
static func road_center_x(z: float) -> float:
	var w := clampf((-z - 18.0) / 14.0, 0.0, 1.0) * clampf((z + 136.0) / 14.0, 0.0, 1.0)
	return w * (6.0 * sin(0.055 * (z + 18.0)) + 2.6 * sin(0.021 * (z + 18.0) + 1.7))


# Signed distance to the street network edge (negative = on a street / in the plaza).
# Mirrors terrain_splat.gdshader hk_street_d() so paint, clutter, and audits agree.
static func hk_street_dist(x: float, z: float) -> float:
	var p := Vector2(x, z)
	var best := 1e9
	for s: Array in HK_STREET_SEGS:
		var a := Vector2(s[0], s[1])
		var ab := Vector2(s[2], s[3]) - a
		var t: float = clampf((p - a).dot(ab) / ab.dot(ab), 0.0, 1.0)
		best = minf(best, p.distance_to(a + ab * t) - s[4])
	var dq := (p - HK_PLAZA_POS).abs() - HK_PLAZA_HALF
	var outside := Vector2(maxf(dq.x, 0.0), maxf(dq.y, 0.0)).length()
	best = minf(best, outside + minf(maxf(dq.x, dq.y), 0.0))
	return best


# T-202: inside the wall circuit (with apron) — clutter tufts never spawn here and the
# street/plaza paint is confined to it.
static func hk_in_city(x: float, z: float) -> bool:
	return absf(x) <= 126.0 and z <= -136.0 and z >= -344.0


# T-314: distance to the nearest village branch-path edge (negative = on the worn path).
# Mirrors terrain_splat.gdshader vp_path_d() so clutter never scatters tufts back onto a
# path the shader just painted.
static func vp_path_dist(x: float, z: float) -> float:
	var p := Vector2(x, z)
	var best := 1e9
	for s: Array in VP_SEGS:
		var a := Vector2(s[0], s[1])
		var ab := Vector2(s[2], s[3]) - a
		var t: float = clampf((p - a).dot(ab) / ab.dot(ab), 0.0, 1.0)
		best = minf(best, p.distance_to(a + ab * t) - s[4])
	return best


# T-313: is (x,z) inside a worked-land rect (tilled field plot or the fence pasture)? Mirrors
# terrain_splat.gdshader field_mask()/paddock_mask() box tests so clutter tufts never scatter
# back onto plowed earth or the trodden pen.
static func in_farmstead_rect(x: float, z: float) -> bool:
	for r: Array in FIELD_RECTS:
		if absf(x - r[0]) < r[2] + 0.6 and absf(z - r[1]) < r[3] + 0.6:
			return true
	if (
		absf(x - PADDOCK_RECT[0]) < PADDOCK_RECT[2] + 0.6
		and absf(z - PADDOCK_RECT[1]) < PADDOCK_RECT[3] + 0.6
	):
		return true
	return false


# T-347: is (x,z) inside the ASHMOOR paved district? Mirrors ashmoor_soot_mask (clutter reroll).
static func in_ashmoor_district(x: float, z: float) -> bool:
	var r: Array = ASHMOOR_SOOT_RECT
	return absf(x - r[0]) < r[2] + 0.6 and absf(z - r[1]) < r[3] + 0.6


# T-132/T-287/T-309: the vale ground mesh. The height field itself lives in TerrainField (shared
# with the world-audit oracle). Protected-flat: core (r<75), King's Road + Highkeep city rect,
# lake bowl. The near fringe rolls, fades to a flat plain, then MOUNTAINS rise beyond the ±500
# bound — see terrain_field.gd. The mesh is graded: the current playable footprint keeps full
# resolution; it extends coarsely to ±650 to show the mountain wall and kill the grey void.
func _terrain_height(x: float, z: float) -> float:
	return _terrain.height(x, z)


# One axis of a graded grid: fine steps inside [fine_lo, fine_hi], easing to coarse steps outside
# so the extended backdrop costs few triangles. Rectilinear (axis-aligned quads) => no T-cracks.
func _grid_lines(
	lo: float, hi: float, fine_lo: float, fine_hi: float, fine_step: float, coarse_step: float
) -> PackedFloat32Array:
	var lines := PackedFloat32Array()
	var v := lo
	while v < hi - 0.001:
		lines.append(v)
		var outside := maxf(fine_lo - v, v - fine_hi)  # >0 once past the fine window
		v = minf(v + lerpf(fine_step, coarse_step, clampf(outside / 220.0, 0.0, 1.0)), hi)
	lines.append(hi)
	return lines


func _build_ground() -> void:
	ground = StaticBody3D.new()
	ground.name = "Ground"
	_terrain = TERRAIN_FIELD.new()
	var mesh := MeshInstance3D.new()
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var half := GROUND_SIZE / 2.0
	var fine := GROUND_SIZE / 128.0  # 3.125m — the shipped playable-footprint resolution
	# T-309: reach past the ±500 gameplay bound so the mountain ring (that rises beyond it) is
	# fully in-frame and no camera can see the slab edge or grey void. Fine window preserves the
	# T-202 footprint (x ±200, z -400..200) exactly; the extension out to ±650 is coarse backdrop.
	var xs := _grid_lines(-650.0, 650.0, -205.0, 205.0, fine, 16.0)
	var zs := _grid_lines(-650.0, 650.0, -405.0, 205.0, fine, 16.0)
	# T-695: the ~230k height() samples (~1.1s) run up front — threaded live, inline under headless/
	# kill-switch (both byte-identical) — into a row-major grid the vertex loop reads. Mesh/trimesh/
	# attach stay synchronous on main, so the ground is present when _ready returns.
	var nx := xs.size()
	var threaded := _threaded_load and DisplayServer.get_name() != "headless"
	var heights := TERRAIN_SAMPLER.new().sample(_terrain, xs, zs, threaded)
	for iz in range(zs.size() - 1):
		for ix in range(nx - 1):
			var x0 := xs[ix]
			var x1 := xs[ix + 1]
			var z0 := zs[iz]
			var z1 := zs[iz + 1]
			var row0 := iz * nx
			var row1 := (iz + 1) * nx
			var pts := [
				Vector3(x0, heights[row0 + ix], z0),
				Vector3(x1, heights[row0 + ix + 1], z0),
				Vector3(x1, heights[row1 + ix + 1], z1),
				Vector3(x0, heights[row1 + ix], z1),
			]
			for idx in [0, 1, 2, 0, 2, 3]:
				var p: Vector3 = pts[idx]
				# T-170 round 8c: larger tile footprint (22m vs 16m) so the painted-ground repeat is
				# less obvious across the meadow (the splat shader's breakup adds macro variation).
				st.set_uv(Vector2((p.x + half) / 22.0, (p.z + half) / 22.0))
				st.add_vertex(p)
	st.generate_normals()
	mesh.mesh = st.commit()
	# T-132 painted splat ground (judge round 3): hand-painted grass/dirt albedo blended in
	# world space; the road corridor + anti-tiling breakup live in the shader.
	var mat := ShaderMaterial.new()
	mat.shader = TERRAIN_SHADER
	mat.set_shader_parameter("grass_tex", GRASS_ALBEDO)
	mat.set_shader_parameter("dirt_tex", DIRT_ALBEDO)
	# T-185 realism: scan normal maps (same masks as the albedo blend)
	mat.set_shader_parameter("grass_nrm", GRASS_NORMAL)
	mat.set_shader_parameter("dirt_nrm", DIRT_NORMAL)
	# T-406: real cobble scan on the Ashmoor High Street strip (per-sett relief + wear ruts)
	mat.set_shader_parameter("cobble_tex", COBBLE_ALBEDO)
	mat.set_shader_parameter("cobble_nrm", COBBLE_NORMAL)
	mat.set_shader_parameter("breakup_tex", _make_noise_texture(0.05, 4711, true))
	# T-179: Crystal Lake shore ring — the splat shader paints a wet-sand/mud band around the
	# waterline so grass never meets open water directly (kills the razor square/grass seam).
	mat.set_shader_parameter("lake_center", LAKE_CENTER)
	mat.set_shader_parameter("lake_radius", LAKE_RADIUS)
	mesh.material_override = mat
	ground.add_child(mesh)
	# T-327: collide with the REAL terrain (trimesh from the displaced mesh) so a body rests on
	# hills/hollows instead of a flat y=0 plane. local_player.gd derives vertical support from the
	# shared TerrainField; this trimesh backs horizontal collide-and-slide on the surface.
	var terrain_col := CollisionShape3D.new()
	terrain_col.shape = mesh.mesh.create_trimesh_shape()
	ground.add_child(terrain_col)
	# Safety catch far below the deepest relief — a fallen/edge-case body never drops to infinity
	# (the old y=0 WorldBoundaryShape3D pinned every walked point to zero; the terrain now owns it).
	var floor_col := CollisionShape3D.new()
	var floor_plane := WorldBoundaryShape3D.new()
	floor_plane.plane = Plane(Vector3.UP, -50.0)
	floor_col.shape = floor_plane
	ground.add_child(floor_col)
	add_child(ground)


# T-079: scattered ground clutter (grass tufts + rocks) via MultiMesh — thousands of
# instances, one draw call each kind. Deterministic seed so screenshots are reproducible.
func _build_clutter() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 20260702
	# Grass history (T-090/T-167/T-169): the painted terrain texture carries the meadow detail and
	# the 3D grass is kept to sparse accent tufts (one draw call per tint), deepened off the lime
	# tone to sit in the scan meadow. T-490: three UPRIGHT grass silhouettes (was one splayed
	# succulent rosette) — desaturated cool-to-warm greens, no blue-green cast; g_mid/g_dark are
	# short turf and g_tall a taller straw-tipped sward. Geometry lives in meadow_clutter.gd.
	_clutter_noise = MEADOW.make_noise()
	var g_mid := MEADOW.build_tuft_mesh(
		GRASS_SHADER,
		_wind_noise_tex,
		Color(0.31, 0.42, 0.20),
		Color(0.10, 0.18, 0.08),
		Vector4(0.30, 7, 0.014, 0.05)
	)
	var g_dark := MEADOW.build_tuft_mesh(
		GRASS_SHADER,
		_wind_noise_tex,
		Color(0.22, 0.33, 0.15),
		Color(0.08, 0.15, 0.07),
		Vector4(0.26, 6, 0.013, 0.045)
	)
	var g_tall := MEADOW.build_tuft_mesh(
		GRASS_SHADER,
		_wind_noise_tex,
		Color(0.55, 0.53, 0.31),
		Color(0.16, 0.25, 0.12),
		Vector4(0.54, 5, 0.012, 0.09)
	)
	# T-085: grab the grass sway materials (one ShaderMaterial per tint, shared across every
	# instance of that MultiMesh) so weather gusts can modulate their wind_strength each frame.
	_collect_foliage_wind_mat(g_mid)
	_collect_foliage_wind_mat(g_dark)
	_collect_foliage_wind_mat(g_tall)
	# T-490 #3: density-FIELD scatter (density=true) — a low-freq noise plus proximity rules bias
	# placement so the meadow is patchy: dense at fence-lines, water/river margins, path VERGES and
	# disturbed ground by dwellings; thin-to-bare on the sheep-cropped commons and worn road margins.
	# Instance count is preserved (one draw call); low-density candidates collapse to zero scale,
	# which is what opens the genuine bare gaps a uniform carpet never had.
	add_child(_scatter(g_mid, 7000, 60.0, rng, 0.8, 1.4, true))
	add_child(_scatter(g_dark, 2600, 58.0, rng, 0.8, 1.45, true))
	add_child(_scatter(g_tall, 1400, 66.0, rng, 0.75, 1.3, true))
	add_child(_scatter(g_mid, 2600, 120.0, rng, 0.8, 1.5, true))
	add_child(_scatter(_rock_mesh(), 90, 130.0, rng, 0.5, 1.8))
	# T-134/T-170 round 8b: meadow colour pops. The old dense wheat + max-saturation flower
	# triangles read as gold "debug pennants" (judge flagged twice) — wheat removed, flowers cut
	# to a sparse, muted, shaded sprinkle.
	add_child(_scatter(_flower_mesh(Color(0.80, 0.74, 0.42)), 12, 105.0, rng, 0.5, 0.7))
	add_child(_scatter(_flower_mesh(Color(0.66, 0.34, 0.34)), 12, 105.0, rng, 0.5, 0.7))
	add_child(_scatter(_flower_mesh(Color(0.72, 0.72, 0.80)), 12, 110.0, rng, 0.6, 0.85))
	# T-406: Ashmoor gutter litter — handbill/newspaper scraps, one MultiMesh (ashmoor_litter.gd)
	add_child(AshmoorLitter.build())


func _scatter(
	mesh: Mesh,
	count: int,
	radius: float,
	rng: RandomNumberGenerator,
	s_min: float,
	s_max: float,
	density := false
) -> MultiMeshInstance3D:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = mesh
	mm.instance_count = count
	for i in range(count):
		var pos := Vector3.ZERO
		var accepted := false
		# Reroll positions on the road corridor (T-146) or in Crystal Lake (T-088) so the path
		# and the open water read clean.
		for _attempt in range(6):
			var angle := rng.randf_range(0.0, TAU)
			var dist := sqrt(rng.randf()) * radius  # even area distribution
			pos = Vector3(cos(angle) * dist, 0.0, sin(angle) * dist)
			# T-190: corridor extended through the village to the north entrance (was z<2.5)
			var road_dx := absf(pos.x - road_center_x(pos.z))
			var in_road_span := pos.z < 27.0 and pos.z > -140.0
			var on_road := road_dx < 3.6 and in_road_span
			var in_lake := Vector2(pos.x, pos.z).distance_to(LAKE_CENTER) < LAKE_RADIUS + 0.5
			# T-185: no tufts through interior floors — reroll inside the street-village plots
			# (hand-listed v3 plot circles; the T-187 sockets/metadata pass should derive these).
			var in_plot := false
			for plot: Vector2 in DWELLING_PLOTS:
				if Vector2(pos.x, pos.z).distance_to(plot) < PLOT_RADIUS:
					in_plot = true
					break
			# T-202: no meadow tufts inside the city circuit (streets, plaza, plots — the
			# city floor is trodden earth; scatter radii don't reach it today, but the
			# guard keeps future radius bumps honest).
			var in_city := hk_in_city(pos.x, pos.z)
			# T-314: reroll off the new branch paths too (a soft margin past the painted
			# edge so tufts don't crowd the dither border).
			var path_d := vp_path_dist(pos.x, pos.z)
			var on_path := path_d < 1.4
			# T-313: no meadow tufts on the farmstead's plowed field/paddock (worn earth).
			var on_farmstead := in_farmstead_rect(pos.x, pos.z)
			# T-342: reroll tufts out of the river channel + its wet banks.
			var river_edge := RIVER_VIEW.dist(pos.x, pos.z) - RIVER_VIEW.RIVER_HALF
			var on_river := river_edge < 1.6
			# T-347: also reroll tufts off the Ashmoor paved district (era-2 offset region).
			if not (
				on_road
				or in_lake
				or in_plot
				or in_city
				or on_path
				or on_farmstead
				or on_river
				or in_ashmoor_district(pos.x, pos.z)
			):
				# T-490: valid ground. Density kinds accept only where the meadow field is high, so
				# sparse commons stay sparse; uniform kinds (rocks/flowers) take the first clear spot.
				var road_off := (road_dx - 3.6) if in_road_span else 999.0
				var d := MEADOW.density(
					pos.x,
					pos.z,
					_clutter_noise,
					LAKE_CENTER,
					LAKE_RADIUS,
					river_edge,
					path_d,
					road_off,
					DWELLING_PLOTS,
					PLOT_RADIUS,
					PADDOCK_RECT
				)
				if not density or rng.randf() < d:
					accepted = true
					break
		pos.y = _terrain_height(pos.x, pos.z)
		# T-490: a density candidate that never cleared the field collapses to zero scale — this is
		# what opens the genuine bare gaps (trampled commons, worn margins) a uniform carpet lacked.
		var scl := 0.0 if (density and not accepted) else rng.randf_range(s_min, s_max)
		var basis := Basis(Vector3.UP, rng.randf_range(0.0, TAU))
		basis = basis.scaled(Vector3.ONE * scl)
		mm.set_instance_transform(i, Transform3D(basis, pos))
	var inst := MultiMeshInstance3D.new()
	inst.name = "Clutter"
	inst.multimesh = mm
	inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return inst


func _flower_mesh(col: Color) -> Mesh:
	# A small four-petal dab: two crossed quads with a bright unshaded color.
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for angle in [0.0, PI / 2.0]:
		var right := Vector3(cos(angle), 0.0, sin(angle)) * 0.12
		var top := Vector3(0.0, 0.20, 0.0)
		st.add_vertex(-right + top * 0.3)
		st.add_vertex(right + top * 0.3)
		st.add_vertex(top)
	st.generate_normals()
	var mesh := st.commit()
	var mat := StandardMaterial3D.new()
	# Shaded (was UNSHADED — that made flowers glow at full saturation regardless of scene
	# light, reading as debug markers). Now they sit in the day/night + zone grade like grass.
	mat.albedo_color = col
	mat.roughness = 1.0
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mesh.surface_set_material(0, mat)
	return mesh


func _rock_mesh() -> Mesh:
	var sphere := SphereMesh.new()
	sphere.radius = 0.28
	sphere.height = 0.38
	sphere.radial_segments = 7
	sphere.rings = 4
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.48, 0.47, 0.44)
	mat.roughness = 1.0
	sphere.material = mat
	return sphere


func _build_lighting() -> void:
	# T-079: warm golden key light (WoW's late-morning sun) + soft sky ambient.
	sun = DirectionalLight3D.new()
	sun.name = "Sun"
	sun.rotation_degrees = Vector3(-48.0, -32.0, 0.0)  # overwritten every frame by _process below
	# T-185: near-white daylight (~5500K) — the PHYSICAL sky supplies dawn/dusk warmth via
	# scattering, so the light color no longer fakes it (the old amber tint double-warmed).
	sun.light_color = Color(1.0, 0.97, 0.92)
	sun.light_energy = 1.9
	sun.shadow_enabled = true
	# T-138: crisper, longer-range shadows so the city + buildings cast real shadows, with a soft
	# PCF edge. 4-split PSSM keeps near detail while reaching the distant skyline.
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	sun.directional_shadow_max_distance = 220.0
	sun.directional_shadow_split_1 = 0.06
	sun.directional_shadow_split_2 = 0.18
	sun.directional_shadow_split_3 = 0.45
	sun.shadow_blur = 1.1
	sun.shadow_bias = 0.04
	add_child(sun)

	world_environment = WorldEnvironment.new()
	world_environment.name = "WorldEnvironment"
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	# T-185 realism (art-direction §5): PHYSICAL sky — Rayleigh/Mie scattering drives sky color,
	# horizon warmth and aerial perspective from the sun elevation (dawn/dusk for free).
	var sky_mat := PhysicalSkyMaterial.new()
	sky_mat.turbidity = 4.0
	sky_mat.rayleigh_coefficient = 2.0
	sky_mat.mie_coefficient = 0.004
	sky_mat.ground_color = Color(0.32, 0.30, 0.26)
	sky_mat.energy_multiplier = 2.6  # AgX's darker response needs a brighter sky dome
	_sky_material = sky_mat  # T-408: era layer mutes the dome inside Ashmoor
	var sky := Sky.new()
	sky.sky_material = sky_mat
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 1.0
	# T-552 night ambient FLOOR colour (night_sky.gd); unused by day (sky_contribution stays 1.0).
	env.ambient_light_color = NIGHT_SKY.NIGHT_AMBIENT_COLOR
	# T-185: AgX tonemap — filmic response (soft highlight rolloff); exposure tuned for AgX's mids.
	env.tonemap_mode = Environment.TONE_MAPPER_AGX
	env.tonemap_exposure = 1.15
	env.adjustment_enabled = true
	env.adjustment_contrast = 1.04
	env.adjustment_saturation = 1.03
	# T-078: modern lighting (Forward+/RTX-class). SSAO contact shading + SDFGI sky/sun bounce GI.
	env.ssao_enabled = true
	# T-169: stronger contact AO seats props/foliage/characters on the ground (were "floating").
	env.ssao_intensity = 2.0
	env.ssao_radius = 1.4
	# T-138: SSIL — colored light bounces off nearby surfaces; pairs with SDFGI for RT-equivalent GI.
	env.ssil_enabled = true
	env.ssil_intensity = 1.0
	env.sdfgi_enabled = true
	env.sdfgi_bounce_feedback = 0.5
	env.sdfgi_read_sky_light = true  # the physical sky feeds GI — interiors get real skylight
	# AAA-spec: subtle VOLUMETRIC fog — light shafts + atmospheric depth (low density; disabled below).
	env.volumetric_fog_enabled = true
	env.volumetric_fog_density = 0.012
	env.volumetric_fog_albedo = Color(0.86, 0.88, 0.92)
	env.volumetric_fog_length = 96.0
	env.volumetric_fog_sky_affect = 0.0
	env.volumetric_fog_ambient_inject = 0.4
	# Blind-judge r3: keep only a whisper of glow + far haze (bloom was eating mid-ground contrast).
	env.glow_enabled = true
	env.glow_intensity = 0.12
	env.glow_bloom = 0.02
	# T-185 (realism judge): real AERIAL PERSPECTIVE — fog_aerial_perspective mutes distance to sky.
	env.fog_enabled = true
	env.fog_light_color = Color(0.75, 0.80, 0.86)
	# T-303: raised from T-201's 0.0010 so distant walls/treeline mute into sky (~35-45% by 200m)
	# while the near meadow (<50m) stays crisp; still short of pea-soup.
	env.fog_density = 0.0026
	env.fog_aerial_perspective = 0.75
	env.fog_sky_affect = 0.0
	# T-138: SSR — Crystal Lake mirrors the sky, treeline, and city.
	env.ssr_enabled = true
	env.ssr_max_steps = 56
	env.ssr_fade_in = 0.2
	env.ssr_fade_out = 3.0
	env.ssr_depth_tolerance = 0.4
	# T-170 (judge round 8b): volumetric haze was the biggest "washed/flat" source — OFF; depth comes
	# from light + distance fog, not a global haze.
	env.volumetric_fog_enabled = false
	# T-170: brightness held at 1.0 so the strong warm key + saturated sky don't blow to white.
	env.adjustment_brightness = 1.0
	env.adjustment_color_correction = ERA_ATMOS.make_zone_lut()  # Blizzard-style zone grade
	world_environment.environment = env
	add_child(world_environment)


# Third-person rig: SpringArm3D (raycasts to keep the camera out of walls) + a Camera3D child.
func _build_camera() -> void:
	camera_arm = SpringArm3D.new()
	camera_arm.name = "CameraArm"
	camera_arm.spring_length = 8.0
	camera_arm.position = Vector3(0.0, 2.0, 0.0)  # ~head height; player attaches here in T-054
	camera_arm.rotation_degrees = Vector3(-25.0, 0.0, 0.0)  # tilt down toward the ground
	camera = Camera3D.new()
	camera.name = "Camera3D"  # SpringArm3D pulls it in to spring_length (or the wall hit)
	camera_arm.add_child(camera)
	add_child(camera_arm)
	camera.current = true


# T-085/T-614: weather — a camera-following rain emitter (built + followed by RainRig; world-
# parented, NOT hung off the preview camera_arm — see rain_rig.gd for the root cause) + a wind
# gust that drives the foliage. Built clear by default; `set_rain(true)` turns on rain + a grey
# overcast fog/ambient dip.
func _build_weather() -> void:
	rain = RAIN_RIG.build()
	add_child(rain)


# Toggle rain on/off (with a matching overcast fog dip). Server-driven weather can call this later.
# The overcast look (fog/ambient) always follows the outdoor truth, even while set_rain_suppressed
# is hiding the actual raindrops indoors — otherwise stepping into a building would visibly clear
# the weather instead of just keeping the player dry.
func set_rain(on: bool) -> void:
	_rain_wanted = on
	_apply_rain_emitting()
	if world_environment != null and world_environment.environment != null:
		var env := world_environment.environment
		env.fog_density = 0.02 if on else 0.0026  # T-303: matches the base aerial-perspective fog
		env.ambient_light_energy = 0.55 if on else 1.0


# T-187: indoor gating — stop rain PARTICLES (only) while the player is inside a building's
# interior volume, without touching the outdoor overcast look. Independent of set_rain() so
# leaving the building simply resumes whatever the weather system already wanted.
func set_rain_suppressed(suppressed: bool) -> void:
	_rain_suppressed = suppressed
	_apply_rain_emitting()


func _apply_rain_emitting() -> void:
	if rain != null:
		rain.emitting = _rain_wanted and not _rain_suppressed


# T-085: register a grass MultiMesh's shared sway material so the weather gust can drive it. One
# ShaderMaterial per tint, shared across every instance, so this is a handful of refs.
func _collect_foliage_wind_mat(mesh: Mesh) -> void:
	if mesh == null:
		return
	var m := mesh.surface_get_material(0)
	if m is ShaderMaterial:
		_foliage_wind_mats.append(m)


# T-734: server truth for the day clock (day_t in handshake_ok, then "world_clock" resyncs).
# Frozen wins: AVALON_FREEZE_DAY is the QA pin pilots rely on — while frozen, server sync is
# ignored entirely (precedence documented in day_clock_sync.gd + the T-734 ticket).
func server_day_sync(t: float) -> void:
	if not _day_frozen:
		_day_t = _day_sync.on_server_day_t(t, _day_t)


# T-137/T-289: day/night cycle — the sun sweeps a true compass arc: rises due EAST (day_t=0),
# crosses due SOUTH at peak elevation (day_t=0.25, noon, N-hemisphere convention), sets due WEST
# (day_t=0.5), then continues below the horizon on the north side through "night" (day_t 0.5-1.0)
# until it rises again. World convention (docs/design/world-conventions.md): -Z=north, +Z=south,
# +X=east, -X=west — matches the pilot's yaw 0=-Z. The sky shader tracks LIGHT0_DIRECTION so the
# sun disc, horizon glow, and clouds follow for free. True night dressing (stars/moon) is T-084.
func _process(delta: float) -> void:
	if sun == null:
		return
	if not _day_frozen:
		# T-734: shared-rate walk + a rate-capped slew toward the last server resync (the old
		# free-run plus gentle correction — same fmod rate, never a visible sun-snap).
		_day_t = _day_sync.advance(_day_t, delta)
	var arc := sin(_day_t * TAU)  # -1..1 over the day; elevation envelope (negative = below horizon)
	var elev_deg := SUN_ELEV_PEAK_DEG * arc
	# Compass azimuth: 90=east (sunrise), 180=south (noon), 270=west (sunset), 360/0=north (midnight).
	var az_deg := 90.0 + 360.0 * _day_t
	# DirectionalLight3D shines along local -Z; with Godot's Ry(yaw)*Rx(pitch) basis, the sun's
	# world position resolves to pitch=-elevation, yaw=180-azimuth (derived once, see T-289 ticket).
	sun.rotation_degrees.x = -elev_deg
	sun.rotation_degrees.y = 180.0 - az_deg
	# T-085: advance the client-local weather cycle (NOT gated by _day_frozen — a frozen sun for QA
	# must not freeze weather). `darkness` 0..1 is how overcast it is; it COOPERATES with the sun arc
	# by multiplying the arc's energy DOWN (never re-deriving or fighting the T-289 arc math). The
	# rain want still gates indoors through the T-187 _rain_suppressed path in _apply_rain_emitting.
	var darkness := 0.0
	if _weather_ctl != null:
		var w := _weather_ctl.tick(delta)
		darkness = float(w["darkness"])
		_rain_wanted = bool(w["rain"])
		_apply_rain_emitting()
	# T-614: park the emitter over whichever camera is LIVE (the preview rig until the player
	# spawns, local_player's rig after takeover) so the emission box/AABB cover the actual view.
	RAIN_RIG.follow(rain, get_viewport().get_camera_3d())
	var overcast_dim := 1.0 - OVERCAST_MAX_AMBIENT_DIP * darkness
	# T-408: advance the per-region blend and overlay the lerped preset on the sun-arc + weather base.
	# era 0 is the identity (scale 1.0, fog floor == base min, smog 0) so the home world is untouched;
	# era 1 (Ashmoor) swaps to the smog read smoothly (no pop).
	_era_blend = ERA_ATMOS.advance(_era_blend, _era_target, ERA_ATMOS_RATE, delta)
	var era := ERA_ATMOS.lerp_preset(ERA_ATMOS.ERA0, ERA_ATMOS.ERA1, _era_blend)
	# T-169/T-170 cool sky-fill (tracks arc); T-085 overcast thickens the T-303 aerial fog.
	var base_ambient := (0.92 + 0.12 * arc) * overcast_dim
	var base_fog := lerpf(0.0026, OVERCAST_MAX_FOG, darkness)
	# T-697 fix 4: every slow look write below (Environment, lamps, cloud tint, water sheen) is a
	# pure function of (sun elevation, overcast darkness, era blend), all of which crawl (a full
	# day is 1200 s). Quantize the drivers and skip the writes while the quantized read holds —
	# 0.1° of sun / 0.5% of overcast / 0.2% of era blend sit far below perception, and re-writing
	# identical values still dirtied render state every frame all day long.
	var look_sig := Vector3(
		snappedf(elev_deg, 0.1), snappedf(darkness, 0.005), snappedf(_era_blend, 0.002)
	)
	var look_changed := look_sig != _look_sig
	_look_sig = look_sig
	if look_changed and world_environment != null and world_environment.environment != null:
		var env := world_environment.environment
		# T-404: a small cool ambient floor lifts the deep-night void so shapes read between lamps
		# (0 by day -> the era-0 daytime ambient is byte-identical; era smog mutes the lift).
		env.ambient_light_energy = (
			base_ambient * float(era["ambient_energy_scale"])
			+ NIGHT_SKY.night_ambient(elev_deg, _era_blend)
		)
		# T-552: fade the ambient off the black night sky onto the flat cool floor (1.0 by day).
		env.ambient_light_sky_contribution = NIGHT_SKY.night_sky_contribution(elev_deg)
		# era fog is a FLOOR over the weather fog: Ashmoor stays dense, heavy rain can still thicken it.
		env.fog_density = maxf(base_fog, float(era["fog_density_floor"]))
		env.fog_light_color = era["fog_light_color"]
		env.fog_aerial_perspective = float(era["fog_aerial_perspective"])
		env.adjustment_saturation = float(era["saturation"])
		_apply_era_lut(float(era["smog"]))
		if _sky_material != null:
			_sky_material.energy_multiplier = float(era["sky_energy"])
	# T-289: fade the sun's contribution out below the horizon (full night stars/moon is T-084/T-137).
	# T-085: overcast also dims the direct sun (clouds over the disc), same bounded multiplier.
	sun.light_energy = (
		1.9
		* clampf(0.15 + 0.85 * smoothstep(-4.0, 6.0, elev_deg), 0.0, 1.0)
		* overcast_dim
		* float(era["sun_energy_scale"])
	)
	# T-614 secondary: a crisp sun shadow under a rain sky reads wrong — fade the shadow with
	# the overcast darkness (clear weather resolves to 1.0, so the sunny look is byte-identical).
	sun.shadow_opacity = 1.0 - OVERCAST_MAX_SHADOW_FADE * darkness

	# T-404: night sky — the moon rides the ANTI-SOLAR arc (half a day offset from the sun, same
	# T-289 elevation/azimuth math), so it rises as the sun sets and peaks at midnight. The dome +
	# moonlight fade in off the SAME sun elevation the direct light uses; overcast (darkness) and the
	# T-408 era blend mute them. era 0 by day: every driver is 0, so the dome/light stay dark.
	if _night_sky != null and camera != null:
		var moon_t := fmod(_day_t + 0.5, 1.0)
		var moon_elev := SUN_ELEV_PEAK_DEG * sin(moon_t * TAU)
		var moon_az := 90.0 + 360.0 * moon_t
		_night_sky.update(
			elev_deg, moon_elev, moon_az, darkness, _era_blend, camera.global_position
		)

	# T-298: street lights (lamppost lanterns, plaza/gate braziers) fade in as the sun drops so the
	# capital reads as a lived-in, lit city at dusk/night instead of going dark and dead. Driven off
	# the same sun elevation the direct light uses — off by day, full after sunset. The lights are
	# attached engine-side in WorldPropsLayer and carry their lit energy in "base_energy" meta.
	# T-697 fix 4: the lamp writes fire only when the quantized night factor moved (dusk/dawn) or
	# the cached lamp list changed (prop streaming) — all day/all night they used to rewrite every
	# lamp's energy + visible every frame.
	var night := clampf(1.0 - smoothstep(-3.0, 7.0, elev_deg), 0.0, 1.0)
	var night_q := snappedf(night, 0.002)
	if _night_lights_dirty:
		_night_lights = get_tree().get_nodes_in_group("night_lights")
		_night_lights_dirty = false
		_night_shown = -1.0  # fresh/streamed-in lamps need the current level applied
	if night_q != _night_shown:
		_night_shown = night_q
		for lt in _night_lights:
			# T-619: every night light is an OmniLight3D now; the Light3D cast stays future-proof.
			var ol := lt as Light3D
			if ol == null:
				continue
			ol.light_energy = float(ol.get_meta("base_energy", 2.0)) * night
			ol.visible = night > 0.02

	if look_changed:
		# T-441: water sky sheen follows the sun arc (overcast-dimmed) — no milky glow at night.
		WATER_VIEW.day_tick(_water_mats, elev_deg, overcast_dim)
		# T-303: cloud deck tint — warm near the horizon (dawn/dusk), neutral at midday. T-417:
		# then dim toward the moonlit grey as the sun drops, off the SAME night_factor the T-404
		# night sky uses — exactly 0 by day, so the daytime look is byte-unchanged (a no-op lerp).
		var dusk_warmth := clampf(1.0 - absf(elev_deg) / SUN_ELEV_PEAK_DEG, 0.0, 1.0)
		var cloud_tint := Color(1.0, 1.0, 1.0).lerp(Color(1.08, 0.86, 0.68), dusk_warmth * 0.55)
		cloud_tint = cloud_tint.lerp(CLOUD_NIGHT_TINT, NIGHT_SKY.night_factor(elev_deg))
		for mat: StandardMaterial3D in _cloud_materials:
			mat.albedo_color = cloud_tint
	for cloud: MeshInstance3D in _clouds:
		cloud.position.x += delta * float(cloud.get_meta("drift_speed"))
		if cloud.position.x > 380.0:
			cloud.position.x -= 760.0


# T-408: the region hook. EraSkin (main.gd's throttled tick) forwards the SAME era it resolves for
# the VFX + held-focus re-skin; here it just sets the tween target. _process does the smooth blend.
func set_era_atmosphere(era_id: int) -> void:
	_era_target = 1.0 if era_id >= 1 else 0.0


# T-408: rebuild the grade LUT only when the quantized smog step changes (a 17^3 loop is too heavy
# per frame). smog 0 -> step 0 -> base zone grade, so era 0 never rebuilds after the initial one.
func _apply_era_lut(smog: float) -> void:
	var step := int(round(clampf(smog, 0.0, 1.0) * ERA_LUT_STEPS))
	if step == _era_lut_step:
		return
	_era_lut_step = step
	if world_environment != null and world_environment.environment != null:
		var lut := ERA_ATMOS.make_zone_lut(float(step) / float(ERA_LUT_STEPS))
		world_environment.environment.adjustment_color_correction = lut


func get_camera() -> Camera3D:
	return camera
