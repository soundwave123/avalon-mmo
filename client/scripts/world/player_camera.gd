class_name PlayerCamera
extends RefCounted

# T-126: pure camera-feel math for the third-person rig (WoW-parity handling). Mirrors the
# movement_predictor.gd / anim_state_machine.gd / npc_wander.gd house style — no nodes, no OS
# time, inputs are never mutated, the caller (local_player.gd) injects `delta` + the current
# scalar state and reads the result back. So the zoom clamps, frame-rate-independent easing, the
# collision pull-in/pull-out asymmetry, the pitch limits and the follow-lag are all unit-tested
# WITHOUT the engine input loop, a SpringArm, or a physics world. The node wiring that consumes
# these (rig layout, the live "feels right?" pass) stays in local_player.gd and is deferred to
# the orchestrator's in-world feel pass.
#
# Frame-rate independence: every ease uses an exponential 1 - e^(-rate*dt) blend, not a raw
# lerp(a, b, const) — so a value settles over the same wall-clock time at 30 fps or 144 fps, and
# no per-call allocation happens (T-210: all scalar math, no temporaries).

# --- Tuning constants: the ONE place to tune camera feel (treat as the module's exports) ---
# T-126b (QA-batch feel pass, 2026-07-10): 0.7 m/notch took ~20 wheel notches to sweep the full
# 1.5..16 band — a lot of scrolling. Raised to ~1.1 m/notch (fewer notches across the range; the
# 12/s ZOOM_SMOOTHING ease still keeps the motion smooth, no snap feel).
const ZOOM_STEP := 1.1  # metres of camera distance per wheel notch (T-126b QA tuning rec)
const ZOOM_MIN := 1.5  # closest third-person — near enough to inspect the model
const ZOOM_MAX := 16.0  # farthest pull-back
const ZOOM_SMOOTHING := 12.0  # wheel-zoom ease rate (1/s); higher = snappier settle
const COLLISION_IN_SMOOTHING := 1000.0  # near-instant pull-IN when a wall intrudes (never clip)
const COLLISION_OUT_SMOOTHING := 6.0  # gentle ease-OUT when the wall clears (no snap-back pop)
# T-126b: the SpringArm probe is a single ray, which a tight corner (two near-perpendicular
# walls) can defeat — the ray slips past the second wall while the camera itself (real volume,
# not a point) still pokes through it. A standoff margin holds the camera a bit shorter than the
# raw ray hit so corners clear too. Cheap and honest: no shape-cast, no extra physics query, a
# pure scalar the caller subtracts from whatever distance the probe reports.
const COLLISION_MARGIN := 0.3  # metres of standoff subtracted from the raw probe hit distance
const PITCH_MIN_DEG := -80.0  # look-down limit (can't roll under the feet)
const PITCH_MAX_DEG := 30.0  # look-up limit (can't roll over the top)
const YAW_SMOOTHING := 30.0  # follow-lag on turn (1/s); near-rigid by default, feel-tuned later
# T-636: point-blank melee (ability range 2.5m, mob melee_range 2.0m — the NORMAL engagement
# distance, not an edge case) let the collided distance collapse toward 0 exactly like a tight
# wall corner would, jamming the lens inside the target's mesh (a large blown-out backface blob —
# see the ticket screenshots). A mob isn't architecture: flush-hugging it is the wrong read. Floor
# the distance so the camera never collapses that far, and lift the pitch to look down over the
# target instead (WoW's over-the-shoulder read) rather than staying level and clipping through it.
const MIN_ENTITY_DISTANCE := 1.4  # never let the collided distance collapse below this (metres)
const CLOSE_RANGE_THRESHOLD := 3.0  # below this collided distance, start lifting the camera
const CLOSE_RANGE_PITCH_LIFT_DEG := 18.0  # extra look-down at/below MIN_ENTITY_DISTANCE


# Clamp a desired camera distance after a wheel input. Positive `steps` = wheel-UP = zoom IN
# (shorter distance); negative = wheel-DOWN = zoom OUT — matches the shipped pilot 'wheel' op.
static func zoom_after_steps(current_target: float, steps: int) -> float:
	return clampf(current_target - float(steps) * ZOOM_STEP, ZOOM_MIN, ZOOM_MAX)


# Clamp any distance into the zoom band (used to sanitise the initial/desired distance).
static func clamp_zoom(dist: float) -> float:
	return clampf(dist, ZOOM_MIN, ZOOM_MAX)


# Frame-rate-independent exponential smoothing toward a target. `smoothing` is a rate (1/s): the
# remaining gap shrinks by 1 - e^(-smoothing*delta) each call, identical settle time at any
# framerate. smoothing <= 0 or delta <= 0 => no movement; a very large smoothing => effectively
# instant. Never overshoots (the blend factor stays in [0, 1)).
static func ease_toward(current: float, target: float, smoothing: float, delta: float) -> float:
	if smoothing <= 0.0 or delta <= 0.0:
		return current
	var t := 1.0 - exp(-smoothing * delta)
	return current + (target - current) * t


# Camera-distance easing with WoW's asymmetry: pull IN fast (a wall must never be allowed to
# clip the view) but ease OUT slowly (no jarring pop the instant an obstruction clears). `target`
# is the already-collided distance the spring probe reports.
static func collision_ease(current: float, target: float, delta: float) -> float:
	var smoothing := COLLISION_IN_SMOOTHING if target < current else COLLISION_OUT_SMOOTHING
	return ease_toward(current, target, smoothing, delta)


# The collided camera distance from a SpringArm3D hit RATIO in [0, 1] (1.0 = clear/full desired
# distance, <1.0 = a wall pulled it in). Robust helper for when the caller reads a ratio rather
# than the absolute assigned distance.
static func collided_distance(desired: float, hit_ratio: float) -> float:
	return desired * clampf(hit_ratio, 0.0, 1.0)


# T-126b: apply the standoff margin to a raw probe-collided distance. Floors at 0 (never negative
# — a probe hit closer than the margin just means the camera sits right at the pivot, which is
# still a valid, honest "as close as physically possible" result rather than a clamp artifact).
static func margin_distance(collided: float, margin: float = COLLISION_MARGIN) -> float:
	return maxf(collided - margin, 0.0)


# T-636: floor the (already margin-applied) collided distance so the camera never collapses flush
# against a nearby obstruction — walls included (a small standoff off a corner reads fine too),
# but this specifically exists to stop a point-blank mob from pulling the lens inside its mesh.
static func entity_floor_distance(
	collided: float, floor_dist: float = MIN_ENTITY_DISTANCE
) -> float:
	return maxf(collided, floor_dist)


# Clamp pitch (radians) into the look band — applied on every mouse-look delta.
static func clamp_pitch(pitch: float) -> float:
	return clampf(pitch, deg_to_rad(PITCH_MIN_DEG), deg_to_rad(PITCH_MAX_DEG))


# T-636: WoW-style over-the-shoulder lift. As the RAW collided distance (pre-floor — the true
# "how close is the obstruction" signal) shrinks toward point-blank range, bias the pitch to look
# down more steeply so the camera rides up and over the target instead of staying level with its
# torso. No lift at/above CLOSE_RANGE_THRESHOLD; full lift at/below MIN_ENTITY_DISTANCE; blends
# linearly between. More negative pitch = look down more (matches PITCH_MIN_DEG's convention), so
# the lift SUBTRACTS from the base pitch; the result is still clamped into the normal pitch band.
static func close_range_pitch(base_pitch: float, raw_collided: float) -> float:
	if raw_collided >= CLOSE_RANGE_THRESHOLD:
		return clamp_pitch(base_pitch)
	var span := CLOSE_RANGE_THRESHOLD - MIN_ENTITY_DISTANCE
	var t := 1.0 if span <= 0.0 else clampf((CLOSE_RANGE_THRESHOLD - raw_collided) / span, 0.0, 1.0)
	var lift := deg_to_rad(CLOSE_RANGE_PITCH_LIFT_DEG) * t
	return clamp_pitch(base_pitch - lift)


# Follow-lag: ease the camera yaw toward the body's facing the SHORT way around the circle,
# frame-rate independently. Near-rigid at the default YAW_SMOOTHING; the subjective amount of lag
# is a feel-pass knob. wrapf keeps the step on the shortest arc so a wrap past +/-PI never spins.
static func smooth_yaw(current: float, target: float, smoothing: float, delta: float) -> float:
	if smoothing <= 0.0 or delta <= 0.0:
		return current
	var t := 1.0 - exp(-smoothing * delta)
	return current + wrapf(target - current, -PI, PI) * t
