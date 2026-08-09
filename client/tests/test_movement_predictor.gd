extends GutTest

# T-054: the client-prediction/reconciliation math — pure, unit-tested without nodes/network.

const MovementPredictor = preload("res://scripts/world/movement_predictor.gd")
# T-321: walk toggle sends smaller per-tick deltas; these are the walk/run displacements at 20Hz.
const _WALK_PER_TICK := 2.5 * 0.05  # WALK_SPEED (2.5 m/s) * a 20Hz tick = 0.125 units
const _RUN_PER_TICK := 6.0 * 0.05  # RUN_SPEED (6.0 m/s) * a 20Hz tick = 0.30 units


func test_predict_applies_delta() -> void:
	var p := MovementPredictor.predict(Vector3(1, 0, 1), Vector3(2, 0, 0), 100.0)
	assert_eq(p, Vector3(3, 0, 1), "delta applied to position")


func test_predict_clamps_to_max_speed_like_the_server() -> void:
	# A 10-unit delta with max speed 3 → clamped to length 3 (mirrors the server's MAX_SPEED clamp).
	var p := MovementPredictor.predict(Vector3.ZERO, Vector3(10, 0, 0), 3.0)
	assert_almost_eq(p.length(), 3.0, 0.001, "predicted move clamped to max speed")


func test_reconcile_lerps_small_gap_toward_server() -> void:
	# Predicted slightly ahead of the server (normal latency) → smoothed, not snapped.
	var out := MovementPredictor.reconcile(Vector3(1.0, 0, 0), Vector3(0.0, 0, 0), 2.0, 0.5)
	assert_eq(out, Vector3(0.5, 0, 0), "lerps halfway toward authoritative")


func test_reconcile_snaps_large_gap_to_server() -> void:
	# Predicted far from the server (the server clamped a speed-hack / desync) → snap to truth.
	var auth := Vector3(0, 0, 0)
	var out := MovementPredictor.reconcile(Vector3(50, 0, 0), auth, 2.0, 0.5)
	assert_eq(out, auth, "snaps to the server position past the threshold")


func test_reconcile_zero_gap_is_stable() -> void:
	var p := Vector3(5, 0, 5)
	assert_eq(MovementPredictor.reconcile(p, p, 2.0, 0.3), p, "no correction when already in sync")


# T-321: the walk toggle sends SMALLER per-tick deltas (WALK_SPEED < RUN_SPEED). Confirm the
# predictor treats a walk-magnitude delta exactly like a run one — the server's max-speed clamp
# only ever caps a delta from ABOVE, so a slower delta is passed through untouched and reconcile
# still just lerps the latency gap away (no rubber-banding regression from the new movement feel).
func test_walk_and_run_deltas_both_pass_the_server_speed_clamp_untouched() -> void:
	# Both are well under the server MAX_SPEED_PER_TICK (100), so predict() applies them verbatim.
	var walk := MovementPredictor.predict(Vector3.ZERO, Vector3(_WALK_PER_TICK, 0, 0), 100.0)
	var run := MovementPredictor.predict(Vector3.ZERO, Vector3(_RUN_PER_TICK, 0, 0), 100.0)
	assert_almost_eq(walk.x, _WALK_PER_TICK, 0.0001, "walk delta is server-legal, applied as-is")
	assert_almost_eq(run.x, _RUN_PER_TICK, 0.0001, "run delta is server-legal, applied as-is")


func test_walk_tick_reconciles_without_rubber_banding() -> void:
	# A walk-sized latency gap stays far below the snap threshold, so it lerps (smooth), never snaps.
	var predicted := Vector3(_WALK_PER_TICK, 0, 0)
	var out := MovementPredictor.reconcile(predicted, Vector3.ZERO, 3.0, 0.25)
	assert_almost_eq(
		out.x, _WALK_PER_TICK * 0.75, 0.0001, "small walk gap is eased 25% toward the server"
	)
	assert_lt(out.x, _WALK_PER_TICK, "moved toward the server (no overshoot / no rubber-band)")


# T-327: on a slope the server's authoritative position carries a DERIVED ground height (godot y)
# while our local prediction sits at y=0 (we derive our own height from TerrainField). A big height
# delta must NOT be read as a positional gap and snap us — the reconcile measures the PLANAR (x, z)
# gap only. This is the readiness proof that walkable relief won't rubber-band.
func test_slope_height_delta_does_not_trigger_a_false_snap() -> void:
	# Planar gap is tiny (0.1) but the server is 8m higher (a steep hill). Old full-3D distance
	# (~8.0) would have blown past the 3.0 snap threshold and hard-snapped every tick.
	var predicted := Vector3(5.0, 0.0, 5.0)  # our local height stays 0 (we own it)
	var authoritative := Vector3(5.1, 8.0, 5.0)  # server derived +8m of hill
	var out := MovementPredictor.reconcile(predicted, authoritative, 3.0, 0.25)
	assert_false(out.is_equal_approx(authoritative), "must NOT snap on a pure height delta")
	assert_almost_eq(out.x, 5.025, 0.0001, "planar x eased 25% toward the server")
	assert_eq(out.y, 0.0, "local height is preserved (client owns y, never trusts the packet)")


func test_slope_reconcile_still_snaps_a_real_planar_desync() -> void:
	# A genuine planar desync (speed-hack / clamp) still snaps even when heights also differ — the
	# height axis is simply ignored, it never masks a real ground-plane gap.
	var out := MovementPredictor.reconcile(Vector3(50, 0, 0), Vector3(0, 6, 0), 3.0, 0.25)
	assert_almost_eq(out.x, 0.0, 0.0001, "planar gap past threshold snaps to server x")
	assert_almost_eq(out.z, 0.0, 0.0001, "planar gap past threshold snaps to server z")
