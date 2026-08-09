# T-311: ambient NPC daily-life movement — a pure wander tick (no OS time, no globals, no state).
# Mirrors mob_ai._tick_patrol but data-driven from an npcs.json `wander` block. world_rpc.gd owns
# the live store + writes the moved position back into _content_npcs (so the talk-proximity gate
# reads live positions); this module only computes the next runtime state from the previous one.
#
# wander cfg (npcs.json, all optional):
#   mode: "radius"    — amble to random points within `radius` of the post (villagers/courtiers)
#         "waypoints" — loop the `waypoints` route (guards patrol)
#   radius: float     — radius-mode reach in metres (quest-givers keep this small, <= 6 m, so the
#                       INTERACT_RADIUS talk gate always resolves near the post)
#   waypoints: [[x, y], ...] — waypoint-mode route in server ground coords
#   speed: float      — walk speed m/s (default 1.2 — a walk, never a sprint)
#   pause_min/pause_max: seconds paused at each point (default 2 .. 6)
#
# runtime state dict (opaque): {pos: Vector3, target: Vector3, paused_until: int, wp: int,
#                               dir: int (+1/-1 waypoint travel direction — reverses at a wall)}
#
# Report #15: an optional `blocker` (movement_collision.gd shape — segment_blocked(fx,fz,tx,tz))
# gates every step so an ambient NPC never walks through a building. On hitting a wall the NPC
# does what a person does: stop, pause a beat, turn around and walk back the way it came
# (waypoints reverse route direction; radius amblers head home to the post).

extends RefCounted

const _ARRIVE_EPS := 0.15  # within this of the target counts as "arrived" (then pause + repick)
const _DEFAULT_SPEED := 1.2  # m/s — a stroll; guards/villagers never sprint
const _DEFAULT_PAUSE_MIN := 2.0
const _DEFAULT_PAUSE_MAX := 6.0
const _DEFAULT_RADIUS := 3.0


# Does this npc cfg describe a real wander route? (Static NPCs return false and never tick.)
static func has_wander(cfg) -> bool:
	if not (cfg is Dictionary):
		return false
	var mode := str(cfg.get("mode", ""))
	if mode == "waypoints":
		return (cfg.get("waypoints", []) as Array).size() > 0
	if mode == "radius":
		return float(cfg.get("radius", 0.0)) > 0.0
	return false


# Initial runtime state anchored at the NPC's post. wp = -1 so the first arrival picks waypoint 0.
static func new_state(post: Vector3) -> Dictionary:
	return {"pos": post, "target": post, "paused_until": 0, "wp": -1, "dir": 1}


# One tick. Pure: never mutates inputs, never reads OS time. `now` = server tick counter; `dt` =
# seconds per tick (fixed — so movement speed is hardware-independent); `rng` = caller's seeded
# generator; `blocker` (optional) = the wall oracle — a step crossing a wall is refused and the
# NPC stops, pauses, then turns around. Returns the next runtime state.
static func tick(
	state: Dictionary, cfg: Dictionary, post: Vector3, now: int, dt: float, rng, blocker = null
) -> Dictionary:
	var pos: Vector3 = state.get("pos", post)
	var target: Vector3 = state.get("target", pos)
	var paused_until: int = int(state.get("paused_until", 0))
	var wp: int = int(state.get("wp", -1))
	var dir: int = int(state.get("dir", 1))

	# Paused at a point of interest — hold position until the pause elapses.
	if now < paused_until:
		return {"pos": pos, "target": target, "paused_until": paused_until, "wp": wp, "dir": dir}

	if pos.distance_to(target) <= _ARRIVE_EPS:
		# Arrived: pick the next destination and pause here first.
		var picked := _next_target(cfg, post, wp, dir, rng)
		target = picked["target"]
		wp = int(picked["wp"])
		paused_until = now + _pause_ticks(cfg, dt, rng)
		return {"pos": pos, "target": target, "paused_until": paused_until, "wp": wp, "dir": dir}

	# Step toward the target at walk speed — never overshoot.
	var speed := float(cfg.get("speed", _DEFAULT_SPEED))
	var to_target: Vector3 = target - pos
	var dist := to_target.length()
	var next := pos
	if dist > 0.0:
		next = pos + to_target.normalized() * minf(dist, speed * maxf(dt, 0.0))
	if blocker != null and blocker.segment_blocked(pos.x, pos.y, next.x, next.y):
		# A wall (Report #15): stop where we stand, pause a beat, then head back the way we came —
		# waypoint routes reverse travel direction; radius amblers walk home to the post.
		if str(cfg.get("mode", "radius")) == "waypoints":
			var wps: Array = cfg.get("waypoints", [])
			dir = -dir
			if not wps.is_empty():
				wp = posmod(wp + dir, wps.size())
				var w = wps[wp]
				target = Vector3(float(w[0]), float(w[1]), 0.0)
		else:
			target = post
		paused_until = now + _pause_ticks(cfg, dt, rng)
		return {"pos": pos, "target": target, "paused_until": paused_until, "wp": wp, "dir": dir}
	return {"pos": next, "target": target, "paused_until": paused_until, "wp": wp, "dir": dir}


# The authored pause window (seconds -> whole ticks); shared by arrivals and wall turn-arounds.
static func _pause_ticks(cfg: Dictionary, dt: float, rng) -> int:
	var pmin := float(cfg.get("pause_min", _DEFAULT_PAUSE_MIN))
	var pmax := maxf(pmin, float(cfg.get("pause_max", _DEFAULT_PAUSE_MAX)))
	var pause_s: float = rng.randf_range(pmin, pmax) if rng != null else pmin
	return int(round(pause_s / maxf(dt, 0.0001)))


# The next destination + waypoint index. radius: a random point within `radius` of the post
# (small radius keeps quest-givers findable). waypoints: the next point along the route in the
# current travel direction (`dir` = -1 after a wall turn-around paces the route backwards).
static func _next_target(cfg: Dictionary, post: Vector3, wp: int, dir: int, rng) -> Dictionary:
	if str(cfg.get("mode", "radius")) == "waypoints":
		var wps: Array = cfg.get("waypoints", [])
		if wps.is_empty():
			return {"target": post, "wp": 0}
		var nx := posmod(wp + (dir if dir != 0 else 1), wps.size())
		var w = wps[nx]
		return {"target": Vector3(float(w[0]), float(w[1]), 0.0), "wp": nx}
	var radius := float(cfg.get("radius", _DEFAULT_RADIUS))
	if rng == null:
		return {"target": post, "wp": wp}
	var angle: float = rng.randf_range(0.0, TAU)
	var reach: float = rng.randf_range(0.0, radius)
	return {"target": post + Vector3(cos(angle), sin(angle), 0.0) * reach, "wp": wp}
