extends GutTest

# T-126: the WoW-parity camera-feel math is pure (no nodes, no physics, no OS time), so the zoom
# clamps, frame-rate-independent easing, the collision pull-in/pull-out asymmetry, the pitch band
# and the follow-lag are all unit-tested here without the engine input loop. The rig wiring +
# subjective feel pass live in local_player.gd and are deferred to the orchestrator.

const PlayerCamera = preload("res://scripts/world/player_camera.gd")


# --- Wheel zoom: step math + clamps ---
func test_zoom_in_shortens_distance_by_one_step() -> void:
	# Positive steps = wheel UP = zoom IN = shorter distance.
	var d := PlayerCamera.zoom_after_steps(8.0, 1)
	assert_almost_eq(d, 8.0 - PlayerCamera.ZOOM_STEP, 0.0001, "one notch in = one ZOOM_STEP closer")


func test_zoom_out_lengthens_distance_by_one_step() -> void:
	var d := PlayerCamera.zoom_after_steps(8.0, -1)
	assert_almost_eq(
		d, 8.0 + PlayerCamera.ZOOM_STEP, 0.0001, "one notch out = one ZOOM_STEP farther"
	)


func test_zoom_clamps_to_min_no_matter_how_far_in() -> void:
	var d := PlayerCamera.zoom_after_steps(PlayerCamera.ZOOM_MIN, 50)  # spam wheel-up
	assert_eq(d, PlayerCamera.ZOOM_MIN, "zoom-in floors at ZOOM_MIN (can't pass through the model)")


func test_zoom_clamps_to_max_no_matter_how_far_out() -> void:
	var d := PlayerCamera.zoom_after_steps(PlayerCamera.ZOOM_MAX, -50)  # spam wheel-down
	assert_eq(d, PlayerCamera.ZOOM_MAX, "zoom-out ceils at ZOOM_MAX")


func test_clamp_zoom_pulls_out_of_band_values_in() -> void:
	assert_eq(PlayerCamera.clamp_zoom(-3.0), PlayerCamera.ZOOM_MIN, "below-band clamps to min")
	assert_eq(PlayerCamera.clamp_zoom(999.0), PlayerCamera.ZOOM_MAX, "above-band clamps to max")


# --- Easing: convergence, no overshoot, frame-rate independence ---
func test_ease_moves_toward_target_without_overshoot() -> void:
	var v := PlayerCamera.ease_toward(0.0, 10.0, 12.0, 0.016)
	assert_gt(v, 0.0, "moved toward the target")
	assert_lt(v, 10.0, "did not overshoot the target in one step")


func test_ease_converges_over_many_steps() -> void:
	var v := 0.0
	for _i in range(240):  # ~4 simulated seconds at 60fps
		v = PlayerCamera.ease_toward(v, 10.0, 12.0, 0.016)
	assert_almost_eq(v, 10.0, 0.001, "settles onto the target")


func test_ease_is_framerate_independent() -> void:
	# One 0.1s step must land at ~the same place as ten 0.01s steps (exponential, not raw lerp).
	var big := PlayerCamera.ease_toward(0.0, 1.0, 10.0, 0.1)
	var small := 0.0
	for _i in range(10):
		small = PlayerCamera.ease_toward(small, 1.0, 10.0, 0.01)
	assert_almost_eq(big, small, 0.001, "same wall-clock settle regardless of frame size")


func test_ease_is_noop_on_zero_or_negative_rate_or_dt() -> void:
	assert_eq(PlayerCamera.ease_toward(3.0, 9.0, 0.0, 0.016), 3.0, "zero rate holds")
	assert_eq(PlayerCamera.ease_toward(3.0, 9.0, 12.0, 0.0), 3.0, "zero delta holds")
	assert_eq(PlayerCamera.ease_toward(3.0, 9.0, -5.0, 0.016), 3.0, "negative rate holds")


# --- Collision easing: pull IN fast, ease OUT slow (WoW anti-clip / anti-pop) ---
func test_collision_pull_in_is_near_instant() -> void:
	# A wall drops the collided distance 8 -> 2: the camera should snap almost all the way in
	# within a single frame (never let a wall clip the view).
	var v := PlayerCamera.collision_ease(8.0, 2.0, 0.016)
	assert_almost_eq(v, 2.0, 0.05, "pull-in reaches the wall distance in one frame")


func test_collision_ease_out_is_gradual() -> void:
	# The wall clears (2 -> 8): the camera must NOT jump back out in one frame (no pop).
	var v := PlayerCamera.collision_ease(2.0, 8.0, 0.016)
	assert_gt(v, 2.0, "eases outward")
	assert_lt(v, 5.0, "but only part-way in one frame — no snap-back pop")


func test_collision_ease_out_eventually_reaches_desired() -> void:
	var v := 2.0
	for _i in range(240):
		v = PlayerCamera.collision_ease(v, 8.0, 0.016)
	assert_almost_eq(v, 8.0, 0.01, "the eased pull-out still arrives at the desired distance")


func test_collided_distance_scales_by_hit_ratio() -> void:
	assert_almost_eq(PlayerCamera.collided_distance(8.0, 1.0), 8.0, 0.0001, "clear = full distance")
	assert_almost_eq(PlayerCamera.collided_distance(8.0, 0.25), 2.0, 0.0001, "quarter ratio = 2m")
	assert_almost_eq(PlayerCamera.collided_distance(8.0, 5.0), 8.0, 0.0001, "ratio clamped to 1")
	assert_almost_eq(PlayerCamera.collided_distance(8.0, -1.0), 0.0, 0.0001, "ratio clamped to 0")


# --- Collision margin (T-126b: standoff so a corner-defeated single ray doesn't clip) ---
func test_margin_distance_applies_the_standoff() -> void:
	assert_almost_eq(
		PlayerCamera.margin_distance(5.0, 0.3),
		4.7,
		0.0001,
		"margin pulls the camera in short of the raw ray hit"
	)
	assert_almost_eq(
		PlayerCamera.margin_distance(5.0),
		5.0 - PlayerCamera.COLLISION_MARGIN,
		0.0001,
		"defaults to COLLISION_MARGIN"
	)
	assert_eq(
		PlayerCamera.margin_distance(0.1, 0.3),
		0.0,
		"a hit closer than the margin floors at 0, never goes negative"
	)


# --- Pitch clamps ---
func test_pitch_clamps_to_the_look_band() -> void:
	assert_almost_eq(
		PlayerCamera.clamp_pitch(deg_to_rad(-200.0)),
		deg_to_rad(PlayerCamera.PITCH_MIN_DEG),
		0.0001,
		"can't roll under the feet"
	)
	assert_almost_eq(
		PlayerCamera.clamp_pitch(deg_to_rad(200.0)),
		deg_to_rad(PlayerCamera.PITCH_MAX_DEG),
		0.0001,
		"can't roll over the top"
	)


func test_pitch_in_band_is_untouched() -> void:
	var p := deg_to_rad(-25.0)
	assert_almost_eq(PlayerCamera.clamp_pitch(p), p, 0.0001, "an in-band pitch passes through")


# --- Follow-lag (yaw) ---
func test_smooth_yaw_moves_toward_target() -> void:
	var y := PlayerCamera.smooth_yaw(0.0, 1.0, 30.0, 0.016)
	assert_gt(y, 0.0, "eases toward the body yaw")
	assert_lt(y, 1.0, "does not overshoot")


func test_smooth_yaw_takes_the_short_way_around_the_wrap() -> void:
	# Body at -170deg, camera at +170deg: the shortest path is +20deg (through 180), NOT -340.
	var cur := deg_to_rad(170.0)
	var target := deg_to_rad(-170.0)
	var y := PlayerCamera.smooth_yaw(cur, target, 30.0, 0.016)
	assert_gt(y, cur, "steps the short way (increasing past +180), not the long way back to 0")


func test_smooth_yaw_converges() -> void:
	var y := 0.0
	for _i in range(240):
		y = PlayerCamera.smooth_yaw(y, 1.2, 30.0, 0.016)
	assert_almost_eq(y, 1.2, 0.001, "camera yaw catches the body facing")
