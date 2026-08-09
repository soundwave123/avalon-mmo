extends GutTest

# T-441: water bodies are one substance sitting in the T-445 carved bed — the lake and the
# capital river share ONE shader with its default palette, the visible river sheet is trimmed
# to the carved course (never under a cottage foundation), the material reads true scene depth
# (Beer-Lambert murk + soft depth-fade banks), and the new reed clusters dress the wet margin.

const WorldView = preload("res://scripts/world/world_view.gd")
const RiverView = preload("res://scripts/world/river_view.gd")
const WaterView = preload("res://scripts/world/water_view.gd")
const TerrainField = preload("res://scripts/world/terrain_field.gd")
const WATER_SHADER = preload("res://shaders/water.gdshader")


func _world():
	var wv = WorldView.new()
	add_child_autofree(wv)  # _ready builds lake + river
	return wv


func _load_props() -> Array:
	var raw: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://assets/props.json"))
	return raw["props"] if raw is Dictionary and raw.has("props") else raw


func test_lake_and_river_share_one_water_substance() -> void:
	var wv = _world()
	var lake := wv.get_node("CrystalLake") as MeshInstance3D
	var river := wv.get_node("CapitalRiver") as MeshInstance3D
	assert_not_null(lake, "Crystal Lake water plane exists")
	assert_not_null(river, "capital river ribbon exists")
	for body: MeshInstance3D in [lake, river]:
		var mat := body.material_override as ShaderMaterial
		assert_eq(mat.shader, WATER_SHADER, "%s runs the shared water shader" % body.name)
		# One substance: neither body overrides the palette — colour comes from the shader
		# defaults + the true depth read, so pond and river can never drift apart again.
		assert_null(
			mat.get_shader_parameter("deep_color"),
			"%s must not override deep_color (one substance)" % body.name
		)
		assert_null(
			mat.get_shader_parameter("shallow_color"),
			"%s must not override shallow_color (one substance)" % body.name
		)


func test_water_shader_reads_true_scene_depth() -> void:
	# Regression guard for the T-441 depth read: the milky flat-sheet look came from a material
	# that never consulted the depth buffer. The shader must keep its depth-texture uniform and
	# the Beer-Lambert / edge-fade uniforms the world code relies on.
	assert_true(WATER_SHADER.code.contains("hint_depth_texture"), "depth buffer is sampled")
	assert_true(WATER_SHADER.code.contains("absorption"), "Beer-Lambert murk uniform present")
	assert_true(WATER_SHADER.code.contains("edge_fade"), "soft bank depth-fade uniform present")


func test_river_water_edge_stays_inside_the_carved_bed() -> void:
	# The visible sheet must be trimmed to the T-445 carved course: alpha reaches 0 within the
	# bed floor (half-width 3.2 m through the pads), so the water edge always sits over
	# submerged mud, never on dry grass.
	var half: float = RiverView.water_half_width_max()
	assert_between(half, 2.5, 3.2, "water sheet trimmed to the carved bed floor")
	var field = TerrainField.new()
	# Poor-ward reach (centerline runs (19,-140) -> (18,-112)): the ground under both water
	# edges is carved below the y=0.06 water plane.
	for z: float in [-116.0, -122.0, -128.0, -134.0]:
		var cx := lerpf(19.0, 18.0, (z + 140.0) / 28.0)
		for side: float in [-1.0, 1.0]:
			var h: float = field.height(cx + side * half, z)
			assert_lt(h, 0.0, "bed under the water edge at z=%s side=%s is submerged" % [z, side])


func test_highkeep_wall_stretch_has_culvert_water_continuation() -> void:
	# T-492: at the north curtain-wall stretch the river must not read as a dry ditch ending
	# in open lawn. The water ribbon continues past the wall crossing and the bed under the
	# player's QA sightline remains submerged, so a culvert/sluice prop can honestly frame it.
	var north_tail := Vector2(RiverView.RIVER_PTS[0][0], RiverView.RIVER_PTS[0][1])
	assert_lt(north_tail.y, -374.0, "water ribbon continues beyond the north curtain wall")
	assert_between(north_tail.x, 50.0, 62.0, "river tail stays aligned with the carved channel")
	var field = TerrainField.new()
	var half: float = RiverView.water_half_width_max()
	for z: float in [-292.0, -285.0, -278.0]:
		var d := RiverView.dist(40.0, z)
		assert_lt(d, half, "wall-shot centerline carries visible water at z=%s" % z)
		assert_lt(field.height(40.0, z), RiverView.WATER_Y, "wall-shot bed is below water")


func test_poor_cottages_stand_clear_of_the_water() -> void:
	# The audit symptom: the river sheet clipped straight under the poor cottages. Every
	# cottage must now stand beyond the visible water edge with bank to spare.
	var checked := 0
	for p in _load_props():
		if not (p is Dictionary and String(p.get("scene", "")).contains("cottage_poor")):
			continue
		var d: float = RiverView.dist(float(p["x"]), float(p["y"]))
		assert_gt(
			d,
			RiverView.water_half_width_max() + 1.0,
			"cottage at (%s,%s) stands on dry ground past the bank" % [p["x"], p["y"]]
		)
		checked += 1
	assert_eq(checked, 7, "all poor cottages checked (4 gate-hamlet + T-604 x2 + T-605 farmstead)")


func test_t441_reeds_dress_the_wet_margin() -> void:
	# Biology: reeds mark the band where water meets land — every T-441 cluster sits between
	# the visible water edge and the top of the cut bank, seated at/below grade 0 (the margin),
	# never out in open water or up on the dry lawn.
	var edge: float = RiverView.water_half_width_max()
	var checked := 0
	for p in _load_props():
		if not (p is Dictionary and String(p.get("tag", "")) == "t441"):
			continue
		var d: float = RiverView.dist(float(p["x"]), float(p["y"]))
		assert_between(d, edge, 5.5, "reed at (%s,%s) sits on the margin band" % [p["x"], p["y"]])
		assert_lt(float(p.get("terrain_y", 0.0)), 0.11, "reed is seated at/below the bank grade")
		checked += 1
	assert_gt(checked, 15, "the river margin carries real reed dressing")


func test_t531_river_tail_tapers_to_a_soft_terminus() -> void:
	# T-531: the western tail used to end in a full-width square strip edge mid-meadow (a dug-canal
	# read). The ribbon mesh now ramps its half-width down over the FINAL segment so the sheet
	# tapers to a sliver at the terminus, while RIVER_HALF and the transverse shader fade stay
	# untouched (the terrain/audit/splat three-way sync must not move).
	var n: int = RiverView.RIVER_PTS.size()
	assert_almost_eq(RiverView.tail_width_scale(0, n), 1.0, 0.001, "upstream ribbon is full width")
	assert_almost_eq(
		RiverView.tail_width_scale(n - 3, n), 1.0, 0.001, "taper does not reach existing bank reeds"
	)
	assert_lt(RiverView.tail_width_scale(n - 2, n), 1.0, "penultimate cross-section narrows")
	assert_lt(
		RiverView.tail_width_scale(n - 1, n), 0.2, "terminus collapses to a sliver, not square"
	)
	# Sanity: the taper is a pure mesh-vertex scale — the sync-critical constant is unchanged.
	assert_eq(RiverView.RIVER_HALF, 3.6, "RIVER_HALF (three-way splat sync) untouched by the taper")


func test_t531_tail_reeds_dress_the_naturalised_terminus() -> void:
	# The tapering tail peters into a reed marsh at the terminus [-52,-92] instead of stopping
	# square. Every T-531 reed sits near that terminus and is seated in the wet carved margin
	# (grade below the y=0.06 water plane), matching the T-441 shore treatment.
	var terminus := Vector2(RiverView.RIVER_PTS[RiverView.RIVER_PTS.size() - 1][0], -92.0)
	var checked := 0
	for p in _load_props():
		if not (p is Dictionary and String(p.get("tag", "")) == "t531"):
			continue
		var here := Vector2(float(p["x"]), float(p["y"]))
		assert_lt(here.distance_to(terminus), 18.0, "reed at %s hugs the river terminus" % here)
		assert_lt(float(p.get("terrain_y", 0.0)), 0.06, "tail reed seated in the wet margin")
		checked += 1
	assert_gt(checked, 5, "the naturalised tail carries a real reed marsh")


func test_day_tick_drives_the_sheen_with_the_sun_arc() -> void:
	# The milky-white read glowed day AND night; the sheen now follows the sun (dimmed by
	# overcast) so night water stops glowing.
	var mat := ShaderMaterial.new()
	mat.shader = WATER_SHADER
	var mats: Array[ShaderMaterial] = [mat]
	WaterView.day_tick(mats, 46.0, 1.0)  # full day
	assert_almost_eq(float(mat.get_shader_parameter("sheen_strength")), 1.0, 0.001, "day sheen")
	WaterView.day_tick(mats, 46.0, 0.55)  # overcast day
	assert_almost_eq(float(mat.get_shader_parameter("sheen_strength")), 0.55, 0.001, "overcast")
	WaterView.day_tick(mats, -20.0, 1.0)  # deep night
	assert_almost_eq(float(mat.get_shader_parameter("sheen_strength")), 0.0, 0.001, "night sheen")
