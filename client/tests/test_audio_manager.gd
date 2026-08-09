extends GutTest

# T-111: the AudioManager is built in code, so its wiring is headlessly unit-testable (the actual
# SOUND can't be verified without an audio device — these prove the stream/loop/pool wiring is
# correct, i.e. the world will emit a looping ambience + one-shots).

const AudioManager = preload("res://scripts/audio/audio_manager.gd")


func _am():
	var am = AudioManager.new()
	add_child_autofree(am)  # _ready loads the ambient stream + builds the SFX pool
	return am


func test_ambient_stream_loaded_and_looping() -> void:
	var am = _am()
	assert_not_null(am.ambient, "ambient AudioStreamPlayer exists")
	assert_true(am.ambient.stream is AudioStream, "ambient has a stream assigned")
	assert_true(am.ambient.autoplay, "ambient autoplays")
	if am.ambient.stream is AudioStreamWAV:
		assert_eq(
			am.ambient.stream.loop_mode,
			AudioStreamWAV.LOOP_FORWARD,
			"ambient stream is set to loop (no silence gap)"
		)


func test_sfx_pool_built() -> void:
	var am = _am()
	var pool := 0
	for c in am.get_children():
		if c is AudioStreamPlayer and String(c.name).begins_with("Sfx"):
			pool += 1
	assert_gt(pool, 1, "a one-shot SFX pool was built")


func test_play_sfx_assigns_known_stream() -> void:
	var am = _am()
	am.play_sfx("hit")
	var assigned := false
	for c in am.get_children():
		if c is AudioStreamPlayer and String(c.name).begins_with("Sfx") and c.stream != null:
			assigned = true
	assert_true(assigned, "play_sfx('hit') assigned a stream to a pool player")


# T-343 p3: play_sfx grew a pitch param (one file -> several re-tuned ability variants). The trap
# guarded here: the pool players are SHARED, so a pitched play must never leak its pitch into the
# next default-pitch one-shot on the same player pool.
func test_play_sfx_pitch_variant_sets_then_resets_on_the_pool() -> void:
	var am = _am()
	am.play_sfx("hit", -9.0, 1.3)
	assert_almost_eq(am._sfx_players[0].pitch_scale, 1.3, 0.001, "pitched play sets pitch_scale")
	am.play_sfx("hit")
	assert_almost_eq(
		am._sfx_players[1].pitch_scale, 1.0, 0.001, "a default play is back at base pitch"
	)


func test_phase3_school_cues_are_registered_one_shots() -> void:
	# T-343 p3: the per-school kit cues exist in the SFX map and import with loop OFF (the T-415
	# discipline inverted — a looped one-shot would ring forever off a single cast).
	var am = _am()
	var cues := [
		"melee_swing",
		"fire_cast",
		"fire_impact",
		"holy_cast",
		"holy_impact",
		"heal_chime",
		"shadow_cast"
	]
	for cue_name: String in cues:
		assert_true(am.SFX.has(cue_name), cue_name + " is registered in the SFX map")
		var s := load(str(am.SFX[cue_name])) as AudioStreamWAV
		assert_not_null(s, cue_name + " loads as an AudioStreamWAV")
		if s != null:
			assert_eq(s.loop_mode, AudioStreamWAV.LOOP_DISABLED, cue_name + " loop stays OFF")


func test_unknown_sfx_is_ignored_safely() -> void:
	var am = _am()
	am.play_sfx("does_not_exist")  # must be a no-op, not a crash
	assert_true(true, "unknown sfx name is ignored")


func test_footstep_is_rate_limited() -> void:
	var am = _am()
	am.footstep_if_due(100000)  # first call fires + records the time
	var t1 = am._last_step_ms
	am.footstep_if_due(100000)  # within the (huge) interval -> must NOT re-fire
	assert_eq(am._last_step_ms, t1, "footstep respects the cadence interval")


# T-503: the frostbolt CHARGE layer — a dedicated, looping cast-bar drone (not a pool one-shot).
func test_frost_charge_layer_built_and_loops() -> void:
	var am = _am()
	assert_not_null(am.charge, "the frost-charge AudioStreamPlayer exists")
	assert_true(am.charge.stream is AudioStream, "the charge layer has a stream assigned")
	if am.charge.stream is AudioStreamWAV:
		assert_eq(
			am.charge.stream.loop_mode,
			AudioStreamWAV.LOOP_FORWARD,
			"the charge bed loops (covers any cast length without a gap)"
		)
	assert_false(am.is_charging(), "the charge layer is silent until a cast starts")


func test_start_charge_plays_at_the_low_pitch() -> void:
	var am = _am()
	am.start_charge()
	assert_true(am.is_charging(), "start_charge begins the charge layer")
	assert_almost_eq(
		am.charge.pitch_scale, AudioManager.CHARGE_PITCH_LO, 0.001, "charge starts at the low pitch"
	)


func test_charge_progress_ramps_pitch_up_then_stop_ends_it() -> void:
	var am = _am()
	am.start_charge()
	am.set_charge_progress(1.0)  # cast full -> the top of the rise
	assert_almost_eq(
		am.charge.pitch_scale, AudioManager.CHARGE_PITCH_HI, 0.001, "a full cast rises to hi pitch"
	)
	am.stop_charge()
	assert_false(am.is_charging(), "stop_charge ends the layer (impact / interrupt)")


# T-503: the impact ducks the Music bus, then _process recovers it back toward 0 dB.
func test_music_duck_dips_the_bus_and_recovers() -> void:
	var am = _am()
	var bus := AudioServer.get_bus_index(AudioManager.MUSIC_BUS)
	if bus == -1:  # no Music bus in this headless run -> duck is a safe no-op, nothing to assert
		am.duck_music()  # must not crash
		assert_true(true, "duck_music is a safe no-op without the Music bus")
		return
	am.duck_music()
	assert_almost_eq(
		AudioServer.get_bus_volume_db(bus),
		AudioManager.MUSIC_DUCK_DB,
		0.001,
		"duck_music dips the Music bus"
	)
	for _i in range(120):  # ~2s of recovery at 60fps — well past the ~0.5s ramp
		am._process(0.016)
	assert_almost_eq(
		AudioServer.get_bus_volume_db(bus), 0.0, 0.01, "the duck recovers back to 0 dB"
	)


# T-078: the settings menu drives these volume setters.
func test_set_sfx_volume_db_offsets_future_one_shots() -> void:
	var am = _am()
	am.set_sfx_volume_db(-12.0)
	am.play_sfx("hit", -9.0)  # per-call -9 dB + the stored -12 dB user offset
	var found := 999.0
	for c in am.get_children():
		if c is AudioStreamPlayer and String(c.name).begins_with("Sfx") and c.stream != null:
			found = c.volume_db
	assert_almost_eq(found, -21.0, 0.001, "play_sfx respects the stored SFX volume offset")


func test_set_ambient_volume_db_offsets_the_base() -> void:
	var am = _am()
	am.set_ambient_volume_db(-8.0)
	assert_almost_eq(
		am.ambient.volume_db,
		AudioManager.AMBIENT_BASE_DB - 8.0,
		0.001,
		"ambient = base + user offset"
	)


# T-305: a daytime birdsong bed loops under the meadow so open ground isn't a flat drone.
func test_birdsong_bed_loaded_and_looping() -> void:
	var am = _am()
	assert_not_null(am.birdsong, "birdsong bed AudioStreamPlayer exists")
	assert_true(am.birdsong.stream is AudioStream, "birdsong has a stream assigned")
	assert_true(am.birdsong.autoplay, "birdsong autoplays")
	if am.birdsong.stream is AudioStreamWAV:
		assert_eq(
			am.birdsong.stream.loop_mode, AudioStreamWAV.LOOP_FORWARD, "birdsong loops seamlessly"
		)


func test_birdsong_day_gate_lifts_to_base_in_daylight() -> void:
	# T-305: with no WorldView day-clock parent _day_factor() defaults to daylight (1.0), so one
	# _process tick drives the bed to exactly its base level (no night attenuation term).
	var am = _am()
	am._process(0.016)
	assert_almost_eq(
		am.birdsong.volume_db,
		AudioManager.BIRDSONG_BASE_DB,
		0.001,
		"daylight birdsong sits at its base level (night atten term is zero)"
	)


# T-409: the Era-2 Ashmoor city-hum bed loops like the meadow but is born era-gated (silent outside
# the district), and one headless _process tick keeps it silenced (no camera = medieval listener)
# while the meadow stays at its base level — the eras never share ambience.
func test_ashmoor_hum_bed_loaded_looping_and_born_gated() -> void:
	var am = _am()
	assert_not_null(am.ashmoor_hum, "ashmoor hum bed AudioStreamPlayer exists")
	assert_true(am.ashmoor_hum.stream is AudioStream, "hum has a stream assigned")
	if am.ashmoor_hum.stream is AudioStreamWAV:
		assert_eq(
			am.ashmoor_hum.stream.loop_mode, AudioStreamWAV.LOOP_FORWARD, "hum loops seamlessly"
		)
	assert_almost_eq(
		am.ashmoor_hum.volume_db,
		AudioManager.ASHMOOR_HUM_BASE_DB + AmbientFxLayer.ERA_MISMATCH_ATTEN_DB,
		0.001,
		"the Era-2 hum is born silenced outside the district"
	)


func test_era_gate_keeps_hum_silent_and_meadow_at_base_outside_ashmoor() -> void:
	var am = _am()
	am._process(0.016)  # headless: no camera -> medieval listener
	assert_almost_eq(
		am.ashmoor_hum.volume_db,
		AudioManager.ASHMOOR_HUM_BASE_DB + AmbientFxLayer.ERA_MISMATCH_ATTEN_DB,
		0.001,
		"the Era-2 hum stays era-silenced in the medieval world"
	)
	assert_almost_eq(
		am.ambient.volume_db,
		AudioManager.AMBIENT_BASE_DB,
		0.001,
		"the meadow bed plays at base in its own era (era term is zero)"
	)


# T-187: indoor ambience gating layers ON TOP of the user's slider offset, never overwriting it.
func test_indoor_muffle_layers_on_top_of_user_offset() -> void:
	var am = _am()
	am.set_ambient_volume_db(-8.0)  # the user turned ambience down a bit
	am.set_indoor_muffle(true)
	assert_almost_eq(
		am.ambient.volume_db,
		AudioManager.AMBIENT_BASE_DB - 8.0 + AudioManager.AMBIENT_INDOOR_MUFFLE_DB,
		0.001,
		"indoors: base + user offset + muffle"
	)
	am.set_indoor_muffle(false)
	assert_almost_eq(
		am.ambient.volume_db,
		AudioManager.AMBIENT_BASE_DB - 8.0,
		0.001,
		"exiting restores exactly the user's offset, not a re-derived absolute"
	)
