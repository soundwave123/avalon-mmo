extends GutTest

# T-737: which ground am I standing on? Pure analytic statics composed from the SAME mirrors the
# clutter scatter and the world audit already use (WorldView.hk_street_dist / vp_path_dist /
# in_farmstead_rect / in_ashmoor_district / road_center_x), so the footstep you HEAR agrees with
# the ground the splat shader PAINTED. No texture reads, no raycasts, no physics — cheap enough
# to call every footfall, and headlessly testable.

const Surface = preload("res://scripts/world/terrain_surface.gd")
const World = preload("res://scripts/world/world_view.gd")


func test_open_meadow_is_grass() -> void:
	assert_eq(Surface.surface_at(60.0, 60.0), Surface.GRASS, "far from any paint = meadow turf")
	assert_eq(Surface.surface_at(-80.0, 90.0), Surface.GRASS, "open ground the other side")


func test_highkeep_plaza_and_streets_are_stone() -> void:
	# HK_PLAZA_POS (0,-215): flagstone market plaza, inside the wall circuit.
	assert_eq(Surface.surface_at(0.0, -215.0), Surface.STONE, "the market plaza is flagstone")
	# A point on the approach avenue (HK_STREET_SEGS segment 0,-140 -> -2,-168).
	assert_eq(Surface.surface_at(0.0, -140.0), Surface.STONE, "a cobbled avenue reads as stone")


func test_ashmoor_paved_district_is_stone() -> void:
	# ASHMOOR_SOOT_RECT centre (-420,-2): the era-2 paved/packed industrial district.
	assert_eq(Surface.surface_at(-420.0, -2.0), Surface.STONE, "Ashmoor's district reads hard")
	assert_eq(Surface.surface_at(-600.0, -2.0), Surface.GRASS, "and it stops at its edge")


func test_the_kings_road_corridor_is_dirt() -> void:
	# The road wobbles, so the test point is derived from the same centreline the shader uses.
	var z := -60.0
	var cx := World.road_center_x(z)
	assert_eq(Surface.surface_at(cx, z), Surface.DIRT, "the road centre is packed earth")
	assert_eq(Surface.surface_at(cx + 30.0, z), Surface.GRASS, "30 m off the verge is meadow again")


func test_the_road_does_not_bleed_outside_its_z_corridor() -> void:
	# road_center_x() flattens to 0 outside the wobble window, so a naive |x - centre| test would
	# paint the whole x~0 meridian as road. The z gate is what stops that.
	assert_eq(Surface.surface_at(0.0, 200.0), Surface.GRASS, "far south of the road's end")


func test_village_branch_paths_are_dirt() -> void:
	# VP_SEGS[0] runs (0,-9.5) -> (-2.2,-9.8) with a 0.80 m half-width.
	assert_eq(Surface.surface_at(0.0, -9.5), Surface.DIRT, "a worn village spur")


func test_worked_farmland_is_dirt() -> void:
	# FIELD_RECTS[0] = planted wheat plot at (29,15); PADDOCK_RECT = the pen at (26,4).
	assert_eq(Surface.surface_at(29.0, 15.0), Surface.DIRT, "a tilled plot is turned earth")
	assert_eq(Surface.surface_at(26.0, 4.0), Surface.DIRT, "the trodden sheep pen")


func test_indoors_overrides_every_outdoor_surface() -> void:
	# The interior gate wins outright: you are on a plank floor regardless of what is painted
	# on the terrain underneath the building.
	assert_eq(Surface.surface_at(60.0, 60.0, true), Surface.WOOD, "indoors over meadow")
	assert_eq(Surface.surface_at(0.0, -215.0, true), Surface.WOOD, "indoors over the plaza")


func test_every_result_is_a_known_surface_with_a_clip_family() -> void:
	# Fail-closed contract: surface_at can never invent a name the audio side has no clips for.
	var probes := [
		Vector2(0.0, 0.0),
		Vector2(0.0, -215.0),
		Vector2(-420.0, -2.0),
		Vector2(29.0, 15.0),
		Vector2(600.0, -600.0),
		Vector2(-120.0, -300.0),
	]
	for p: Vector2 in probes:
		for indoors in [false, true]:
			var s := Surface.surface_at(p.x, p.y, indoors)
			assert_true(Surface.SURFACES.has(s), "%s at %s is a known surface" % [s, str(p)])
