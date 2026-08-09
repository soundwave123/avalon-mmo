extends GutTest

# T-733: the bird-call scheduler. The requirement is a STATISTICAL property — "random and pleasant,
# not dense and repetitive" — so these are statistical assertions over a seeded RNG. The DoD gate
# ("the fixed-interval pattern is gone") is the gap-variance ratio SD/mean: a metronome scores ~0.0,
# uniform +/-20% jitter around a period ~0.12, a Poisson process ~0.8. The gate is 0.5, asserted on
# both the raw draw and the live scheduler.

const BirdCalls = preload("res://scripts/world/bird_calls.gd")
const DT := 1.0 / 60.0
const DAWN := 0.0  # T-415 day-clock convention: noon = 0.25, sunrise ~ 0.0, midnight = 0.75
const NOON := 0.25
const MIDNIGHT := 0.75


func _run(seed_v: int, day_t: float, sim_s: float, voice_count := 2) -> Dictionary:
	var b := BirdCalls.new()
	b.rng.seed = seed_v
	for i in range(voice_count):
		b.add_voice("voice_%d" % i)
	var t := 0.0
	var times: Array = []
	var calls: Array = []
	while t < sim_s:
		for c: Dictionary in b.tick(DT, day_t):
			times.append(t)
			calls.append(c)
		t += DT
	return {"times": times, "calls": calls, "sched": b}


func _stats(values: Array) -> Dictionary:
	var sum := 0.0
	var lo := INF
	var hi := -INF
	for v in values:
		sum += float(v)
		lo = minf(lo, float(v))
		hi = maxf(hi, float(v))
	var n := maxi(1, values.size())
	var mean: float = sum / n
	var acc := 0.0
	for v in values:
		acc += (float(v) - mean) * (float(v) - mean)
	return {"n": values.size(), "mean": mean, "sd": sqrt(acc / n), "max": hi, "min": lo}


func _gaps(times: Array) -> Array:
	var out: Array = []
	for i in range(1, times.size()):
		out.append(float(times[i]) - float(times[i - 1]))
	return out


func test_gap_draws_are_exponential_not_a_fixed_interval() -> void:
	# The DoD gate at the level of the draw. Shifted exponential => E[gap] = min + mean, SD = mean
	# (the floor shifts the mean, it does not narrow the spread).
	var prof: Dictionary = BirdCalls.PROFILES["tree"]
	var mean_g := float(prof["mean_gap_s"])
	var min_g := float(prof["min_gap_s"])
	var rng := RandomNumberGenerator.new()
	rng.seed = 20260808
	var gaps: Array = []
	for i in range(4000):
		gaps.append(BirdCalls.next_gap_s(rng.randf(), mean_g, 1.0, min_g, float(prof["max_gap_s"])))
	var s := _stats(gaps)
	assert_almost_eq(float(s["mean"]), min_g + mean_g, mean_g * 0.12, "mean matches the model")
	assert_almost_eq(float(s["sd"]), mean_g, mean_g * 0.18, "SD matches the model (exponential)")
	assert_gt(float(s["sd"]) / float(s["mean"]), 0.5, "gaps are Poisson-wide, not fixed-interval")
	assert_gt(float(s["max"]), (min_g + mean_g) * 3.0, "the tail gives genuinely long quiet spells")
	assert_true(float(s["min"]) >= min_g - 0.0001, "no draw ever undercuts the floor")


func test_draw_bounds_and_density_scaling() -> void:
	# u=0 lands exactly ON the floor (it is added, so probability mass is not piled there); the cap
	# bounds the tail; density divides the rate == multiplies the mean gap.
	assert_almost_eq(BirdCalls.next_gap_s(0.0, 19.0, 1.0, 4.5, 150.0), 4.5, 0.001, "u=0 -> floor")
	assert_almost_eq(BirdCalls.next_gap_s(1.0, 19.0, 1.0, 4.5, 60.0), 60.0, 0.001, "tail is capped")
	var full := BirdCalls.next_gap_s(0.632, 20.0, 1.0, 0.0, 9999.0)
	var sparse := BirdCalls.next_gap_s(0.632, 20.0, 0.25, 0.0, 9999.0)
	assert_almost_eq(sparse / full, 4.0, 0.05, "quarter density = four times the mean gap")


func test_density_curve_biases_dawn_over_midday_and_wraps() -> void:
	var dawn := BirdCalls.density_at(DAWN)
	var noon := BirdCalls.density_at(NOON)
	assert_almost_eq(dawn, 1.0, 0.001, "sunrise is the peak of the curve (the dawn chorus)")
	assert_gt(dawn, noon * 4.0, "dawn is multiples denser than midday")
	assert_lt(noon, 0.25, "midday is sparse — the owner's 'constant midday chatter' hour")
	assert_gt(noon, 0.0, "…sparse, not silent")
	assert_almost_eq(BirdCalls.density_at(MIDNIGHT), 0.0, 0.001, "midnight: crickets, not birds")
	var evening := BirdCalls.density_at(0.42)
	assert_gt(evening, noon, "the evening chorus lifts off the midday floor")
	assert_lt(evening, dawn, "…and never reaches the dawn chorus")
	var pre := BirdCalls.density_at(0.99)  # across the 0.98 -> 0.00 seam
	assert_gt(pre, 0.80, "pre-dawn is rising toward the sunrise peak")
	assert_lt(pre, 1.0, "…but has not reached it yet")
	assert_almost_eq(BirdCalls.density_at(1.0), dawn, 0.001, "day_t wraps at the seam")


func test_bed_density_atten_tracks_the_curve() -> void:
	# The global birdsong BED is one looping player and can't be scheduled, so it rides the curve
	# as an attenuation instead: full at dawn, deeply pulled back at midday.
	assert_almost_eq(BirdCalls.bed_density_atten_db(1.0, -11.0), 0.0, 0.001, "dawn: bed at base")
	assert_almost_eq(BirdCalls.bed_density_atten_db(0.0, -11.0), -11.0, 0.001, "no birds: full dim")
	assert_lt(
		BirdCalls.bed_density_atten_db(BirdCalls.density_at(NOON), -11.0),
		-8.0,
		"the midday bed is pulled well back"
	)


func test_scheduled_gaps_are_wide_and_never_share_a_beat() -> void:
	# The DoD gate at the level of the SCHEDULER — two voices, de-clustering active, 60 Hz ticks.
	# This is the distribution the player actually hears.
	var r := _run(11, DAWN, 3600.0)
	var s := _stats(_gaps(r["times"]))
	assert_gt(int(s["n"]), 100, "an hour of dawn produces plenty of calls to measure")
	assert_gt(float(s["sd"]) / float(s["mean"]), 0.5, "scheduled gaps are Poisson-wide")
	assert_gt(float(s["max"]), float(s["mean"]) * 2.5, "long quiet stretches actually happen")
	assert_true(
		float(s["min"]) >= BirdCalls.MIN_GLOBAL_GAP_S - 0.001,
		"closest pair %.3fs >= the de-cluster floor %.2fs" % [s["min"], BirdCalls.MIN_GLOBAL_GAP_S]
	)
	assert_gt(int(r["sched"].calls_deferred), 0, "the de-cluster rule actually fired at dawn")


func test_density_falls_from_dawn_to_midday_and_sleeps_at_night() -> void:
	var dawn_n: int = _run(5, DAWN, 3600.0)["times"].size()
	var noon_n: int = _run(5, NOON, 3600.0)["times"].size()
	gut.p("T-733 layer density — dawn %.2f/min, noon %.2f/min" % [dawn_n / 60.0, noon_n / 60.0])
	assert_gt(dawn_n, noon_n * 3, "the dawn chorus is multiples denser than midday")
	assert_gt(noon_n, 0, "midday still has the occasional bird")
	assert_lt(noon_n / 60.0, 2.0, "midday is under two calls a minute across the whole layer")
	assert_eq(_run(5, MIDNIGHT, 3600.0)["times"].size(), 0, "the layer sleeps at night")


func test_a_voice_never_overlaps_itself() -> void:
	var b := BirdCalls.new()
	b.rng.seed = 99
	b.add_voice("solo")
	var t := 0.0
	var last := -999.0
	while t < 1800.0:
		for c: Dictionary in b.tick(DT, DAWN):
			assert_gt(t - last, float(c["burst_s"]), "the previous call finished before this one")
			last = t
		t += DT
	assert_gt(b.calls_fired, 20, "the solo voice called repeatedly over half an hour")


func test_per_call_variation_stays_inside_the_tasteful_band() -> void:
	var prof: Dictionary = BirdCalls.PROFILES["tree"]
	var r := _run(31, DAWN, 3600.0)
	var pitches: Array = []
	var gains: Array = []
	var offsets: Array = []
	for c: Dictionary in r["calls"]:
		pitches.append(float(c["pitch"]))
		gains.append(float(c["gain_db"]))
		offsets.append(float(c["offset_s"]))
		assert_between(
			float(c["pitch"]), prof["pitch_band"][0], prof["pitch_band"][1], "pitch band"
		)
		assert_between(float(c["gain_db"]), prof["gain_band_db"][0], 0.0, "never above zone base")
		assert_between(float(c["burst_s"]), prof["burst_s"][0], prof["burst_s"][1], "burst band")
		assert_between(float(c["offset_s"]), 0.0, prof["source_len_s"], "offset inside the source")
	# …and the variation is REAL, not a constant that happens to sit inside the band.
	var ps := _stats(pitches)
	assert_gt(
		float(ps["max"]) - float(ps["min"]),
		(float(prof["pitch_band"][1]) - float(prof["pitch_band"][0])) * 0.6,
		"per-call pitch actually sweeps the band"
	)
	assert_gt(float(_stats(gains)["sd"]), 0.5, "per-call level genuinely varies")
	# the anti-repetition win: one 9.6s asset, read from a different place every single time
	assert_gt(float(_stats(offsets)["sd"]), 1.0, "each call reads a different slice of the source")


func test_seeded_schedule_is_reproducible() -> void:
	# Same seed -> same schedule, so a mix regression is diagnosable instead of "it felt busy".
	assert_eq(
		str(_run(1234, DAWN, 600.0)["times"]),
		str(_run(1234, DAWN, 600.0)["times"]),
		"same seed, same call times"
	)


func test_envelope_fades_in_and_out() -> void:
	var f := BirdCalls.ENVELOPE_FLOOR_DB
	assert_almost_eq(
		BirdCalls.envelope_db(0.0, 2.0, 0.2, 0.4), f, 0.001, "starts silent (no click)"
	)
	assert_almost_eq(BirdCalls.envelope_db(2.0, 2.0, 0.2, 0.4), f, 0.001, "ends silent (no click)")
	assert_almost_eq(BirdCalls.envelope_db(1.0, 2.0, 0.2, 0.4), 0.0, 0.001, "full through sustain")
	assert_lt(
		BirdCalls.envelope_db(0.05, 2.0, 0.2, 0.4),
		BirdCalls.envelope_db(0.15, 2.0, 0.2, 0.4),
		"the attack rises"
	)
	assert_lt(
		BirdCalls.envelope_db(1.95, 2.0, 0.2, 0.4),
		BirdCalls.envelope_db(1.70, 2.0, 0.2, 0.4),
		"the release falls away"
	)
