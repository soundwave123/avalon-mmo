# T-379: server-side movement collision (anti-noclip). Proves the geometry gate rejects a move
# whose segment crosses a static wall, that legitimate door/gate traversal and along-wall motion
# still pass, and that resolve() layers speed cap + per-second budget + bounds clamp + collision in
# the right (fail-closed) order. Pure: the module loads barrier geometry from data and the rate
# limiter is injected, so nothing here needs a booted server.

extends GutTest

const _MCOL = preload("res://scripts/movement_collision.gd")
const _MRL = preload("res://scripts/move_rate_limiter.gd")
const _SC = preload("res://scripts/server_config.gd")


# A three-sided box open on the +x side (a door gap), centered on origin, half-extent 10.
func _boxed() -> Object:
	var c = _MCOL.new("")  # no data load
	# west, north, south edges; the east side (x=+10) is left open as the "door".
	c.add_polyline([[10.0, -10.0], [-10.0, -10.0], [-10.0, 10.0], [10.0, 10.0]], false)
	return c


func test_segment_through_wall_blocked() -> void:
	var c = _boxed()
	# Straight west-to-east through the solid west wall (x=-10) into the interior.
	assert_true(
		c.segment_blocked(-20.0, 0.0, 0.0, 0.0), "a segment crossing a wall must be blocked"
	)


func test_segment_through_opening_passes() -> void:
	var c = _boxed()
	# Approach the open +x side and step in — crosses no wall segment.
	assert_false(c.segment_blocked(20.0, 0.0, 0.0, 0.0), "entering through the open side must pass")


func test_move_along_wall_not_blocked() -> void:
	var c = _boxed()
	# Sliding flush ALONG the west wall (collinear) is legal — you can walk beside a wall.
	assert_false(
		c.segment_blocked(-10.0, -10.0, -10.0, 10.0), "collinear along-wall motion is legal"
	)


func test_move_fully_inside_not_blocked() -> void:
	var c = _boxed()
	assert_false(
		c.segment_blocked(-5.0, -5.0, 5.0, 5.0), "a move that stays inside crosses no wall"
	)


# --- the real world barrier: the Highkeep curtain wall ------------------------
func test_highkeep_wall_crossing_blocked() -> void:
	var c = _MCOL.new()  # loads res://data/regions/barriers.json
	assert_gt(c.wall_count(), 0, "the seed barrier set must load at least the curtain wall")
	# Straight shot from well outside the west wall (x=-200) to the keep precinct (0,-240): must
	# cross the west curtain (x=-120) — this is the ticket's exact noclip-into-the-vault exploit.
	assert_true(
		c.segment_blocked(-200.0, -240.0, 0.0, -240.0), "noclip through the curtain is blocked"
	)


func test_highkeep_gate_traversal_passes() -> void:
	var c = _MCOL.new()
	# Down the central spine (x=0) from outside the north gate (z=-130) into the market (z=-200):
	# the gate is the OPEN gap in the wall polyline, so this legitimate approach crosses no segment.
	assert_false(c.segment_blocked(0.0, -130.0, 0.0, -200.0), "walking through the gate must pass")


func test_inside_the_walls_moves_freely() -> void:
	var c = _MCOL.new()
	# Once inside, moving between the market and the keep yard crosses no curtain segment.
	assert_false(c.segment_blocked(0.0, -200.0, 0.0, -290.0), "movement inside the walls is free")


# --- resolve(): the layered intake used by main._on_request_move --------------
func test_resolve_accepts_legit_delta() -> void:
	var c = _MCOL.new("")
	var res: Dictionary = c.resolve(Vector2(0, 0), Vector2(5, 0), 1, 0, _MRL.new())
	assert_true(res["ok"], "a small legal delta is accepted")
	assert_true(res["pos"].is_equal_approx(Vector2(5, 0)), "and applies the delta")


func test_resolve_rejects_overspeed() -> void:
	var c = _MCOL.new("")
	var over := Vector2(_SC.MAX_SPEED_PER_TICK + 50, 0)
	var res: Dictionary = c.resolve(Vector2(0, 0), over, 1, 0, _MRL.new())
	assert_false(res["ok"], "a delta above the per-message speed cap is rejected")
	assert_eq(res["reason"], "speed", "with the speed reason")


func test_resolve_rejects_over_budget() -> void:
	var c = _MCOL.new("")
	var lim = _MRL.new()
	# Drain the per-second budget with legal-speed hops, then the next legal-speed hop is over budget.
	var reason := ""
	for i in range(20):
		var r: Dictionary = c.resolve(Vector2(0, 0), Vector2(_SC.MAX_SPEED_PER_TICK, 0), 2, 0, lim)
		if not r["ok"]:
			reason = r["reason"]
			break
	assert_eq(reason, "rate", "a sustained legal-speed burst is cut off by the per-second budget")


func test_resolve_clamps_out_of_bounds() -> void:
	# No region table loaded (empty regions_path) -> the pre-T-590 global ±500 fallback clamp. The
	# per-region raised envelopes (T-593) are covered by test_world_regions; this pins the fallback.
	var c = _MCOL.new("", "")
	# A legal-speed hop that would leave the ±500 box is clamped (accepted, not rejected).
	var res: Dictionary = c.resolve(
		Vector2(_SC.BOUNDS_MAX - 10, 0), Vector2(90, 0), 3, 0, _MRL.new()
	)
	assert_true(res["ok"], "an out-of-bounds move is clamped, not rejected")
	assert_almost_eq(res["pos"].x, _SC.BOUNDS_MAX, 0.01, "clamped to the hard bound")


func test_resolve_rejects_noclip() -> void:
	var c = _MCOL.new()
	# A single legal-speed delta aimed straight through the north curtain (off the gate).
	var res: Dictionary = c.resolve(Vector2(-50, -130), Vector2(0, -40), 4, 0, _MRL.new())
	assert_false(res["ok"], "a legal-speed delta through a wall is rejected by the geometry gate")
	assert_eq(res["reason"], "collision", "with the collision reason")


func test_mounted_cap_accepts_faster_delta_but_normal_cap_rejects_it() -> void:
	var c = _MCOL.new("")
	var fast := Vector2(_SC.MAX_SPEED_PER_TICK + 10.0, 0.0)
	assert_false(c.resolve(Vector2.ZERO, fast, 1, 0, _MRL.new())["ok"], "on-foot cap rejects")
	var mounted: Dictionary = c.resolve(
		Vector2.ZERO,
		fast,
		2,
		0,
		_MRL.new(),
		_SC.MAX_SPEED_MOUNTED_PER_TICK,
		_SC.MOVE_UNITS_MOUNTED_PER_SECOND
	)
	assert_true(mounted["ok"], "server-selected mounted cap accepts the same delta")


func test_mounted_speed_still_cannot_cross_geometry() -> void:
	var c = _MCOL.new()
	var mounted: Dictionary = c.resolve(
		Vector2(-50, -130),
		Vector2(0, -50),
		3,
		0,
		_MRL.new(),
		_SC.MAX_SPEED_MOUNTED_PER_TICK,
		_SC.MOVE_UNITS_MOUNTED_PER_SECOND
	)
	assert_false(mounted["ok"], "mount speed does not bypass the same anti-noclip gate")
	assert_eq(str(mounted["reason"]), "collision")


# --- add_rect: solid-building blocker with a carved door ----------------------
func test_rect_blocker_wall_blocks_door_passes() -> void:
	var c = _MCOL.new("")
	# A 10x10 solid building at origin with a 3m-wide door centered on its south (-z) edge (0,-5).
	c.add_rect(Vector2(0, 0), Vector2(5, 5), 0.0, [{"center": [0.0, -5.0], "half": 1.5}])
	assert_true(c.segment_blocked(-20.0, 0.0, 0.0, 0.0), "through the solid west wall is blocked")
	assert_false(c.segment_blocked(0.0, -20.0, 0.0, 0.0), "in through the south door gap passes")


func test_no_barriers_blocks_nothing() -> void:
	var c = _MCOL.new("")
	assert_eq(c.wall_count(), 0, "an empty barrier set has no walls")
	assert_false(
		c.segment_blocked(-500.0, 0.0, 500.0, 0.0), "with no walls, nothing is ever blocked"
	)
