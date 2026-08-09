class_name NpcMarkersLayer
extends Node2D

# T-048: manages one NpcMarker per NPC from the server's npc_indicators payload — create on first
# sight, update position + indicator each refresh, free when an NPC drops out of the payload.
# World-space (Node2D); renders correctly once the client has a world view + camera (follow-on).

var _markers: Dictionary = {}  # npc_id -> NpcMarker


func update(npcs: Array) -> void:
	var seen: Dictionary = {}
	for npc: Dictionary in npcs:
		var npc_id := str(npc.get("npc_id", ""))
		if npc_id == "":
			continue
		seen[npc_id] = true
		var marker = _markers.get(npc_id)
		if marker == null:
			marker = NpcMarker.new()
			marker.name = "Marker_%s" % npc_id
			_markers[npc_id] = marker
			add_child(marker)
		marker.setup(npc_id, Vector2(float(npc.get("x", 0.0)), float(npc.get("y", 0.0))))
		marker.apply(str(npc.get("indicator", "")))
	for npc_id: String in _markers.keys():
		if not seen.has(npc_id):
			_markers[npc_id].queue_free()
			_markers.erase(npc_id)


# T-058: targeted update — upsert only the listed markers; unlisted ones are untouched.
func apply_partial(npcs: Array) -> void:
	for npc: Dictionary in npcs:
		var npc_id := str(npc.get("npc_id", ""))
		if npc_id == "":
			continue
		var marker = _markers.get(npc_id)
		if marker == null:
			marker = NpcMarker.new()
			marker.name = "Marker_%s" % npc_id
			_markers[npc_id] = marker
			add_child(marker)
		marker.setup(npc_id, Vector2(float(npc.get("x", 0.0)), float(npc.get("y", 0.0))))
		marker.apply(str(npc.get("indicator", "")))


func marker_count() -> int:
	return _markers.size()


func get_marker(npc_id: String):
	return _markers.get(npc_id)
