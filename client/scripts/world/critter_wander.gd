class_name CritterWander
# T-310: pure ambient-critter tick — graze/amble wander + threat-triggered flee, for the livestock
# and small critters WorldPropsLayer places from props.json. Mirrors npc_wander.gd's shape (no OS
# time, no globals, inputs never mutated; caller injects `now`/`dt`/`rng`) but client-side and in
# the client's own (x, z) ground plane — this is cosmetic dressing, not server truth, so there is
# no server-tick counter to ride. `now` is any monotonic counter the caller supplies (WorldProps-
# Layer uses Time.get_ticks_msec()); pause windows are stored in the SAME units as `now` (i.e.
# milliseconds, if that's what the caller passes), never derived from dt, so pacing survives
# uneven frame times.
#
# cfg (all optional, per-species — see world_props_layer.gd's _CRITTER_CFG):
#   comfort_radius: float — a threat closer than this triggers flee (default 4.5)
#   resettle_mult: float  — flee ends once the nearest threat clears comfort_radius * this (1.6)
#   max_radius: float     — bounds clamp: neither graze nor flee target may leave this ring around
#                           `home` (the paddock-fence / dooryard containment — T-310 note 5)
#   wander_radius: float  — graze-amble reach around home (default 2.0)
#   flee_dist: float      — how far a flee hop reaches before the next repick (default 3.0)
#   speed: float          — graze walk speed, m/s (default 0.4)
#   flee_speed: float     — flee trot speed, m/s (default 2.2)
#   pause_min/pause_max: graze pause at each amble point, in `now` units (default 3000..8000, i.e.
#                        milliseconds, matching the caller's ms-based `now`)
#
# state (opaque): {pos: Vector3, target: Vector3, paused_until: int, fleeing: bool, moving: bool}

extends RefCounted

const _ARRIVE_EPS := 0.12
const _DEFAULT_COMFORT_RADIUS := 4.5
const _DEFAULT_RESETTLE_MULT := 1.6
const _DEFAULT_MAX_RADIUS := 6.0
const _DEFAULT_WANDER_RADIUS := 2.0
const _DEFAULT_FLEE_DIST := 3.0
const _DEFAULT_SPEED := 0.4
const _DEFAULT_FLEE_SPEED := 2.2
const _DEFAULT_PAUSE_MIN := 3000.0
const _DEFAULT_PAUSE_MAX := 8000.0


static func new_state(home: Vector3) -> Dictionary:
	return {"pos": home, "target": home, "paused_until": 0, "fleeing": false, "moving": false}


# One tick. `threats` is an Array of Vector3 (world-space positions of the player + any nearby
# mobs) gathered once per tick by the caller and shared across every critter that ticks this frame.
static func tick(
	state: Dictionary, cfg: Dictionary, home: Vector3, threats: Array, now: int, dt: float, rng
) -> Dictionary:
	var pos: Vector3 = state.get("pos", home)
	var target: Vector3 = state.get("target", pos)
	var paused_until: int = int(state.get("paused_until", 0))
	var fleeing: bool = bool(state.get("fleeing", false))

	var comfort := float(cfg.get("comfort_radius", _DEFAULT_COMFORT_RADIUS))
	var resettle := comfort * float(cfg.get("resettle_mult", _DEFAULT_RESETTLE_MULT))
	var nearest := _nearest_dist(pos, threats)

	if not fleeing and nearest <= comfort:
		fleeing = true
		paused_until = 0  # a startled animal never "finishes its nap" first
	elif fleeing and nearest > resettle:
		fleeing = false
		target = pos  # settle here; the next tick's "arrived" check picks a fresh graze amble
		paused_until = 0

	if fleeing:
		# Threats may have moved since the last repick — keep the escape vector current.
		target = _flee_target(pos, home, threats, cfg)
		var flee_speed := float(cfg.get("flee_speed", _DEFAULT_FLEE_SPEED))
		pos = _step(pos, target, flee_speed, dt)
		return {
			"pos": pos,
			"target": target,
			"paused_until": paused_until,
			"fleeing": true,
			"moving": true
		}

	if now < paused_until:
		return {
			"pos": pos,
			"target": target,
			"paused_until": paused_until,
			"fleeing": false,
			"moving": false
		}

	if pos.distance_to(target) <= _ARRIVE_EPS:
		target = _next_graze_target(home, cfg, rng)
		var pmin := float(cfg.get("pause_min", _DEFAULT_PAUSE_MIN))
		var pmax := maxf(pmin, float(cfg.get("pause_max", _DEFAULT_PAUSE_MAX)))
		var pause_units: float = rng.randf_range(pmin, pmax) if rng != null else pmin
		paused_until = now + int(round(pause_units))
		return {
			"pos": pos,
			"target": target,
			"paused_until": paused_until,
			"fleeing": false,
			"moving": false
		}

	var speed := float(cfg.get("speed", _DEFAULT_SPEED))
	pos = _step(pos, target, speed, dt)
	return {
		"pos": pos, "target": target, "paused_until": paused_until, "fleeing": false, "moving": true
	}


# Step toward the target at `speed` m/s — never overshoot (mirrors npc_wander._step's own inline).
static func _step(pos: Vector3, target: Vector3, speed: float, dt: float) -> Vector3:
	var to_target := target - pos
	var dist := to_target.length()
	if dist <= 0.0:
		return pos
	return pos + to_target.normalized() * minf(dist, speed * maxf(dt, 0.0))


static func _nearest_dist(pos: Vector3, threats: Array) -> float:
	var nearest := INF
	for t in threats:
		var d: float = pos.distance_to(t)
		if d < nearest:
			nearest = d
	return nearest


# Away from the nearest threat, clamped inside max_radius of `home` — the flee response can never
# walk the animal through a fence or into a building (T-310 note 5's bounds-clamp).
static func _flee_target(pos: Vector3, home: Vector3, threats: Array, cfg: Dictionary) -> Vector3:
	var max_radius := float(cfg.get("max_radius", _DEFAULT_MAX_RADIUS))
	var flee_dist := float(cfg.get("flee_dist", _DEFAULT_FLEE_DIST))
	var away := Vector3.ZERO
	var nearest := INF
	for t in threats:
		var d: float = pos.distance_to(t)
		if d < nearest:
			nearest = d
			away = pos - t
	if away.length() < 0.01:
		away = pos - home
	if away.length() < 0.01:
		away = Vector3.RIGHT
	var raw := pos + away.normalized() * flee_dist
	return _clamp_to_radius(raw, home, max_radius)


static func _next_graze_target(home: Vector3, cfg: Dictionary, rng) -> Vector3:
	var radius := float(cfg.get("wander_radius", _DEFAULT_WANDER_RADIUS))
	if rng == null:
		return home
	var angle: float = rng.randf_range(0.0, TAU)
	var reach: float = rng.randf_range(0.0, radius)
	var raw := home + Vector3(cos(angle), 0.0, sin(angle)) * reach
	# T-310 note 5: even a misconfigured wander_radius (bigger than the pen) can't pick a graze
	# point outside max_radius of home — the fence-safety clamp applies to BOTH behaviours.
	var max_radius := float(cfg.get("max_radius", _DEFAULT_MAX_RADIUS))
	return _clamp_to_radius(raw, home, max_radius)


# A simple circle clamp — good enough for the roughly-round pens/dooryards livestock get placed
# in; no polygon fence geometry to test against, so a home+radius bound is the honest fallback.
static func _clamp_to_radius(point: Vector3, center: Vector3, radius: float) -> Vector3:
	var offset := point - center
	if offset.length() <= radius:
		return point
	return center + offset.normalized() * radius
