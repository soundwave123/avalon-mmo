extends GutTest

# T-187: pure geometry + hysteresis tests for interior_zones.gd — no scene tree needed, just
# Vector3/Dictionary fixtures. See interior_gate.gd for the stateful per-frame wrapper.

const InteriorZones = preload("res://scripts/world/interior_zones.gd")


func _box_volume() -> Dictionary:
	# A 4x6 footprint (x half=2, z half=3), 3m tall, centered at (10, 0, 20), unrotated.
	return {
		"id": "house",
		"center": Vector3(10.0, 0.0, 20.0),
		"half_extents": Vector2(2.0, 3.0),
		"height": 3.0,
		"rot_y": 0.0,
	}


func test_contains_true_dead_center() -> void:
	var v := _box_volume()
	assert_true(InteriorZones.contains(Vector3(10.0, 1.0, 20.0), v), "dead center is inside")


func test_contains_false_outside_footprint() -> void:
	var v := _box_volume()
	assert_false(
		InteriorZones.contains(Vector3(20.0, 1.0, 20.0), v), "far outside the footprint on x"
	)


func test_contains_false_above_roof() -> void:
	var v := _box_volume()
	assert_false(InteriorZones.contains(Vector3(10.0, 10.0, 20.0), v), "well above the roof height")


func test_contains_respects_margin() -> void:
	var v := _box_volume()
	# Just outside the x half-extent (2.3 vs half 2.0) — fails with zero margin, passes expanded.
	var just_outside := Vector3(12.3, 1.0, 20.0)
	assert_false(InteriorZones.contains(just_outside, v, 0.0), "just outside, no margin")
	assert_true(InteriorZones.contains(just_outside, v, 0.5), "just outside, expanded margin")


func test_contains_handles_rotation() -> void:
	# Rotate the box 90 degrees — the "long" (z, half=3) axis now runs along world X.
	var v := _box_volume()
	v["rot_y"] = deg_to_rad(90.0)
	# 2.8 along world x from center: inside the rotated long axis (half 3), would be OUTSIDE the
	# unrotated short axis (half 2) — proves the rotation math actually runs, not a no-op.
	var point := Vector3(12.8, 1.0, 20.0)
	assert_true(InteriorZones.contains(point, v), "inside once the long axis is rotated onto x")


func test_volume_from_local_aabb_places_center_and_extents() -> void:
	# A local AABB offset from its own origin (as a real building's door-facing footprint would
	# be) — position (-1,-2,0.5) size... wait keep simple: position at origin, size 4x3x6.
	var local_aabb := AABB(Vector3(-2.0, 0.0, -3.0), Vector3(4.0, 3.0, 6.0))
	var vol := InteriorZones.volume_from_local_aabb(
		"cottage", local_aabb, Vector3(5.0, 0.0, 5.0), 0.0, 1.0
	)
	assert_eq(vol["id"], "cottage")
	assert_almost_eq(vol["center"].x, 5.0, 0.001, "local aabb was centered on x, no offset")
	assert_almost_eq(vol["center"].z, 5.0, 0.001, "local aabb was centered on z, no offset")
	assert_almost_eq(vol["half_extents"].x, 2.0, 0.001)
	assert_almost_eq(vol["half_extents"].y, 3.0, 0.001)
	assert_almost_eq(vol["height"], 3.0, 0.001)


func test_volume_from_local_aabb_applies_scale() -> void:
	var local_aabb := AABB(Vector3(-1.0, 0.0, -1.0), Vector3(2.0, 2.0, 2.0))
	var vol := InteriorZones.volume_from_local_aabb("scaled", local_aabb, Vector3.ZERO, 0.0, 2.0)
	assert_almost_eq(vol["half_extents"].x, 2.0, 0.001, "half extent doubled by scale 2.0")
	assert_almost_eq(vol["height"], 4.0, 0.001, "height doubled by scale 2.0")


func test_resolve_indoors_enters_when_well_inside() -> void:
	var v := _box_volume()
	var res := InteriorZones.resolve_indoors(Vector3(10.0, 1.0, 20.0), [v], false, "")
	assert_true(res["indoors"])
	assert_eq(res["id"], "house")


func test_resolve_indoors_hysteresis_keeps_you_indoors_in_the_doorway() -> void:
	var v := _box_volume()
	# A point just PAST the outer edge (half.x=2.0), where a zero-margin test would already read
	# "outside" — but the exit margin (0.6 default) should still call this indoors, since the
	# player was already inside last frame. This is the doorway-flicker guard.
	var doorway := Vector3(12.3, 1.0, 20.0)
	var res := InteriorZones.resolve_indoors(doorway, [v], true, "house")
	assert_true(res["indoors"], "exit margin keeps the doorway from flickering to outdoors")
	assert_eq(res["id"], "house")


func test_resolve_indoors_actually_exits_past_the_exit_margin() -> void:
	var v := _box_volume()
	var far_outside := Vector3(20.0, 1.0, 20.0)
	var res := InteriorZones.resolve_indoors(far_outside, [v], true, "house")
	assert_false(res["indoors"], "far enough outside actually exits")
	assert_eq(res["id"], "")


func test_resolve_indoors_entering_a_new_volume_uses_the_stricter_enter_margin() -> void:
	# Standing right at the boundary (half.x=2.0 exactly) while NOT already indoors should NOT
	# count as entering — enter_margin shrinks the box, so you must be a bit further in.
	var v := _box_volume()
	var at_edge := Vector3(12.0, 1.0, 20.0)
	var res := InteriorZones.resolve_indoors(at_edge, [v], false, "")
	assert_false(res["indoors"], "right at the edge doesn't count as entering yet")
