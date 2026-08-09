extends GutTest

# T-321: the WoW-parity movement-feel math is pure (no nodes, no physics, no OS time), so the
# run/walk speed choice, the desired-velocity mapping, and the acceleration/deceleration + turn
# smoothing curve are all unit-tested here without the engine input loop. The rig wiring + the
# subjective feel pass live in local_player.gd and are deferred to the orchestrator.

const PlayerMovement = preload("res://scripts/world/player_movement.gd")
const AnimStateMachine = preload("res://scripts/world/anim_state_machine.gd")


# --- Run/walk speed choice ---
func test_run_speed_is_the_shipped_move_speed() -> void:
	assert_almost_eq(PlayerMovement.target_speed(false), 6.0, 0.0001, "run = shipped MOVE_SPEED")


func test_walk_speed_is_below_the_anim_run_threshold() -> void:
	# The whole point of the walk toggle: a walk-speed move must read as the WALK clip, not run.
	assert_lt(
		PlayerMovement.target_speed(true),
		AnimStateMachine.RUN_THRESHOLD_MPS,
		"walk speed is below the anim run threshold, so walk produces a walk clip"
	)


func test_walk_speed_is_still_actual_movement() -> void:
	assert_gt(PlayerMovement.target_speed(true), 0.0, "walk still moves the character")


func test_toggle_flips_walk_state() -> void:
	assert_true(PlayerMovement.toggled_walk(false), "run -> walk")
	assert_false(PlayerMovement.toggled_walk(true), "walk -> run")


# --- T-572: mount speed (the bug — mounting used to change nothing) ---
func test_mounted_speed_is_the_documented_multiplier_of_on_foot_run() -> void:
	assert_almost_eq(
		PlayerMovement.target_speed(false, true),
		PlayerMovement.RUN_SPEED * PlayerMovement.MOUNT_SPEED_MULT,
		0.0001,
		"mounted run = on-foot run * the documented mount multiplier"
	)
	assert_gt(
		PlayerMovement.target_speed(false, true),
		PlayerMovement.target_speed(false, false),
		"mounting must actually move the player faster (T-572: it used to be a no-op)"
	)


func test_mount_overrides_the_walk_toggle() -> void:
	# No slow-mount clip exists — a mounted player always moves at the mount's run tier.
	assert_almost_eq(
		PlayerMovement.target_speed(true, true),
		PlayerMovement.RUN_SPEED_MOUNTED,
		0.0001,
		"mount speed wins over a stale walk toggle"
	)


func test_default_target_speed_is_unmounted_for_back_compat_callers() -> void:
	assert_almost_eq(
		PlayerMovement.target_speed(false),
		PlayerMovement.RUN_SPEED,
		0.0001,
		"mounted defaults false"
	)


# --- Desired velocity: input rotated by facing, normalised, scaled ---
func test_desired_velocity_forward_at_zero_yaw_points_minus_z() -> void:
	# W = -z; at yaw 0 the desired velocity is straight -z at the given speed (Godot ground plane).
	var v := PlayerMovement.desired_velocity(Vector3(0, 0, -1), 0.0, 6.0)
	assert_almost_eq(v.z, -6.0, 0.0001, "forward at full speed")
	assert_almost_eq(v.x, 0.0, 0.0001, "no lateral drift")


func test_desired_velocity_normalises_diagonals() -> void:
	# W+D shouldn't move root-2 faster than a cardinal press.
	var v := PlayerMovement.desired_velocity(Vector3(1, 0, -1), 0.0, 6.0)
	assert_almost_eq(v.length(), 6.0, 0.0001, "diagonal is clamped to the same speed")


func test_desired_velocity_zero_input_is_zero() -> void:
	assert_eq(
		PlayerMovement.desired_velocity(Vector3.ZERO, 1.23, 6.0),
		Vector3.ZERO,
		"no input => no desired velocity (caller then decelerates)"
	)


# --- Acceleration / deceleration + turn smoothing (the velocity ease) ---
func test_accel_ramps_toward_target_without_overshoot() -> void:
	var v := PlayerMovement.ease_velocity(Vector3.ZERO, Vector3(6, 0, 0), 16.0, 20.0, 0.016)
	assert_gt(v.length(), 0.0, "started accelerating from rest")
	assert_lt(v.length(), 6.0, "did not snap to full speed in one frame (momentum ramps)")


func test_accel_converges_to_full_speed() -> void:
	var v := Vector3.ZERO
	for _i in range(120):  # ~2s at 60fps
		v = PlayerMovement.ease_velocity(v, Vector3(6, 0, 0), 16.0, 20.0, 0.016)
	assert_almost_eq(v.length(), 6.0, 0.001, "reaches full run speed")


func test_decel_eases_to_rest_after_input_release() -> void:
	# Moving at full speed, target drops to zero (input released): must keep gliding, not snap.
	var v := PlayerMovement.ease_velocity(Vector3(6, 0, 0), Vector3.ZERO, 16.0, 20.0, 0.016)
	assert_lt(v.length(), 6.0, "decelerating")
	assert_gt(v.length(), 0.0, "but not an instant dead stop (deceleration curve)")


func test_decel_eventually_reaches_rest() -> void:
	var v := Vector3(6, 0, 0)
	for _i in range(120):
		v = PlayerMovement.ease_velocity(v, Vector3.ZERO, 16.0, 20.0, 0.016)
	assert_almost_eq(v.length(), 0.0, 0.001, "glides to a full stop")


func test_turn_smoothing_rotates_velocity_gradually() -> void:
	# Full speed +x, now steer to full speed +z (a 90-degree turn): the velocity vector must swing
	# through intermediate headings, not teleport its direction.
	var v := PlayerMovement.ease_velocity(Vector3(6, 0, 0), Vector3(0, 0, 6), 16.0, 20.0, 0.016)
	assert_gt(v.z, 0.0, "picked up velocity in the new heading")
	assert_gt(v.x, 0.0, "but still carries momentum in the old heading (smooth turn, not a snap)")


# --- Frame-rate independence (required for every curve) ---
func test_accel_is_framerate_independent() -> void:
	# One 0.1s step must land ~where ten 0.01s steps land (exponential ease, not raw lerp).
	var big := PlayerMovement.ease_velocity(Vector3.ZERO, Vector3(6, 0, 0), 16.0, 20.0, 0.1)
	var small := Vector3.ZERO
	for _i in range(10):
		small = PlayerMovement.ease_velocity(small, Vector3(6, 0, 0), 16.0, 20.0, 0.01)
	assert_almost_eq(big.length(), small.length(), 0.01, "same wall-clock accel at any frame size")


func test_decel_is_framerate_independent() -> void:
	var big := PlayerMovement.ease_velocity(Vector3(6, 0, 0), Vector3.ZERO, 16.0, 20.0, 0.1)
	var small := Vector3(6, 0, 0)
	for _i in range(10):
		small = PlayerMovement.ease_velocity(small, Vector3.ZERO, 16.0, 20.0, 0.01)
	assert_almost_eq(big.length(), small.length(), 0.01, "same wall-clock decel at any frame size")


func test_ease_velocity_is_noop_on_zero_or_negative_rate_or_dt() -> void:
	var cur := Vector3(6, 0, 0)
	assert_eq(
		PlayerMovement.ease_velocity(cur, Vector3.ZERO, 0.0, 0.0, 0.016), cur, "zero rate holds"
	)
	assert_eq(
		PlayerMovement.ease_velocity(cur, Vector3.ZERO, 16.0, 20.0, 0.0), cur, "zero delta holds"
	)
