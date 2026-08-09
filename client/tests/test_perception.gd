extends GutTest

# Validates the headless perception gate (no rendering needed). This is the pattern future 3D tickets
# reuse: place a camera + a world point, assert whether the camera can see it.

const Perception = preload("res://scripts/world/perception.gd")


func _camera() -> Camera3D:
	var cam := Camera3D.new()
	add_child_autofree(cam)
	cam.global_position = Vector3.ZERO
	cam.look_at(Vector3(0, 0, -10))  # face -Z
	return cam


func test_point_in_front_is_on_screen() -> void:
	assert_true(Perception.is_on_screen(_camera(), Vector3(0, 0, -5)), "directly ahead → visible")


func test_point_behind_is_not_on_screen() -> void:
	assert_false(
		Perception.is_on_screen(_camera(), Vector3(0, 0, 5)), "behind the camera → not visible"
	)


func test_point_far_to_the_side_is_not_on_screen() -> void:
	assert_false(
		Perception.is_on_screen(_camera(), Vector3(100, 0, -5)), "outside the FOV → not visible"
	)


func test_null_or_detached_camera_is_safe() -> void:
	assert_false(
		Perception.is_on_screen(null, Vector3.ZERO), "null camera → not visible (no crash)"
	)
	assert_false(
		Perception.is_on_screen(Camera3D.new(), Vector3.ZERO), "detached camera → not visible"
	)


func test_screen_position_for_visible_point_is_in_viewport() -> void:
	var cam := _camera()
	var sp := Perception.screen_position(cam, Vector3(0, 0, -5))
	var rect := cam.get_viewport().get_visible_rect()
	assert_true(rect.has_point(sp), "a point dead ahead projects inside the viewport rect")
