# T-463: pure nameplate level-of-detail + declutter math, shared by the NPC name labels
# (npc_world_layer) and any future plate surface. Two jobs, both camera-fact-in/number-out so the
# rules are unit-testable headlessly (the npc_wander pure-module idiom):
#   alpha_for_distance — plates fade out with range instead of popping (readable near, gone far),
#     the WoW/FFXIV distance-declutter read.
#   stagger_offsets — bunched units (the training-yard NPC crowd) get a deterministic vertical
#     stagger so plates stack into a readable column instead of smearing over each other.
# The layers own their Label3D nodes; this module never touches a node.

extends RefCounted

# Fade band (meters from the camera): fully readable inside START, gone past END. END matches the
# 25-30 m nameplate horizon the mob plates already use (LABEL_CULL_DISTANCE_M = 25).
const FADE_START := 16.0
const FADE_END := 28.0

# T-589: quest !/? markers are a separate LONG-range navigation tier (WoW's 40->60 yd read, scaled
# ~1:1 to Avalon meters per docs/design/overhead-ui-distances.md) — spottable across a plaza, well
# past where names/health bars have already faded out.
const MARKER_FADE_START := 40.0
const MARKER_FADE_END := 55.0

# T-589: scale-shrink curve (WoW nameplateMaxScaleDistance/MinScale read) — full size up close,
# shrinking toward a floor (never vanishing) as an anchor approaches its tier's fade edge. Shared by
# both tiers; callers pass their own fade-end as `floor_distance`.
const SCALE_FULL_DISTANCE := 10.0
const SCALE_FLOOR := 0.6

# T-589: WoW's nameplateOccludedAlphaMult — an occluded marker dims to this fraction of its normal
# alpha instead of being hidden (see occluded_alpha).
const OCCLUDED_ALPHA_MULT := 0.4

# Declutter: anchors closer than CLUSTER_RADIUS (planar meters) count as one bunch; each later
# member of a bunch is lifted by STAGGER_STEP world units so names stack instead of overlap.
const CLUSTER_RADIUS := 1.7
const STAGGER_STEP := 0.34

# T-656: root-cause fix for "camera clips into point-blank melee targets" — session-24 live
# testing found the follow camera was never actually inside a mob's MESH; it was legitimately
# avoiding a wall (T-636's own floor/pitch is correct there), and the symptom was a mob's
# Label3D nameplate (normal, unbounded perspective scaling — remote_entities_layer.gd never had
# an npc_world_layer-style near clamp) blowing up to fill the frame once wall-avoidance forced
# the camera down to MIN_ENTITY_DISTANCE (1.4 m). near_clamp_scale below: 1.0 (full size) at/beyond
# `near`; shrinks proportionally with distance below it, holding roughly CONSTANT apparent screen
# size instead of growing without bound as the camera approaches — the same "cancel perspective"
# trick npc_world_layer.gd's local marker_pixel_scale already uses for its near side.
const NEAR_CLAMP_M := 2.5  # below this camera distance, a plate stops growing with proximity


# 1.0 inside the fade band, linear falloff across it, 0.0 beyond — never negative, never > 1.
static func alpha_for_distance(
	distance: float, fade_start: float = FADE_START, fade_end: float = FADE_END
) -> float:
	if distance <= fade_start:
		return 1.0
	if distance >= fade_end:
		return 0.0
	return 1.0 - (distance - fade_start) / (fade_end - fade_start)


# 1.0 (full size) inside `full_distance`, linearly shrinking to `floor_scale` at `floor_distance`
# (a tier's fade edge), clamped at the floor beyond it — the fade reads as depth, not a pop. Never
# below floor_scale, never above 1.0.
static func scale_for_distance(
	distance: float,
	full_distance: float = SCALE_FULL_DISTANCE,
	floor_distance: float = FADE_END,
	floor_scale: float = SCALE_FLOOR
) -> float:
	if distance <= full_distance:
		return 1.0
	if distance >= floor_distance:
		return floor_scale
	var t := (distance - full_distance) / (floor_distance - full_distance)
	return 1.0 - t * (1.0 - floor_scale)


# WoW's dim-not-hide occlusion read: an occluded anchor renders at `mult` of its normal alpha
# instead of being hidden. Occlusion is passed in as a bool (not computed here) so this stays pure
# and headless-testable — the caller does the PhysicsDirectSpaceState3D ray check.
static func occluded_alpha(
	alpha: float, occluded: bool, mult: float = OCCLUDED_ALPHA_MULT
) -> float:
	return alpha * mult if occluded else alpha


static func near_clamp_scale(distance: float, near: float = NEAR_CLAMP_M) -> float:
	if distance >= near or near <= 0.0:
		return 1.0
	return clampf(distance / near, 0.0, 1.0)


# Vertical de-overlap for bunched plates. `anchors` is an Array of Vector3 world anchors in a
# STABLE order (the caller iterates its entity dict in insertion order, which Godot preserves, so
# the stagger is deterministic frame to frame — no flicker). Returns one extra height per anchor:
# the first plate of a bunch sits at 0, each subsequent plate within `radius` (planar x/z distance)
# of an earlier one is lifted a further `step`.
static func stagger_offsets(
	anchors: Array, radius: float = CLUSTER_RADIUS, step: float = STAGGER_STEP
) -> Array:
	var offsets: Array = []
	for i in range(anchors.size()):
		var rank := 0
		var a: Vector3 = anchors[i]
		for j in range(i):
			var b: Vector3 = anchors[j]
			var dx := a.x - b.x
			var dz := a.z - b.z
			if sqrt(dx * dx + dz * dz) <= radius:
				rank += 1
		offsets.append(step * float(rank))
	return offsets
