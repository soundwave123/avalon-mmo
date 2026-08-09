extends GutTest

# T-085: pure WeatherState tick math — no OS time, no globals, inputs never mutated. Mirrors
# test_critter_wander.gd / test_npc_wander.gd's shape. Covers the clear->overcast->rain cycle
# (transitions, durations, determinism), the ramped overcast darkness + rain-intensity outputs,
# and the gust/wind_strength math (bounded, deterministic).

const _WS = preload("res://scripts/world/weather_state.gd")

const DT := 1.0 / 60.0  # a plain client frame; the module is dt-scaled, not fps-locked


# A controllable rng: randf() picks the overcast branch, randf_range() picks the dwell time.
class StubRng:
	extends RefCounted
	var randf_value := 0.0
	var range_pick := 0.0  # 0.0 -> min of the range, 1.0 -> max

	func randf() -> float:
		return randf_value

	func randf_range(a: float, b: float) -> float:
		return a + (b - a) * range_pick


func _seeded(seed_val: int = 7) -> RandomNumberGenerator:
	var r := RandomNumberGenerator.new()
	r.seed = seed_val
	return r


# ---- new_state ----


func test_new_state_starts_clear_and_settled() -> void:
	var s := _WS.new_state()
	assert_eq(int(s["phase"]), _WS.PHASE_CLEAR, "boots clear (sunny meadow default)")
	assert_eq(int(s["prev_phase"]), _WS.PHASE_CLEAR, "no pending transition")
	assert_eq(float(s["duration"]), 0.0, "duration drawn on the first tick")


func test_first_tick_draws_a_clear_dwell_and_stays_clear() -> void:
	var out := _WS.tick(_WS.new_state(), DT, _seeded())
	assert_eq(int(out["phase"]), _WS.PHASE_CLEAR, "still clear on the opening tick")
	assert_gt(float(out["duration"]), 0.0, "opening dwell time drawn")
	assert_false(bool(out["rain"]), "no rain while clear")
	assert_almost_eq(float(out["darkness"]), 0.0, 0.0001, "clear sky is undimmed")


# ---- transitions ----


func test_clear_expires_to_overcast() -> void:
	var st := {
		"phase": _WS.PHASE_CLEAR,
		"prev_phase": _WS.PHASE_CLEAR,
		"elapsed": 200.0,
		"duration": 150.0,  # already past dwell
		"since_change": 99.0,
	}
	var out := _WS.tick(st, DT, _seeded())
	assert_eq(int(out["phase"]), _WS.PHASE_OVERCAST, "clear always builds into overcast")
	assert_eq(int(out["prev_phase"]), _WS.PHASE_CLEAR, "prev tracks the phase we left")
	assert_almost_eq(float(out["elapsed"]), 0.0, 0.0001, "elapsed resets on transition")


func test_overcast_breaks_into_rain_when_roll_is_low() -> void:
	var rng := StubRng.new()
	rng.randf_value = 0.3  # < 0.6 -> rain
	var st := {
		"phase": _WS.PHASE_OVERCAST,
		"prev_phase": _WS.PHASE_CLEAR,
		"elapsed": 999.0,
		"duration": 90.0,
		"since_change": 99.0,
	}
	var out := _WS.tick(st, DT, rng)
	assert_eq(int(out["phase"]), _WS.PHASE_RAIN, "a low roll breaks overcast into rain")


func test_overcast_clears_when_roll_is_high() -> void:
	var rng := StubRng.new()
	rng.randf_value = 0.9  # >= 0.6 -> clear
	var st := {
		"phase": _WS.PHASE_OVERCAST,
		"prev_phase": _WS.PHASE_RAIN,
		"elapsed": 999.0,
		"duration": 90.0,
		"since_change": 99.0,
	}
	var out := _WS.tick(st, DT, rng)
	assert_eq(int(out["phase"]), _WS.PHASE_CLEAR, "a high roll passes overcast back to clear")


func test_rain_always_tapers_through_overcast() -> void:
	var st := {
		"phase": _WS.PHASE_RAIN,
		"prev_phase": _WS.PHASE_OVERCAST,
		"elapsed": 999.0,
		"duration": 60.0,
		"since_change": 99.0,
	}
	var out := _WS.tick(st, DT, _seeded())
	assert_eq(int(out["phase"]), _WS.PHASE_OVERCAST, "rain never snaps straight to clear")


# ---- durations bounded to the per-phase range ----


func test_drawn_dwell_is_inside_the_phase_range() -> void:
	var rng := StubRng.new()
	rng.range_pick = 1.0  # max end of the range
	var st := {
		"phase": _WS.PHASE_CLEAR,
		"prev_phase": _WS.PHASE_CLEAR,
		"elapsed": 999.0,
		"duration": 10.0,
		"since_change": 99.0,
	}
	var out := _WS.tick(st, DT, rng)  # transitions to overcast, draws its dwell
	assert_almost_eq(float(out["duration"]), 150.0, 0.001, "overcast max dwell honoured")
	rng.range_pick = 0.0
	var out2 := _WS.tick(st, DT, rng)
	assert_almost_eq(float(out2["duration"]), 60.0, 0.001, "overcast min dwell honoured")


# ---- ramped look outputs ----


func test_overcast_fully_ramped_darkness() -> void:
	var st := {
		"phase": _WS.PHASE_OVERCAST,
		"prev_phase": _WS.PHASE_OVERCAST,
		"elapsed": 1.0,
		"duration": 90.0,
		"since_change": 99.0,
	}
	var out := _WS.tick(st, DT, _seeded())
	assert_almost_eq(float(out["darkness"]), 0.5, 0.01, "settled overcast is half-dimmed")
	assert_false(bool(out["rain"]), "overcast alone is not rain")


func test_rain_fully_ramped_darkness_and_intensity() -> void:
	var st := {
		"phase": _WS.PHASE_RAIN,
		"prev_phase": _WS.PHASE_RAIN,
		"elapsed": 1.0,
		"duration": 60.0,
		"since_change": 99.0,
	}
	var out := _WS.tick(st, DT, _seeded())
	assert_almost_eq(float(out["darkness"]), 1.0, 0.01, "settled rain is fully dimmed")
	assert_true(bool(out["rain"]), "settled rain emits particles")
	assert_almost_eq(float(out["rain_intensity"]), 1.0, 0.01, "rain intensity peaks")


func test_darkness_is_bounded_0_to_1_across_a_long_run() -> void:
	var s := _WS.new_state()
	var rng := _seeded(123)
	for i in range(20000):
		s = _WS.tick(s, 0.5, rng)
		var d := float(s["darkness"])
		assert_between(d, 0.0, 1.0, "darkness never leaves [0,1]")
		assert_between(float(s["rain_intensity"]), 0.0, 1.0, "rain intensity stays in [0,1]")


func test_rain_ramps_in_not_snaps() -> void:
	# mid-transition overcast->rain: half-ramped intensity, already emitting.
	var st := {
		"phase": _WS.PHASE_RAIN,
		"prev_phase": _WS.PHASE_OVERCAST,
		"elapsed": 5.0,
		"duration": 60.0,
		"since_change": 6.0,  # _RAMP is 12 -> blend 0.5
	}
	var out := _WS.tick(st, 0.0, _seeded())
	assert_almost_eq(float(out["rain_intensity"]), 0.5, 0.02, "rain fades in over the ramp")
	assert_true(bool(out["rain"]), "emitting once intensity crosses epsilon")


# ---- determinism ----


func test_same_seed_replays_the_same_weather() -> void:
	var a := _WS.new_state()
	var b := _WS.new_state()
	var ra := _seeded(555)
	var rb := _seeded(555)
	for i in range(6000):
		a = _WS.tick(a, 0.5, ra)
		b = _WS.tick(b, 0.5, rb)
		assert_eq(int(a["phase"]), int(b["phase"]), "phase matches at tick %d" % i)
		assert_almost_eq(float(a["elapsed"]), float(b["elapsed"]), 0.0001, "elapsed matches")


func test_inputs_are_not_mutated() -> void:
	var st := _WS.new_state()
	var before := st.duplicate(true)
	_WS.tick(st, DT, _seeded())
	assert_eq(st, before, "tick returns a new dict, never mutates its input")


# ---- gust math ----


func test_gust_is_bounded_0_to_1() -> void:
	for i in range(2000):
		var t := float(i) * 0.13
		assert_between(_WS.gust(t), 0.0, 1.0, "gust pulse stays in [0,1]")


func test_gust_is_deterministic() -> void:
	assert_eq(_WS.gust(3.7), _WS.gust(3.7), "same time -> same pulse (no rng/OS time)")


func test_wind_strength_bounded_and_monotonic() -> void:
	var base := 0.11
	var amp := 0.16
	assert_almost_eq(_WS.wind_strength(base, amp, 0.0), base, 0.0001, "no gust -> base sway")
	assert_almost_eq(_WS.wind_strength(base, amp, 1.0), base + amp, 0.0001, "full gust -> base+amp")
	assert_gt(
		_WS.wind_strength(base, amp, 0.8),
		_WS.wind_strength(base, amp, 0.3),
		"stronger pulse -> stronger sway"
	)
	# out-of-range pulses clamp rather than overshoot.
	assert_almost_eq(_WS.wind_strength(base, amp, 5.0), base + amp, 0.0001, "pulse clamps at 1")
	assert_almost_eq(_WS.wind_strength(base, amp, -5.0), base, 0.0001, "pulse clamps at 0")
