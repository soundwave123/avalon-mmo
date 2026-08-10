extends GutTest

# T-752: the 3D mix must be measured at the PLAYER'S EARS, not at the camera.
#
# Godot mixes every AudioStreamPlayer3D relative to the current AudioListener3D and, when none is
# current, relative to the active Camera3D. Avalon had none — so the listening point was the WoW-
# style chase camera, which this rig parks ~8 m behind and ~5 m above the character. Three
# consequences, all of them audible: a mob swinging in your face was mixed as an 8 m-distant sound;
# remote footsteps at melee range read as across-the-street (LocomotionAudio.UNIT_SIZE is 4 m, so
# 8 m of boom is a real attenuation, not a rounding error); and the Ashmoor era gate — a -50 dB
# cliff on every ambience bed — was decided by where the CAMERA stood, so a left-drag orbit at the
# district boundary silenced or unsilenced an entire era's soundscape without the player moving.
#
# These run headless: the fix is a scene-graph relationship plus a resolution rule, and both are
# observable without an audio device. The pilot's T-415 audio-graph dump reports the same two
# numbers live (dist_to_cam vs dist_to_listener, pilot.gd _audio_graph).

const LocalPlayer = preload("res://scripts/world/local_player.gd")

# Just inside the Ashmoor district's east edge (WorldView.ASHMOOR_SOOT_RECT = [-420,-2,40,22] plus
# a 0.6 margin -> x > -460.6 and x < -379.4). At this spot the character is in the 1920s district
# but the chase camera, 8 m behind at 25 deg of tilt (~7.25 m of ground reach), is not.
const INSIDE_ASHMOOR := Vector3(-381.0, 0.0, 0.0)
const MEADOW_SPOT := Vector3(120.0, 0.0, 120.0)


func _player() -> LocalPlayer:
	var p = LocalPlayer.new()
	add_child_autofree(p)  # _ready builds the capsule, the listener, and the camera rig
	return p


func _listener_of(p: Node) -> AudioListener3D:
	return p.get_node_or_null("PlayerListener") as AudioListener3D


# ── the node exists, on the BODY, and is current ──────────────────────────────────────────────────
func test_player_builds_a_current_listener_on_the_body_not_the_camera_rig() -> void:
	var p := _player()
	var lis := _listener_of(p)
	assert_not_null(lis, "the local player builds an AudioListener3D")
	assert_eq(lis.get_parent(), p, "it hangs off the BODY, not off the camera rig")
	assert_true(lis.is_current(), "and it is made current, so it displaces the camera as listener")
	assert_almost_eq(lis.position.y, LocalPlayer.EAR_HEIGHT, 0.001, "at ear height on the body")
	assert_ne(lis.get_parent(), p.camera.get_parent(), "it is NOT parented where the camera hangs")


func test_the_viewport_reports_the_player_listener_as_the_measuring_point() -> void:
	var p := _player()
	assert_eq(
		p.get_viewport().get_audio_listener_3d(),
		_listener_of(p),
		"Godot mixes at the player's listener (not the fallback camera)"
	)
	assert_eq(
		AmbientFxLayer.listener_node(p),
		_listener_of(p),
		"and the shared resolver agrees with the engine"
	)


# ── the measured semantics change: distance is to the BODY, invariant under camera orbit ──────────
# This is the headless equivalent of the pilot audio-graph dump's dist_to_cam vs dist_to_listener,
# and the numbers it prints are the ones recorded in the ticket.
func test_emitter_distance_follows_the_body_and_ignores_camera_orbit() -> void:
	var p := _player()
	p.global_position = MEADOW_SPOT
	# A remote player's footstep emitter two metres away — inside melee range. Offset along the
	# camera's OWN axis (the rig hangs at local +Z): an emitter offset sideways happens to sit
	# equidistant from the camera before and after a half-turn, which would hide the very swing
	# this test exists to measure.
	var emitter := AudioStreamPlayer3D.new()
	add_child_autofree(emitter)
	emitter.global_position = MEADOW_SPOT + Vector3(0.0, 0.0, 2.0)
	var lis := _listener_of(p)
	var cam: Camera3D = p.camera

	var d_listener_0 := lis.global_position.distance_to(emitter.global_position)
	var d_cam_0 := cam.global_position.distance_to(emitter.global_position)
	# Orbit the camera a half-turn (T-321 left-drag swings this pivot; the body never moves).
	p._cam_yaw_pivot.rotation.y = PI
	var d_listener_1 := lis.global_position.distance_to(emitter.global_position)
	var d_cam_1 := cam.global_position.distance_to(emitter.global_position)
	# Derived, for the record: inverse-distance attenuation is 20*log10(unit_size/distance) capped
	# at max_db, so a distance RATIO is a dB figure. LocomotionAudio's emitters use unit_size 4 and
	# max_db 0, which makes the numbers above ~5 dB of wrongly-applied rolloff at melee range plus
	# ~3 dB of swing from nothing but a camera orbit.
	var rolloff := _inv_dist_db(d_cam_0) - _inv_dist_db(d_listener_0)
	var fmt := "T-752 measured (emitter 2 m from the body): listener %.2f -> %.2f m | camera"
	fmt += " %.2f -> %.2f m | camera-vs-listener = %.1f dB of rolloff at unit_size 4"
	gut.p(fmt % [d_listener_0, d_listener_1, d_cam_0, d_cam_1, rolloff])

	assert_almost_eq(
		d_listener_1, d_listener_0, 0.001, "orbiting the camera does not move the player's ears"
	)
	assert_lt(d_listener_0, 3.0, "a 2 m-away emitter is measured as a near sound (~2 m)")
	assert_gt(d_cam_0, 6.0, "the camera measured that same near sound as 6+ m away")
	assert_gt(
		d_cam_0 / d_listener_0,
		2.0,
		"the camera boom more than doubled the measured distance — >6 dB of false rolloff"
	)
	assert_gt(
		absf(d_cam_1 - d_cam_0),
		2.0,
		"and a pure camera orbit swung the camera-measured distance by metres"
	)


# Godot's ATTENUATION_INVERSE_DISTANCE, at LocomotionAudio's unit_size/max_db. Reporting only.
static func _inv_dist_db(dist: float) -> float:
	# max_db 0 = never boosted, so the linear gain is capped at 1.0 inside the unit radius.
	return linear_to_db(minf(LocomotionAudio.UNIT_SIZE / maxf(dist, 0.0001), 1.0))


# ── the era gate no longer flips with camera facing ───────────────────────────────────────────────
func test_era_gate_reads_the_body_not_the_camera_at_the_district_boundary() -> void:
	var p := _player()
	p.global_position = INSIDE_ASHMOOR
	p._yaw = PI * 0.5  # face west: the chase camera swings EAST, out of the district
	p.rotation.y = p._yaw
	var cam_pos := p.camera.global_position
	# Precondition — this test is only meaningful if the rig really did straddle the boundary.
	assert_eq(
		AmbientFxLayer.resolved_era(cam_pos.x, cam_pos.z),
		AmbientFxLayer.ERA_MEDIEVAL,
		"precondition: the camera is outside the district (the pre-T-752 listening point)"
	)
	assert_eq(
		AmbientFxLayer.listener_era(p),
		AmbientFxLayer.ERA_ASHMOOR,
		"the era gate follows the character standing in Ashmoor, not the camera outside it"
	)


func test_listener_position_decides_the_era_over_a_camera_in_the_other_era() -> void:
	# The resolution rule in isolation: a current listener always wins over the active camera.
	var cam := Camera3D.new()
	add_child_autofree(cam)
	cam.global_position = MEADOW_SPOT
	cam.current = true
	var lis := AudioListener3D.new()
	add_child_autofree(lis)
	lis.global_position = INSIDE_ASHMOOR
	lis.make_current()
	assert_eq(
		AmbientFxLayer.listener_era(lis),
		AmbientFxLayer.ERA_ASHMOOR,
		"listener in Ashmoor + camera in the meadow -> Ashmoor"
	)
	lis.clear_current()
	assert_eq(
		AmbientFxLayer.listener_era(cam),
		AmbientFxLayer.ERA_MEDIEVAL,
		"with no listener the camera is the fallback — the engine's own rule, unchanged"
	)


# ── the music score's region crossfade rides the same point ───────────────────────────────────────
func test_music_region_follows_the_listener_not_the_camera() -> void:
	var m := MusicBedLayer.new()
	add_child_autofree(m)
	var cam := Camera3D.new()
	add_child_autofree(cam)
	cam.global_position = MEADOW_SPOT  # open field -> "meadow" bed
	cam.current = true
	var lis := AudioListener3D.new()
	add_child_autofree(lis)
	lis.global_position = Vector3(2.5, 0.0, 8.0)  # the village core -> "village" bed
	lis.make_current()
	assert_eq(
		m._active_region(),
		"village",
		"the score crossfades on where the player stands, not where the camera hangs"
	)
	lis.clear_current()
	assert_eq(m._active_region(), "meadow", "camera fallback still works with no listener")
