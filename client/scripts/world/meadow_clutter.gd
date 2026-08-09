extends RefCounted

# T-490 meadow ground-cover — extracted from world_view.gd to stay under the 1000-line gdlint cap
# (mirrors river_view.gd / water_view.gd). Owns two things world_view feeds geometry into:
#
#  1. build_tuft_mesh() — an UPRIGHT temperate-grass clump. It replaces the old splayed "rosette of
#     short WIDE blades arcing OUTWARD" (splay = 0.26) that up close read as a fleshy agave/aloe
#     rosette — a New-World succulent — and carpeted every field. Real meadow grass is a tuft of
#     NARROW blades that rise vertically and taper to a fine tip, only the upper reach nodding to
#     the wind. blades/height/base_w/nod give 2-3 variants (short turf + a tall straw-tipped sward).
#
#  2. density() — the meadow DENSITY field. A real meadow is patchy, not a uniform lawn: grass runs
#     tall where the grazer and the mower can't reach (fence-lines, ditch/water margins, path
#     verges, the disturbed strip against a cottage wall) and is cropped thin-to-bare on the open
#     sheep-common and the worn road margins. Returns an accept probability in [0,1]; world_view
#     passes in its own geometry so paint, clutter and audits stay single-sourced.


# Deterministic low-frequency patch field (fixed seed so screenshots reproduce).
static func make_noise() -> FastNoiseLite:
	var n := FastNoiseLite.new()
	n.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	n.fractal_type = FastNoiseLite.FRACTAL_FBM
	n.fractal_octaves = 3
	n.frequency = 0.028
	n.seed = 490
	return n


# UV.y = 1 at the base, 0 at the tip (drives the grass shader's wind bend + base->tip gradient).
# shape packs the silhouette knobs: x=height, y=blade count, z=base half-width, w=tip nod.
static func build_tuft_mesh(
	shader: Shader, wind_tex: Texture2D, top: Color, bottom: Color, shape: Vector4
) -> Mesh:
	var height := shape.x
	var blades := int(shape.y)
	var base_w := shape.z
	var nod := shape.w
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var segments := 3
	for k in range(blades):
		# fan the blades over the circle for body, but each stays near-vertical (a clump, not a spray)
		var a := float(k) * TAU / float(blades) + 0.7 * float(k % 3)
		var lean := Vector3(cos(a), 0.0, sin(a))  # azimuth the fine tip nods toward
		var wide := Vector3(-sin(a), 0.0, cos(a))  # blade width axis
		# per-blade height jitter so the clump silhouette is ragged, not a clipped hedge
		var bh := height * (0.72 + 0.28 * float((k * 7 + 3) % 5) / 4.0)
		for i in range(segments):
			var t0 := float(i) / float(segments)
			var t1 := float(i + 1) / float(segments)
			# rises straight up (base ON the ground at t=0 — grass must not float); only the upper
			# reach nods sideways by `nod`, so the blade never arcs into a fleshy outward dome.
			var b0 := Vector3(0.0, bh * t0, 0.0) + lean * (nod * pow(t0, 2.2))
			var b1 := Vector3(0.0, bh * t1, 0.0) + lean * (nod * pow(t1, 2.2))
			var l0 := b0 - wide * (base_w * (1.0 - 0.85 * t0))
			var r0 := b0 + wide * (base_w * (1.0 - 0.85 * t0))
			var l1 := b1 - wide * (base_w * (1.0 - 0.85 * t1))
			var r1 := b1 + wide * (base_w * (1.0 - 0.85 * t1))
			var uy0 := 1.0 - t0
			var uy1 := 1.0 - t1
			st.set_uv(Vector2(0.0, uy0))
			st.add_vertex(l0)
			st.set_uv(Vector2(1.0, uy0))
			st.add_vertex(r0)
			st.set_uv(Vector2(1.0, uy1))
			st.add_vertex(r1)
			st.set_uv(Vector2(0.0, uy0))
			st.add_vertex(l0)
			st.set_uv(Vector2(1.0, uy1))
			st.add_vertex(r1)
			st.set_uv(Vector2(0.0, uy1))
			st.add_vertex(l1)
	var mesh := st.commit()
	var mat := ShaderMaterial.new()
	mat.shader = shader
	mat.set_shader_parameter("wind_noise", wind_tex)
	mat.set_shader_parameter("top_color", top)
	mat.set_shader_parameter("bottom_color", bottom)
	mesh.surface_set_material(0, mat)
	return mesh


# Accept probability in [0,1] for a tuft at (x,z). Distances are precomputed by world_view (it
# already samples them for the exclusion test): river_edge_d = signed distance past the channel
# half-width; path_verge_d = vp_path_dist (negative on the worn path); road_verge_off = metres past
# the 3.6 m road corridor (or a large sentinel off the road span).
static func density(
	x: float,
	z: float,
	noise: FastNoiseLite,
	lake_center: Vector2,
	lake_radius: float,
	river_edge_d: float,
	path_verge_d: float,
	road_verge_off: float,
	plots: Array,
	plot_radius: float,
	paddock_rect: Array
) -> float:
	var p := Vector2(x, z)
	# Patchy base: remap noise [-1,1] then square so the open common dips to genuine bare ground.
	var base := clampf(0.5 + 0.72 * noise.get_noise_2d(x, z), 0.0, 1.0)
	base = base * base
	var boost := 0.0
	var lake_d := absf(p.distance_to(lake_center) - lake_radius)  # wet lake margin
	if lake_d < 5.0:
		boost = maxf(boost, 0.85 * (1.0 - lake_d / 5.0))
	if absf(river_edge_d) < 4.0:  # river banks
		boost = maxf(boost, 0.7 * (1.0 - absf(river_edge_d) / 4.0))
	if path_verge_d > 0.0 and path_verge_d < 3.0:  # just off the worn path, never on it
		boost = maxf(boost, 0.65 * (1.0 - path_verge_d / 3.0))
	if road_verge_off > 0.0 and road_verge_off < 3.0:  # King's Road verge (centre stays bare)
		boost = maxf(boost, 0.55 * (1.0 - road_verge_off / 3.0))
	for plot: Vector2 in plots:  # disturbed nitrogen-rich strip hard against dwelling walls
		var pd := p.distance_to(plot) - plot_radius
		if pd > 0.0 and pd < 4.0:
			boost = maxf(boost, 0.75 * (1.0 - pd / 4.0))
			break
	var fence_d := _paddock_fence_dist(x, z, paddock_rect)  # tall drift along the stock fence
	if fence_d < 2.2:
		boost = maxf(boost, 0.8 * (1.0 - fence_d / 2.2))
	return clampf(base + boost, 0.0, 1.0)


# Distance from (x,z) to the sheep-paddock fence line (the [cx,cz,hx,hz] rectangle perimeter).
static func _paddock_fence_dist(x: float, z: float, rect: Array) -> float:
	var dx: float = absf(x - rect[0]) - rect[2]
	var dz: float = absf(z - rect[1]) - rect[3]
	var outside := Vector2(maxf(dx, 0.0), maxf(dz, 0.0)).length()
	return absf(outside + minf(maxf(dx, dz), 0.0))
