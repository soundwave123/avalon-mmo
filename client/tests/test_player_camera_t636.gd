extends GutTest

# T-636: point-blank melee (ability range 2.5m, mob melee_range 2.0m — the NORMAL engagement
# distance) let the SpringArm probe's collided distance collapse toward 0 exactly like a tight
# wall corner would, jamming the camera lens inside the target's mesh (a large blown-out
# backface-lit blob — see the ticket screenshots). Split from test_player_camera.gd (which sits at
# the gdlint 20-public-method cap) mirroring the test_combat_feedback_cast_flash.gd precedent.
#
# Pure math only (see test_player_camera.gd's header for why): the live SpringArm3D/physics wiring
# in local_player.gd's _update_camera is play-test-verified, not unit-tested.

const PlayerCamera = preload("res://scripts/world/player_camera.gd")


# --- Entity floor distance: never collapse the camera flush against a point-blank obstruction ---
func test_entity_floor_distance_raises_a_too_close_hit() -> void:
	assert_almost_eq(
		PlayerCamera.entity_floor_distance(0.2),
		PlayerCamera.MIN_ENTITY_DISTANCE,
		0.0001,
		"a near-zero hit (point-blank mob) is floored, never left near the pivot"
	)


func test_entity_floor_distance_leaves_a_clear_distance_untouched() -> void:
	assert_almost_eq(
		PlayerCamera.entity_floor_distance(8.0),
		8.0,
		0.0001,
		"a distance already above the floor passes through unchanged"
	)


func test_entity_floor_distance_custom_floor() -> void:
	assert_almost_eq(PlayerCamera.entity_floor_distance(0.5, 2.0), 2.0, 0.0001)
	assert_almost_eq(PlayerCamera.entity_floor_distance(3.0, 2.0), 3.0, 0.0001)


# --- Close-range pitch lift: WoW over-the-shoulder read at point-blank melee ---
func test_close_range_pitch_untouched_when_clear() -> void:
	var base := deg_to_rad(-10.0)
	assert_almost_eq(
		PlayerCamera.close_range_pitch(base, PlayerCamera.CLOSE_RANGE_THRESHOLD),
		base,
		0.0001,
		"at/above the threshold there's nothing to lift for"
	)
	assert_almost_eq(
		PlayerCamera.close_range_pitch(base, 10.0), base, 0.0001, "far clear distance, no lift"
	)


func test_close_range_pitch_full_lift_at_the_entity_floor() -> void:
	var base := deg_to_rad(-10.0)
	var lifted := PlayerCamera.close_range_pitch(base, PlayerCamera.MIN_ENTITY_DISTANCE)
	var expected := PlayerCamera.clamp_pitch(
		base - deg_to_rad(PlayerCamera.CLOSE_RANGE_PITCH_LIFT_DEG)
	)
	assert_almost_eq(lifted, expected, 0.0001, "full lift at (or inside) the point-blank floor")
	assert_lt(lifted, base, "looks DOWN more (more negative pitch) at point-blank range")


func test_close_range_pitch_blends_linearly_between_threshold_and_floor() -> void:
	var base := 0.0
	var span := PlayerCamera.CLOSE_RANGE_THRESHOLD - PlayerCamera.MIN_ENTITY_DISTANCE
	var midpoint := PlayerCamera.CLOSE_RANGE_THRESHOLD - span * 0.5
	var half_lift := PlayerCamera.close_range_pitch(base, midpoint)
	var full_lift := PlayerCamera.close_range_pitch(base, PlayerCamera.MIN_ENTITY_DISTANCE)
	assert_lt(half_lift, base, "some lift partway between threshold and floor")
	assert_lt(full_lift, half_lift, "closer than the midpoint lifts further")


func test_close_range_pitch_never_exceeds_the_look_down_band() -> void:
	# Already at the look-down limit — the lift must clamp, never punch past PITCH_MIN_DEG.
	var base := deg_to_rad(PlayerCamera.PITCH_MIN_DEG)
	var lifted := PlayerCamera.close_range_pitch(base, 0.0)
	assert_almost_eq(lifted, deg_to_rad(PlayerCamera.PITCH_MIN_DEG), 0.0001)
