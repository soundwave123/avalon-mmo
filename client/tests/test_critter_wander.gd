extends GutTest

# T-310: pure CritterWander tick math -- no OS time, no globals, inputs never mutated. Mirrors
# T-311's test_npc_wander.gd shape but adds the flee/resettle half (livestock reacting to a nearby
# player/mob) plus the home+radius bounds-clamp (T-310 note 5 -- never through the pasture fence).

const _CW = preload("res://scripts/world/critter_wander.gd")

const DT := 1.0 / 60.0  # a plain client frame; the module itself is dt-scaled, not fps-locked


func _rng(seed_val: int = 42) -> RandomNumberGenerator:
	var r := RandomNumberGenerator.new()
	r.seed = seed_val
	return r


# ---- new_state ----


func test_new_state_anchored_at_home() -> void:
	var home := Vector3(5, 0, 2)
	var s := _CW.new_state(home)
	assert_eq(s["pos"], home, "starts at home")
	assert_eq(s["target"], home, "target is home until the first repick")
	assert_eq(int(s["paused_until"]), 0, "not paused at spawn")
	assert_false(bool(s["fleeing"]), "not fleeing at spawn")


# ---- graze wander ----


func test_step_is_capped_at_graze_speed() -> void:
	var cfg := {"speed": 0.4, "wander_radius": 0.0}
	var st := {
		"pos": Vector3.ZERO, "target": Vector3(100, 0, 0), "paused_until": 0, "fleeing": false
	}
	var out := _CW.tick(st, cfg, Vector3.ZERO, [], 1000, DT, _rng())
	assert_almost_eq((out["pos"] as Vector3).length(), 0.4 * DT, 0.0001, "one tick = speed*dt")
	assert_true(bool(out["moving"]), "still travelling to the target")


func test_reaching_target_starts_a_pause_and_holds_position() -> void:
	var cfg := {"pause_min": 2000.0, "pause_max": 2000.0, "wander_radius": 1.0}
	var home := Vector3(5, 0, 2)
	var st := _CW.new_state(home)
	var arrived := _CW.tick(st, cfg, home, [], 1000, DT, _rng())
	assert_gt(int(arrived["paused_until"]), 1000, "arrival schedules a pause")
	assert_false(bool(arrived["moving"]), "not moving the instant it arrives/pauses")
	var held := _CW.tick(arrived, cfg, home, [], 1500, DT, _rng())
	assert_eq(held["pos"], arrived["pos"], "no movement during the pause")
	assert_false(bool(held["moving"]), "still idle mid-pause")


func test_graze_wander_stays_within_wander_radius_of_home() -> void:
	var cfg := {"wander_radius": 2.0, "pause_min": 0.0, "pause_max": 0.0}
	var home := Vector3(5, 0, 2)
	var st := _CW.new_state(home)
	var rng := _rng(7)
	var max_d := 0.0
	for t in range(2000):
		st = _CW.tick(st, cfg, home, [], t, DT, rng)
		max_d = maxf(max_d, (st["pos"] as Vector3).distance_to(home))
	assert_lt(max_d, 2.0 + 0.001, "never strays past the wander radius while grazing")
	assert_gt(max_d, 0.3, "but it actually drifts (not a statue)")


# ---- flee ----


func test_flee_triggers_inside_comfort_radius() -> void:
	var cfg := {"comfort_radius": 4.0, "max_radius": 20.0, "flee_dist": 2.0}
	var home := Vector3.ZERO
	var st := _CW.new_state(home)
	var threat := Vector3(2.0, 0, 0)  # 2m away, inside the 4m comfort radius
	var out := _CW.tick(st, cfg, home, [threat], 0, DT, _rng())
	assert_true(bool(out["fleeing"]), "a threat inside comfort radius triggers flee")
	assert_true(bool(out["moving"]), "fleeing always reads as moving")


func test_flee_does_not_trigger_outside_comfort_radius() -> void:
	var cfg := {"comfort_radius": 4.0, "max_radius": 20.0}
	var home := Vector3.ZERO
	var st := _CW.new_state(home)
	var threat := Vector3(10.0, 0, 0)  # well outside comfort radius
	var out := _CW.tick(st, cfg, home, [threat], 0, DT, _rng())
	assert_false(bool(out["fleeing"]), "a distant threat doesn't spook the animal")


func test_flee_direction_is_away_from_the_threat() -> void:
	var cfg := {"comfort_radius": 5.0, "max_radius": 20.0, "flee_dist": 3.0, "flee_speed": 100.0}
	var home := Vector3.ZERO
	var st := _CW.new_state(home)
	var threat := Vector3(2.0, 0, 0)  # threat to the +X side
	var out := _CW.tick(st, cfg, home, [threat], 0, DT, _rng())
	var pos: Vector3 = out["pos"]
	assert_lt(pos.x, 0.0, "flees to the -X side, away from the +X threat")


func test_resettle_once_threat_clears_the_resettle_radius() -> void:
	var cfg := {"comfort_radius": 4.0, "resettle_mult": 1.5, "max_radius": 20.0, "flee_dist": 1.0}
	var home := Vector3.ZERO
	# Start already fleeing, sitting well past the resettle distance (4.0 * 1.5 = 6.0).
	var st := {
		"pos": Vector3(7.0, 0, 0), "target": Vector3(8.0, 0, 0), "paused_until": 0, "fleeing": true
	}
	var far_threat := Vector3(0, 0, 0)  # 7m away -- past resettle (6.0)
	var out := _CW.tick(st, cfg, home, [far_threat], 0, DT, _rng())
	assert_false(bool(out["fleeing"]), "resettles once clear of the resettle radius")


func test_resettle_holds_flee_between_comfort_and_resettle_radius() -> void:
	# Hysteresis band: still fleeing between comfort (4.0) and resettle (6.0) so it doesn't flicker
	# back and forth right at the comfort-radius edge.
	var cfg := {"comfort_radius": 4.0, "resettle_mult": 1.5, "max_radius": 20.0}
	var st := {
		"pos": Vector3(5.0, 0, 0), "target": Vector3(6.0, 0, 0), "paused_until": 0, "fleeing": true
	}
	var threat := Vector3(0, 0, 0)  # 5m away: past comfort but inside resettle
	var out := _CW.tick(st, cfg, Vector3.ZERO, [threat], 0, DT, _rng())
	assert_true(bool(out["fleeing"]), "stays alert inside the resettle band")


# ---- bounds clamp (T-310 note 5: never through the pasture fence) ----


func test_flee_bounds_clamp_holds_within_max_radius_of_home() -> void:
	var cfg := {"comfort_radius": 50.0, "max_radius": 3.0, "flee_dist": 10.0, "flee_speed": 50.0}
	var home := Vector3(20.0, 0, 5.0)
	var st := _CW.new_state(home)
	var threat := Vector3(19.0, 0, 5.0)  # right next to it -- a big flee_dist would blow past 3m
	var rng := _rng(3)
	for t in range(200):
		st = _CW.tick(st, cfg, home, [threat], t, DT, rng)
		assert_lte(
			(st["pos"] as Vector3).distance_to(home), 3.0 + 0.001, "flee never leaves max_radius"
		)


func test_graze_bounds_clamp_holds_within_max_radius_of_home() -> void:
	var cfg := {"wander_radius": 50.0, "max_radius": 3.0, "pause_min": 0.0, "pause_max": 0.0}
	var home := Vector3(20.0, 0, 5.0)
	var st := _CW.new_state(home)
	var rng := _rng(9)
	for t in range(500):
		st = _CW.tick(st, cfg, home, [], t, DT, rng)
		assert_lte(
			(st["pos"] as Vector3).distance_to(home),
			3.0 + 0.001,
			"an oversized wander_radius is still clamped to max_radius"
		)


# ---- purity ----


func test_tick_does_not_mutate_inputs() -> void:
	var cfg := {"comfort_radius": 4.0, "max_radius": 10.0}
	var st := {"pos": Vector3.ZERO, "target": Vector3(1, 0, 0), "paused_until": 0, "fleeing": false}
	var st_before := st.duplicate(true)
	var cfg_before := cfg.duplicate(true)
	var threats := [Vector3(2, 0, 0)]
	var threats_before := threats.duplicate(true)
	_CW.tick(st, cfg, Vector3.ZERO, threats, 10, DT, _rng())
	assert_eq(st, st_before, "state input untouched")
	assert_eq(cfg, cfg_before, "cfg input untouched")
	assert_eq(threats, threats_before, "threats input untouched")


func test_movement_rate_is_dt_scaled_not_frame_scaled() -> void:
	var cfg := {"comfort_radius": 50.0, "max_radius": 1000.0, "flee_dist": 100.0, "flee_speed": 1.2}
	var threat := Vector3(1, 0, 0)
	var a := {"pos": Vector3.ZERO, "target": Vector3.ZERO, "paused_until": 0, "fleeing": false}
	for t in range(10):
		a = _CW.tick(a, cfg, Vector3.ZERO, [threat], t, DT, _rng())
	var b := {"pos": Vector3.ZERO, "target": Vector3.ZERO, "paused_until": 0, "fleeing": false}
	for t in range(20):
		b = _CW.tick(b, cfg, Vector3.ZERO, [threat], t, DT * 0.5, _rng())
	assert_almost_eq(
		(a["pos"] as Vector3).x, (b["pos"] as Vector3).x, 0.001, "distance tracks elapsed time"
	)
