extends GutTest

# T-311: pure NpcWander tick math — no OS time, no globals, inputs never mutated. Mirrors the
# mob_ai patrol pattern but data-driven from an npcs.json `wander` block.

const _NW = preload("res://scripts/npc_wander.gd")

const HZ := 20
const DT := 1.0 / 20.0


func _rng(seed_val: int = 42) -> RandomNumberGenerator:
	var r := RandomNumberGenerator.new()
	r.seed = seed_val
	return r


# ---- has_wander ----


func test_has_wander_true_for_radius_and_waypoints() -> void:
	assert_true(_NW.has_wander({"mode": "radius", "radius": 3.0}), "radius>0 wanders")
	assert_true(_NW.has_wander({"mode": "waypoints", "waypoints": [[1, 1]]}), "route wanders")


func test_has_wander_false_for_empty_or_zero() -> void:
	assert_false(_NW.has_wander({}), "no block = rooted")
	assert_false(_NW.has_wander({"mode": "radius", "radius": 0.0}), "zero radius = rooted")
	assert_false(_NW.has_wander({"mode": "waypoints", "waypoints": []}), "no waypoints = rooted")
	assert_false(_NW.has_wander("nope"), "non-dict = rooted")


# ---- new_state ----


func test_new_state_anchored_at_post() -> void:
	var post := Vector3(5, 2, 0)
	var s := _NW.new_state(post)
	assert_eq(s["pos"], post, "starts at the post")
	assert_eq(s["target"], post, "target is the post until the first repick")
	assert_eq(int(s["paused_until"]), 0, "not paused at spawn")


# ---- movement ----


func test_step_is_capped_at_walk_speed() -> void:
	# A far waypoint target: one tick advances exactly speed*dt toward it (never a teleport).
	var cfg := {"mode": "waypoints", "waypoints": [[100.0, 0.0]], "speed": 1.2}
	var st := {"pos": Vector3.ZERO, "target": Vector3(100, 0, 0), "paused_until": 0, "wp": 0}
	var out := _NW.tick(st, cfg, Vector3.ZERO, 10, DT, _rng())
	assert_almost_eq((out["pos"] as Vector3).length(), 1.2 * DT, 0.0001, "one tick = speed*dt")


func test_reaching_target_starts_a_pause_and_holds_position() -> void:
	var cfg := {"mode": "radius", "radius": 3.0, "pause_min": 2.0, "pause_max": 2.0}
	var post := Vector3(5, 2, 0)
	# pos already at target → arrival: picks a new target + a pause window.
	var st := _NW.new_state(post)
	var arrived := _NW.tick(st, cfg, post, 100, DT, _rng())
	assert_gt(int(arrived["paused_until"]), 100, "arrival schedules a pause")
	# While paused the NPC does not move.
	var held := _NW.tick(arrived, cfg, post, 105, DT, _rng())
	assert_eq(held["pos"], arrived["pos"], "no movement during the pause")


func test_radius_wander_stays_within_radius_of_post() -> void:
	# A quest-giver keeps a small radius so the INTERACT_RADIUS talk gate always resolves near it.
	var cfg := {"mode": "radius", "radius": 2.0, "pause_min": 0.0, "pause_max": 0.0}
	var post := Vector3(5, 2, 0)
	var st := _NW.new_state(post)
	var rng := _rng(7)
	var max_d := 0.0
	for t in range(2000):
		st = _NW.tick(st, cfg, post, t, DT, rng)
		max_d = maxf(max_d, (st["pos"] as Vector3).distance_to(post))
	assert_lt(max_d, 2.0 + 0.001, "never strays past the wander radius")
	assert_gt(max_d, 0.3, "but it actually moves (not a statue)")


func test_waypoints_loop_visits_every_point() -> void:
	var wps := [[0.0, 0.0], [4.0, 0.0], [4.0, 4.0]]
	var cfg := {
		"mode": "waypoints", "waypoints": wps, "speed": 2.0, "pause_min": 0.0, "pause_max": 0.0
	}
	var post := Vector3.ZERO
	var st := _NW.new_state(post)
	var visited := {}
	for t in range(4000):
		st = _NW.tick(st, cfg, post, t, DT, _rng())
		for i in range(wps.size()):
			if (st["pos"] as Vector3).distance_to(Vector3(wps[i][0], wps[i][1], 0)) < 0.2:
				visited[i] = true
	assert_eq(visited.size(), wps.size(), "the patrol reaches every waypoint")


# ---- Report #15: wall handling — stop at geometry, turn around, never penetrate ----


# Mock wall oracle (movement_collision.gd shape): blocks any step crossing the x = wall_x line.
class WallAtX:
	var wall_x: float

	func _init(x: float) -> void:
		wall_x = x

	func segment_blocked(fx: float, _fz: float, tx: float, _tz: float) -> bool:
		return (fx < wall_x) != (tx < wall_x)


func test_blocked_waypoint_step_stops_pauses_and_reverses_route() -> void:
	var cfg := {
		"mode": "waypoints",
		"waypoints": [[0.0, 0.0], [10.0, 0.0]],
		"speed": 2.0,
		"pause_min": 1.0,
		"pause_max": 1.0
	}
	# Mid-leg toward waypoint 1, one step short of a wall at x = 5.
	var st := {"pos": Vector3(4.95, 0, 0), "target": Vector3(10, 0, 0), "paused_until": 0, "wp": 1}
	var out := _NW.tick(st, cfg, Vector3.ZERO, 50, DT, _rng(), WallAtX.new(5.0))
	assert_eq(out["pos"], Vector3(4.95, 0, 0), "stops AT the wall — no penetration step")
	assert_gt(int(out["paused_until"]), 50, "pauses a beat before turning around")
	assert_eq(int(out["dir"]), -1, "route direction reverses (walk back the way it came)")
	assert_eq(out["target"], Vector3.ZERO, "new target = the waypoint it came from")


func test_blocked_radius_step_heads_home_to_the_post() -> void:
	# speed 2.0 -> a 0.1 m step from 4.9 actually reaches the x = 5 wall (default 1.2 * DT
	# = 0.06 m stops short — a legal free step, nothing to block).
	var cfg := {"mode": "radius", "radius": 6.0, "speed": 2.0, "pause_min": 1.0, "pause_max": 1.0}
	var post := Vector3(1, 0, 0)
	var st := {"pos": Vector3(4.9, 0, 0), "target": Vector3(8, 0, 0), "paused_until": 0, "wp": -1}
	var out := _NW.tick(st, cfg, post, 50, DT, _rng(), WallAtX.new(5.0))
	assert_eq(out["pos"], Vector3(4.9, 0, 0), "stops at the wall")
	assert_eq(out["target"], post, "ambler turns around and walks home to the post")
	assert_gt(int(out["paused_until"]), 50, "pauses before the turn-around")


func test_wanderer_never_crosses_the_wall_over_a_long_run() -> void:
	# Route authored THROUGH the wall (the Report #15 defect shape): the NPC must pace up to the
	# wall and turn, never appearing on the far side — and keep moving (no permanent freeze).
	var cfg := {
		"mode": "waypoints",
		"waypoints": [[0.0, 0.0], [10.0, 0.0]],
		"speed": 2.0,
		"pause_min": 0.5,
		"pause_max": 0.5
	}
	var st := _NW.new_state(Vector3.ZERO)
	var wall := WallAtX.new(5.0)
	var rng := _rng(3)
	var max_x := -INF
	var revisited_start := false
	for t in range(4000):
		st = _NW.tick(st, cfg, Vector3.ZERO, t, DT, rng, wall)
		max_x = maxf(max_x, (st["pos"] as Vector3).x)
		if t > 200 and (st["pos"] as Vector3).x < 0.2:
			revisited_start = true
	assert_lt(max_x, 5.0, "never on the far side of the wall")
	assert_gt(max_x, 2.0, "still walks its open leg (not frozen at spawn)")
	assert_true(revisited_start, "turned around and walked back where it came from")


func test_null_blocker_keeps_legacy_behaviour() -> void:
	var cfg := {"mode": "waypoints", "waypoints": [[10.0, 0.0]], "speed": 1.2}
	var st := {"pos": Vector3.ZERO, "target": Vector3(10, 0, 0), "paused_until": 0, "wp": 0}
	var out := _NW.tick(st, cfg, Vector3.ZERO, 10, DT, _rng())
	assert_almost_eq((out["pos"] as Vector3).x, 1.2 * DT, 0.0001, "no blocker = free step")


# ---- purity ----


func test_tick_does_not_mutate_inputs() -> void:
	var cfg := {"mode": "waypoints", "waypoints": [[100.0, 0.0]], "speed": 1.2}
	var st := {"pos": Vector3.ZERO, "target": Vector3(100, 0, 0), "paused_until": 0, "wp": 0}
	var st_before := st.duplicate(true)
	var cfg_before := cfg.duplicate(true)
	_NW.tick(st, cfg, Vector3.ZERO, 10, DT, _rng())
	assert_eq(st, st_before, "state input untouched")
	assert_eq(cfg, cfg_before, "cfg input untouched")


func test_movement_rate_is_dt_scaled_not_frame_scaled() -> void:
	# Same elapsed time via half dt / double ticks lands at the same distance (hardware-independent).
	var cfg := {"mode": "waypoints", "waypoints": [[100.0, 0.0]], "speed": 1.2}
	var target := Vector3(100, 0, 0)
	var a := {"pos": Vector3.ZERO, "target": target, "paused_until": 0, "wp": 0}
	for t in range(10):
		a = _NW.tick(a, cfg, Vector3.ZERO, t, DT, _rng())
	var b := {"pos": Vector3.ZERO, "target": target, "paused_until": 0, "wp": 0}
	for t in range(20):
		b = _NW.tick(b, cfg, Vector3.ZERO, t, DT * 0.5, _rng())
	assert_almost_eq(
		(a["pos"] as Vector3).x, (b["pos"] as Vector3).x, 0.0001, "distance tracks elapsed time"
	)
