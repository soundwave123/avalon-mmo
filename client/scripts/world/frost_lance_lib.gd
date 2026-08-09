class_name FrostLanceLib
extends RefCounted

# T-343 round 2: pure static mesh/material builders for the frost-lance VFX family. Split from
# FrostLanceVfx so the stage logic and the geometry/material recipes stay independently readable
# (and independently committable). Everything here is allocation-at-build-time only.

# One shared soft radial falloff sprite for every lance billboard. Bare additive quads render as
# HARD-EDGED SQUARES at r2's larger particle scales — the single worst "Roblox" tell from the
# first self-review pass. Procedural (GradientTexture2D), so no vendored asset is needed.
static var _soft: GradientTexture2D = null


static func soft_tex() -> GradientTexture2D:
	if _soft == null:
		var g := Gradient.new()
		g.set_offsets(PackedFloat32Array([0.0, 0.35, 1.0]))
		g.set_colors(
			PackedColorArray([Color(1, 1, 1, 1), Color(1, 1, 1, 0.55), Color(1, 1, 1, 0.0)])
		)
		_soft = GradientTexture2D.new()
		_soft.gradient = g
		_soft.fill = GradientTexture2D.FILL_RADIAL
		_soft.fill_from = Vector2(0.5, 0.5)
		_soft.fill_to = Vector2(1.0, 0.5)
		_soft.width = 64
		_soft.height = 64
	return _soft


# Soft-edged additive billboard quad (the only billboard style the lance family allows).
static func quad(size: float, color: Color, energy: float) -> QuadMesh:
	var q := QuadMesh.new()
	q.size = Vector2(size, size)
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	m.billboard_keep_scale = true
	m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	m.vertex_color_use_as_albedo = true
	m.albedo_texture = soft_tex()
	m.albedo_color = color
	m.emission_enabled = true
	m.emission = Color(color.r, color.g, color.b)
	m.emission_energy_multiplier = energy
	q.material = m
	return q


static func ramp(a: Color, b: Color) -> GradientTexture1D:
	var g := Gradient.new()
	g.set_offsets(PackedFloat32Array([0.0, 1.0]))
	g.set_colors(PackedColorArray([a, b]))
	var t := GradientTexture1D.new()
	t.gradient = g
	return t


# white-hot birth -> tinted mid -> transparent death (the contrast ramp r1 billboards lacked)
static func ramp2(hot: Color, cold: Color) -> GradientTexture1D:
	var g := Gradient.new()
	g.set_offsets(PackedFloat32Array([0.0, 0.35, 1.0]))
	g.set_colors(
		PackedColorArray(
			[Color(1, 1, 1, 1), Color(hot.r, hot.g, hot.b, 0.9), Color(cold.r, cold.g, cold.b, 0)]
		)
	)
	var t := GradientTexture1D.new()
	t.gradient = g
	return t


# Emissive glassy ice: lit (specular glints), white-hot or deep-blue via color/energy.
static func ice_mat(color: Color, energy: float, alpha: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(color.r, color.g, color.b, alpha)
	if alpha < 1.0:
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.emission_enabled = true
	m.emission = color
	m.emission_energy_multiplier = energy
	m.metallic = 0.15
	m.roughness = 0.08
	return m


# Flat fan disc (ground creep / impact ring), UV-mapped radially for radial_mat.
static func disc_mesh(radius: float, segs: int) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in range(segs):
		var a0 := float(i) * TAU / float(segs)
		var a1 := float(i + 1) * TAU / float(segs)
		st.set_uv(Vector2(0.5, 0.5))
		st.add_vertex(Vector3.ZERO)
		st.set_uv(Vector2(0.5 + 0.5 * cos(a1), 0.5 + 0.5 * sin(a1)))
		st.add_vertex(Vector3(cos(a1) * radius, 0.0, sin(a1) * radius))
		st.set_uv(Vector2(0.5 + 0.5 * cos(a0), 0.5 + 0.5 * sin(a0)))
		st.add_vertex(Vector3(cos(a0) * radius, 0.0, sin(a0) * radius))
	st.generate_normals()
	return st.commit()


# Radial frost gradient (bright crystalline rim, fading center) on an additive unshaded disc.
static func radial_mat(color: Color, energy: float) -> StandardMaterial3D:
	var grad := Gradient.new()
	grad.set_offsets(PackedFloat32Array([0.0, 0.62, 0.88, 1.0]))
	(
		grad
		. set_colors(
			PackedColorArray(
				[
					Color(color.r, color.g, color.b, 0.22),
					Color(color.r, color.g, color.b, 0.55),
					Color(1.0, 1.0, 1.0, 1.0),
					Color(color.r, color.g, color.b, 0.0),
				]
			)
		)
	)
	var tex := GradientTexture2D.new()
	tex.gradient = grad
	tex.fill = GradientTexture2D.FILL_RADIAL
	tex.fill_from = Vector2(0.5, 0.5)
	tex.fill_to = Vector2(1.0, 0.5)
	tex.width = 128
	tex.height = 128
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	m.cull_mode = BaseMaterial3D.CULL_DISABLED  # ground discs must show from any camera side
	m.albedo_texture = tex
	m.albedo_color = Color(1, 1, 1)
	m.emission_enabled = true
	m.emission = color
	m.emission_energy_multiplier = energy
	return m


# One elongated crystal spike along -Z: front apex + jittered mid ring + back apex (octahedral,
# 8 faces). `tip_frac` = how far ahead of the ring the front tip sits (0..1 of len).
static func add_spike(
	st: SurfaceTool,
	center: Vector3,
	length: float,
	girth: float,
	tip_frac: float,
	rng: RandomNumberGenerator
) -> void:
	var tip := center + Vector3(0, 0, -length * tip_frac)
	var tail := center + Vector3(0, 0, length * (1.0 - tip_frac))
	var ring_pts: Array = []
	for i in range(4):
		var a := float(i) * TAU / 4.0 + rng.randf_range(-0.2, 0.2)
		var r := girth * rng.randf_range(0.75, 1.25)
		ring_pts.append(center + Vector3(cos(a) * r, sin(a) * r, rng.randf_range(-0.08, 0.08)))
	for i in range(4):
		var v0: Vector3 = ring_pts[i]
		var v1: Vector3 = ring_pts[(i + 1) % 4]
		st.add_vertex(tip)
		st.add_vertex(v1)
		st.add_vertex(v0)
		st.add_vertex(tail)
		st.add_vertex(v0)
		st.add_vertex(v1)
