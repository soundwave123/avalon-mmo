extends GutTest

# T-737: the playback side of locomotion audio. Own footfalls go through the AudioManager 2D pool
# (always centred, always audible); OTHER players and mobs get a positional AudioStreamPlayer3D
# parented to their body and reused, so the T-415 audio-graph dump can see the emitters and the
# mix falls off with distance. Also the inverted T-415 gate: every locomotion clip is a ONE-SHOT
# and its import must leave looping OFF, or a single footstep becomes an infinite drone.

const Loco = preload("res://scripts/audio/locomotion_audio.gd")
const Cadence = preload("res://scripts/world/footstep_cadence.gd")


func _body() -> Node3D:
	var n := Node3D.new()
	add_child_autofree(n)
	return n


func test_every_cadence_clip_is_registered_in_the_sfx_table() -> void:
	# The scheduler can only name clips the AudioManager can actually load — otherwise play_sfx
	# silently no-ops and the game ships silent again (the T-415 failure mode).
	var names: Array = []
	for surface in Cadence.SURFACES:
		for i in range(Cadence.VARIATIONS):
			names.append(Cadence.clip_for(Cadence.GAIT_WALK, surface, i))
	for i in range(Cadence.VARIATIONS):
		names.append(Cadence.clip_for(Cadence.GAIT_MOUNT_GALLOP, "grass", i))
	assert_eq(names.size(), Cadence.SURFACES.size() * Cadence.VARIATIONS + Cadence.VARIATIONS)
	for n in names:
		assert_true(AudioManager.SFX.has(n), "%s is registered for playback" % n)


func test_every_locomotion_clip_loads_and_never_loops() -> void:
	# Inverted T-415 discipline: beds MUST loop, one-shots MUST NOT. A looping footstep is the
	# worst possible bug here — it never stops.
	var checked := 0
	for n in Loco.clip_names():
		var s = load(AudioManager.SFX[n])
		assert_not_null(s, "%s loads" % n)
		assert_true(s is AudioStreamWAV, "%s is a WAV sample" % n)
		assert_eq((s as AudioStreamWAV).loop_mode, AudioStreamWAV.LOOP_DISABLED, "%s loop OFF" % n)
		checked += 1
	assert_eq(checked, 20, "all 16 surface footfalls + 4 mount falls are covered")


func test_clips_are_short_one_shots_not_beds() -> void:
	# A belt-and-braces sanity bound: a footfall is a fraction of a second. If someone ever points
	# one of these names at a bed WAV, this catches it before it loops the meadow under your boots.
	for n in Loco.clip_names():
		var s := load(AudioManager.SFX[n]) as AudioStreamWAV
		assert_lt(s.get_length(), 1.0, "%s is a one-shot (%.3fs)" % [n, s.get_length()])


func test_an_emitter_is_created_once_and_then_reused() -> void:
	var body := _body()
	var a := Loco.ensure_emitter(body)
	assert_not_null(a, "an emitter is created for a remote body")
	assert_true(a is AudioStreamPlayer3D, "remote footfalls are positional")
	var b := Loco.ensure_emitter(body)
	assert_eq(a, b, "the same emitter is reused, not re-created every footfall")
	var found := body.find_children("*", "AudioStreamPlayer3D", true, false)
	assert_eq(found.size(), 1, "exactly one emitter per body — no leak per step")


func test_the_emitter_is_configured_to_fall_off_with_distance() -> void:
	# Mirrors the AmbientFxLayer.build_emitters() attenuation block that T-415 already verified.
	var e := Loco.ensure_emitter(_body())
	assert_eq(e.attenuation_model, AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE)
	assert_gt(e.unit_size, 0.0, "a real audible radius")
	assert_gt(e.max_distance, e.unit_size, "culled beyond the audible radius")
	assert_eq(e.max_db, 0.0, "never boosted when the emitter is right on top of the camera")


func test_remote_footfalls_are_quieter_than_your_own() -> void:
	# The ticket asks for other players to be present but not to compete with your own feet.
	#
	# T-756: the old second assertion was `own + REMOTE_TRIM_DB < own` — pure algebra, true for
	# any negative constant whatsoever, and it never touched the playback path. Deleting the
	# `+ REMOTE_TRIM_DB` from play_remote_steps (the actual regression it is named against) left
	# it passing. Drive the real call and read the level off the emitter.
	assert_lt(Loco.REMOTE_TRIM_DB, 0.0, "remote steps are trimmed down, not up")
	var own := Cadence.gain_db(Cadence.GAIT_RUN, 6.0)
	var body := _body()
	Loco.play_remote_steps(body, [{"clip": "step_grass_1", "gain_db": own, "pitch": 1.0}])
	var e := Loco.ensure_emitter(body)
	assert_almost_eq(
		e.volume_db,
		own + Loco.REMOTE_TRIM_DB,
		0.001,
		"the remote path applies the trim to the emitter it actually plays"
	)
	assert_lt(e.volume_db, own, "a remote runner sits under your own footfalls")


func test_playing_a_remote_step_arms_the_emitter() -> void:
	var body := _body()
	var e := Loco.play_step_3d(body, "step_grass_1", -14.0, 1.03)
	assert_not_null(e, "a known clip plays")
	assert_not_null(e.stream, "the emitter got a stream assigned")
	assert_almost_eq(e.pitch_scale, 1.03, 0.0001, "per-footfall pitch jitter reaches the emitter")


func test_a_newly_spawned_entity_is_silent_on_its_first_frame() -> void:
	# Regression found in-world with the T-415 audio-graph dump: every mob in the zone had grown a
	# footstep emitter at spawn while standing perfectly still. Frame one's "speed" is the spawn
	# snap, not a stride, so it must produce nothing at all.
	var body := _body()
	var e := {}
	LocomotionAudio.tick_entity(e, body, 1.0 / 60.0, 240.0)  # a big spawn jump
	assert_null(
		body.get_node_or_null(LocomotionAudio.EMITTER_NAME),
		"no emitter is created for an entity that only just appeared"
	)
	# ...and a genuinely walking entity on a later frame still gets one.
	for _i in range(90):
		LocomotionAudio.tick_entity(e, body, 1.0 / 60.0, 6.0)
	assert_not_null(
		body.get_node_or_null(LocomotionAudio.EMITTER_NAME), "a walking entity does get an emitter"
	)


func test_an_unknown_clip_is_a_silent_no_op_not_a_crash() -> void:
	# Fail-closed, matching AudioManager.play_sfx: a missing asset drops that footfall rather
	# than taking the client down mid-run.
	assert_null(Loco.play_step_3d(_body(), "step_lava_9", -14.0, 1.0), "unknown clip ignored")
