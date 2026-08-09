class_name TargetSelection
# T-462: pure selection over RemoteEntitiesLayer's server-fed entity rows. This module owns no
# state and sends no intent: it only maps a physics collider / TAB cycle to a candidate entity id.
# The world server still validates that id, range, resources, and combat state on every ability.

extends RefCounted

# T-571: NPC_CLICK is target_id_for_click's sentinel for "an NPC body was hit" — that click belongs
# to the talk handler, so the caller should leave the combat target alone.
const NPC_CLICK := -2


# Resolve Main's direct physics ray hit. Walk ancestors so a future child collider remains
# targetable; stop naturally at the scene root when the collider belongs to the world instead.
static func target_id_for_collider(entities: Dictionary, collider: Node) -> int:
	var cursor := collider
	while cursor != null:
		for id: String in entities:
			var entity: Dictionary = entities[id]
			if entity.get("node") == cursor:
				return int(entity.get("target_id", -1))
		cursor = cursor.get_parent()
	return -1


# T-571: carved out of main.gd's _unhandled_input (main.gd sits at the 1000-line cap) — resolves
# one left-click screen position through the 3D world in one call.
static func target_id_for_click(
	cam: Camera3D, screen_pos: Vector2, entities: Dictionary, npc_world: Node
) -> int:
	var from := cam.project_ray_origin(screen_pos)
	var to := from + cam.project_ray_normal(screen_pos) * 1000.0
	var space := cam.get_world_3d().direct_space_state
	var hit: Dictionary = space.intersect_ray(PhysicsRayQueryParameters3D.create(from, to))
	var collider: Node = hit.get("collider", null)
	var picked_id := target_id_for_collider(entities, collider)
	if picked_id != -1:
		return picked_id
	if collider != null and npc_world != null and collider.get_parent() == npc_world:
		return NPC_CLICK
	return -1


# Modern-MMO TAB rule: cycle living hostile mobs nearest-first. Candidates exist only because the
# server included them in this client's interest snapshot; combat still validates the chosen id.
static func next_hostile_target(entities: Dictionary, current_id: int, origin: Vector3) -> int:
	var candidates: Array = []
	for id: String in entities:
		var entity: Dictionary = entities[id]
		if bool(entity.get("is_player", false)) or int(entity.get("hp", 1)) <= 0:
			continue
		var node := entity.get("node") as Node3D
		if node == null:
			continue
		(
			candidates
			. append(
				{
					"target_id": int(entity.get("target_id", -1)),
					"distance": origin.distance_squared_to(node.global_position),
				}
			)
		)
	candidates.sort_custom(
		func(a: Dictionary, b: Dictionary) -> bool:
			if is_equal_approx(float(a["distance"]), float(b["distance"])):
				return int(a["target_id"]) < int(b["target_id"])
			return float(a["distance"]) < float(b["distance"])
	)
	if candidates.is_empty():
		return -1
	for i in candidates.size():
		if int(candidates[i]["target_id"]) == current_id:
			return int(candidates[(i + 1) % candidates.size()]["target_id"])
	return int(candidates[0]["target_id"])
