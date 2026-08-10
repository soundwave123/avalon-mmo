class_name PilotMouse
extends RefCounted

# The pilot's mouse-input module, and the one place that reconciles the two coordinate spaces
# T-747's UI stretch introduced. pilot.gd sits at the 1000-line cap, so the synthesis bodies live
# here.
#
# THE SPACE PROBLEM (T-747). With canvas_items stretch the pilot straddles a boundary that is
# invisible until clicks quietly miss by a third:
#
#   * Input.parse_input_event positions are WINDOW space. Godot applies the inverse stretch on the
#     way in, so an event sent at the content centre (640,360) is DELIVERED to Controls at
#     (426.7,240) — measured on 4.7.1.
#   * Screenshots are WINDOW space too (the capture is the render target), which is what keeps the
#     agent workflow "read a pixel off the shot, `pilot.py click x y`" correct with no conversion.
#   * But everything the pilot computes a target FROM is CONTENT space: Camera3D.unproject_position,
#     Control.get_global_rect(), get_visible_rect().
#
# So the rule is one-directional and absolute: anything derived from a camera or a Control rect
# goes through UiViewport.content_to_window() before injection; anything read off a screenshot
# goes through window_to_content() before it is handed to a camera ray. Under the pilot's default
# AVALON_PILOT_RESOLUTION=1280x720 the window equals the base and both conversions are the
# identity — which is exactly why this bug would have survived every pilot smoke test and only
# shown up on the owner's 1920x1080 machine.


# A HEADLESS window boots degenerate (measured 64x64 — the project's window size is never applied
# without a display), which crushes every screen-space op: unproject piles entities into a corner,
# HUD buttons overlap the screen centre and swallow injected mouse events. Under stretch it is
# worse than it looks, because `expand` resolves the content rect against the WINDOW's aspect: a
# 64x64 window yields 1280x1280 of content, not the authored 1280x720.
#
# Normalising to the shipped window size (project.godot's window_*_override) fixes both at once and
# lands the content rect on exactly the authored base. The old value here was 1152x648, chosen
# pre-stretch to "match a real client"; it now matches nothing — under stretch it would pin a
# permanent 0.9 scale between injected coordinates and content.
static func ensure_viewport(pilot: Node) -> void:
	UiViewport.normalize_headless(pilot)


# The window-space centre of the screen. NOT get_visible_rect().size/2 — that is the CONTENT
# centre, and injecting it would land the event a third of the way in from the top-left.
static func window_centre(pilot: Node) -> Vector2:
	return UiViewport.content_to_window(
		pilot.get_viewport(), pilot.get_viewport().get_visible_rect().size / 2.0
	)


# Synthesize a left-click at a WINDOW-space position (the space `pilot.py click x y` speaks, since
# its coordinates are read off a screenshot). Callers holding a CONTENT position must convert
# first — see click_content().
static func click_window(pos: Vector2) -> void:
	var motion := InputEventMouseMotion.new()
	motion.position = pos
	motion.global_position = pos
	Input.parse_input_event(motion)
	for pressed in [true, false]:
		var ev := InputEventMouseButton.new()
		ev.button_index = MOUSE_BUTTON_LEFT
		ev.pressed = pressed
		ev.position = pos
		ev.global_position = pos
		Input.parse_input_event(ev)


# Synthesize a left-click at a CONTENT-space position — a Control's get_global_rect() centre, or
# anything unprojected from the camera.
static func click_content(pilot: Node, pos: Vector2) -> Vector2:
	var win_pos := UiViewport.content_to_window(pilot.get_viewport(), pos)
	click_window(win_pos)
	return win_pos


# T-736: {"op":"rclick","name":"<username>"} — right-click a named entity through the REAL input
# path. Finds the entity in remote_entities, unprojects its body via the live camera, then
# synthesizes an RMB press+release at that pixel with NO motion in between (below the T-739
# deadzone), so local_player emits right_clicked and PartyInviteFlow's ray-pick resolves this
# same entity. The whole live chain (deadzone -> ray -> relationship gate -> context menu) runs;
# nothing is short-circuited.
static func rclick(pilot: Node, username: String) -> Dictionary:
	ensure_viewport(pilot)
	var main := pilot.get_tree().root.get_node_or_null("Main")
	if main == null:
		return {"ok": false, "error": "no Main"}
	var remotes = main.get("remote_entities")
	var cam := pilot.get_viewport().get_camera_3d()
	if remotes == null or cam == null:
		return {"ok": false, "error": "no remote entities layer or camera"}
	var entities: Dictionary = remotes.get("_entities")
	for id in entities:
		var entity: Dictionary = entities[id]
		if str(entity.get("username", "")) != username:
			continue
		var node = entity.get("node")
		if node == null:
			return {"ok": false, "error": "entity has no body node"}
		# Chest height — comfortably inside the clickable body collider from any camera pitch.
		var world_pos: Vector3 = (node as Node3D).global_position + Vector3(0.0, 1.0, 0.0)
		if cam.is_position_behind(world_pos):
			return {"ok": false, "error": "target is behind the camera"}
		# unproject_position is CONTENT space; parse_input_event wants WINDOW space (T-747).
		var pos := cam.unproject_position(world_pos)
		var win_pos := UiViewport.content_to_window(pilot.get_viewport(), pos)
		for pressed in [true, false]:
			var ev := InputEventMouseButton.new()
			ev.button_index = MOUSE_BUTTON_RIGHT
			ev.pressed = pressed
			ev.position = win_pos
			ev.global_position = win_pos
			Input.parse_input_event(ev)
		var vp := pilot.get_viewport().get_visible_rect().size
		return {
			"ok": true,
			"x": pos.x,  # CONTENT space — where the entity is, in Control/camera coordinates
			"y": pos.y,
			"window_x": win_pos.x,  # WINDOW space — where the event went, i.e. screenshot pixels
			"window_y": win_pos.y,
			"target_id": int(id),
			"vp": [vp.x, vp.y],
		}
	return {"ok": false, "error": "entity not found: %s" % username}
