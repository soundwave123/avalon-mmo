extends RefCounted

# T-342 capital river geometry — extracted from world_view.gd to stay under the 1000-line gdlint
# cap. Owns the river centerline and the water-ribbon mesh build; world_view feeds in the shared
# water shader + the two noise textures (its _make_noise_texture stays there). The ribbon is a
# triangle strip whose per-vertex UV carries (along-length u, transverse v in [0,1]); the water
# shader's river_mode fades alpha to 0 at the banks off the transverse coordinate (vs the lake's
# radial disc carve), so the same wave/fresnel/sky-sheen surface reads as a flowing channel.
#
# Centerline (x,z), north -> south. KEEP IN SYNC with terrain_splat.gdshader RIV_SEG and
# scripts/world-audit.py RIVER (three-way splat sync).
const RIVER_PTS: Array = [
	[57.0, -382.0],
	[54.0, -362.0],
	[44.0, -300.0],
	[34.0, -256.0],
	[26.0, -218.0],
	[23.0, -210.0],
	[21.0, -175.0],
	[19.0, -140.0],
	[18.0, -112.0],
	[5.2, -109.0],
	[-10.0, -107.0],
	[-30.0, -100.0],
	[-52.0, -92.0],
]
const RIVER_HALF := 3.6  # channel half-width to the plane edge (water discards past ~0.78)
# T-441: the water surface sits IN the T-445 carved bed. KEEP IN SYNC with water_view.gd WATER_Y
# and terrain_field.gd's bed carve (floor -0.5, bed half-width >= 3.2 through the pads).
const WATER_Y := 0.06
# Transverse waterline: alpha reaches 0 by (BANK_BASE + BANK_WOBBLE) * RIVER_HALF = 3.17 m off
# the centerline — always inside the carved bed floor (3.2 m), so the visible water edge sits
# over submerged mud, never on the dry bank or under a cottage foundation.
const BANK_BASE := 0.78
const BANK_WOBBLE := 0.10


# Maximum half-width of the VISIBLE water sheet (metres from the centerline).
static func water_half_width_max() -> float:
	return (BANK_BASE + BANK_WOBBLE) * RIVER_HALF


# T-531: naturalise the western tail. The ribbon is a triangle strip whose downstream cross-section
# is otherwise a straight, full-width edge — mid-meadow that reads as a dug canal's square end. This
# ramps the plane half-width down over the FINAL segment so the sheet tapers to a reedy point (a
# stream petering into the marsh at [-52,-92]) instead of stopping square. It scales ONLY the
# visual mesh vertices: RIVER_HALF and the transverse shader fade (water_half_width_max) are
# unchanged, so the terrain bed carve / world-audit / splat three-way sync stay byte-identical.
static func tail_width_scale(i: int, n: int) -> float:
	if i >= n - 1:
		return 0.10  # terminus: a sliver, hidden under the T-531 reed cap
	if i == n - 2:
		return 0.55  # penultimate: the taper shoulder
	return 1.0


# Distance from (x,z) to the river centerline (>=0). Mirrors terrain_splat.gdshader riv_d() and
# scripts/world-audit.py river_dist(); used to keep grass clutter out of the channel/wet banks.
static func dist(x: float, z: float) -> float:
	var p := Vector2(x, z)
	var best := 1e9
	for i in range(RIVER_PTS.size() - 1):
		var a := Vector2(RIVER_PTS[i][0], RIVER_PTS[i][1])
		var ab := Vector2(RIVER_PTS[i + 1][0], RIVER_PTS[i + 1][1]) - a
		var t: float = clampf((p - a).dot(ab) / ab.dot(ab), 0.0, 1.0)
		best = minf(best, p.distance_to(a + ab * t))
	return best


# Build the river as a MeshInstance3D running the water shader in river_mode. `ripple_tex`/
# `shore_tex` are world_view's noise textures (ripple shimmer + static bank wobble field).
static func build(shader: Shader, ripple_tex: Texture2D, shore_tex: Texture2D) -> MeshInstance3D:
	var river := MeshInstance3D.new()
	river.name = "CapitalRiver"
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var n := RIVER_PTS.size()
	var lefts: Array = []
	var rights: Array = []
	var us := PackedFloat32Array()
	var acc := 0.0
	for i in range(n):
		var p := Vector2(RIVER_PTS[i][0], RIVER_PTS[i][1])
		var prev := Vector2(RIVER_PTS[maxi(i - 1, 0)][0], RIVER_PTS[maxi(i - 1, 0)][1])
		var nxt := Vector2(RIVER_PTS[mini(i + 1, n - 1)][0], RIVER_PTS[mini(i + 1, n - 1)][1])
		var tang := nxt - prev
		if tang.length() < 0.001:
			tang = Vector2(0.0, 1.0)
		tang = tang.normalized()
		var nrm := Vector2(-tang.y, tang.x)  # unit perpendicular to the flow
		var hw := RIVER_HALF * tail_width_scale(i, n)  # T-531 tail taper (visual mesh only)
		lefts.append(p + nrm * hw)
		rights.append(p - nrm * hw)
		if i > 0:
			acc += p.distance_to(Vector2(RIVER_PTS[i - 1][0], RIVER_PTS[i - 1][1]))
		us.append(acc / 6.0)  # along-length UV (ripple tiling scale)
	var y := WATER_Y
	for i in range(n - 1):
		var l0: Vector2 = lefts[i]
		var r0: Vector2 = rights[i]
		var l1: Vector2 = lefts[i + 1]
		var r1: Vector2 = rights[i + 1]
		var u0 := us[i]
		var u1 := us[i + 1]
		_vert(st, l0, u0, 0.0, y)
		_vert(st, r0, u0, 1.0, y)
		_vert(st, r1, u1, 1.0, y)
		_vert(st, l0, u0, 0.0, y)
		_vert(st, r1, u1, 1.0, y)
		_vert(st, l1, u1, 0.0, y)
	st.generate_normals()
	river.mesh = st.commit()
	var mat := ShaderMaterial.new()
	mat.shader = shader
	mat.set_shader_parameter("river_mode", true)
	# T-441: NO colour overrides — the river and the lake share the shader's default palette
	# (one substance); true depth does the shallow/deep work per body.
	mat.set_shader_parameter("ripple_noise", ripple_tex)
	mat.set_shader_parameter("shore_noise", shore_tex)
	mat.set_shader_parameter("waterline_base", BANK_BASE)  # bank fade point (transverse units)
	mat.set_shader_parameter("waterline_wobble", BANK_WOBBLE)
	mat.set_shader_parameter("shore_softness", 0.16)  # ~0.58 m soft transverse margin
	mat.set_shader_parameter("wave_height", 0.05)  # a channel, gentler than the open lake
	mat.set_shader_parameter("flow_speed", 0.45)  # faint downstream drift of the shimmer
	river.material_override = mat
	river.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return river


static func _vert(st: SurfaceTool, p: Vector2, uu: float, vv: float, y: float) -> void:
	st.set_uv(Vector2(uu, vv))
	st.add_vertex(Vector3(p.x, y, p.y))
