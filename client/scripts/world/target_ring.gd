class_name TargetRing
extends MeshInstance3D

# T-735: the genre-standard target-selection affordance — a FLAT ground-projected ring under the
# selected unit's feet, sized from that unit's collision footprint and colored by the T-286
# relationship palette. It replaces T-057's fixed TorusMesh, which carried `rotation_degrees.x = 90`
# — but a Godot TorusMesh is ALREADY flat (it rings the Y axis), so that rotation stood the donut UP
# into a vertical hoop through the model with half of it under the ground plane. The visible half is
# the "oversized half-circle covering the monster" the owner reported, and at a fixed 0.85 radius it
# swallowed small mobs whole. Code-built geometry (no texture/decal asset) per the repo's style;
# every sizing/coloring decision is a static pure function, so it is unit-testable headless.

const RADIUS_MARGIN := 1.25  # ring sits just OUTSIDE the footprint, never on/inside the silhouette
const MIN_RADIUS := 0.30  # critters still get a readable ring
const MAX_RADIUS := 3.00  # a boss ring stays a ring, not a stadium
const BAND_RATIO := 0.16  # band width as a fraction of the outer radius (thin arc, not a disc)
const MIN_BAND := 0.06
const SEGMENTS := 48  # smooth at melee range, trivial at this triangle count
# Lifted a hair off the ground so a coplanar ring doesn't z-fight the terrain. Small enough that
# the ring still reads as painted ON the ground rather than floating over it.
const GROUND_EPSILON := 0.05
const FILL_ALPHA := 0.62  # solid enough to read, translucent enough to show the grass under it
const GLOW_ENERGY := 0.9  # "subtle emissive glow over solid fill" — keeps the ring legible at night

var _radius: float = 0.0
var _rel: int = -1


# T-735: THE radius rule. Derives the ground footprint from the unit's own collision shape (never a
# fixed size) so a rat's ring hugs the rat and the Hollow King's ring rings the king. render_scale
# is the T-332 boss multiplier; callers that already scaled the shape itself pass 1.0.
static func radius_for_shape(shape: Shape3D, render_scale: float = 1.0) -> float:
	var footprint := 0.5  # unknown shape — fall back to a human-ish half-metre footprint
	if shape is CapsuleShape3D:
		footprint = (shape as CapsuleShape3D).radius
	elif shape is SphereShape3D:
		footprint = (shape as SphereShape3D).radius
	elif shape is CylinderShape3D:
		footprint = (shape as CylinderShape3D).radius
	elif shape is BoxShape3D:
		# planar half-extent: the widest of the two ground axes (a box's Y is height, not footprint)
		var size := (shape as BoxShape3D).size
		footprint = maxf(size.x, size.z) * 0.5
	return radius_for_footprint(footprint * maxf(0.01, render_scale))


# The margin + clamp half of the rule, split out so tests can pin each step independently.
static func radius_for_footprint(footprint: float) -> float:
	return clampf(footprint * RADIUS_MARGIN, MIN_RADIUS, MAX_RADIUS)


# Flat annulus in the XZ plane (y = 0), normals up. Two concentric rings of verts stitched into a
# quad strip — no vertical geometry exists, so the ring physically cannot cross the silhouette.
static func build_mesh(outer_radius: float) -> ArrayMesh:
	var outer := maxf(0.02, outer_radius)
	var inner := maxf(0.01, outer - maxf(MIN_BAND, outer * BAND_RATIO))
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()
	for i in range(SEGMENTS + 1):
		var t := float(i) / float(SEGMENTS)
		var a := TAU * t
		var c := cos(a)
		var s := sin(a)
		verts.append(Vector3(c * inner, 0.0, s * inner))
		verts.append(Vector3(c * outer, 0.0, s * outer))
		normals.append(Vector3.UP)
		normals.append(Vector3.UP)
		uvs.append(Vector2(t, 0.0))
		uvs.append(Vector2(t, 1.0))
	for i in range(SEGMENTS):
		var b := i * 2
		indices.append_array([b, b + 1, b + 2, b + 1, b + 3, b + 2])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


# T-286: the ring speaks the same color language as the nameplate/health bar (hostile red, neutral
# yellow, friendly/party green) so one glance answers "what did I just select".
static func color_for_relationship(rel: int) -> Color:
	return Relationship.plate_color(rel as Relationship.Rel)


func _init() -> void:
	name = "TargetRing"
	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED  # readable from a low camera angle too
	mat.emission_enabled = true
	mat.emission_energy_multiplier = GLOW_ENERGY
	mat.disable_receive_shadows = true
	material_override = mat
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	visible = false
	set_radius(MIN_RADIUS)
	set_relationship(Relationship.Rel.HOSTILE)


# Resize to a unit's footprint. Idempotent: same radius twice rebuilds nothing (this is called on
# every target change and would otherwise churn an ArrayMesh per click).
func set_radius(radius: float) -> void:
	var r := clampf(radius, MIN_RADIUS, MAX_RADIUS)
	if mesh != null and is_equal_approx(r, _radius):
		return
	_radius = r
	mesh = build_mesh(r)


func set_relationship(rel: int) -> void:
	if rel == _rel and mesh != null:
		return
	_rel = rel
	var c := color_for_relationship(rel)
	var mat := material_override as StandardMaterial3D
	mat.albedo_color = Color(c.r, c.g, c.b, FILL_ALPHA)
	mat.emission = c


func radius() -> float:  # headless-test accessor
	return _radius


func relationship() -> int:  # headless-test accessor
	return _rel
