class_name HostileProximity
# #79: pure predicate over RemoteEntitiesLayer's entity rows — "is there a still-alive hostile
# within range_m of origin". PerformanceRecapPanel's autopop gate (recap_autopop_gate.gd) needs a
# way to tell "one hostile just died" from "the whole pull is actually over": a `performance_recap`
# reply arrives on EVERY mob death (world/performance_recap_service.gd), not just when the last one
# falls, so the recap used to snap open over screen-centre while a second hostile was still alive
# and attacking.
#
# Split out as its own pure static module (the TargetSelection idiom, target_selection.gd) rather
# than a new RemoteEntitiesLayer method — that class already sits at gdlint's max-public-methods
# cap. Pure function over the entities Dictionary: RemoteEntitiesLayer's own `_entities` (accessed
# via `.get("_entities")`, the same seam target_selection.gd's own tests already use).

extends RefCounted


# Mobs only (players are never the "hostile" this query cares about); dead (hp<=0) or despawned
# mobs don't count.
static func has_live_hostile_nearby(entities: Dictionary, origin: Vector3, range_m: float) -> bool:
	for id: String in entities:
		var e: Dictionary = entities[id]
		if bool(e.get("is_player", true)):
			continue
		if int(e.get("hp", 0)) <= 0:
			continue
		var node: Node3D = e.get("node")
		if node == null:
			continue
		if origin.distance_to(node.global_position) <= range_m:
			return true
	return false
