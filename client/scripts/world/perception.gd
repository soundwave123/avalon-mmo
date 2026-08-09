class_name Perception
extends RefCounted

# Headless 3D "perception" checks: GEOMETRIC, not pixels. --headless disables rendering (so pixel
# tests need a virtual display, Xvfb), but is_position_in_frustum + unproject_position are pure math
# and work headless. So we gate "is the entity where the camera sees it" with no display, catching
# off-camera / wrong-position / broken-camera bugs that state-only checks miss. See ADR 0009.


# True when world_pos is inside the camera's view frustum (in front, within FOV + near/far). Ignores
# occlusion (walls): fine for the gray-box world; revisit when geometry can occlude.
static func is_on_screen(camera: Camera3D, world_pos: Vector3) -> bool:
	if camera == null or not camera.is_inside_tree():
		return false
	return camera.is_position_in_frustum(world_pos)


# Where world_pos projects on screen (pixels). Meaningful only when is_on_screen() is true. Useful
# for richer assertions (a marker above an entity). Behind the camera, unproject is unreliable.
static func screen_position(camera: Camera3D, world_pos: Vector3) -> Vector2:
	if camera == null or not camera.is_inside_tree() or camera.is_position_behind(world_pos):
		return Vector2(-1, -1)
	return camera.unproject_position(world_pos)
