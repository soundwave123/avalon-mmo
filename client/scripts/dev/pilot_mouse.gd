class_name PilotMouse
extends RefCounted

# T-736: {"op":"rclick","name":"<username>"} — right-click a named entity through the REAL input
# path. Finds the entity in remote_entities, unprojects its body via the live camera, then
# synthesizes an RMB press+release at that pixel with NO motion in between (below the T-739
# deadzone), so local_player emits right_clicked and PartyInviteFlow's ray-pick resolves this
# same entity. The whole live chain (deadzone -> ray -> relationship gate -> context menu) runs;
# nothing is short-circuited. Carved into its own module: pilot.gd sits at the 1000-line cap.


# A HEADLESS window boots degenerate (~64 px square — project size is never applied without a
# display), which crushes every screen-space op: unproject piles entities into a corner, HUD
# buttons overlap the screen centre and swallow injected mouse events. Normalise once to the
# playtest window so pilot geometry matches a real client's.
static func ensure_viewport(pilot: Node) -> void:
	var win := pilot.get_tree().root
	if win.size.x < 320:
		win.size = Vector2i(1152, 648)


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
		var pos := cam.unproject_position(world_pos)
		for pressed in [true, false]:
			var ev := InputEventMouseButton.new()
			ev.button_index = MOUSE_BUTTON_RIGHT
			ev.pressed = pressed
			ev.position = pos
			ev.global_position = pos
			Input.parse_input_event(ev)
		var vp := pilot.get_viewport().get_visible_rect().size
		return {"ok": true, "x": pos.x, "y": pos.y, "target_id": int(id), "vp": [vp.x, vp.y]}
	return {"ok": false, "error": "entity not found: %s" % username}
