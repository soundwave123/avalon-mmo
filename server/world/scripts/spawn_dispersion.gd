# T-373: spawn & quest-hub dispersion — capacity lever 4 (after AOI T-370, region bucketing
# T-371, delta T-372). Those levers cut broadcast cost for DISTRIBUTED play, but the T-355 spike
# proved they give ZERO relief in a crowd (§2a "THE CATCH"): every fresh login landed on world
# origin (main.gd start_pos = Vector3.ZERO), so the whole population piled into one 80 m AOI cell,
# K == N, and AOI could not dissolve the hotspot. The residual cost is SAME-SPOT CLUSTERING. This
# module spreads logins across hubs so the spawn crowd is broken up at the source.
#
# Server-authoritative & fail-closed. Hubs are AUTHORED DATA (res://data/regions/spawn_points.json),
# each VALIDATED once at boot against the two oracles the server already trusts:
#   1. TERRAIN FIELD — a hub must sit on flat walkable ground (|height| <= flat_eps), never a slope
#      where the flat gameplay plane would float/sink (terrain_field.gd's core invariant).
#   2. movement_collision (T-379) — a hub must NOT sit inside the curtain wall or a building
#      footprint
#      (point_inside == false), so dispersion can never drop a player inside geometry.
# An invalid hub is dropped; if EVERY hub is invalid pick() returns origin — degrading to the
# pre-T-373 clustering, never to "spawn in a wall".
#
# Pure / injectable core (candidates + oracles + rng passed in) so it unit-tests headlessly; the
# static boot() wires the live terrain field, barriers, data file, and the AVALON_SPAWN_FIXED
# escape hatch (truthy pins every login to origin so piloted harnesses stay stable). Selection is
# round-robin over the hubs (even spread independent of the rng) plus a small in-hub jitter.
#
# T-527 (population-adaptive spawn density): at target population T-373's full dispersion breaks up
# the login crowd; at friends-and-family scale (single digits concurrent) that SAME dispersion
# inverts — the few active players are scattered across a gigantic map and a newcomer never sees
# another human in hour 1, starving relatedness (the charter's strongest retention lever). Fix: the
# round-robin fans over only the FIRST `active_hub_count(concurrency)` validated hubs. Below a
# low-pop threshold this collapses to a single shared hub (fresh players land near each other); each
# further block of concurrent players (LOW_POP_STEP) unlocks another hub, monotonically, until the
# whole validated set is in play again at target population and full T-373 dispersion is restored.
# This is invisible + power-neutral (no reward for grouping, no penalty for soloing) and, because it
# only ever draws from the already-validated `_hubs` set, EVERY T-515 mob-safe property holds at
# every population level. concurrency < 0 (unknown) => full dispersion, so old callers don't change.

extends RefCounted

const _SC = preload("res://scripts/server_config.gd")
const _TF = preload("res://scripts/terrain_field.gd")
const _WR = preload("res://scripts/world_regions.gd")  # T-590: region-aware bounds oracle
const _SPAWN_FILE := "res://data/regions/spawn_points.json"

# T-527 default density knobs. LOW_POP_THRESHOLD: at/below this live count, collapse to one shared
# hub. LOW_POP_STEP: each additional block of this many concurrent players unlocks one more hub, so
# full dispersion is restored at LOW_POP_THRESHOLD + STEP*(hub_count-1) concurrent players (13 for
# the shipped 4 hubs — comfortably inside the "low-tens" F&F target).
const LOW_POP_THRESHOLD := 4
const LOW_POP_STEP := 4

var _hubs: Array[Vector2] = []  # validated hub anchors, planar (x, z)
var _jitter: float
var _next: int = 0  # round-robin cursor over _hubs
var _fixed: bool = false  # AVALON_SPAWN_FIXED — pin every login to origin (harness hatch)
var _terrain: Callable = Callable()  # ground-height oracle for the picked point's z
var _low_pop_threshold: int = LOW_POP_THRESHOLD
var _low_pop_step: int = LOW_POP_STEP
# T-590: region-aware bounds oracle — a hub must sit inside its region's clamp envelope. Null (not
# injected — the pure-core unit tests) falls back to the flat ±500 box, so validation is unchanged.
var _regions = null


# candidates: Array of [x, z] (or Vector2) hub anchors. terrain_height: Callable(x, z) -> float
# (invalid skips the flat check). collision: object with point_inside(x, z) -> bool (null skips the
# geometry check). jitter: in-hub scatter radius (m). flat_eps: max |terrain height| for "flat".
# regions: a WorldRegions (T-590) for the per-region bounds test (null -> the global ±500 box).
func _init(
	candidates: Array,
	terrain_height: Callable = Callable(),
	collision = null,
	jitter: float = 6.0,
	flat_eps: float = 0.6,
	regions = null
) -> void:
	_regions = regions
	_jitter = maxf(jitter, 0.0)
	_terrain = terrain_height
	for c in candidates:
		var p := _to_v2(c)
		if _is_valid(p, terrain_height, collision, flat_eps):
			_hubs.append(p)
		else:
			push_warning("[spawn] rejected hub (%.1f, %.1f) — off-ground/in geometry" % [p.x, p.y])


# Live wiring: load the hub data, build the terrain oracle + read the escape hatch, validate against
# the injected barriers. Returns a ready SpawnDispersion (used by main.gd in one line).
static func boot(collision) -> Object:
	var terrain = _TF.new()
	var sd = load("res://scripts/spawn_dispersion.gd").new(
		load_hubs(_SPAWN_FILE), Callable(terrain, "height"), collision, 6.0, 0.6, _WR.load_default()
	)
	var env := str(OS.get_environment("AVALON_SPAWN_FIXED")).to_lower()
	sd.set_fixed(env in ["1", "true", "yes", "on"])
	print("[world] spawn dispersion: %d hubs (fixed=%s)" % [sd.hub_count(), str(sd.is_fixed())])
	return sd


func set_fixed(fixed: bool) -> void:
	_fixed = fixed


func is_fixed() -> bool:
	return _fixed


# The login spawn point as a Vector3 in PlayerSessions convention (x = planar x, y = planar z,
# z = ground height). Origin when AVALON_SPAWN_FIXED is set or no hub validated (fail-closed).
# T-527: concurrency is the live count of players ALREADY online (server-authoritative, from
# main.gd's _connected_players). The round-robin fans over only the first active_hub_count()
# validated hubs so a low-pop world clusters newcomers; concurrency < 0 => full dispersion.
func pick(rng: RandomNumberGenerator, concurrency: int = -1) -> Vector3:
	if _fixed or _hubs.is_empty():
		return Vector3.ZERO
	var active: int = active_hub_count(concurrency)
	var hub: Vector2 = _hubs[_next % active]
	_next += 1
	return _jittered(hub, rng)


# T-706: FIRST-EVER character spawn — always the first validated hub (the authored hub[0] anchor,
# the only one inside the 55 m marker horizon of the Drillmaster), never the round-robin. At 5+
# concurrency pick() unlocks hubs 63-115 m from the tutorial giver, which strands a guided newcomer
# with zero on-screen wayfinding. Returning logins keep full T-373/T-527 dispersion via pick().
# Fail-closed exactly like pick(): AVALON_SPAWN_FIXED or an empty validated set -> origin.
func pick_first_hub(rng: RandomNumberGenerator) -> Vector3:
	if _fixed or _hubs.is_empty():
		return Vector3.ZERO
	return _jittered(_hubs[0], rng)


# T-527 pure core: how many of the validated hubs fresh logins fan across at this concurrency.
# Monotonic non-decreasing in concurrency, clamped to [1, hub_count]. concurrency < 0 (unknown) or
# at/above full-dispersion population => all hubs (T-373 target); at/below the low-pop threshold =>
# one shared hub (newcomers cluster). Every returned count is a prefix of the validated `_hubs`, so
# the T-515 mob-safe invariant holds regardless of population.
func active_hub_count(concurrency: int) -> int:
	var n: int = _hubs.size()
	if n <= 1:
		return n
	if concurrency < 0:
		return n  # unknown concurrency -> full dispersion (backward compatible)
	if concurrency <= _low_pop_threshold:
		return 1
	var unlocked: int = (
		1 + int(ceil(float(concurrency - _low_pop_threshold) / float(_low_pop_step)))
	)
	return clampi(unlocked, 1, n)


# T-527: override the population-density knobs (tests / tuning). step is floored at 1.
func set_density_knobs(low_pop_threshold: int, low_pop_step: int) -> void:
	_low_pop_threshold = maxi(low_pop_threshold, 0)
	_low_pop_step = maxi(low_pop_step, 1)


func hub_count() -> int:
	return _hubs.size()


# --- internals ----------------------------------------------------------------
# Uniform pick over the hub's jitter disc, in PlayerSessions convention (x, planar z, ground).
func _jittered(hub: Vector2, rng: RandomNumberGenerator) -> Vector3:
	var a := rng.randf() * TAU
	var r := sqrt(rng.randf()) * _jitter  # sqrt -> uniform over the disc, no center bias
	var x := hub.x + cos(a) * r
	var z := hub.y + sin(a) * r
	var ground: float = _terrain.call(x, z) if _terrain.is_valid() else 0.0
	return Vector3(x, z, ground)


func _is_valid(p: Vector2, terrain_height: Callable, collision, flat_eps: float) -> bool:
	# T-590: region-aware bounds (else the flat ±500 fallback). Today every region is the ±500 box.
	if _regions != null:
		if not _regions.in_bounds(p.x, p.y):
			return false
	elif (
		p.x < _SC.BOUNDS_MIN or p.x > _SC.BOUNDS_MAX or p.y < _SC.BOUNDS_MIN or p.y > _SC.BOUNDS_MAX
	):
		return false
	if terrain_height.is_valid() and absf(float(terrain_height.call(p.x, p.y))) > flat_eps:
		return false
	if collision != null and collision.has_method("point_inside"):
		if collision.point_inside(p.x, p.y):
			return false
	return true


func _to_v2(c) -> Vector2:
	if c is Vector2:
		return c
	if c is Array and c.size() >= 2:
		return Vector2(float(c[0]), float(c[1]))
	return Vector2.ZERO


# Load hub anchors from spawn_points.json ({"hubs":[[x,z],...]}); [] on missing/malformed so the
# caller falls back to origin.
static func load_hubs(path: String) -> Array:
	if not FileAccess.file_exists(path):
		push_warning("[spawn] no spawn_points file at %s — origin fallback" % path)
		return []
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return []
	var doc = JSON.parse_string(f.get_as_text())
	if typeof(doc) != TYPE_DICTIONARY or not (doc.get("hubs", null) is Array):
		push_warning("[spawn] malformed %s (need hubs array)" % path)
		return []
	return doc["hubs"]
