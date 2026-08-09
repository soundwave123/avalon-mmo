extends GutTest

# T-308 (absorbs T-316 HUD half): compass heading math. Per world-conventions.md, yaw 0 = north
# (-Z), and yaw grows clockwise through east/south/west.

const CompassStrip = preload("res://scripts/ui/compass_strip.gd")


func test_yaw_zero_is_north() -> void:
	assert_eq(CompassStrip.cardinal(0.0), "N")


func test_yaw_ninety_is_east() -> void:
	assert_eq(CompassStrip.cardinal(deg_to_rad(90.0)), "E")


func test_yaw_one_eighty_is_south() -> void:
	assert_eq(CompassStrip.cardinal(deg_to_rad(180.0)), "S")


func test_yaw_two_seventy_is_west() -> void:
	assert_eq(CompassStrip.cardinal(deg_to_rad(270.0)), "W")


func test_diagonal_is_northeast() -> void:
	assert_eq(CompassStrip.cardinal(deg_to_rad(45.0)), "NE")


func test_negative_yaw_wraps() -> void:
	assert_eq(CompassStrip.cardinal(deg_to_rad(-90.0)), "W", "-90 deg wraps to 270 = west")


func test_wraps_near_360_to_north() -> void:
	assert_eq(CompassStrip.cardinal(deg_to_rad(359.0)), "N", "just shy of a full turn reads north")


func test_normalize_deg_range() -> void:
	assert_almost_eq(CompassStrip.normalize_deg(-10.0), 350.0, 0.001)
	assert_almost_eq(CompassStrip.normalize_deg(370.0), 10.0, 0.001)


func test_instance_updates_label() -> void:
	var c := CompassStrip.new()
	add_child_autofree(c)
	c.update_heading(deg_to_rad(90.0))
	assert_eq(c.get_cardinal(), "E")


# ---- T-710/T-711: guidance-pip bearing math (same convention as the heading) ----------------


func test_bearing_to_deg_matches_the_heading_convention() -> void:
	var origin := Vector3.ZERO
	assert_almost_eq(CompassStrip.bearing_to_deg(origin, Vector3(0, 0, -10)), 0.0, 0.001, "north")
	assert_almost_eq(CompassStrip.bearing_to_deg(origin, Vector3(10, 0, 0)), 90.0, 0.001, "east")
	assert_almost_eq(CompassStrip.bearing_to_deg(origin, Vector3(0, 0, 10)), 180.0, 0.001, "south")
	assert_almost_eq(CompassStrip.bearing_to_deg(origin, Vector3(-10, 0, 0)), 270.0, 0.001, "west")


func test_relative_bearing_is_zero_when_facing_the_target() -> void:
	# Facing east (yaw 90 in the compass convention) with the target due east = dead ahead.
	assert_almost_eq(
		CompassStrip.relative_bearing_deg(deg_to_rad(90.0), Vector3.ZERO, Vector3(10, 0, 0)),
		0.0,
		0.001
	)


func test_relative_bearing_signs_left_and_right() -> void:
	# Facing north: east is +90 (clockwise/right), west is -90 (left).
	var yaw := 0.0
	assert_almost_eq(
		CompassStrip.relative_bearing_deg(yaw, Vector3.ZERO, Vector3(10, 0, 0)), 90.0, 0.001
	)
	assert_almost_eq(
		CompassStrip.relative_bearing_deg(yaw, Vector3.ZERO, Vector3(-10, 0, 0)), -90.0, 0.001
	)


func test_pip_offset_maps_and_clamps() -> void:
	assert_almost_eq(CompassStrip.pip_offset(0.0, 62.0), 0.0, 0.001, "dead ahead = center")
	assert_almost_eq(CompassStrip.pip_offset(45.0, 62.0), 31.0, 0.001, "half range = half width")
	assert_almost_eq(CompassStrip.pip_offset(170.0, 62.0), 62.0, 0.001, "behind clamps to the edge")
	assert_almost_eq(CompassStrip.pip_offset(-170.0, 62.0), -62.0, 0.001)


func test_pip_shows_and_clears_on_the_instance() -> void:
	var c := CompassStrip.new()
	add_child_autofree(c)
	assert_false(c.is_pip_visible(), "hidden until guidance aims it")
	c.set_pip(30.0)
	assert_true(c.is_pip_visible())
	c.clear_pip()
	assert_false(c.is_pip_visible())


# ---- T-460: idle HUD chrome — the compass is text over a gradient, not a box ----------------


func test_compass_surface_has_no_opaque_box_or_thick_border() -> void:
	var c := CompassStrip.new()
	add_child_autofree(c)
	var panel := c.get_node("CompassPanel") as PanelContainer
	var sb := panel.get_theme_stylebox("panel")
	assert_true(sb is StyleBoxEmpty, "the compass surface carries no fill or border at all")


func test_compass_backdrop_is_a_subtle_gradient() -> void:
	var c := CompassStrip.new()
	add_child_autofree(c)
	var backdrop := c.get_node("CompassGradient") as TextureRect
	assert_not_null(backdrop, "the chat-idiom gradient sits behind the heading text")
	assert_true(backdrop.texture is GradientTexture2D, "gradient, not a filled box")
	assert_lte(backdrop.modulate.a, 0.3, "reference model: at most a subtle ~25-30% veil")
