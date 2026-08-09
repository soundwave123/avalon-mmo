extends GutTest

# T-446: pure NpcIdle tick — facing drift + role act pulses, no OS time, no globals, inputs never
# mutated, caller injects the rng (the npc_wander.gd idiom).

const _NI = preload("res://scripts/npc_idle.gd")

const HZ := 20
const DT := 1.0 / 20.0


func _rng(seed_val: int = 42) -> RandomNumberGenerator:
	var r := RandomNumberGenerator.new()
	r.seed = seed_val
	return r


func _cfg() -> Dictionary:
	return {"acts": ["hammer"], "act_min": 2.0, "act_max": 4.0, "act_dur": 1.0}


# ---- has_idle ----


func test_has_idle_only_for_a_non_empty_block() -> void:
	assert_true(_NI.has_idle({"acts": ["pray"]}), "acts block opts in")
	assert_true(_NI.has_idle({"turn_min": 3.0}), "turn-only block opts in")
	assert_false(_NI.has_idle({}), "empty block = no idle life")
	assert_false(_NI.has_idle(null), "non-dict = no idle life")


# ---- act pulses ----


func test_act_fires_within_the_window_and_clears_after_duration() -> void:
	var st: Dictionary = _NI.new_state(0.0)
	var rng := _rng()
	var fired_at := -1
	var cleared_at := -1
	for t in range(HZ * 10):
		st = _NI.tick(st, _cfg(), false, 0.0, t, DT, rng)
		if fired_at < 0 and str(st["act"]) == "hammer":
			fired_at = t
		if fired_at >= 0 and cleared_at < 0 and str(st["act"]) == "":
			cleared_at = t
	assert_gt(fired_at, 0, "an act pulse fires")
	assert_lt(fired_at, HZ * 5, "first pulse lands within the jittered window")
	assert_gt(cleared_at, fired_at, "the pulse clears again")
	assert_almost_eq(float(cleared_at - fired_at) * DT, 1.0, 2.0 * DT, "held for act_dur seconds")


func test_act_pulses_repeat_so_the_smith_keeps_hammering() -> void:
	var st: Dictionary = _NI.new_state(0.0)
	var rng := _rng(7)
	var pulses := 0
	var prev := ""
	for t in range(HZ * 60):
		st = _NI.tick(st, _cfg(), false, 0.0, t, DT, rng)
		var act := str(st["act"])
		if act != "" and prev == "":
			pulses += 1
		prev = act
	assert_gt(pulses, 3, "the work loop repeats (not a one-time gag)")


func test_no_acts_configured_means_no_pulse_ever() -> void:
	var st: Dictionary = _NI.new_state(0.0)
	var rng := _rng()
	for t in range(HZ * 30):
		st = _NI.tick(st, {"turn_min": 2.0, "turn_max": 4.0}, false, 0.0, t, DT, rng)
		assert_eq(str(st["act"]), "", "turn-only cfg never acts")


# ---- facing drift ----


func test_facing_drifts_over_time_and_stays_wrapped() -> void:
	var st: Dictionary = _NI.new_state(0.0)
	var rng := _rng(3)
	var cfg := {"turn_min": 1.0, "turn_max": 2.0}
	var changes := 0
	var prev_facing := 0.0
	for t in range(HZ * 30):
		st = _NI.tick(st, cfg, false, 0.0, t, DT, rng)
		var f := float(st["facing"])
		if absf(f - prev_facing) > 0.001:
			changes += 1
			prev_facing = f
		assert_between(f, -PI, PI, "facing stays wrapped")
	assert_gt(changes, 5, "the NPC shifts its facing repeatedly (never frozen)")


func test_walking_locks_facing_to_travel_and_drops_the_act() -> void:
	var st := {"facing": 0.5, "act": "hammer", "act_until": 999, "next_act": 999, "next_turn": 999}
	var out: Dictionary = _NI.tick(st, _cfg(), true, 1.234, 10, DT, _rng())
	assert_eq(float(out["facing"]), 1.234, "walking faces the travel direction")
	assert_eq(str(out["act"]), "", "a walking NPC never keeps acting")
	assert_eq(int(out["next_act"]), 0, "schedules re-jitter on the next stationary tick")


func test_schedules_rejitter_after_a_walk_so_the_crowd_desyncs() -> void:
	# Two NPCs that stop walking on the same tick still pulse at different times (rng jitter).
	var a: Dictionary = _NI.tick(_NI.new_state(0.0), _cfg(), true, 0.0, 0, DT, _rng(1))
	var b: Dictionary = _NI.tick(_NI.new_state(0.0), _cfg(), true, 0.0, 0, DT, _rng(2))
	a = _NI.tick(a, _cfg(), false, 0.0, 1, DT, _rng(1))
	b = _NI.tick(b, _cfg(), false, 0.0, 1, DT, _rng(2))
	assert_ne(int(a["next_act"]), int(b["next_act"]), "act beats are staggered, not a metronome")


# ---- purity + dt scaling ----


func test_tick_does_not_mutate_inputs() -> void:
	var st := {"facing": 0.1, "act": "", "act_until": 0, "next_act": 5, "next_turn": 5}
	var cfg := _cfg()
	var st_before := st.duplicate(true)
	var cfg_before := cfg.duplicate(true)
	_NI.tick(st, cfg, false, 0.0, 10, DT, _rng())
	assert_eq(st, st_before, "state input untouched")
	assert_eq(cfg, cfg_before, "cfg input untouched")


func test_windows_are_dt_scaled_not_tick_scaled() -> void:
	# The same cfg at half dt schedules twice the ticks — i.e. the SAME elapsed seconds.
	var cfg := {"acts": ["hammer"], "act_min": 2.0, "act_max": 2.0}
	var a: Dictionary = _NI.tick(_NI.new_state(0.0), cfg, false, 0.0, 0, DT, _rng(9))
	var b: Dictionary = _NI.tick(_NI.new_state(0.0), cfg, false, 0.0, 0, DT * 0.5, _rng(9))
	assert_eq(int(b["next_act"]), int(a["next_act"]) * 2, "half dt = double ticks = same seconds")
