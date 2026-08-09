extends GutTest
# T-373: spawn & quest-hub dispersion (capacity lever 4). Proves the pure spawn-point selector that
# breaks the (0,0) login pileup AOI can't dissolve (T-355 spike §2a). Covered here:
#   - hubs validate against the terrain oracle (flat ground) and movement_collision (T-379: not
#     inside a wall/footprint) — a bad candidate is dropped, never picked;
#   - an all-invalid set fails CLOSED to origin (pre-T-373 clustering, never a bad placement);
#   - round-robin picks fan a login burst across every valid hub (spread >> AOI radius);
#   - the pick lands within the jitter disc of its hub, in PlayerSessions convention (x, z, ground);
#   - point_inside (the geometry oracle) reads inside a closed footprint and outside open ground.

const _SD = preload("res://scripts/spawn_dispersion.gd")
const _MCOL = preload("res://scripts/movement_collision.gd")
const _TF = preload("res://scripts/terrain_field.gd")


func _flat(_x: float, _z: float) -> float:  # a perfectly flat terrain oracle
	return 0.0


func _rng(seed_val: int = 42) -> RandomNumberGenerator:
	var r := RandomNumberGenerator.new()
	r.seed = seed_val
	return r


# --- validation: flat-ground + geometry oracles drop bad hubs --------------------------------
func test_flat_ground_oracle_drops_sloped_hubs() -> void:
	# oracle: (0,0) flat, (100,100) a 5 m slope -> only the flat hub survives.
	var oracle := func(x, _z): return 0.0 if x < 50.0 else 5.0
	var sd = _SD.new([[0.0, 0.0], [100.0, 100.0]], oracle, null, 6.0, 0.6)
	assert_eq(sd.hub_count(), 1, "the sloped hub is rejected by the terrain oracle")


func test_geometry_oracle_drops_hubs_inside_a_footprint() -> void:
	# a closed 20x20 building rect at (200,0); a hub at its centre is inside, one outside isn't.
	var col = _MCOL.new("")  # no data file -> empty, then add one footprint
	col.add_rect(Vector2(200.0, 0.0), Vector2(10.0, 10.0), 0.0, [])
	var sd = _SD.new([[200.0, 0.0], [0.0, 0.0]], Callable(self, "_flat"), col, 6.0, 0.6)
	assert_eq(sd.hub_count(), 1, "the hub inside the building footprint is rejected")


func test_out_of_bounds_hub_rejected() -> void:
	var sd = _SD.new([[9000.0, 0.0], [0.0, 0.0]], Callable(self, "_flat"), null, 6.0, 0.6)
	assert_eq(sd.hub_count(), 1, "a hub beyond the world bounds is rejected")


# --- fail-closed: no valid hub -> origin -----------------------------------------------------
func test_all_invalid_falls_back_to_origin() -> void:
	var oracle := func(_x, _z): return 9.0  # everything is a cliff
	var sd = _SD.new([[0.0, 0.0], [10.0, 10.0]], oracle, null)
	assert_eq(sd.hub_count(), 0, "no hub validated")
	assert_eq(sd.pick(_rng()), Vector3.ZERO, "fails closed to origin (pre-T-373 behaviour)")


# --- dispersion: round-robin fans a burst across every hub -----------------------------------
func test_round_robin_covers_all_hubs() -> void:
	var hubs := [[0.0, 34.0], [40.0, -18.0], [-36.0, 18.0], [0.0, -90.0]]
	var sd = _SD.new(hubs, Callable(self, "_flat"), null, 6.0)
	var seen := {}
	var rng := _rng()
	for i in hubs.size():
		var p := sd.pick(rng)
		# nearest hub to the pick
		var best := 0
		var best_d := INF
		for h in range(hubs.size()):
			var d := Vector2(p.x, p.y).distance_to(Vector2(hubs[h][0], hubs[h][1]))
			if d < best_d:
				best_d = d
				best = h
		seen[best] = true
		assert_lt(best_d, 6.001, "pick %d lands within its hub's jitter disc" % i)
	assert_eq(seen.size(), hubs.size(), "a 4-login burst covered all 4 hubs (no origin pileup)")


func _ground(_x: float, _z: float) -> float:  # a nonzero flat ground (still within flat_eps)
	return 0.25


func test_pick_uses_playersessions_convention_and_ground() -> void:
	# terrain returns a nonzero ground so we assert pick().z carries it (x=planar x, y=planar z).
	var sd = _SD.new([[12.0, -8.0]], Callable(self, "_ground"), null, 0.0)  # zero jitter -> exact hub
	var p := sd.pick(_rng())
	assert_almost_eq(p.x, 12.0, 0.001, "pick.x is planar x")
	assert_almost_eq(p.y, -8.0, 0.001, "pick.y is planar z")
	assert_almost_eq(p.z, 0.25, 0.001, "pick.z is the derived ground height")


# --- T-527: population-adaptive spawn density ------------------------------------------------
# The 4 mob-safe hubs (T-515). Every population-adaptive pick must stay a subset of these.
func _pop_hubs() -> Array:
	return [[0.0, 34.0], [40.0, -18.0], [-36.0, 18.0], [0.0, -90.0]]


func _nearest_hub(p: Vector3, hubs: Array) -> int:
	var best := 0
	var best_d := INF
	for h in range(hubs.size()):
		var d := Vector2(p.x, p.y).distance_to(Vector2(hubs[h][0], hubs[h][1]))
		if d < best_d:
			best_d = d
			best = h
	return best


func test_low_concurrency_collapses_to_one_shared_hub() -> void:
	# At/below the low-pop threshold a burst of fresh logins all land on the SAME shared hub, so
	# newcomers actually see each other (the T-527 relatedness fix).
	var hubs := _pop_hubs()
	var sd = _SD.new(hubs, Callable(self, "_flat"), null, 6.0)
	assert_eq(sd.active_hub_count(0), 1, "empty world -> a single shared hub")
	assert_eq(sd.active_hub_count(4), 1, "at the low-pop threshold still one shared hub")
	var rng := _rng()
	var seen := {}
	# a login burst while the online count stays at/below the threshold (conc 0..4) -> all cluster.
	for i in range(5):
		var p := sd.pick(rng, i)
		seen[_nearest_hub(p, hubs)] = true
	assert_eq(
		seen.size(), 1, "a low-concurrency burst clustered on ONE hub (players land together)"
	)


func test_high_concurrency_restores_full_dispersion() -> void:
	# At target population every validated hub is back in the round-robin (T-373 behaviour restored).
	var hubs := _pop_hubs()
	var sd = _SD.new(hubs, Callable(self, "_flat"), null, 6.0)
	assert_eq(sd.active_hub_count(64), hubs.size(), "high pop -> all hubs (full dispersion)")
	var rng := _rng()
	var seen := {}
	for _i in range(hubs.size()):
		var p := sd.pick(rng, 64)
		seen[_nearest_hub(p, hubs)] = true
	assert_eq(seen.size(), hubs.size(), "high-concurrency burst fanned across every hub")


func test_active_hub_count_is_monotonic_in_population() -> void:
	# As simulated population rises the number of active hubs never decreases and spans 1..hub_count.
	var sd = _SD.new(_pop_hubs(), Callable(self, "_flat"), null, 6.0)
	var prev := 0
	for conc in range(0, 40):
		var n: int = sd.active_hub_count(conc)
		assert_true(n >= prev, "active hub count is monotonic non-decreasing at conc=%d" % conc)
		assert_true(n >= 1 and n <= sd.hub_count(), "active count stays in [1, hub_count]")
		prev = n
	assert_eq(sd.active_hub_count(0), 1, "starts collapsed at one hub")
	assert_eq(prev, sd.hub_count(), "reaches full dispersion at high population")


func test_unknown_concurrency_defaults_to_full_dispersion() -> void:
	# The default arg (old callers / concurrency < 0) keeps the pre-T-527 full-dispersion behaviour.
	var sd = _SD.new(_pop_hubs(), Callable(self, "_flat"), null, 6.0)
	assert_eq(sd.active_hub_count(-1), sd.hub_count(), "unknown concurrency -> full dispersion")


func test_every_population_level_stays_within_the_mob_safe_hub_set() -> void:
	# T-515 invariant: at EVERY population level the chosen point sits in some validated hub's jitter
	# disc — adaptive density never invents an unvalidated (possibly mob-adjacent) spawn.
	var hubs := _pop_hubs()
	var sd = _SD.new(hubs, Callable(self, "_flat"), null, 6.0)
	var rng := _rng()
	for conc in [0, 1, 4, 5, 8, 12, 13, 40]:
		for _i in range(8):
			var p := sd.pick(rng, conc)
			var idx := _nearest_hub(p, hubs)
			var d := Vector2(p.x, p.y).distance_to(Vector2(hubs[idx][0], hubs[idx][1]))
			assert_lt(d, 6.001, "conc=%d pick lands within a validated hub's jitter disc" % conc)


func test_density_knobs_are_tunable() -> void:
	# set_density_knobs shifts where collapse/full-dispersion happen; step is floored at 1.
	var sd = _SD.new(_pop_hubs(), Callable(self, "_flat"), null, 6.0)
	sd.set_density_knobs(2, 1)  # collapse only at conc<=2, then one hub per extra player
	assert_eq(sd.active_hub_count(2), 1, "custom threshold collapses at conc<=2")
	assert_eq(sd.active_hub_count(3), 2, "one extra player unlocks one hub with step=1")
	assert_eq(sd.active_hub_count(99), sd.hub_count(), "still clamps to hub_count")


# --- T-706: fresh-character spawns pin to hub[0] ---------------------------------------------
func test_fresh_pick_pins_to_first_hub_at_any_concurrency() -> void:
	# A first-ever character must land on hub[0] even at 13+ concurrency (full dispersion for
	# everyone else), and interleaved returning picks must not drag the fresh pin off hub[0].
	var hubs := _pop_hubs()
	var sd = _SD.new(hubs, Callable(self, "_flat"), null, 6.0)
	var rng := _rng()
	var first := Vector2(hubs[0][0], hubs[0][1])
	for i in range(16):
		sd.pick(rng, 13)  # a returning login advances the round-robin cursor
		var p: Vector3 = sd.pick_first_hub(rng)
		var d := Vector2(p.x, p.y).distance_to(first)
		assert_lt(d, 6.001, "fresh pick %d lands in hub[0]'s jitter disc, never dispersed" % i)


func test_returning_picks_still_disperse_around_a_fresh_pin() -> void:
	# The pin must not break T-373 for returning logins: a full-population burst still covers
	# every hub even with fresh picks interleaved.
	var hubs := _pop_hubs()
	var sd = _SD.new(hubs, Callable(self, "_flat"), null, 6.0)
	var rng := _rng()
	var seen := {}
	for _i in range(hubs.size()):
		sd.pick_first_hub(rng)
		seen[_nearest_hub(sd.pick(rng, 64), hubs)] = true
	assert_eq(seen.size(), hubs.size(), "returning burst still fans across every hub")


func test_fresh_pick_fails_closed_like_pick() -> void:
	var oracle := func(_x, _z): return 9.0  # everything is a cliff -> no hub validates
	var sd_none = _SD.new([[0.0, 0.0]], oracle, null)
	assert_eq(sd_none.pick_first_hub(_rng()), Vector3.ZERO, "no validated hub -> origin")
	var sd_fixed = _SD.new(_pop_hubs(), Callable(self, "_flat"), null, 6.0)
	sd_fixed.set_fixed(true)
	assert_eq(
		sd_fixed.pick_first_hub(_rng()), Vector3.ZERO, "AVALON_SPAWN_FIXED pins to origin (harness)"
	)


# --- point_inside geometry oracle (movement_collision T-373 addition) ------------------------
func test_point_inside_closed_footprint() -> void:
	var col = _MCOL.new("")
	col.add_rect(Vector2(0.0, 0.0), Vector2(10.0, 10.0), 0.0, [])
	assert_true(col.point_inside(0.0, 0.0), "centre of a closed footprint reads inside")
	assert_false(col.point_inside(50.0, 0.0), "a point well outside reads outside")


func test_point_inside_false_on_open_ground() -> void:
	var col = _MCOL.new("")  # no barriers at all
	assert_false(col.point_inside(0.0, 0.0), "no geometry -> never inside")
