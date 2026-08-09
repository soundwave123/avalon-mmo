# T-361: extracted from client/main.gd (which sat at the gdlint 1000-line cap) to make room for the
# chat panel. The AVALON_OBSERVE two-client harness probe — watches remote entities for `secs`,
# tracking peak player/entity counts and whether a remote player entered the camera view (ADR 0009).
# Kept a plain RefCounted so main.gd owns the env parsing + result-file write.

extends RefCounted

# T-727: a remote player is "running" for the facing check above this ground speed (m/s). Well
# under the 6 m/s run speed the harness mover uses, well over interpolation jitter at rest.
const RUN_SPEED_MPS := 2.0
# The facing lerp eases at 10/s toward the travel heading, so a freshly spawned body needs a beat to
# swing onto its heading (it starts at yaw 0). Only score dots after this much cumulative run time —
# the inversion this guards is a permanent 180, not a startup transient.
const FACING_WARMUP_S := 0.6

var max_players: int = 0
var max_entities: int = 0
var remote_in_view: bool = false
var facing_samples: int = 0  # T-727: scored frames of a remote player actually running
var min_facing_dot: float = 1.0  # T-727: worst dot(forward, travel) seen; -1 == running backwards
var _secs: float = 8.0
var _elapsed: float = 0.0
var _last_facings: Dictionary = {}  # T-727: id -> last frame's {pos, forward}
var _run_time: Dictionary = {}  # T-727: id -> cumulative seconds observed running


func setup(secs: float) -> void:
	_secs = secs


# Accumulate one frame of observation. Returns true once the window (`secs`) has elapsed.
func tick(delta: float, remote_entities, camera) -> bool:
	_elapsed += delta
	if remote_entities != null:
		max_players = maxi(max_players, remote_entities.player_count())
		max_entities = maxi(max_entities, remote_entities.entity_count())
		var facings: Dictionary = remote_entities.player_facings()
		if camera != null:
			for id: String in facings:
				if Perception.is_on_screen(camera, (facings[id] as Dictionary)["pos"]):
					remote_in_view = true
					break
		_tick_facing(delta, facings)
	return _elapsed >= _secs


# T-727: does each remote player FACE the way it travels? Per player, compare this frame's body
# forward against the direction it actually moved since the last frame. A correct client scores ~+1;
# the T-727 defect (body yaw pointing +Z at the travel direction while the rig faces -Z) scores ~-1.
func _tick_facing(delta: float, now: Dictionary) -> void:
	if delta <= 0.0:
		return
	for id: String in now:
		var cur: Dictionary = now[id]
		var prev: Variant = _last_facings.get(id)
		if prev != null:
			var travel: Vector3 = (cur["pos"] as Vector3) - ((prev as Dictionary)["pos"] as Vector3)
			travel.y = 0.0
			if travel.length() / delta >= RUN_SPEED_MPS:
				_run_time[id] = float(_run_time.get(id, 0.0)) + delta
				if float(_run_time[id]) >= FACING_WARMUP_S:
					var dot: float = (cur["forward"] as Vector3).dot(travel.normalized())
					min_facing_dot = minf(min_facing_dot, dot)
					facing_samples += 1
			else:
				_run_time[id] = 0.0  # stopped/turning — restart the warm-up before scoring again
	_last_facings = now


func result() -> Dictionary:
	return {
		"max_remote_players": max_players,
		"max_remote_entities": max_entities,
		"remote_player_in_view": remote_in_view,
		# T-727: the regression the ticket's DoD demands — a running remote player's facing must
		# agree with its movement (dot > 0). Zero samples means the run never happened (harness
		# problem), which the harness script treats as a failure rather than a silent pass.
		"facing_samples": facing_samples,
		"min_facing_dot": min_facing_dot,
		"facing_matches_travel": facing_samples > 0 and min_facing_dot > 0.0,
	}
