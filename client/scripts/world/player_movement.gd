class_name PlayerMovement
extends RefCounted

# T-321: pure movement-feel math for the local player (WoW-parity handling — the movement half of
# T-126, split out on the systems lane's recommendation). Mirrors the player_camera.gd /
# movement_predictor.gd / anim_state_machine.gd house style: no nodes, no OS time, inputs are never
# mutated, the caller (local_player.gd) injects `delta` + the current velocity and reads the result
# back. So the acceleration/deceleration curve, the turn smoothing, and the run/walk speed choice
# are all unit-tested WITHOUT the engine input loop, a CharacterBody3D, or a physics world. The node
# wiring that consumes these (collide-and-slide, ground snapping, the live "feels right?" pass)
# stays in local_player.gd and is deferred to the orchestrator's in-world feel pass.
#
# Frame-rate independence: the velocity ease uses the same exponential 1 - e^(-rate*dt) blend as
# player_camera.gd's ease_toward (not a raw lerp(a, b, const)), so a velocity settles over the same
# wall-clock time at 30 fps or 144 fps and never overshoots. All scalar/vector math, no per-call
# allocation beyond the returned Vector3 (T-210).
#
# Server authority note (checked 2026-07-09, server/world/scripts/main.gd _on_request_move):
# the server only REJECTS a move whose per-tick delta exceeds MAX_SPEED_PER_TICK (plus a
# per-second rate budget). It never enforces a MINIMUM. A client-side walk toggle is therefore
# always rate-legal (slower than run is slower than max) and needs NO server flag — walk is a
# client-visual/animation choice, honest because the server accepts the smaller deltas as-is.

# --- Tuning constants: the ONE place to tune movement feel (treat as the module's exports) ---
const RUN_SPEED := 6.0  # units/sec — the shipped LocalPlayer.MOVE_SPEED (reads as RUN, > 4.0)
const WALK_SPEED := 2.5  # units/sec — deliberately BELOW AnimStateMachine.RUN_THRESHOLD_MPS (4.0)
# so the walk toggle produces walk-speed movement AND a walk clip without any anim special-casing.
# T-572: mirrors ServerConfig.MOUNT_SPEED_MULT / PLAYER_RUN_SPEED_MOUNTED — mounting was a no-op
# because this module never varied speed with mount state (the server's mount-aware cap was raised
# but nothing ever sent a faster delta to test it against). No mounted WALK tier exists (no
# slow-mount animation authored), so a mount overrides the walk toggle outright.
const MOUNT_SPEED_MULT := 1.6
const RUN_SPEED_MOUNTED := RUN_SPEED * MOUNT_SPEED_MULT  # 9.6 units/sec
const ACCEL_SMOOTHING := 16.0  # ramp-up rate (1/s); ~0.15s to full speed — WoW-crisp, not floaty
const DECEL_SMOOTHING := 20.0  # stop/slow rate (1/s); a touch snappier than accel (no ice-skating)
const STOP_EPS := 0.05  # below this speed with no input, treat as fully stopped (kill drift/jitter)


# The ground speed the player should move at, given the walk toggle and mount state. Mounted always
# wins (run tier, no walk-while-mounted clip exists); on foot, walk is below the anim run threshold
# so locomotion resolves to the walk clip, and run is the full shipped move speed.
static func target_speed(is_walking: bool, is_mounted: bool = false) -> float:
	if is_mounted:
		return RUN_SPEED_MOUNTED
	return WALK_SPEED if is_walking else RUN_SPEED


# The desired ground velocity (m/s, Godot x/z plane) from a raw WASD input direction rotated by the
# character's facing yaw. Zero input => zero desired velocity (the caller then decelerates to rest).
# The input is normalised so diagonals aren't faster; mirrors local_player's shipped rotate-by-yaw.
static func desired_velocity(input_dir: Vector3, yaw: float, speed: float) -> Vector3:
	if input_dir == Vector3.ZERO:
		return Vector3.ZERO
	return input_dir.normalized().rotated(Vector3.UP, yaw) * speed


# Frame-rate-independent easing of the WHOLE velocity vector toward the target. Because the entire
# vector eases, this gives BOTH acceleration/deceleration (magnitude change) AND turn smoothing
# (direction change on a WASD/facing change) in one exponential blend. The rate is `decel` when the
# target is slower than the current speed (stopping / easing off), `accel` otherwise (speeding up
# or turning into a new direction) — WoW's crisp asymmetry. rate <= 0 or delta <= 0 => no change;
# a very large rate => effectively instant. Never overshoots (the blend factor stays in [0, 1)).
static func ease_velocity(
	current: Vector3, target: Vector3, accel: float, decel: float, delta: float
) -> Vector3:
	var rate := accel if target.length() >= current.length() else decel
	if rate <= 0.0 or delta <= 0.0:
		return current
	var t := 1.0 - exp(-rate * delta)
	return current + (target - current) * t


# Flip the walk/run toggle state (the key handler calls this on a fresh key-down; pure so the
# toggle semantics are testable without an InputEvent).
static func toggled_walk(is_walking: bool) -> bool:
	return not is_walking
