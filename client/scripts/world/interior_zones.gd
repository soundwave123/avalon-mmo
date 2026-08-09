class_name InteriorZones
extends RefCounted

# T-187 (interior awareness bundle): pure, headless-testable geometry + state logic for "is the
# player indoors, and in which building". No Node/scene-tree dependency here on purpose — this is
# unit-testable with plain Vector3/Dictionary fixtures; WorldPropsLayer builds the volume list from
# real placed buildings (position + rotation + GLB mesh bounds), and a thin per-frame caller (see
# main.gd) feeds a live player position through resolve_indoors().
#
# A volume is an ORIENTED footprint box (buildings rotate in 90-degree steps in the village but
# arbitrary degrees on the procedural kit — e.g. prop_farmhouse.glb sits at rot_deg 250 — so this
# does real Y-axis rotation math rather than assuming axis-aligned world AABBs):
#   {"id": String, "center": Vector3 (footprint center, y = floor height),
#    "half_extents": Vector2 (half-width/half-depth in the building's OWN x/z axes),
#    "height": float (floor to roof-ish top), "rot_y": float (radians)}

# T-187: fixed vertical tolerance — NOT scaled by the horizontal hysteresis margin below. The
# door-threshold hysteresis is a HORIZONTAL concern (walking through a doorway); a player's feet
# sit right at floor height (center.y), so shrinking the vertical range by the same negative
# ENTER_MARGIN used for the footprint would put the floor itself outside the "enterable" range
# and the player would never register as indoors. This constant instead gives a little generous
# slack at both floor and roof (uneven ground / roof-mesh imprecision) independent of enter/exit.
const VERTICAL_SLACK := 0.5

# Hysteresis margins for resolve_indoors(): once indoors in a given volume, EXIT_MARGIN (positive,
# expands the footprint) makes leaving harder than entering; ENTER_MARGIN (negative, shrinks it)
# makes newly entering a DIFFERENT volume require being well inside it. This is what keeps a
# player standing in a doorway from flickering the rain/ambience state every frame.
const ENTER_MARGIN := -0.3
const EXIT_MARGIN := 0.6


# Builds one volume dictionary from a building's placement + its LOCAL (pre-transform) mesh AABB —
# i.e. the AABB measured in the building's own coordinate frame before rot_y/scale/position are
# applied (Godot's MeshInstance3D.get_aabb() composed across a scene's meshes gives exactly this).
static func volume_from_local_aabb(
	id: String, local_aabb: AABB, world_position: Vector3, rot_y: float, scale: float = 1.0
) -> Dictionary:
	var half_x: float = local_aabb.size.x * 0.5 * scale
	var half_z: float = local_aabb.size.z * 0.5 * scale
	# The local AABB's center is rarely (0,0,0) (door-facing offsets, asymmetric roofs); rotate the
	# local-space footprint center into world space and add it to the placed position.
	var local_center_xz := Vector2(
		(local_aabb.position.x + local_aabb.size.x * 0.5) * scale,
		(local_aabb.position.z + local_aabb.size.z * 0.5) * scale
	)
	var cos_r := cos(rot_y)
	var sin_r := sin(rot_y)
	var world_center := (
		world_position
		+ Vector3(
			local_center_xz.x * cos_r + local_center_xz.y * sin_r,
			local_aabb.position.y * scale,
			-local_center_xz.x * sin_r + local_center_xz.y * cos_r
		)
	)
	return {
		"id": id,
		"center": world_center,
		"half_extents": Vector2(half_x, half_z),
		"height": local_aabb.size.y * scale,
		"rot_y": rot_y,
	}


# True if `point` is inside `volume`'s footprint, expanded/shrunk horizontally by `margin`
# (negative margin shrinks the box — used for the "must be well inside to count as entering"
# hysteresis half). The vertical range always uses the fixed VERTICAL_SLACK — see its doc comment.
static func contains(point: Vector3, volume: Dictionary, margin: float = 0.0) -> bool:
	var center: Vector3 = volume["center"]
	var rot_y: float = volume["rot_y"]
	var dx := point.x - center.x
	var dz := point.z - center.z
	var cos_r := cos(-rot_y)
	var sin_r := sin(-rot_y)
	var local_x := dx * cos_r - dz * sin_r
	var local_z := dx * sin_r + dz * cos_r
	var half: Vector2 = volume["half_extents"]
	if absf(local_x) > half.x + margin or absf(local_z) > half.y + margin:
		return false
	var height: float = volume["height"]
	return point.y >= center.y - VERTICAL_SLACK and point.y <= center.y + height + VERTICAL_SLACK


static func resolve_indoors(
	point: Vector3,
	volumes: Array,
	was_indoors: bool,
	was_volume_id: String,
	enter_margin: float = ENTER_MARGIN,
	exit_margin: float = EXIT_MARGIN
) -> Dictionary:
	if was_indoors:
		for v: Dictionary in volumes:
			if str(v["id"]) == was_volume_id and contains(point, v, exit_margin):
				return {"indoors": true, "id": was_volume_id}
	for v: Dictionary in volumes:
		if contains(point, v, enter_margin):
			return {"indoors": true, "id": str(v["id"])}
	return {"indoors": false, "id": ""}
