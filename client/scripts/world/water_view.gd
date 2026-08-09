extends RefCounted

# T-441 water surface module — extracted from world_view.gd (which sits at the 1000-line gdlint
# cap, same precedent as river_view.gd). Owns the Crystal Lake plane build and the per-frame
# day/night drive of the shared water look. The lake and the T-342 river run the SAME
# shaders/water.gdshader with its DEFAULT colours — one substance; the shader's true depth read
# (Beer-Lambert murk + soft depth-fade banks) does the shallow/deep work per body, so nothing
# here retunes colour per body.

# Crystal Lake water plane sits just above the terrain's y=0 walk plane; the T-445 shore bowl
# (-0.55 m) puts the bed below it. KEEP IN SYNC with river_view.gd WATER_Y.
const WATER_Y := 0.06

# T-560: the visible plane is pulled north of and smaller than the shore bowl the caller passes, so
# its south edge clears the training-yard rail (yard footprint x 7..18, z 5..13; rail at z=13). The
# bowl, prop ring and grass-clear stay on the caller's center/radius (moving them would orphan the
# authored lakeside dressing — floats/sinks in world-audit), so ONLY this render mesh shifts. With
# the default lake (center z=22, radius 12) the plane sits at z=24 / radius 10 -> south edge z=14,
# a 1 m gap off the rail, while its north edge (z=34) still nests inside the cleared basin.
const YARD_CLEAR_SHIFT := 2.0  # metres north (+z) off the bowl centre
const YARD_CLEAR_SHRINK := 2.0  # metres of radius trimmed so the south edge pulls back off the yard


# Build Crystal Lake — a subdivided water plane running the shared water shader. The shader
# carves a blobby pond out of the square plane (T-179 shore_noise waterline) and now (T-441)
# depth-fades the margins, so the shoreline is a soft wet band, never a razor edge.
static func build_lake(
	shader: Shader, center: Vector2, radius: float, ripple_tex: Texture2D, shore_tex: Texture2D
) -> MeshInstance3D:
	var plane_center := center + Vector2(0.0, YARD_CLEAR_SHIFT)  # T-560: north off the training yard
	var plane_radius := maxf(1.0, radius - YARD_CLEAR_SHRINK)
	var water := MeshInstance3D.new()
	water.name = "CrystalLake"
	var plane := PlaneMesh.new()
	plane.size = Vector2(plane_radius * 2.0, plane_radius * 2.0)
	plane.subdivide_width = 48
	plane.subdivide_depth = 48
	water.mesh = plane
	water.position = Vector3(plane_center.x, WATER_Y, plane_center.y)
	var mat := ShaderMaterial.new()
	mat.shader = shader
	mat.set_shader_parameter("ripple_noise", ripple_tex)
	# Low-frequency, static field that shapes the irregular waterline (a blobby lake, not a disc).
	mat.set_shader_parameter("shore_noise", shore_tex)
	water.material_override = mat
	water.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return water


# T-441 day/night drive: the fresnel sky sheen is the "reads as water at distance" cue by day,
# but a full-strength pale sheen at night glows milky. Driven off the SAME sun elevation the
# direct light uses (world_view._process), dimmed with overcast exactly like the sun energy.
static func day_tick(mats: Array[ShaderMaterial], elev_deg: float, overcast_dim: float) -> void:
	var sheen := clampf(smoothstep(-6.0, 4.0, elev_deg), 0.0, 1.0) * overcast_dim
	for mat in mats:
		mat.set_shader_parameter("sheen_strength", sheen)
