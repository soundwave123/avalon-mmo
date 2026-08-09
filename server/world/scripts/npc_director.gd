# T-311: owns ambient NPC daily-life movement for the world. Seeds per-NPC NpcWander runtime state
# from content, advances it one server tick (idempotent within a tick), and writes each mover's live
# position back into the content NPC so the INTERACT_RADIUS talk/turn-in gate follows a moving NPC.
# Split out of world_rpc.gd to keep that file under the gdlint 1000-line cap — world_rpc holds one
# instance and delegates (setup → seed, main tick → tick).
#
# T-446: the tick is now three pure passes so the settlement reads alive, not queued:
#   1. wander  (npc_wander.gd)     — amble/patrol toward the next point
#   2. separate (npc_separation.gd) — soft personal-space repulsion; NPCs never share a footprint
#   3. idle    (npc_idle.gd)        — facing drift + role act pulses ("hammer"/"pray"/"gesture")
# An NPC is tracked if it carries a `wander` and/or an `idle` block; idle-only NPCs stay anchored
# at their workplace post (leashed) but still get spacing + idle life. `wander.anchor: [x, y]`
# optionally re-posts a wanderer at its workplace (drillmaster at the training ring) without
# moving its authored spawn row.

extends RefCounted

const _NW = preload("res://scripts/npc_wander.gd")
const _NI = preload("res://scripts/npc_idle.gd")
const _NS = preload("res://scripts/npc_separation.gd")

const _SEP_SPEED := 1.0  # m/s cap on the separation shuffle (dt-scaled per tick)
const _MOVING_SPEED_EPS := 0.3  # planar m/s below this counts as stationary (idle facing owns it)
const _LEASH_SLACK := 0.75  # radius-mode leash = wander radius + this (stays inside the 3 m gate)
const _IDLE_LEASH := 1.25  # idle-only NPCs may be nudged at most this far off their post

var _state: Dictionary = {}  # npc_id -> NpcWander runtime state (opaque)
var _idle: Dictionary = {}  # npc_id -> NpcIdle runtime state (opaque) — T-446
var _post: Dictionary = {}  # npc_id -> Vector3 fixed post (anchor for wander + leash)
# T-698: npc_id -> region index of its POST (static: wander leash <= a few m, regions >=420 m
# apart), computed once by set_regions. Empty map = no table injected -> every NPC always ticks.
var _region: Dictionary = {}
var _last_tick: int = -1
# Report #15: the wall oracle (movement_collision.gd shape — segment_blocked(fx,fz,tx,tz)).
# Injected by main at boot with the NPC obstacle set (building footprints + the curtain wall) so
# ambient NPCs stop and turn at geometry instead of clipping through it. null = no geometry gate.
var _blocker = null


func set_blocker(blocker) -> void:
	_blocker = blocker


# T-698: precompute each tracked NPC's static region (call AFTER seed). Null/empty table clears
# the map — the awake gate below then degrades to always-tick, the pre-T-698 behaviour.
func set_regions(regions) -> void:
	_region.clear()
	if regions == null or regions.region_count() == 0:
		return
	for npc_id in _post:
		var post: Vector3 = _post[npc_id]
		_region[npc_id] = regions.region_index(post.x, post.y)


# T-698: does this NPC tick this pass? Mirrors sleeping_zones.is_mob_awake_cached: no awake set or
# no region map = always tick; an unmapped NPC degrades to awake, never to silently-asleep. A
# skipped NPC resumes exactly where it stood — wander/idle state advances on absolute ticks.
func _is_awake(npc_id: String, awake) -> bool:
	if awake == null or _region.is_empty() or not _region.has(npc_id):
		return true
	return (awake as Dictionary).has(_region[npc_id])


# Seed runtime state for every NPC that carries a `wander` and/or `idle` block. Fully static NPCs
# (neither block) are never tracked and never ride the positions broadcast.
func seed(content_npcs: Dictionary) -> void:
	_state.clear()
	_idle.clear()
	_post.clear()
	_last_tick = -1
	for npc_id in content_npcs:
		var npc = content_npcs[npc_id]
		var wanders: bool = _NW.has_wander(npc.wander)
		var idles: bool = _NI.has_idle(npc.idle)
		if not wanders and not idles:
			continue
		_post[npc_id] = _anchor_of(npc)
		if wanders:
			_state[npc_id] = _NW.new_state(_post[npc_id])
		if idles:
			_idle[npc_id] = _NI.new_state(0.0)


# T-446: the wander post — `wander.anchor: [x, y]` (the workplace) when authored, else the spawn.
static func _anchor_of(npc) -> Vector3:
	if npc.wander is Dictionary and npc.wander.get("anchor", null) is Array:
		var a: Array = npc.wander["anchor"]
		if a.size() >= 2:
			return Vector3(float(a[0]), float(a[1]), 0.0)
	return Vector3(npc.x, npc.y, 0.0)


# Advance one tick and return the live rows of the tracked NPCs. Idempotent within a server tick
# (headless FPS can call many times per tick). Writes moved positions back into content_npcs so
# the talk-proximity gate reads live coordinates. T-698: `awake` (main's sleeping-zone region set)
# skips NPCs whose region holds no player — separation pairs can't span regions (>=420 m apart vs
# ~1 m spacing), so gating pass 1 gates all three passes consistently.
func tick(content_npcs: Dictionary, now: int, tick_hz: int, rng, awake = null) -> Array:
	if _post.is_empty():
		return positions(content_npcs)
	if now != _last_tick:
		_last_tick = now
		var dt := 1.0 / float(maxi(tick_hz, 1))
		var prev: Dictionary = {}
		var proposed: Dictionary = {}
		for npc_id in _post:  # pass 1: wander
			var npc = content_npcs.get(npc_id, null)
			if npc == null or not _is_awake(npc_id, awake):
				continue
			prev[npc_id] = Vector3(npc.x, npc.y, 0.0)
			if _state.has(npc_id):
				var st: Dictionary = _NW.tick(
					_state[npc_id], npc.wander, _post[npc_id], now, dt, rng, _blocker
				)
				_state[npc_id] = st
				proposed[npc_id] = st["pos"]
			else:
				proposed[npc_id] = prev[npc_id]
		if proposed.is_empty():  # T-698: every mover asleep — skip the fixed-set build + separation
			return positions(content_npcs)
		# pass 2: personal space — tracked NPCs repel each other and rooted NPCs (fixed obstacles).
		var fixed: Array = []
		for npc_id in content_npcs:
			if not _post.has(npc_id):
				var npc = content_npcs[npc_id]
				fixed.append(Vector3(npc.x, npc.y, 0.0))
		var sep: Dictionary = _NS.separate(proposed, fixed, _NS.DEFAULT_MIN_DIST, _SEP_SPEED * dt)
		for npc_id in prev:  # pass 3: leash + idle life + write-back
			var npc = content_npcs[npc_id]
			var pos := _NS.clamp_to_post(sep[npc_id], _post[npc_id], _leash_radius(npc.wander))
			# Report #15: the separation shuffle / leash clamp must not shove an NPC through a wall
			# either. A displaced step that crosses geometry falls back to the pre-separation
			# wander step (still wall-checked in pass 1) — dropping the WHOLE move instead
			# deadlocks an NPC pinned between a crowd and a wall into a statue (courier-at-the-
			# tavern freeze); only if even the plain wander step crosses do we hold position.
			if (
				_blocker != null
				and _blocker.segment_blocked(prev[npc_id].x, prev[npc_id].y, pos.x, pos.y)
			):
				var unsep: Vector3 = proposed[npc_id]
				var unsep_ok: bool = not _blocker.segment_blocked(
					prev[npc_id].x, prev[npc_id].y, unsep.x, unsep.y
				)
				pos = unsep if unsep_ok else prev[npc_id]
			if _state.has(npc_id):
				_state[npc_id]["pos"] = pos  # wander continues from the separated spot
			var delta: Vector3 = pos - prev[npc_id]
			var moving := delta.length() / dt > _MOVING_SPEED_EPS
			if _idle.has(npc_id):
				var yaw := atan2(delta.x, delta.y) if moving else 0.0
				_idle[npc_id] = _NI.tick(_idle[npc_id], npc.idle, moving, yaw, now, dt, rng)
			npc.x = pos.x
			npc.y = pos.y
	return positions(content_npcs)


# How far separation may displace an NPC from its post. Waypoint routes roam by design (no leash);
# radius wanderers keep radius + slack (INTERACT_RADIUS honesty); idle-only NPCs barely budge.
func _leash_radius(wander_cfg) -> float:
	if not (wander_cfg is Dictionary) or (wander_cfg as Dictionary).is_empty():
		return _IDLE_LEASH
	if str(wander_cfg.get("mode", "")) == "waypoints":
		return INF
	return float(wander_cfg.get("radius", 0.0)) + _LEASH_SLACK


# Live rows of the tracked NPCs only ({npc_id, x, y} + T-446 idle extras) — the client already has
# every NPC's post from npc_indicators, so the per-tick packet stays small. `f` (facing, radians in
# server ground space) and `act` (role action pulse, only while active) ride the same entry; the
# T-372 delta layer leaves mobs/NPCs full-frame so extra fields are safe.
func positions(content_npcs: Dictionary) -> Array:
	var out: Array = []
	for npc_id in _post:
		var npc = content_npcs.get(npc_id, null)
		if npc == null:
			continue
		var row := {"npc_id": npc_id, "x": npc.x, "y": npc.y}
		if _idle.has(npc_id):
			var ist: Dictionary = _idle[npc_id]
			row["f"] = snappedf(float(ist.get("facing", 0.0)), 0.01)
			var act := str(ist.get("act", ""))
			if act != "":
				row["act"] = act
		out.append(row)
	return out


func is_tracked(npc_id: String) -> bool:
	return _post.has(npc_id)


func post_of(npc_id: String) -> Vector3:
	return _post.get(npc_id, Vector3.ZERO)


func mover_count() -> int:
	return _post.size()
