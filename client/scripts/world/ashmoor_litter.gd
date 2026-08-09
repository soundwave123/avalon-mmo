class_name AshmoorLitter
extends RefCounted
# T-406: Ashmoor gutter litter — scattered handbills/newspaper scraps as ONE MultiMesh (one
# draw call, the T-079 clutter idiom) so the High Street reads lived-in without a per-paper
# node cost. Deterministic seed = reproducible screenshots. Two gutter lines (the kerb line on
# the door-side frontage + the north-wall base on the cobble strip) carry the density; the
# mid-street stays sparse per the Dishonored/Bloodborne edge-clutter layout language.

const SEED := 20260714
const PAPER_COLOR := Color(0.78, 0.75, 0.66)  # rain-aged newsprint, never clean white
const INK_COLOR := Color(0.55, 0.53, 0.48)
# district frontage span (matches the terrace row x extent; SYNC informally with props.json)
const X_MIN := -441.0
const X_MAX := -391.0


static func build() -> MultiMeshInstance3D:
	var rng := RandomNumberGenerator.new()
	rng.seed = SEED
	var mesh := QuadMesh.new()
	mesh.size = Vector2(0.17, 0.24)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = PAPER_COLOR
	mat.roughness = 1.0
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mesh.material = mat
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = mesh
	# 46 door-side gutter scraps + 26 strip-side + 8 sparse mid-street strays
	var spots: Array[Vector3] = []
	for i in range(46):
		spots.append(Vector3(rng.randf_range(X_MIN, X_MAX), 0.012, rng.randf_range(13.85, 14.45)))
	for i in range(26):
		spots.append(Vector3(rng.randf_range(X_MIN, X_MAX), 0.012, rng.randf_range(2.9, 3.7)))
	for i in range(8):
		spots.append(
			Vector3(rng.randf_range(X_MIN + 6.0, X_MAX - 6.0), 0.012, rng.randf_range(-5.0, 1.5))
		)
	mm.instance_count = spots.size()
	for i in range(spots.size()):
		# flat on the ground, random yaw, a slight cup/tilt so edges catch the gaslight
		var basis := Basis(Vector3.UP, rng.randf_range(0.0, TAU))
		basis = basis.rotated(basis.x, -PI / 2.0 + rng.randf_range(-0.14, 0.14))
		basis = basis.scaled(Vector3.ONE * rng.randf_range(0.8, 1.25))
		mm.set_instance_transform(i, Transform3D(basis, spots[i]))
	var inst := MultiMeshInstance3D.new()
	inst.name = "AshmoorLitter"
	inst.multimesh = mm
	inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return inst
