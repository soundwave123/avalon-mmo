class_name TerrainField
extends RefCounted

# T-132/T-287/T-309/T-327/T-445: the single source of truth for the vale's terrain height field,
# shared by WorldView (the rendered ground mesh), scripts/dev/terrain_height_probe.gd (the
# world-audit / reseat oracle), AND the world server (byte-identical copy under
# server/world/scripts, enforced by scripts/check_shared_files_sync.sh).
#
# T-445 (walkable relief): T-327 made this field the server's ground authority (movement stays
# planar; height derives from (x, z) on every side, never the wire), so the walked floor no longer
# needs to be flat. The land now carries gentle pastoral relief (2-6 m rolling rises/hollows)
# EVERYWHERE except protected FLAT PADS under the built clusters — rigid multi-metre GLBs (city
# walls, greybox, keep, bridge, crypt, arena) are seated at one terrain_y and need level ground:
#   core        — the village circle (main street, farmstead, Crystal Lake)
#   city rect   — Highkeep's full circuit + apron (walls/greybox/keep are one-piece GLBs)
#   ward pad    — the King's Road bridge + poor-ward cottages north of the gate
#   crypt/arena/ashmoor — the offset-region set pieces at (±420, 0) / (0, 420)
# Between the village and the bridge pad the King's Road DIPS through a shallow swale (the road
# follows a contour instead of striping across a lawn), and the T-342 river runs in a CARVED BED
# (~0.5 m below the y=0.06 water plane) with cut banks — suppressed under the bridge piers and at
# the wall base so those T-342 seatings stay honest. Relief amplitude fades in the far coarse-mesh
# band and hands off to the T-309 mountain ring beyond the ±500 clamp box.

const LAKE_CENTER := Vector2(18.0, 22.0)
const LAKE_RADIUS := 12.0
const BOUND := 500.0  # ServerConfig.BOUNDS_MIN/MAX — the hard clamp the mountain ring hides

# T-559 training-yard dry pad: the lake shore bowl's 17 m skirt crossed the T-444 yard footprint
# (q_tut_01 ring 14,10; dummy 10,10; effigy 16,10; trainers 14,7/16,7) and sank the whole yard
# 0.03-0.41 m below the y=0.06 water plane — every fresh player q_tut_01 sent to the ring stood
# in drowning water. The pad suppresses the bowl over the yard rect and lifts it to a gentle dry
# rise, so the ground only falls toward the lake NE of the rail. KEEP IN SYNC with
# q_tut_01_first_steps.json loc_training_ring, npcs.json trainer anchors + the t444 props block.
const YARD_CENTER := Vector2(12.5, 9.0)
const YARD_HALF := Vector2(5.5, 4.0)  # covers x 7..18, z 5..13 — the walked yard footprint
const YARD_BLEND := 5.0  # smoothstep skirt back to the open shore/meadow
const YARD_RISE := 0.24  # pad grade: 0.18 m clear of the 0.06 water plane

# T-445: river centerline for the bed carve. KEEP IN SYNC with river_view.gd RIVER_PTS,
# terrain_splat.gdshader RIV_SEG and scripts/world-audit.py RIVER (the T-342 three-way sync).
const RIVER_PTS: Array = [
	[57.0, -382.0],
	[54.0, -362.0],
	[44.0, -300.0],
	[34.0, -256.0],
	[26.0, -218.0],
	[23.0, -210.0],
	[21.0, -175.0],
	[19.0, -140.0],
	[18.0, -112.0],
	[5.2, -109.0],
	[-10.0, -107.0],
	[-30.0, -100.0],
	[-52.0, -92.0],
]

var _noise: FastNoiseLite
var _mound: FastNoiseLite

# T-590: the terrain-region table — each region owns an ORIGIN and a heightfield SAMPLER; height()
# routes a world (x, z) to the NEAREST region origin (the T-371 nearest-anchor idiom) and calls that
# region's sampler. MIRROR of server/world/data/regions/regions.json's origins + terrain.sampler,
# kept a plain member here (NOT a file load) so this shared/pure field stays dependency-free +
# byte-identical across the client & server copies — the same rule broadcast_builder.gd
# REGION_ANCHORS follows; test_world_regions asserts the two agree. T-593 authors the phase-1
# regions on this seam: (1) the Wold / Heartwold (origin 0,0) KEEPS "wold_legacy" (the pre-T-590
# absolute field) so its dressed core stays byte-identical; (2) the Ashmoor March / Ashmoor City
# (origin -420,0) is the FIRST sampler swap — "ashmoor_flat" is byte-identical to legacy inside the
# dressed spike hull and in the far mountain-rim band, diverging to era-2 urban flat only in the
# newly-walkable mid band (migration invariant airtight, proven by test_terrain_field GOLDEN_GRID);
# (3) Greyrise (era 3) is a NEW far region at (0,-1400) with its own "greyrise_flat" field (modern
# arrival flat + the Old Keep heritage rise), reachable by rift only in P1. The nearest-origin scan
# is O(regions) (3 today) and dwarfed by the FastNoiseLite lookups, so no per-call cache is
# warranted; a spatial index is a P2 concern only if the region count grows large.
var _regions: Array = []


func _init() -> void:
	_regions = [
		{"origin": Vector2(0.0, 0.0), "sampler": "wold_legacy"},  # the Wold / Heartwold (era 1)
		{"origin": Vector2(-420.0, 0.0), "sampler": "ashmoor_flat"},  # Ashmoor City (era 2)
		{"origin": Vector2(0.0, -1400.0), "sampler": "greyrise_flat"},  # Greyrise Reach (era 3)
	]
	_noise = FastNoiseLite.new()  # T-132 near-scale rolling hills
	_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	_noise.fractal_octaves = 4
	_noise.frequency = 0.008
	_noise.seed = 20260703
	_mound = FastNoiseLite.new()  # T-287 broad low-frequency swells/hollows
	_mound.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_mound.fractal_type = FastNoiseLite.FRACTAL_FBM
	_mound.fractal_octaves = 3
	_mound.frequency = 0.0032
	_mound.seed = 20260710


# Axis-aligned rect SDF distance (0 inside): |x-cx|<=hx and |z-cz|<=hz reads 0.
static func _rect_d(x: float, z: float, cx: float, cz: float, hx: float, hz: float) -> float:
	var dx := maxf(absf(x - cx) - hx, 0.0)
	var dz := maxf(absf(z - cz) - hz, 0.0)
	return Vector2(dx, dz).length()


# Distance to the river centerline polyline (>=0). Mirrors river_view.gd dist().
func _river_d(x: float, z: float) -> float:
	var p := Vector2(x, z)
	var best := 1e9
	for i in range(RIVER_PTS.size() - 1):
		var a := Vector2(RIVER_PTS[i][0], RIVER_PTS[i][1])
		var ab := Vector2(RIVER_PTS[i + 1][0], RIVER_PTS[i + 1][1]) - a
		var t: float = clampf((p - a).dot(ab) / ab.dot(ab), 0.0, 1.0)
		best = minf(best, p.distance_to(a + ab * t))
	return best


# T-590: register an extra terrain region at runtime (a future zone with its OWN heightfield, or the
# test-only toy region that proves the dispatch generalizes). Production ships only the two _init
# regions; nothing calls this on the live path, so height() stays byte-identical in prod.
# T-590: the origins of the seeded regions — for the test that asserts this const mirror agrees with
# server/world/data/regions/regions.json (the two tables can never silently drift).
func region_origins() -> Array:
	var out: Array = []
	for r in _regions:
		out.append(r["origin"])
	return out


func register_region(origin: Vector2, sampler: String, params: Dictionary = {}) -> void:
	var entry := {"origin": origin, "sampler": sampler}
	for k in params:
		entry[k] = params[k]
	_regions.append(entry)


# T-590: dispatch by nearest region origin, then sample that region's heightfield. Both shipped
# regions name "wold_legacy" (the absolute pre-T-590 field), so every real-world point returns
# _legacy_height(x, z) — byte-identical to the pre-T-590 height().
func height(x: float, z: float) -> float:
	var r: Dictionary = _regions[_nearest_region(x, z)]
	return _sample(str(r["sampler"]), x, z, r)


func _nearest_region(x: float, z: float) -> int:
	var best := 0
	var best_d2: float = INF
	for i in _regions.size():
		var o: Vector2 = _regions[i]["origin"]
		var dx := x - o.x
		var dz := z - o.y
		var d2 := dx * dx + dz * dz
		if d2 < best_d2:
			best_d2 = d2
			best = i
	return best


# Per-sampler heightfield. "wold_legacy" is the shared pre-T-590 world field at ABSOLUTE coords (the
# Wold / Heartwold); "ashmoor_flat" + "greyrise_flat" are the T-593 era-2/era-3 fields (authored in
# zone-LOCAL coords around their own origin); "flat" is a dead-level plane at base_y (the toy / a
# stub). Unknown samplers degrade to the legacy field so a mistyped table can't punch a ground hole.
func _sample(sampler: String, x: float, z: float, r: Dictionary) -> float:
	match sampler:
		"flat":
			return float(r.get("base_y", 0.0))
		"ashmoor_flat":
			var oa: Vector2 = r["origin"]
			return _ashmoor_height(x, z, oa.x, oa.y)
		"greyrise_flat":
			var og: Vector2 = r["origin"]
			return _greyrise_height(x, z, og.x, og.y)
		_:
			return _legacy_height(x, z)


# T-593 Ashmoor City (era-2 gaslight, origin -420,0) — the first sampler SWAP. The migration
# invariant is enforced HERE and is airtight: the region owns everything west of the wold/ashmoor
# seam (x < -210), and the pre-T-593 world was clamped to the global ±500 box, so the WHOLE
# pre-T-593-reachable Ashmoor area (and every golden-grid sample over it, out to x = -480) is
# x >= -500. This sampler is byte-identical to _legacy_height for x >= -500 AND in the far rim band
# beyond the region's own ±550 m clamp (the T-309 mountain/fog rim + the shipped [-620,-620] world-
# edge fixture). It diverges to a low-amplitude era-2 urban flat (a shallow canal quarter) ONLY in
# the NEW western district opened by the ±550 m clamp raise (x < -500), blending smoothly out of
# legacy at the old clamp line and back into the legacy rim near the boundary — no ledge, and no
# existing test point or authored placement ever lands on the divergence.
func _ashmoor_height(x: float, z: float, ox: float, oz: float) -> float:
	var legacy := _legacy_height(x, z)
	var lx := x - ox
	var lz := z - oz
	# west gate: 0 for x >= -500 (byte-identical legacy over the whole pre-T-593-reachable +
	# golden-grid-covered area), ramping to 1 by x = -560 in the new western district.
	var west := smoothstep(-500.0, -560.0, x)
	# rim gate: fade the divergence back into the legacy mountain/fog rim as the ±550 clamp boundary
	# nears, so the world edge rises smoothly and the far rim/fixtures stay exactly legacy.
	var rim := smoothstep(470.0, 550.0, maxf(absf(lx), absf(lz)))
	var w := west * (1.0 - rim)  # divergence weight; exactly 0 east of -500 and at/beyond the rim
	if w <= 0.0:
		return legacy
	var un := 0.35 * _noise.get_noise_2d(x, z)  # era-2 urban flat: gentle sub-metre undulation
	var canal := -0.5 * (1.0 - smoothstep(5.0, 15.0, absf(lz - 30.0)))  # a shallow canal cut, z~30
	return lerpf(legacy, un + canal, w)


# T-593 Greyrise Reach (era-3 modern, NEW far region at 0,-1400) — a fresh sampler with no legacy
# to preserve. Modern arrival-district flat (concrete/asphalt, minimal relief) with the Old Keep
# heritage rise at the region origin (Highkeep's bones a century on — the era-continuity landmark),
# and a T-587 rising rim beyond the ±560 m clamp so the world ends on a hazy rise, never grey void.
func _greyrise_height(x: float, z: float, ox: float, oz: float) -> float:
	var lx := x - ox
	var lz := z - oz
	var h := 0.4 * _noise.get_noise_2d(x, z)  # modern flat: near-level ground
	var keep_d := Vector2(lx, lz).length()  # Old Keep heritage-site mound at the origin
	h += 3.5 * (1.0 - smoothstep(24.0, 78.0, keep_d))
	var rx := maxf(absf(lx) - 560.0, 0.0)
	var rz := maxf(absf(lz) - 560.0, 0.0)
	var rim := smoothstep(0.0, 130.0, Vector2(rx, rz).length())  # rises only past the clamp box
	h += 62.0 * rim
	return h


func _legacy_height(x: float, z: float) -> float:
	# Flat pads under the built clusters (rigid one-piece GLBs need level seats).
	var d_core := maxf(Vector2(x, z).length() - 62.0, 0.0)
	# T-199: Highkeep circuit + apron protected flat (rect SDF) like the village core.
	var d_city := _rect_d(x, z, 0.0, -240.0, 130.0, 110.0)
	# T-445: bridge deck/ramps (T-342, z -98..-127.5) + the poor-ward cottages share one pad.
	var d_ward := _rect_d(x, z, 0.0, -116.0, 21.0, 24.0)
	# T-445: offset-region set pieces — Hollowed Crypt, PvP arena, Ashmoor district.
	var d_crypt := _rect_d(x, z, 420.0, 0.0, 40.0, 40.0)
	var d_arena := _rect_d(x, z, 0.0, 420.0, 40.0, 40.0)
	var d_ash := _rect_d(x, z, -420.0, 3.0, 48.0, 30.0)
	var d := minf(d_core, minf(d_city, d_ward))
	d = minf(d, minf(d_crypt, minf(d_arena, d_ash)))
	var edge := smoothstep(0.0, 45.0, d)  # 0 inside pads -> 1 in the open meadow
	var n := _noise.get_noise_2d(x, z)
	var m := _mound.get_noise_2d(x, z)
	# T-445 rolling relief across the whole walked band (was faded flat past r=330 pre-T-327).
	# Damped in the far band where the ground mesh grid goes coarse (16 m steps) so the render
	# and collision never stray far from the analytic field out there.
	var amp := 1.0 - 0.65 * smoothstep(240.0, 420.0, Vector2(x, z).length())
	var h := ((0.8 + 5.2 * edge) * maxf(n, -0.35) * edge + 2.4 * edge * m) * amp
	# T-445 King's Road swale: between the village edge and the bridge pad the road corridor dips
	# through a shallow hollow (the winding road reads as following a valley floor, and Highkeep's
	# gate front sits above the approach). Gated tighter than the noise skirt so the dip actually
	# develops inside the short corridor, but still exactly 0 on every pad.
	var swale_gate := smoothstep(0.0, 14.0, d)
	var lat := 1.0 - smoothstep(18.0, 80.0, absf(x - 2.0))
	var lon := smoothstep(30.0, 68.0, -z) * (1.0 - smoothstep(88.0, 108.0, -z))
	h -= 1.4 * lat * lon * swale_gate
	# T-287 low backdrop ridge behind Highkeep (z<-352, past the south wall/props, never walked).
	var ridge := smoothstep(352.0, 396.0, -z)
	h += (6.0 + 2.0 * m) * ridge
	# T-309 mountain ring: rises only OUTSIDE the ±500 box (box-exceed distance), where the server
	# clamp already stops the player, so the world ends on a hazy mountain wall (T-303 aerial
	# perspective desaturates it) instead of an invisible wall over open ground.
	var ox := maxf(absf(x) - BOUND, 0.0)
	var oz := maxf(absf(z) - BOUND, 0.0)
	var mtn := smoothstep(0.0, 130.0, Vector2(ox, oz).length())
	h += (78.0 + 28.0 * m) * mtn
	# Crystal Lake shore bowl (visual only; the water plane sits just above y=0). T-559: gated by
	# the training-yard dry pad — the bowl resumes NE of the rail, so the shore falls to the water
	# only past the yard edge (a dry bank under the tutorial ring, never a drowned floor).
	var lake_d := Vector2(x, z).distance_to(LAKE_CENTER)
	var bowl := 0.55 * (1.0 - smoothstep(LAKE_RADIUS * 0.4, LAKE_RADIUS + 5.0, lake_d))
	var yard_d := _rect_d(x, z, YARD_CENTER.x, YARD_CENTER.y, YARD_HALF.x, YARD_HALF.y)
	var dry := 1.0 - smoothstep(0.0, YARD_BLEND, yard_d)
	h += YARD_RISE * dry - bowl * (1.0 - dry)
	# T-445 river bed carve (T-441 cut banks): the channel floor sits ~0.5 m under the y=0.06
	# water plane. Narrow through the pads (the poor-ward cottages stand 4.6 m off the centerline)
	# and wider-banked in the open meadow. Suppressed at the wall base (T-342: water meets the
	# wall, no arch cut) and under the bridge so its piers keep their honest grade-0 seat.
	var riv := _river_d(x, z)
	var half_bed := lerpf(3.2, 4.2, edge)
	var bank_w := lerpf(1.6, 4.5, edge)
	var cut := 1.0 - smoothstep(half_bed, half_bed + bank_w, riv)
	cut *= smoothstep(3.0, 9.0, absf(z + 140.0))  # wall-base band
	cut *= smoothstep(10.0, 16.0, Vector2(x - 5.2, z + 109.0).length())  # bridge pier zone
	return lerpf(h, -0.5, cut)
