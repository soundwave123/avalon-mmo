class_name FlightService
extends RefCounted

# T-431: world-side flight authority. The client names only an action and optional destination.
# Source comes from the proximity-validated service NPC; topology, price, coordinates and region
# come from flight_nodes.json. Master owns known-node persistence + the ledgered debit. Only its
# successful verdict reaches PlayerSessions.update_position, whose TerrainField reseats height.

const _PS := preload("res://scripts/player_sessions.gd")

var _master = null
var _reply: Callable = Callable()
var _nodes: Dictionary = {}  # node_id -> authored row
var _npc_nodes: Dictionary = {}  # npc_id -> node_id
# T-658: unblocks THIS peer's cached mount gate the instant a trainer purchase clears (mirrors the
# mentor-sync/gear-update setter idiom other world_rpc-owned seams use — set once, called by name).
var _mark_learned: Callable = Callable()


func setup(master, reply: Callable, path: String = "res://data/travel/flight_nodes.json") -> String:
	_master = master
	_reply = reply
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return "cannot open flight graph %s" % path
	var doc: Variant = JSON.parse_string(f.get_as_text())
	if typeof(doc) != TYPE_DICTIONARY or not (doc.get("nodes", null) is Array):
		return "malformed flight graph %s" % path
	for raw in doc["nodes"]:
		if not (raw is Dictionary):
			continue
		var row: Dictionary = raw
		var id := str(row.get("id", ""))
		var npc_id := str(row.get("npc_id", ""))
		var coords = row.get("coords", [])
		if id == "" or npc_id == "" or not (coords is Array) or coords.size() < 2:
			return "invalid flight node %s" % id
		_nodes[id] = row.duplicate(true)
		_npc_nodes[npc_id] = id
	for id in _nodes:
		for edge in _nodes[id].get("connections", []):
			if not (edge is Dictionary) or not _nodes.has(str(edge.get("dest", ""))):
				return "invalid flight edge from %s" % id
			if int(edge.get("cost", -1)) <= 0:
				return "invalid flight cost from %s" % id
	return ""


# Talking is the discovery event. npc_id is already known+proximity-gated by WorldRpc._talk.
func discover(_peer_id: int, username: String, npc_id: String) -> void:
	var node := str(_npc_nodes.get(npc_id, ""))
	if node == "" or username == "":
		return
	await _master.call_master(
		"flight_op", {"username": username, "action": "discover", "node": node}
	)


func set_mark_learned(cb: Callable) -> void:
	_mark_learned = cb


func handle(peer_id: int, username: String, npc_id: String, data: Dictionary) -> void:
	var source := str(_npc_nodes.get(npc_id, ""))
	var action := str(data.get("action", ""))
	if source == "":
		_reject(peer_id, npc_id, action, "unknown_roost")
		return
	if action == "list" or action == "browse":
		await _list(peer_id, username, npc_id, source)
	elif action == "fly":
		await _fly(peer_id, username, npc_id, source, str(data.get("dest", "")))
	elif action == "learn_mount":  # T-658: the same flightmaster teaches riding
		await _learn_mount(peer_id, username, npc_id)
	else:
		_reject(peer_id, npc_id, action, "bad_action")


func _list(peer_id: int, username: String, npc_id: String, source: String) -> void:
	var result: Dictionary = await _master.call_master(
		"flight_op", {"username": username, "action": "list"}
	)
	if result.has("error"):
		_reject(peer_id, npc_id, "list", str(result["error"]))
		return
	var known: Array = result.get("known_nodes", [])
	var destinations: Array = []
	for edge: Dictionary in _nodes[source].get("connections", []):
		var dest := str(edge.get("dest", ""))
		if not dest in known:
			continue
		var node: Dictionary = _nodes[dest]
		(
			destinations
			. append(
				{
					"id": dest,
					"name": str(node.get("name", dest)),
					"region_id": str(node.get("region_id", "")),
					"cost": int(edge.get("cost", 0)),
				}
			)
		)
	(
		_reply
		. call(
			peer_id,
			{
				"type": "service_ack",
				"ok": true,
				"npc_id": npc_id,
				"service": "flight",
				"action": "list",
				"source": source,
				"destinations": destinations,
				"coins": int(result.get("coins", 0)),
			}
		)
	)


func _fly(peer_id: int, username: String, npc_id: String, source: String, dest: String) -> void:
	if not _nodes.has(dest):
		_reject(peer_id, npc_id, "fly", "unknown_roost")
		return
	var edge := _edge(source, dest)
	if edge.is_empty():
		_reject(peer_id, npc_id, "fly", "route_unavailable")
		return
	var result: Dictionary = await (
		_master
		. call_master(
			"flight_op",
			{
				"username": username,
				"action": "fly",
				"source": source,
				"dest": dest,
				"cost": int(edge.get("cost", 0)),
			}
		)
	)
	if result.has("error") or not bool(result.get("ok", false)):
		_reject(peer_id, npc_id, "fly", str(result.get("error", "travel_failed")))
		return
	var coords: Array = _nodes[dest]["coords"]
	_PS.set_instance(peer_id, 0)
	_PS.update_position(peer_id, Vector3(float(coords[0]), float(coords[1]), 0.0))
	(
		_reply
		. call(
			peer_id,
			{
				"type": "service_ack",
				"ok": true,
				"npc_id": npc_id,
				"service": "flight",
				"action": "fly",
				"dest": dest,
				"region_id": str(_nodes[dest].get("region_id", "")),
				"coins": int(result.get("coins", 0)),
			}
		)
	)


# T-658: the one-time riding-trainer purchase. Master owns the level gate, the coin sink, and the
# learned_mount flip (TravelOps.learn_mount); a success here also unblocks THIS peer's live
# MountService cache so the very next mount keypress works with no relog.
func _learn_mount(peer_id: int, username: String, npc_id: String) -> void:
	var result: Dictionary = await _master.call_master(
		"flight_op", {"username": username, "action": "learn_mount"}
	)
	if result.has("error") or not bool(result.get("ok", false)):
		_reject(peer_id, npc_id, "learn_mount", str(result.get("error", "cannot_learn")))
		return
	if _mark_learned.is_valid():
		_mark_learned.call(peer_id)
	(
		_reply
		. call(
			peer_id,
			{
				"type": "service_ack",
				"ok": true,
				"npc_id": npc_id,
				"service": "flight",
				"action": "learn_mount",
				"coins": int(result.get("coins", 0)),
			}
		)
	)


func _edge(source: String, dest: String) -> Dictionary:
	for edge: Dictionary in _nodes[source].get("connections", []):
		if str(edge.get("dest", "")) == dest:
			return edge
	return {}


func _reject(peer_id: int, npc_id: String, action: String, reason: String) -> void:
	(
		_reply
		. call(
			peer_id,
			{
				"type": "service_ack",
				"ok": false,
				"npc_id": npc_id,
				"service": "flight",
				"action": action,
				"reason": reason,
			}
		)
	)
