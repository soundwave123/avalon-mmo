# T-446: pure personal-space separation for ambient NPCs — no OS time, no globals, no state,
# no rng (fully deterministic: coincident NPCs split along a direction hashed from their ids).
# Mirrors npc_wander.gd's pure-tick shape; the director applies it AFTER the wander step so two
# NPCs never interpenetrate or share a footprint (the Hale/Loreth/Ansa clump from the audit).
#
# Model: soft pairwise repulsion. Every neighbour (movable or fixed) closer than `min_dist`
# contributes a push of half the overlap along the connecting axis; the summed push is capped at
# `max_step` per call so a crowded NPC shuffles apart over a few ticks instead of teleporting.
# Callers pass max_step = SEP_SPEED * dt to keep the shuffle dt-scaled (hardware-independent).
#
# Coordinates are server ground space (x, y) carried in Vector3(x, y, 0) — same as npc_wander.

extends RefCounted

const DEFAULT_MIN_DIST := 1.5  # T-446 visual spec: villagers spaced >= 1.5 m apart
const _COINCIDENT_EPS := 0.01  # closer than this = "same footprint"; split by id-hash direction


# One separation pass. `movable`: npc_id -> Vector3 current position (these get pushed).
# `fixed`: Array of Vector3 obstacle positions (rooted NPCs — they push but never move).
# Returns npc_id -> Vector3 new position for every movable id (unchanged ids included).
# Pure: inputs are never mutated; iteration is over sorted ids so the result is deterministic
# regardless of Dictionary ordering.
static func separate(
	movable: Dictionary, fixed: Array, min_dist: float, max_step: float
) -> Dictionary:
	var ids := movable.keys()
	ids.sort()
	var out: Dictionary = {}
	for npc_id in ids:
		var pos: Vector3 = movable[npc_id]
		var push := Vector3.ZERO
		for other_id in ids:
			if other_id == npc_id:
				continue
			push += _push_from(npc_id, pos, movable[other_id], min_dist)
		for obstacle in fixed:
			push += _push_from(npc_id, pos, obstacle as Vector3, min_dist)
		if push.length() > max_step:
			push = push.normalized() * max_step
		out[npc_id] = pos + push
	return out


# The repulsion one neighbour exerts: half the overlap, along the axis away from the neighbour.
# A coincident pair (zero axis) splits along a deterministic per-id direction so two NPCs spawned
# on the exact same footprint still separate without any injected rng.
static func _push_from(npc_id: String, pos: Vector3, other: Vector3, min_dist: float) -> Vector3:
	var axis := pos - other
	axis.z = 0.0  # ground-plane only; never push along the unused third component
	var d := axis.length()
	if d >= min_dist:
		return Vector3.ZERO
	if d < _COINCIDENT_EPS:
		var angle := float(npc_id.hash() % 360) * TAU / 360.0
		axis = Vector3(cos(angle), sin(angle), 0.0)
		d = 0.0
	else:
		axis = axis / d
	return axis * ((min_dist - d) * 0.5)


# Leash clamp: keep a separated NPC within `radius` of its post so the push can never shove a
# quest-giver outside the INTERACT_RADIUS talk gate (mirrors critter_wander._clamp_to_radius).
static func clamp_to_post(pos: Vector3, post: Vector3, radius: float) -> Vector3:
	var offset := pos - post
	if offset.length() <= radius:
		return pos
	return post + offset.normalized() * radius
