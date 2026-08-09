extends GutTest

# T-737: the locomotion footfall scheduler. Pure RefCounted + a seeded RNG (the T-733 BirdCalls
# idiom) so a full minute of movement can be simulated headlessly at 60 Hz and the ANTI-MACHINE-GUN
# claims measured rather than eyeballed: variation rotation, non-fixed intervals, speed scaling,
# and disjoint foot-vs-mount clip sets. Playback is the caller's job; this only decides WHEN a
# footfall lands and WHICH clip/pitch/level it uses.

const Cadence = preload("res://scripts/world/footstep_cadence.gd")


func _run(seed_v: int, speed: float, mounted: bool, sim_s: float, surface := "grass") -> Dictionary:
	var c = Cadence.new()
	c.rng.seed = seed_v
	var dt := 1.0 / 60.0
	var t := 0.0
	var times: Array = []
	var events: Array = []
	while t < sim_s:
		for ev in c.tick(dt, speed, mounted, surface, false):
			times.append(t)
			events.append(ev)
		t += dt
	return {"times": times, "events": events, "cadence": c}


func _gaps(times: Array) -> Array:
	var g: Array = []
	for i in range(1, times.size()):
		g.append(times[i] - times[i - 1])
	return g


func _stats(values: Array) -> Dictionary:
	if values.is_empty():
		return {"n": 0, "mean": 0.0, "sd": 0.0}
	var sum := 0.0
	for v in values:
		sum += float(v)
	var mean := sum / values.size()
	var acc := 0.0
	for v in values:
		acc += pow(float(v) - mean, 2.0)
	return {"n": values.size(), "mean": mean, "sd": sqrt(acc / values.size())}


func test_gait_selection_splits_walk_run_and_the_two_mounted_gaits() -> void:
	assert_eq(Cadence.gait_for(2.5, false), Cadence.GAIT_WALK, "walk speed -> walk gait")
	assert_eq(Cadence.gait_for(6.0, false), Cadence.GAIT_RUN, "run speed -> run gait")
	assert_eq(Cadence.gait_for(4.0, true), Cadence.GAIT_MOUNT_WALK, "mounted walk (4.0 m/s)")
	assert_eq(Cadence.gait_for(9.6, true), Cadence.GAIT_MOUNT_GALLOP, "mounted run (9.6 m/s)")


func test_run_is_louder_than_walk_and_level_rises_with_speed() -> void:
	# The ticket's "volume scales walk vs run": the gait step is the coarse jump, and level still
	# climbs continuously INSIDE a gait so a hard sprint is not flat against a jog.
	assert_gt(
		Cadence.gain_db(Cadence.GAIT_RUN, 6.0),
		Cadence.gain_db(Cadence.GAIT_WALK, 2.5),
		"running footfalls sit above walking ones"
	)
	assert_gt(
		Cadence.gain_db(Cadence.GAIT_RUN, 6.5),
		Cadence.gain_db(Cadence.GAIT_RUN, 4.1),
		"level rises with speed within the run gait"
	)
	# The coarse jump must dominate the fine trim: the QUIETEST run still beats the LOUDEST walk.
	assert_gt(
		Cadence.gain_db(Cadence.GAIT_RUN, 0.0),
		Cadence.gain_db(Cadence.GAIT_WALK, 999.0),
		"gait separation is never swallowed by the in-gait trim"
	)


func test_foot_and_mount_clip_sets_are_disjoint() -> void:
	var foot := {}
	for ev in _run(11, 6.0, false, 20.0)["events"]:
		foot[ev["clip"]] = true
	var mounted := {}
	for ev in _run(11, 9.6, true, 20.0)["events"]:
		mounted[ev["clip"]] = true
	assert_gt(foot.size(), 0, "on foot fires clips")
	assert_gt(mounted.size(), 0, "mounted fires clips")
	for clip in foot.keys():
		assert_true(str(clip).begins_with("step_"), "foot clip is a surface footfall: " + str(clip))
	for clip in mounted.keys():
		assert_true(
			str(clip).begins_with("mount_step_"), "mounted clip is a mount gait: " + str(clip)
		)
	for clip in mounted.keys():
		assert_false(foot.has(clip), "mounted never reuses a boot clip: " + str(clip))


func test_surface_selects_the_matching_clip_family() -> void:
	for surface in Cadence.SURFACES:
		var events: Array = _run(5, 6.0, false, 8.0, surface)["events"]
		assert_gt(events.size(), 0, surface + " fired footfalls")
		for ev in events:
			assert_eq(ev["surface"], surface, "event carries its surface")
			assert_true(
				str(ev["clip"]).begins_with("step_" + surface + "_"),
				"clip belongs to the %s family: %s" % [surface, str(ev["clip"])]
			)


func test_faster_movement_fires_more_footfalls_per_second() -> void:
	var walk: Array = _run(3, 2.5, false, 20.0)["events"]
	var run: Array = _run(3, 6.0, false, 20.0)["events"]
	assert_gt(run.size(), walk.size(), "running lands more footfalls in the same 20 s")
	gut.p("footfalls/20s: walk=%d run=%d" % [walk.size(), run.size()])


func test_cadence_is_distance_keyed_not_time_keyed() -> void:
	# 60 m covered at two different speeds inside the SAME gait must cost the same number of
	# strides. A time-keyed scheduler (the old fixed 340 ms footstep_if_due) would differ by ~20%.
	var slow: Array = _run(9, 5.0, false, 12.0)["events"]  # 5.0 * 12 = 60 m
	var fast: Array = _run(9, 6.0, false, 10.0)["events"]  # 6.0 * 10 = 60 m
	assert_gt(slow.size(), 10, "enough strides to be meaningful")
	assert_lt(
		absi(slow.size() - fast.size()),
		2,
		"same distance -> same stride count (%d vs %d)" % [slow.size(), fast.size()]
	)


func test_a_variation_never_repeats_back_to_back() -> void:
	var events: Array = _run(21, 6.0, false, 90.0)["events"]
	assert_gt(events.size(), 200, "a long sample of footfalls")
	var repeats := 0
	for i in range(1, events.size()):
		if events[i]["clip"] == events[i - 1]["clip"]:
			repeats += 1
	assert_eq(repeats, 0, "no clip ever plays twice in a row (the machine-gun read)")


func test_every_variation_is_used_and_the_rotation_is_even() -> void:
	var counts := {}
	var events: Array = _run(33, 6.0, false, 90.0)["events"]
	for ev in events:
		counts[ev["index"]] = int(counts.get(ev["index"], 0)) + 1
	assert_eq(counts.size(), Cadence.VARIATIONS, "all %d variations get used" % Cadence.VARIATIONS)
	var expected := float(events.size()) / float(Cadence.VARIATIONS)
	for idx in counts.keys():
		# a shuffle-bag is far tighter than random choice; 35% slack is generous
		assert_lt(
			absf(float(counts[idx]) - expected) / expected,
			0.35,
			"variation %s is not starved" % idx
		)


func test_intervals_are_neither_a_metronome_nor_random_noise() -> void:
	# The DoD is "no fixed-interval repetition read". Coefficient of variation is the instrument:
	# a metronome is 0.0; this must be clearly above that, but a gait is still periodic, so it
	# must stay well under the Poisson-like spread used for bird calls (T-733 asserts CV > 0.5).
	var res := _run(44, 6.0, false, 120.0)
	var gaps := _gaps(res["times"])
	var st := _stats(gaps)
	assert_gt(st["n"], 300, "plenty of intervals")
	var cv: float = st["sd"] / st["mean"]
	gut.p("interval mean=%.4fs sd=%.4fs CV=%.4f n=%d" % [st["mean"], st["sd"], cv, st["n"]])
	assert_gt(cv, 0.03, "intervals are NOT fixed (CV above metronome)")
	assert_lt(cv, 0.35, "intervals still read as a gait, not as random scatter")


func test_pitch_jitter_varies_every_footfall_and_stays_in_band() -> void:
	var events: Array = _run(55, 6.0, false, 40.0)["events"]
	var pitches: Array = []
	for ev in events:
		pitches.append(ev["pitch"])
	var band: Array = Cadence.GAITS[Cadence.GAIT_RUN]["pitch_band"]
	for p in pitches:
		assert_between(float(p), float(band[0]), float(band[1]), "pitch inside the gait band")
	assert_gt(_stats(pitches)["sd"], 0.005, "pitch actually varies footfall to footfall")


func test_seeded_runs_reproduce_exactly() -> void:
	var a := _run(1234, 6.0, false, 20.0)
	var b := _run(1234, 6.0, false, 20.0)
	assert_eq(str(a["events"]), str(b["events"]), "same seed -> identical schedule")
	var c := _run(4321, 6.0, false, 20.0)
	assert_ne(str(a["events"]), str(c["events"]), "a different seed -> a different schedule")


func test_standing_still_and_airborne_are_silent() -> void:
	var c = Cadence.new()
	c.rng.seed = 7
	var fired := 0
	for _i in range(600):
		fired += c.tick(1.0 / 60.0, 0.0, false, "grass", false).size()
	assert_eq(fired, 0, "standing still never lands a footfall")
	for _i in range(600):
		fired += c.tick(1.0 / 60.0, 6.0, false, "grass", true).size()
	assert_eq(fired, 0, "airborne never lands a footfall (no steps mid-jump)")


func test_the_first_stride_after_a_stop_lands_promptly() -> void:
	# Parking the accumulator near-due on a stop is what keeps a start-walking feel responsive
	# instead of silently swallowing the first stride.
	var c = Cadence.new()
	c.rng.seed = 8
	for _i in range(120):
		c.tick(1.0 / 60.0, 0.0, false, "grass", false)
	var fired := 0
	for _i in range(30):  # half a second of running
		fired += c.tick(1.0 / 60.0, 6.0, false, "grass", false).size()
	assert_gt(fired, 0, "a footfall lands within the first half second of moving off")


func test_a_teleport_sized_jump_makes_no_sound() -> void:
	# Regression, found in-world by the T-415 audio-graph dump: callers derive speed from ONE
	# frame's displacement, so a spawn snap / respawn / position resync reads as hundreds of m/s
	# for a single frame. Before this guard, every mob in the zone grew a footstep emitter at
	# spawn while standing perfectly still — including ones 120 m away.
	var c = Cadence.new()
	c.rng.seed = 12
	var fired := 0
	for _i in range(120):
		fired += c.tick(1.0 / 60.0, 400.0, false, "grass", false).size()
	assert_eq(fired, 0, "a teleport-sized jump is not locomotion and makes no sound")
	# ...and a real gallop, the fastest thing in the game, is still under the ceiling.
	assert_lt(9.6, Cadence.MAX_SPEED_MPS, "a galloping mount still registers as movement")
	assert_gt(
		(
			c.tick(1.0 / 60.0, 9.6, true, "grass", false).size()
			+ _run(12, 9.6, true, 4.0)["events"].size()
		),
		0,
		"mounted gallop still fires footfalls"
	)


func test_a_frame_hitch_does_not_dump_a_burst_of_footfalls() -> void:
	var c = Cadence.new()
	c.rng.seed = 9
	var fired: int = c.tick(2.0, 6.0, false, "grass", false).size()  # a 2 s stall = ~6 strides
	assert_lte(fired, Cadence.MAX_STEPS_PER_TICK, "a hitch is capped, not machine-gunned")
