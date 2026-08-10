extends GutTest

# T-111: the AudioManager is built in code, so its wiring is headlessly unit-testable (the actual
# SOUND can't be verified without an audio device — these prove the stream/loop/pool wiring is
# correct, i.e. the world will emit a looping ambience + one-shots).

const AudioManager = preload("res://scripts/audio/audio_manager.gd")


func _am():
	var am = AudioManager.new()
	add_child_autofree(am)  # _ready loads the ambient stream + builds the SFX pool
	return am


# T-756: the Music bus is process-global AudioServer state, not per-test state.
# _ensure_music_bus() below ADDS a bus that nothing ever removed, and every duck test writes
# that bus's volume — so this file leaked audio state forward into every later test in the same
# process (test_music_bed.gd builds the same bus and reads it). T-752 left a single manual
# `am.set_music_volume_db(0.0)` at the tail of one test, which restores an ASSUMED default
# rather than the value that was actually there, and is skipped entirely the moment an assert
# above it fails. Snapshot the real prior state; restore it unconditionally.
var _music_bus_existed := false
var _music_bus_db := 0.0


func before_each() -> void:
	var idx := AudioServer.get_bus_index(AudioManager.MUSIC_BUS)
	_music_bus_existed = idx != -1
	_music_bus_db = AudioServer.get_bus_volume_db(idx) if _music_bus_existed else 0.0


func after_each() -> void:
	var idx := AudioServer.get_bus_index(AudioManager.MUSIC_BUS)
	if idx == -1:
		return
	if _music_bus_existed:
		AudioServer.set_bus_volume_db(idx, _music_bus_db)
	else:
		AudioServer.remove_bus(idx)  # this file created it — leave the server as we found it


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


# T-737: the T-111 `footstep_if_due` hook is GONE — a fixed 340 ms wall-clock cadence playing one
# sample at one volume was the machine-gun the ticket was filed about. Footfalls are now scheduled
# by FootstepCadence (distance-keyed, 4 rotating variations, pitch + stride jitter, surface-aware)
# and played through this same pool; see test_footstep_cadence.gd / test_locomotion_audio.gd.
func test_the_fixed_interval_footstep_hook_is_retired() -> void:
	var am = _am()
	assert_false(
		am.has_method("footstep_if_due"), "the fixed-cadence footstep hook must not come back"
	)


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


# The Music bus is created by MusicBedLayer, which may not have been built yet in this process.
# Create it (bus only — no bed players, no WAV loads) so the duck tests below always really assert
# instead of taking the "no bus, nothing to check" branch the T-503 version could silently take.
func _ensure_music_bus() -> int:
	if AudioServer.get_bus_index(AudioManager.MUSIC_BUS) == -1:
		var m := MusicBedLayer.new()
		m._ensure_bus()
		m.free()
	return AudioServer.get_bus_index(AudioManager.MUSIC_BUS)


# A 40% Music slider, in the dB the settings panel actually sends (settings_panel._slider_db:
# lerp(-40, 0, pct/100)). Named because the whole point of these tests is that the duck is
# measured RELATIVE to a real slider position, never against an implied full-volume default.
const USER_40_PCT_DB := -24.0


# T-503/T-752: the impact ducks the Music bus RELATIVE to the player's Music slider and recovers to
# that level. The T-503 version of this test set no slider level and asserted recovery to 0.0 dB —
# it codified the bug rather than catching it: at this 40% (-24 dB) setting the old absolute
# -12 dB "duck" was a +12 dB BOOST, and the recovery ramp then parked the bus at full volume.
func test_music_duck_dips_relative_to_the_user_level_and_recovers_to_it() -> void:
	var am = _am()
	var bus := _ensure_music_bus()
	assert_ne(bus, -1, "the Music bus exists for this test")
	am.set_music_volume_db(USER_40_PCT_DB)
	assert_almost_eq(
		AudioServer.get_bus_volume_db(bus),
		USER_40_PCT_DB,
		0.001,
		"the user's Music slider sets the bus (routed through AudioManager, T-752)"
	)
	am.duck_music()
	assert_almost_eq(
		AudioServer.get_bus_volume_db(bus),
		USER_40_PCT_DB + AudioManager.MUSIC_DUCK_DB,
		0.001,
		"the duck SUBTRACTS from the user's level (composed, not an absolute -12 dB)"
	)
	assert_lt(
		AudioServer.get_bus_volume_db(bus),
		USER_40_PCT_DB,
		"a duck is quieter than the user's level — at 40% the old absolute duck was +12 dB LOUDER"
	)
	for _i in range(120):  # ~2s of recovery at 60fps — well past the ~0.5s ramp
		am._process(0.016)
	assert_almost_eq(
		AudioServer.get_bus_volume_db(bus),
		USER_40_PCT_DB,
		0.01,
		"recovery lands back on the user's level, NOT on full volume"
	)
	# (T-756: the AudioServer restore moved to after_each — it must not depend on the asserts
	# above this line all having passed.)


# T-752: the invariant, swept across the slider — a duck can never make the score louder, at any
# position, and recovery always returns exactly to the chosen level.
func test_duck_never_exceeds_the_user_level_at_any_slider_position() -> void:
	var am = _am()
	assert_ne(_ensure_music_bus(), -1, "the Music bus exists for this test")
	for user_db: float in [0.0, -6.0, USER_40_PCT_DB, -30.0, -40.0]:
		am.set_music_volume_db(user_db)
		am.duck_music()
		assert_almost_eq(
			am.music_bus_db(),
			user_db + AudioManager.MUSIC_DUCK_DB,
			0.001,
			"duck at %.1f dB = user + duck" % user_db
		)
		assert_lt(
			am.music_bus_db(), user_db, "the duck never exceeds the user level at %.1f dB" % user_db
		)
		for _i in range(120):
			am._process(0.016)
		assert_almost_eq(am.music_bus_db(), user_db, 0.01, "recovers to %.1f dB" % user_db)
	am.set_music_volume_db(0.0)


# T-752: the composition holds in the other order too — dragging the slider DURING a duck must keep
# the dip (the old code would have had the slider write win and cancel the duck outright).
func test_moving_the_slider_mid_duck_keeps_the_dip() -> void:
	var am = _am()
	assert_ne(_ensure_music_bus(), -1, "the Music bus exists for this test")
	am.duck_music()
	am.set_music_volume_db(-20.0)
	assert_almost_eq(
		am.music_bus_db(),
		-20.0 + AudioManager.MUSIC_DUCK_DB,
		0.001,
		"a slider move mid-duck re-composes; it does not cancel the dip"
	)
	am.set_music_volume_db(0.0)


# T-752: the bus-name literal drift ("Music" written out in both files) is gone — one const. Proved
# end-to-end rather than by string identity: the bus AudioManager ducks is the bus the music beds
# actually route their playback to.
func test_the_duck_targets_the_bus_the_music_beds_play_on() -> void:
	var m := MusicBedLayer.new()
	add_child_autofree(m)
	var routed := ""
	for c in m.get_children():
		if c is AudioStreamPlayer:
			routed = str((c as AudioStreamPlayer).bus)
	assert_eq(routed, AudioManager.MUSIC_BUS, "the ducked bus is the one the beds play on")


# T-752 (bonus): ~50 sources sum into Master with no headroom protection. One hard limiter, at its
# default -0.3 dBFS ceiling (inaudible below the ceiling), installed exactly once however many
# AudioManagers are built.
func test_master_carries_exactly_one_hard_limiter() -> void:
	_am()  # _ready installs it
	_am()  # a second manager must not stack a second limiter
	var bus := AudioServer.get_bus_index(AudioManager.MASTER_BUS)
	assert_ne(bus, -1, "a Master bus exists")
	var limiters := 0
	for i in AudioServer.get_bus_effect_count(bus):
		if AudioServer.get_bus_effect(bus, i) is AudioEffectHardLimiter:
			limiters += 1
	assert_eq(limiters, 1, "exactly one hard limiter on Master (idempotent)")


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
