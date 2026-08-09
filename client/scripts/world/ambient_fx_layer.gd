class_name AmbientFxLayer
extends Node3D

# T-139: ambient particle FX that make the vale feel ALIVE (pairs with the T-111 ambience): warm
# pollen/dust motes drifting through the meadow, soft smoke rising from the village chimneys, and
# glowing embers + firelight at the campfire. All GPUParticles3D built in code (no .tscn), so the
# STRUCTURE is headlessly unit-testable; the look is play-test-verified.

# T-209 audio zones — data-driven, headless-testable structure. Each zone is a named
# circle on the city/village plan; zones_at() answers "what should the mix play here".
# T-305 fills in the recorded beds (gen_audio.py, procedural/licence-free) and adds VILLAGE
# zones (the starting village had none), then plays each zone from a positional
# AudioStreamPlayer3D emitter (build_emitters) so the mix cross-fades as the player walks —
# layered UNDER the T-111 meadow bed as placed accents, not a single global track.
# Each entry: name, centre (x,z on the world plan), radius r, stream (res:// WAV), optional
# vol (emitter base dB, default _ZONE_DEFAULT_DB) and day (true = daytime-gated; fades at night).
const _AUD := "res://assets/audio/"
const CROWD := _AUD + "amb_crowd.wav"
const FORGE := _AUD + "amb_forge.wav"
const BELL := _AUD + "amb_bell.wav"
const MILL := _AUD + "amb_mill.wav"
const BIRDSONG := _AUD + "amb_birdsong.wav"
const ROOMTONE := _AUD + "amb_roomtone.wav"
# T-409 Ashmoor (Era-2) period beds — no birdsong/meadow leaks across the rift.
const GASLAMP := _AUD + "amb_gaslamp.wav"
const TRAM := _AUD + "amb_tram.wav"
const SPEAKEASY := _AUD + "amb_speakeasy.wav"
const WIREWIND := _AUD + "amb_wirewind.wav"
# T-675 living-environment beds — the coverage that froze at the village/city: the T-587 boundary
# treeline, night forest accents, water (lake/river), the worked places built since T-209
# (T-605 farmstead, Gorran's forge reuses FORGE, the T-630 Highkeep inn), and the T-629 monster
# territories. Sparse accents (owl hoots, wolf yips, cluck trains) are baked INTO the loops
# (the cathedral_bell idiom), so every zone stream stays a loop-ON bed.
const LEAFWIND := _AUD + "amb_leafwind.wav"
const NIGHTFOREST := _AUD + "amb_nightforest.wav"
const LAKE := _AUD + "amb_lake.wav"
const RIVER := _AUD + "amb_river.wav"
const FARM := _AUD + "amb_farm.wav"
const INN := _AUD + "amb_inn.wav"
const WOLFPACK := _AUD + "amb_wolfpack.wav"
const THICKET := _AUD + "amb_thicket.wav"
const INSECTS := _AUD + "amb_insectdrone.wav"
const _ZONE_DEFAULT_DB := -20.0  # placed accents sit under the T-111 meadow bed (base -17 dB)
# T-409: era tags. The medieval world is ERA 1; the Ashmoor district is ERA 2. A zone's "era"
# (default ERA_MEDIEVAL) is matched against the LISTENER's resolved era (in_ashmoor_district) so a
# cross-era bed fades to silence — birdsong/meadow never leak into 1920s Ashmoor, and vice versa.
const ERA_MEDIEVAL := 1
const ERA_ASHMOOR := 2
# cross-era beds are dimmed by this much (≈inaudible), mirroring the T-305 night-gate dimming.
const ERA_MISMATCH_ATTEN_DB := -60.0
# T-675: a "day" zone fades toward silence at night by this much at full night; a "night" zone
# (crickets' zonal cousins: owl forest, gas-lamp hiss) inverts the same gate — silent by day.
const DAY_GATE_ATTEN_DB := -50.0
# T-675 item 6: the T-305 indoor muffle now reaches the positional beds too — zones tagged
# "interior" (the inn: its murmur IS the indoors) are exempt. KEEP IN SYNC with
# AudioManager.AMBIENT_INDOOR_MUFFLE_DB (test_ambient_fx asserts the pin).
const ZONE_INDOOR_MUFFLE_DB := -12.0
const AUDIO_ZONES: Array = [
	# --- Highkeep (T-209 structure, T-305 recordings) — ERA 1 (default) ---
	{"name": "square_crowd", "x": 0.0, "z": -215.0, "r": 26.0, "stream": CROWD, "day": true},
	{"name": "smithy_hammer", "x": 31.0, "z": -228.0, "r": 18.0, "stream": FORGE},
	{"name": "cathedral_bell", "x": -76.0, "z": -282.0, "r": 60.0, "stream": BELL, "vol": -15.0},
	{"name": "ward_quiet", "x": -72.0, "z": -190.0, "r": 34.0, "stream": ROOMTONE, "vol": -26.0},
	{"name": "ward_quiet_e", "x": 74.0, "z": -196.0, "r": 32.0, "stream": ROOMTONE, "vol": -26.0},
	# --- starting village (T-305 new; coords from client/assets/props.json) — ERA 1 (default) ---
	{"name": "village_forge", "x": -6.5, "z": -8.5, "r": 14.0, "stream": FORGE},
	{"name": "village_market", "x": 2.5, "z": 8.0, "r": 16.0, "stream": CROWD, "day": true},
	{"name": "watermill", "x": 26.0, "z": 26.0, "r": 16.0, "stream": MILL},
	{"name": "treeline_n", "x": 2.0, "z": -40.0, "r": 34.0, "stream": BIRDSONG, "day": true},
	{"name": "treeline_e", "x": 33.0, "z": -23.0, "r": 22.0, "stream": BIRDSONG, "day": true},
	# --- Ashmoor 1920s district (T-409 new) — ERA 2; coords from data/regions/ashmoor.json. All sit
	# inside the ASHMOOR_SOOT_RECT era-detection footprint (the arrival plaza + High Street terraces)
	# so the era gate engages where the player actually stands; no birdsong/meadow, 1920s register. ---
	{"name": "ashmoor_tram", "x": -421.0, "z": 6.0, "r": 30.0, "stream": TRAM, "era": ERA_ASHMOOR},
	{
		"name": "ashmoor_wirewind",
		"x": -420.0,
		"z": 4.0,
		"r": 32.0,
		"stream": WIREWIND,
		"era": ERA_ASHMOOR,
		"vol": -24.0
	},
	{
		"name": "ashmoor_speakeasy",
		"x": -423.75,
		"z": 8.0,
		"r": 11.0,
		"stream": SPEAKEASY,
		"era": ERA_ASHMOOR,
		"vol": -22.0
	},
	# T-675/T-619 pairing: the lamps LIGHT at night, so their hiss is night-gated now too.
	{
		"name": "ashmoor_gaslamp_w",
		"x": -429.0,
		"z": 2.5,
		"r": 6.0,
		"stream": GASLAMP,
		"era": ERA_ASHMOOR,
		"vol": -26.0,
		"night": true
	},
	{
		"name": "ashmoor_gaslamp_e",
		"x": -412.0,
		"z": -8.0,
		"r": 6.0,
		"stream": GASLAMP,
		"era": ERA_ASHMOOR,
		"vol": -26.0,
		"night": true
	},
	# --- T-675 living environment — worked places built since T-209 (coords from props/NPC data) ---
	{
		"name": "farmstead_paddock",
		"x": 45.0,
		"z": -42.0,
		"r": 16.0,
		"stream": FARM,
		"day": true,
		"vol": -22.0
	},
	{"name": "gorran_forge", "x": -24.0, "z": -110.0, "r": 14.0, "stream": FORGE},
	{
		"name": "highkeep_inn",
		"x": 22.0,
		"z": -98.0,
		"r": 12.0,
		"stream": INN,
		"vol": -22.0,
		"interior": true
	},
	# --- T-675 water: Crystal Lake south shore (T-659 fishing spot) + the King's Road river ford ---
	{"name": "lake_shore", "x": 18.0, "z": 10.0, "r": 12.0, "stream": LAKE, "vol": -21.0},
	{"name": "river_ford", "x": 5.2, "z": -109.0, "r": 14.0, "stream": RIVER, "vol": -23.0},
	{"name": "river_bend", "x": 19.0, "z": -140.0, "r": 12.0, "stream": RIVER, "vol": -23.0},
	# --- T-675 monster territories (T-629 den ranges; coords match server spawns.json) — subtle
	# unease accents, not jump scares: the "alive and not all of it friendly" read. ---
	{"name": "greymaw_range", "x": 48.0, "z": 40.0, "r": 18.0, "stream": WOLFPACK, "vol": -23.0},
	{
		"name": "bloodthorn_thicket",
		"x": -33.0,
		"z": -27.5,
		"r": 16.0,
		"stream": THICKET,
		"vol": -23.0
	},
	{
		"name": "elderthorn_grove",
		"x": -50.0,
		"z": -45.0,
		"r": 16.0,
		"stream": INSECTS,
		"vol": -24.0
	},
	# --- T-675 boundary treeline (T-587 conifer band, radius 462-486 around origin): leaf-rustle
	# circles at radius ~474 on the compass points, denser on the north arc (the Wolfswold-facing
	# edge). Night forest accents (owl/wolf) overlay the north arc + the village treeline after
	# dark ("night": the inverted day gate). ---
	{
		"name": "boundary_forest_n",
		"x": 0.0,
		"z": -474.0,
		"r": 60.0,
		"stream": LEAFWIND,
		"vol": -22.0
	},
	{
		"name": "boundary_forest_nne",
		"x": 163.0,
		"z": -445.0,
		"r": 60.0,
		"stream": LEAFWIND,
		"vol": -22.0
	},
	{
		"name": "boundary_forest_nnw",
		"x": -163.0,
		"z": -445.0,
		"r": 60.0,
		"stream": LEAFWIND,
		"vol": -22.0
	},
	{
		"name": "boundary_forest_ne",
		"x": 335.0,
		"z": -335.0,
		"r": 60.0,
		"stream": LEAFWIND,
		"vol": -22.0
	},
	{
		"name": "boundary_forest_nw",
		"x": -335.0,
		"z": -335.0,
		"r": 60.0,
		"stream": LEAFWIND,
		"vol": -22.0
	},
	{
		"name": "boundary_forest_e",
		"x": 474.0,
		"z": 0.0,
		"r": 60.0,
		"stream": LEAFWIND,
		"vol": -22.0
	},
	{
		"name": "boundary_forest_w",
		"x": -474.0,
		"z": 0.0,
		"r": 60.0,
		"stream": LEAFWIND,
		"vol": -22.0
	},
	{
		"name": "boundary_forest_s",
		"x": 0.0,
		"z": 474.0,
		"r": 60.0,
		"stream": LEAFWIND,
		"vol": -22.0
	},
	{
		"name": "boundary_forest_se",
		"x": 335.0,
		"z": 335.0,
		"r": 60.0,
		"stream": LEAFWIND,
		"vol": -22.0
	},
	{
		"name": "boundary_forest_sw",
		"x": -335.0,
		"z": 335.0,
		"r": 60.0,
		"stream": LEAFWIND,
		"vol": -22.0
	},
	{
		"name": "nightwood_n",
		"x": 0.0,
		"z": -474.0,
		"r": 60.0,
		"stream": NIGHTFOREST,
		"night": true,
		"vol": -22.0
	},
	{
		"name": "nightwood_ne",
		"x": 335.0,
		"z": -335.0,
		"r": 60.0,
		"stream": NIGHTFOREST,
		"night": true,
		"vol": -22.0
	},
	{
		"name": "nightwood_nw",
		"x": -335.0,
		"z": -335.0,
		"r": 60.0,
		"stream": NIGHTFOREST,
		"night": true,
		"vol": -22.0
	},
	{
		"name": "nightwood_village",
		"x": 2.0,
		"z": -40.0,
		"r": 34.0,
		"stream": NIGHTFOREST,
		"night": true,
		"vol": -24.0
	},
]
# source height above the (roughly flat, y~0) village ground; play-test tunable
const _EMITTER_Y := 2.0
# T-697 fix 8: the per-emitter dB derivation runs at ~10 Hz, not per frame — the gates it tracks
# (day clock, listener era, indoor muffle) move over seconds, and volume_db steps at 100 ms are
# inaudible. Seeded so the FIRST _process tick still applies immediately (test/boot parity).
const _VOLUME_TICK_S := 0.1

# T-310: a few birds crossing overhead so the sky isn't inert — cheap unshaded billboards on wide
# looping circuits, culled at distance (T-210). Paths are hand-picked to sweep over the village/
# meadow rather than the city (a flock over Highkeep's towers reads odd at this density).
const _BIRD_PATHS: Array = [
	{"center": Vector3(10.0, 42.0, 15.0), "radius": 40.0, "height": 5.0, "speed": 0.045},
	{"center": Vector3(-18.0, 46.0, 5.0), "radius": 30.0, "height": 4.0, "speed": -0.06},
	{"center": Vector3(30.0, 38.0, -10.0), "radius": 22.0, "height": 3.0, "speed": 0.08},
]
const _BIRD_CULL_DISTANCE := 260.0

var particle_count: int = 0  # headless-test accessor
var smoke_count: int = 0  # T-209 headless-test accessor (socket-derived smoke columns)
var rift_count: int = 0  # T-407 headless-test accessor (socket-derived rift shimmer + motes)
var bird_count: int = 0  # T-310 headless-test accessor (sky birds crossing overhead)
var emitter_count: int = 0  # T-305 headless-test accessor (positional zone emitters built)
var _birds: Array = []  # [{node, center, radius, height, speed, phase}] — see _birds_flock()
var _emitters: Array = []  # T-305/T-409/T-675: [{node, base_db, day, night, interior, era}]
var _indoor_muffle_db := 0.0  # T-675 item 6: the T-305 indoor muffle, extended to the zone beds
var _vol_accum := _VOLUME_TICK_S  # T-697 fix 8: volume-tick accumulator (born due)


static func zones_at(x: float, z: float) -> Array:
	var hits: Array = []
	for zone in AUDIO_ZONES:
		var dx: float = x - float(zone["x"])
		var dz: float = z - float(zone["z"])
		if dx * dx + dz * dz <= float(zone["r"]) * float(zone["r"]):
			hits.append(str(zone["name"]))
	return hits


# T-305: fail-closed validation — a zone must have a non-empty stream and a positive radius, or it
# is DROPPED (no silent/zero-radius emitter). Pure + static so the data contract is unit-testable.
static func valid_zones(zones: Array = AUDIO_ZONES) -> Array:
	var out: Array = []
	for zone in zones:
		if not (zone is Dictionary):
			continue
		if not zone.has("stream") or str(zone.get("stream", "")).strip_edges() == "":
			continue
		if float(zone.get("r", 0.0)) <= 0.0:
			continue
		out.append(zone)
	return out


# T-409: a zone's era tag (default ERA_MEDIEVAL). Pure so the data contract is unit-testable.
static func zone_era(zone: Dictionary) -> int:
	return int(zone.get("era", ERA_MEDIEVAL))


# T-409: the era a listener at (x,z) hears — ERA_ASHMOOR inside the district, else ERA_MEDIEVAL.
# Rides the SAME detector as EraSkin/atmosphere (WorldView.in_ashmoor_district) — not a second one.
static func resolved_era(x: float, z: float) -> int:
	return ERA_ASHMOOR if WorldView.in_ashmoor_district(x, z) else ERA_MEDIEVAL


# T-409: the era-gate attenuation (dB) applied to a bed of era `bed_era` when the listener is in
# `listener_era` — 0 when they match, a deep dim otherwise. Mirrors the T-305 night-gate dimming so
# a single term layers onto the base level. Same shape drives the global meadow/city-hum gate.
static func era_gate_atten(bed_era: int, hearer_era: int) -> float:
	return 0.0 if bed_era == hearer_era else ERA_MISMATCH_ATTEN_DB


# T-409: resolve the listener's era from the active Camera3D (the audio listener). Falls back to
# ERA_MEDIEVAL with no camera (headless tests / no viewport), so the medieval beds default on.
static func listener_era(any_node: Node) -> int:
	if any_node == null or not any_node.is_inside_tree():
		return ERA_MEDIEVAL
	var vp := any_node.get_viewport()
	var cam := vp.get_camera_3d() if vp != null else null
	if cam == null:
		return ERA_MEDIEVAL
	var p := cam.global_position
	return resolved_era(p.x, p.z)


func _ready() -> void:
	# T-185 (realism judge): the pollen motes read as "floating white sprite artifacts" against
	# the physical sky — a stylized-era effect, retired. (Function kept; a subtle dust pass can
	# return with the weather work if the look earns it.)
	#_motes()
	# T-209: chimney smoke is SOCKET-DRIVEN — WorldPropsLayer groups every socket_chimney
	# it places; we smoke a deterministic subset once props finish loading (deferred:
	# props and ambient layers are siblings, _ready order is not guaranteed). The three
	# hand-placed village coords are retired — their GLBs now carry sockets.
	_discover_chimneys.call_deferred()
	# T-407: the era-rift monolith's aperture VFX are socket-driven the same way — the GLB ships
	# a socket_rift empty, WorldPropsLayer groups it, we hang the shimmer + motes off it (both
	# the crypt Vault and the Ashmoor arrival plaza instances get dressed by one code path).
	_discover_rifts.call_deferred()
	# T-190: traveler's fire off the road at the north village entrance.
	_campfire(Vector3(-5.5, 0.25, 19.5))
	# T-310: a bird or two crossing the sky — the meadow read as silent-still otherwise.
	_birds_flock()
	# T-305: positional zone ambience — one AudioStreamPlayer3D per valid zone, so the mix
	# cross-fades between the forge, market, watermill, treeline and city as the player walks.
	build_emitters()
	# T-675 item 6: AudioManager fans the T-187 indoor muffle out to this layer via this group.
	add_to_group("ambience_layers")


func _process(delta: float) -> void:
	# T-305: day-gate the daytime beds (market crowd, birdsong) — fade them toward silence at night.
	# T-409: ALSO era-gate every bed — a bed whose era ≠ the listener's era fades to silence, so the
	# medieval beds die inside Ashmoor and the Ashmoor beds die outside it. Both are additive dB terms
	# on the base level. Cheap: one sin() off the day clock + one rect test at the camera.
	_vol_accum += delta  # T-697 fix 8: dB writes at ~10 Hz (see _VOLUME_TICK_S)
	if not _emitters.is_empty() and _vol_accum >= _VOLUME_TICK_S:
		_vol_accum = 0.0
		var day := _day_factor()
		var here := listener_era(self)
		for e: Dictionary in _emitters:
			var enode: AudioStreamPlayer3D = e["node"]
			var vol := float(e["base_db"]) + era_gate_atten(int(e["era"]), here)
			if e["day"]:
				# DAY_GATE_ATTEN_DB below base at full night ≈ inaudible; smooth across dusk/dawn.
				vol += (1.0 - day) * DAY_GATE_ATTEN_DB
			if e["night"]:
				# T-675: the inverted gate — owl wood / gas-lamp hiss fade toward silence by day.
				vol += day * DAY_GATE_ATTEN_DB
			if not e["interior"]:
				# T-675 item 6: walls dampen the outdoor beds while indoors; the inn's own murmur
				# (tagged interior) is exempt — it IS the indoors the player is standing in.
				vol += _indoor_muffle_db
			enode.volume_db = vol
	# T-310: birds fly a simple closed loop (no per-frame allocations — just trig on cached state).
	for b: Dictionary in _birds:
		var cfg: Dictionary = b["cfg"]
		b["phase"] += float(cfg["speed"]) * delta
		var phase: float = b["phase"]
		var center: Vector3 = cfg["center"]
		var radius: float = cfg["radius"]
		var node: Node3D = b["node"]
		node.position = (
			center
			+ Vector3(
				cos(phase) * radius, sin(phase * 2.3) * float(cfg["height"]), sin(phase) * radius
			)
		)
		# Face the direction of travel so it reads as flying, not sliding.
		var tangent := Vector3(-sin(phase), 0.0, cos(phase)) * signf(float(cfg["speed"]))
		if tangent.length() > 0.001:
			node.rotation.y = atan2(tangent.x, tangent.z)


# T-209: smoke every village chimney and roughly half the city's — not every hearth is
# lit at once, and ~40 emitters is the particle budget. Deterministic pick (position
# hash) so screenshots reproduce.
func _discover_chimneys() -> void:
	for sock in get_tree().get_nodes_in_group("chimney_sockets"):
		if not (sock is Node3D):
			continue
		var gp: Vector3 = (sock as Node3D).global_position
		var lit := true
		if gp.z < -136.0:  # inside the city circuit: ~55% of hearths lit
			lit = int(absf(gp.x * 7.31 + gp.z * 3.77)) % 9 < 5
		if lit:
			_smoke(gp)
			smoke_count += 1


# T-407: dress every grouped rift socket (see world_props_layer.gd socket_rift branch) with the
# aperture shimmer + drifting motes. Children of the SOCKET, not this layer, so both monolith
# placements (crypt Vault + Ashmoor plaza, any rotation) line up with the carved aperture for
# free. Allocation-at-build-time only — the motes are GPU-driven (ParticleProcessMaterial) and
# the shimmer is a static emissive plane, so nothing here ever ticks in _process.
func _discover_rifts() -> void:
	for sock in get_tree().get_nodes_in_group("rift_sockets"):
		if not (sock is Node3D):
			continue
		_rift_fx(sock as Node3D)
		rift_count += 1


func _rift_fx(sock: Node3D) -> void:
	# The shimmer membrane: a soft-edged unshaded additive plane filling the torn aperture
	# (frost_lance_lib recipe — a bare additive quad reads as a hard-edged square, T-183/T-343).
	# QuadMesh lies in the local XY plane, exactly the aperture plane of the exported monolith
	# (width across X, height up Y, faces ±Z = the walk-up axis); cull is disabled so the gate
	# reads from both eras' sides.
	var q := QuadMesh.new()
	q.size = Vector2(0.5, 2.15)
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.disable_receive_shadows = true
	var grad := Gradient.new()
	grad.set_offsets(PackedFloat32Array([0.0, 0.55, 1.0]))
	grad.set_colors(
		PackedColorArray([Color(1, 1, 1, 0.85), Color(1, 1, 1, 0.4), Color(1, 1, 1, 0.0)])
	)
	var tex := GradientTexture2D.new()
	tex.gradient = grad
	tex.fill = GradientTexture2D.FILL_RADIAL
	tex.fill_from = Vector2(0.5, 0.5)
	tex.fill_to = Vector2(1.0, 0.5)
	tex.width = 64
	tex.height = 64
	m.albedo_texture = tex
	m.albedo_color = Color(0.55, 0.85, 1.0)
	m.emission_enabled = true
	m.emission = Color(0.30, 0.72, 1.0)
	m.emission_energy_multiplier = 1.8
	q.material = m
	var shimmer := MeshInstance3D.new()
	shimmer.name = "RiftShimmer"
	shimmer.mesh = q
	shimmer.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	shimmer.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	sock.add_child(shimmer)
	# The drifting motes: cold sparks bleeding out of the tear and rising — GPU-side motion,
	# zero script per-frame cost. preprocess so the rift is never seen empty on arrival.
	var proc := ParticleProcessMaterial.new()
	proc.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	proc.emission_box_extents = Vector3(0.45, 1.1, 0.3)
	proc.direction = Vector3(0.0, 1.0, 0.0)
	proc.spread = 40.0
	proc.initial_velocity_min = 0.06
	proc.initial_velocity_max = 0.22
	proc.gravity = Vector3(0.0, 0.05, 0.0)
	proc.scale_min = 0.6
	proc.scale_max = 1.4
	proc.color_ramp = _ramp(
		[
			[0.0, Color(0.55, 0.9, 1.0, 0.0)],
			[0.3, Color(0.45, 0.8, 1.0, 0.8)],
			[1.0, Color(0.5, 0.4, 1.0, 0.0)],
		]
	)
	var motes := GPUParticles3D.new()
	motes.name = "RiftMotes"
	motes.amount = 26
	motes.lifetime = 6.0
	motes.preprocess = 6.0
	motes.draw_pass_1 = _billboard(0.07, true, true)
	motes.process_material = proc
	motes.visibility_aabb = AABB(Vector3(-3, -2, -3), Vector3(6, 8, 6))
	motes.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	sock.add_child(motes)


# T-305: build a positional AudioStreamPlayer3D per VALID zone (fail-closed via valid_zones), each
# looping its bed and attenuating over the zone radius so beds cross-fade as the player moves. The
# active Camera3D is the listener; levels sit under the T-111 meadow bed. Day-tagged zones (market,
# birdsong) are gated in _process. Idempotent-guarded so a double _ready never double-stacks.
func build_emitters() -> void:
	if not _emitters.is_empty():
		return
	for zone: Dictionary in valid_zones():
		var stream := load(str(zone["stream"])) as AudioStream
		if stream == null:
			continue  # fail-closed: a missing/bad asset drops the emitter, never a silent one
		if stream is AudioStreamWAV:
			(stream as AudioStreamWAV).loop_mode = AudioStreamWAV.LOOP_FORWARD
		var radius := float(zone["r"])
		var base_db := float(zone.get("vol", _ZONE_DEFAULT_DB))
		var e := AudioStreamPlayer3D.new()
		e.name = "Zone_" + str(zone["name"])
		e.stream = stream
		e.position = Vector3(float(zone["x"]), _EMITTER_Y, float(zone["z"]))
		e.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
		e.unit_size = radius  # ~full level inside the zone circle, then rolls off
		e.max_distance = radius * 2.4  # hard cull well outside so distant zones don't bleed/cost
		e.max_db = 0.0  # never boost above the emitter's own level when very close
		# T-409: born at the era-gated level (a cross-era bed starts silent — no one-frame leak);
		# _process re-derives the gate every frame as the listener moves.
		e.volume_db = base_db + era_gate_atten(zone_era(zone), listener_era(self))
		e.autoplay = true
		add_child(e)
		e.play()
		_emitters.append(
			{
				"node": e,
				"base_db": base_db,
				"day": bool(zone.get("day", false)),
				"night": bool(zone.get("night", false)),
				"interior": bool(zone.get("interior", false)),
				"era": zone_era(zone)
			}
		)
		emitter_count += 1


# T-675 item 6: the T-305 indoor muffle reaches the positional beds — invoked via the
# "ambience_layers" group from AudioManager.set_indoor_muffle (no new main.gd call site; main.gd
# sits at the 1000-line cap). _process folds the term into every non-interior emitter.
func set_indoor_muffle(indoors: bool) -> void:
	_indoor_muffle_db = ZONE_INDOOR_MUFFLE_DB if indoors else 0.0


# T-305: daylight factor in [0,1] read from the world day clock (WorldView._day_t, our parent at
# runtime) WITHOUT editing the visual-lane world_view.gd — the sun is above the horizon when
# sin(day_t*TAU) > 0. Falls back to full daylight (1.0) when there's no day source (headless tests).
func _day_factor() -> float:
	var p := get_parent()
	if p == null:
		return 1.0
	var dt = p.get("_day_t")
	if dt == null:
		return 1.0
	return clampf(smoothstep(-0.05, 0.25, sin(float(dt) * TAU)), 0.0, 1.0)


# --- shared builders --------------------------------------------------------
func _billboard(size: float, add: bool, soft := false) -> QuadMesh:
	var q := QuadMesh.new()
	q.size = Vector2(size, size)
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	m.billboard_keep_scale = true
	m.vertex_color_use_as_albedo = true  # per-particle colour/alpha ramp drives the look
	m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD if add else BaseMaterial3D.BLEND_MODE_MIX
	m.disable_receive_shadows = true
	if soft:
		# T-183: bare quads read as squares once particles get big (the vista judge's "render
		# artifact" smears were quad edges). Feather with a radial alpha falloff.
		var grad := Gradient.new()
		grad.set_offsets(PackedFloat32Array([0.0, 0.45, 1.0]))
		grad.set_colors(
			PackedColorArray([Color(1, 1, 1, 1), Color(1, 1, 1, 0.55), Color(1, 1, 1, 0.0)])
		)
		var tex := GradientTexture2D.new()
		tex.gradient = grad
		tex.fill = GradientTexture2D.FILL_RADIAL
		tex.fill_from = Vector2(0.5, 0.5)
		tex.fill_to = Vector2(0.5, 0.0)
		tex.width = 64
		tex.height = 64
		m.albedo_texture = tex
	q.material = m
	return q


func _ramp(stops: Array) -> GradientTexture1D:
	var g := Gradient.new()
	g.offsets = []
	var offs := PackedFloat32Array()
	var cols := PackedColorArray()
	for s in stops:
		offs.append(s[0])
		cols.append(s[1])
	g.set_offsets(offs)
	g.set_colors(cols)
	var t := GradientTexture1D.new()
	t.gradient = g
	return t


func _emit(
	amount: int, lifetime: float, pos: Vector3, mesh: Mesh, proc: ParticleProcessMaterial
) -> GPUParticles3D:
	var p := GPUParticles3D.new()
	p.amount = amount
	p.lifetime = lifetime
	p.position = pos
	p.draw_pass_1 = mesh
	p.process_material = proc
	p.preprocess = lifetime  # start mid-flight so nothing pops in
	p.visibility_aabb = AABB(Vector3(-90, -10, -90), Vector3(180, 70, 180))  # never frustum-cull
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(p)
	particle_count += 1
	return p


# --- the three effects ------------------------------------------------------
func _motes() -> void:
	var proc := ParticleProcessMaterial.new()
	proc.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	proc.emission_box_extents = Vector3(62.0, 6.0, 62.0)
	proc.direction = Vector3(0.3, 1.0, 0.15)
	proc.spread = 55.0
	proc.initial_velocity_min = 0.08
	proc.initial_velocity_max = 0.32
	proc.gravity = Vector3(0.0, 0.02, 0.0)
	proc.scale_min = 0.7
	proc.scale_max = 1.8
	proc.color = Color(1.0, 0.93, 0.68, 0.7)  # warm sunlit pollen
	_emit(300, 11.0, Vector3(0.0, 3.0, 6.0), _billboard(0.09, true), proc)


func _smoke(pos: Vector3, tint := Color(0.71, 0.71, 0.74), peak := 0.15, amount := 16) -> void:
	var proc := ParticleProcessMaterial.new()
	proc.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	proc.emission_sphere_radius = 0.22  # rounder base, not a point-source
	proc.direction = Vector3(0.1, 1.0, 0.0)
	proc.spread = 26.0
	proc.initial_velocity_min = 0.18
	proc.initial_velocity_max = 0.42
	proc.gravity = Vector3(0.14, 0.18, 0.04)  # slow rise + downwind lean (widening plume)
	proc.scale_min = 1.0
	proc.scale_max = 1.9
	var head := tint  # fade in from invisible
	head.a = 0.0
	var body := tint  # softest visible peak, later in life
	body.a = peak
	var tail := tint.darkened(0.08)  # ages a touch darker, fades out
	tail.a = 0.0
	proc.color_ramp = _ramp([[0.0, head], [0.35, body], [1.0, tail]])
	# T-183: bigger/slower/wider/longer + a softer ramp so each particle reads as a drifting
	# puff, not the thin bright vertical streak the vista judge flagged (wisp up close, per T-172).
	_emit(amount, 7.5, pos, _billboard(1.8, false, true), proc)


func _birds_flock() -> void:
	for cfg: Dictionary in _BIRD_PATHS:
		var bird := MeshInstance3D.new()
		bird.mesh = _bird_mesh()
		bird.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		bird.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
		bird.visibility_range_end = _BIRD_CULL_DISTANCE  # T-210: distant sky critter, not full-time
		add_child(bird)
		_birds.append({"node": bird, "cfg": cfg, "phase": randf_range(0.0, TAU)})
		bird_count += 1


# A small flat "M" silhouette (two wing planes meeting at the body) — cheap, no texture needed;
# reads as a bird speck at the distances it's actually seen from.
func _bird_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_color(Color(0.08, 0.08, 0.09))
	var w := 0.5
	var pts := [
		Vector3(-w, 0.0, 0.0),
		Vector3(0.0, 0.08, 0.0),
		Vector3(w, 0.0, 0.0),
		Vector3(0.0, -0.03, 0.12),
	]
	for tri in [[0, 1, 3], [1, 2, 3]]:
		for i in tri:
			st.add_vertex(pts[i])
	var mesh := st.commit()
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.vertex_color_use_as_albedo = true
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mesh.surface_set_material(0, mat)
	return mesh


func _campfire(pos: Vector3) -> void:
	var proc := ParticleProcessMaterial.new()
	proc.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	proc.emission_sphere_radius = 0.22
	proc.direction = Vector3(0.0, 1.0, 0.0)
	proc.spread = 26.0
	proc.initial_velocity_min = 0.9
	proc.initial_velocity_max = 1.9
	proc.gravity = Vector3(0.0, -1.1, 0.0)  # embers rise, cool, and fall
	proc.scale_min = 0.5
	proc.scale_max = 1.1
	proc.color_ramp = _ramp(
		[
			[0.0, Color(1.0, 0.66, 0.25, 1.0)],
			[0.5, Color(1.0, 0.42, 0.12, 0.9)],
			[1.0, Color(0.7, 0.18, 0.05, 0.0)],
		]
	)
	_emit(30, 1.6, pos, _billboard(0.06, true), proc)
	# firelight
	var light := OmniLight3D.new()
	light.position = pos + Vector3(0.0, 0.6, 0.0)
	light.light_color = Color(1.0, 0.6, 0.28)
	light.light_energy = 2.2
	light.omni_range = 7.0
	light.shadow_enabled = false
	add_child(light)
