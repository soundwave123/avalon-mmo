class_name DiscoveryNodes
extends RefCounted

# T-427: data-only discovery registry + pure movement-edge query. This module has no session, DB,
# clock, or network access; world_rpc supplies authoritative old/new server positions explicitly.

const _KEYS := ["id", "name", "zone", "x", "y", "radius", "level", "xp", "coins", "lore"]
const MAX_REWARD := 100000


static func load_file(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {"nodes": [], "errors": ["discovery file missing: %s" % path]}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {"nodes": [], "errors": ["discovery file unreadable: %s" % path]}
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	if not (parsed is Dictionary) or not (parsed.get("nodes") is Array):
		return {"nodes": [], "errors": ["discovery file must contain a nodes array: %s" % path]}
	var nodes: Array = parsed["nodes"]
	return {"nodes": nodes, "errors": validate(nodes)}


static func validate(nodes: Array) -> Array:
	var errors: Array = []
	var seen := {}
	for value in nodes:
		if not (value is Dictionary):
			errors.append("discovery node must be an object")
			continue
		var node: Dictionary = value
		var node_id := str(node.get("id", ""))
		for key in node:
			if not str(key) in _KEYS:
				errors.append("discovery %s has unknown key: %s" % [node_id, key])
		if node_id == "":
			errors.append("discovery node missing id")
		elif seen.has(node_id):
			errors.append("duplicate discovery id: %s" % node_id)
		seen[node_id] = true
		for key in ["name", "zone"]:
			if str(node.get(key, "")) == "":
				errors.append("discovery %s missing %s" % [node_id, key])
		for key in ["x", "y", "radius", "level", "xp"]:
			if not node.has(key):
				errors.append("discovery %s missing %s" % [node_id, key])
		if float(node.get("radius", 0.0)) <= 0.0:
			errors.append("discovery %s radius must be > 0" % node_id)
		if int(node.get("level", 0)) < 1:
			errors.append("discovery %s level must be >= 1" % node_id)
		if int(node.get("xp", -1)) < 0 or int(node.get("xp", -1)) > MAX_REWARD:
			errors.append("discovery %s xp out of range" % node_id)
		if int(node.get("coins", 0)) < 0 or int(node.get("coins", 0)) > MAX_REWARD:
			errors.append("discovery %s coins out of range" % node_id)
	return errors


# Nodes containing new_pos but not old_pos: entering an edge, not lingering inside one.
static func entered(nodes: Array, old_pos: Vector3, new_pos: Vector3) -> Array:
	var out: Array = []
	for node: Dictionary in nodes:
		var center := Vector3(float(node.get("x", 0.0)), float(node.get("y", 0.0)), 0.0)
		var radius := float(node.get("radius", 0.0))
		if new_pos.distance_to(center) <= radius and old_pos.distance_to(center) > radius:
			out.append(node)
	return out
