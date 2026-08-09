# T-446: pure idle-life tick — per-role micro-behaviour so a posted NPC never reads frozen. No OS
# time, no globals, inputs never mutated; caller injects `now` (server tick counter), `dt` (fixed
# seconds per tick) and a seeded rng — the npc_wander.gd idiom exactly.
#
# Two channels, both cheap enough to ride the existing positions broadcast:
#   facing — a stationary NPC drifts its facing by a random turn every few seconds (varied, never
#            metronomic); while walking, facing locks to the travel direction the caller supplies.
#   act    — an occasional role-flavoured action pulse ("hammer" for the smith, "pray" for clergy,
#            "gesture" for vendors). The pulse holds for act_dur seconds then clears; the client
#            maps the act name onto an existing one-shot clip and retriggers on each ""->act edge.
#
# idle cfg (npcs.json `idle` block, all optional):
#   acts: ["hammer"|"pray"|"gesture", ...] — action pulse pool ([] = facing drift only)
#   act_min/act_max: seconds between pulses (default 8 .. 18)
#   act_dur: seconds a pulse holds (default 1.8)
#   turn_min/turn_max: seconds between facing drifts (default 4 .. 10)
#
# runtime state dict (opaque): {facing: float, act: String, act_until: int, next_act: int,
#                               next_turn: int}

extends RefCounted

const _DEFAULT_ACT_MIN := 8.0
const _DEFAULT_ACT_MAX := 18.0
const _DEFAULT_ACT_DUR := 1.8
const _DEFAULT_TURN_MIN := 4.0
const _DEFAULT_TURN_MAX := 10.0
const _TURN_MAX_RAD := 1.2  # one drift turns at most ~70 degrees — a shift, not a pirouette


# Does this npc cfg describe idle life? (Any non-empty dict opts in; {} / non-dict = none.)
static func has_idle(cfg) -> bool:
	return cfg is Dictionary and not (cfg as Dictionary).is_empty()


static func new_state(facing: float) -> Dictionary:
	return {"facing": facing, "act": "", "act_until": 0, "next_act": 0, "next_turn": 0}


# One tick. `moving` + `move_yaw` come from the caller's wander step (a walking NPC faces its
# travel and never acts). Pure: returns the next runtime state, never mutates the inputs.
static func tick(
	state: Dictionary, cfg: Dictionary, moving: bool, move_yaw: float, now: int, dt: float, rng
) -> Dictionary:
	var facing := float(state.get("facing", 0.0))
	var act := str(state.get("act", ""))
	var act_until := int(state.get("act_until", 0))
	var next_act := int(state.get("next_act", 0))
	var next_turn := int(state.get("next_turn", 0))

	if moving:
		# Walking: face travel, drop any act, and clear the schedules so arrival re-jitters them
		# (the crowd never resumes idling on one shared beat).
		return {"facing": move_yaw, "act": "", "act_until": 0, "next_act": 0, "next_turn": 0}

	var acts: Array = cfg.get("acts", []) if cfg.get("acts", []) is Array else []

	# First stationary tick (or first after a walk): schedule the next drift/pulse with jitter.
	if next_turn == 0:
		next_turn = (
			now + _ticks(_rand_window(cfg, "turn", _DEFAULT_TURN_MIN, _DEFAULT_TURN_MAX, rng), dt)
		)
	if next_act == 0 and not acts.is_empty():
		next_act = (
			now + _ticks(_rand_window(cfg, "act", _DEFAULT_ACT_MIN, _DEFAULT_ACT_MAX, rng), dt)
		)

	if act != "" and now >= act_until:
		# Pulse over: clear it and schedule the next one.
		act = ""
		next_act = (
			now + _ticks(_rand_window(cfg, "act", _DEFAULT_ACT_MIN, _DEFAULT_ACT_MAX, rng), dt)
		)
	elif act == "" and not acts.is_empty() and now >= next_act:
		act = str(acts[rng.randi_range(0, acts.size() - 1)] if rng != null else acts[0])
		act_until = now + _ticks(float(cfg.get("act_dur", _DEFAULT_ACT_DUR)), dt)

	if act == "" and now >= next_turn:
		# Facing drift — only between acts so a praying cleric doesn't spin mid-prayer.
		if rng != null:
			facing = wrapf(facing + rng.randf_range(-_TURN_MAX_RAD, _TURN_MAX_RAD), -PI, PI)
		next_turn = (
			now + _ticks(_rand_window(cfg, "turn", _DEFAULT_TURN_MIN, _DEFAULT_TURN_MAX, rng), dt)
		)

	return {
		"facing": facing,
		"act": act,
		"act_until": act_until,
		"next_act": next_act,
		"next_turn": next_turn
	}


# Seconds -> whole server ticks (matches npc_wander's pause math; dt-scaled, hardware-independent).
static func _ticks(seconds: float, dt: float) -> int:
	return int(round(seconds / maxf(dt, 0.0001)))


# A jittered window length in seconds from cfg `<key>_min`/`<key>_max` (rng == null -> the min).
static func _rand_window(cfg: Dictionary, key: String, dmin: float, dmax: float, rng) -> float:
	var lo := float(cfg.get(key + "_min", dmin))
	var hi := maxf(lo, float(cfg.get(key + "_max", dmax)))
	return rng.randf_range(lo, hi) if rng != null else lo
