# T-226: mobs treat Crystal Lake as impassable — clamp keeps every AI movement step
# out of the water disc (wolves stood ON the lake in the T-220 proof shot).

extends GutTest

const _MAI = preload("res://scripts/combat/mob_ai.gd")


func test_clamp_leaves_dry_land_untouched() -> void:
	var p := Vector3(0.0, 0.0, 0.0)
	assert_eq(_MAI.clamp_out_of_water(p), p)


func test_clamp_pushes_wet_destination_to_the_rim() -> void:
	var inside := Vector3(18.0, 22.0, 0.0) + Vector3(3.0, 4.0, 0.0)  # 5m from center
	var out := _MAI.clamp_out_of_water(inside)
	var d := Vector2(out.x - 18.0, out.y - 22.0).length()
	assert_almost_eq(d, _MAI.LAKE_RADIUS + 0.2, 0.01, "clamped to the shore rim")


func test_clamp_center_degenerate_is_safe() -> void:
	var out := _MAI.clamp_out_of_water(Vector3(18.0, 22.0, 0.0))
	var d := Vector2(out.x - 18.0, out.y - 22.0).length()
	assert_true(d >= _MAI.LAKE_RADIUS, "dead-center input still lands ashore")


func test_shore_slide_makes_tangential_progress() -> void:
	# A mob on the west shore stepping straight at a target on the east shore must
	# stay dry AND still change position (slides around, never freezes).
	var start := Vector3(18.0 - _MAI.LAKE_RADIUS - 0.2, 22.0, 0.0)
	var toward_center := start + Vector3(1.0, 0.4, 0.0)  # a raw step INTO the water
	var out := _MAI.clamp_out_of_water(toward_center)
	var d := Vector2(out.x - 18.0, out.y - 22.0).length()
	assert_true(d >= _MAI.LAKE_RADIUS, "stays out of the water")
	assert_true(out.distance_to(start) > 0.05, "still moves (slides along the shore)")
