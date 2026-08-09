extends GutTest

# T-596: the continent travel network — flight web integrity, cost/timing monotonicity, the
# per-hub flightmaster roster, and the end-to-end travel-time budget audit against the pacing
# targets in continent-plan.md §3 / game-direction.md §3. Data-only: this reads the shipped
# flight_nodes.json + npcs.json and the ServerConfig speed canon; it never opens the dev stack.
#
# DEFERRED (share the T-585 spawn oracle / T-594 streaming seam — held to the post-T-594 merge):
# the road-margin spawn keep-out rule and the border-crossing hand-off soak.

const _CR = preload("res://scripts/content/content_registry.gd")
const _SC = preload("res://scripts/server_config.gd")

const FLIGHT_PATH := "res://data/travel/flight_nodes.json"

# Phase-1 build zones (continent-plan.md §1) that must each own >=1 flight node.
const P1_ZONE_NODES := ["village", "highkeep", "kargrim", "ashmoor", "greyrise"]

# §3 pacing budget (seconds). A leg longer than the foot ceiling without a flight shortcut is a
# "commute"; a whole-continent traverse shorter than the world floor is "trivially short".
const FOOT_LEG_CEIL := 240.0  # ~4 min: the longest single arterial hop allowed on foot
const HUB_FLIGHT_CEIL := 180.0  # hub-to-hub stays ~2 min once earned (slack over the 120s target)
const CONTINENT_FLIGHT_CEIL := 600.0  # the 10-min continent-diagonal "world feels big" ceiling
const WORLD_FOOT_FLOOR := 240.0  # a world, not a commute: crossing it on foot is a real journey
const WORLD_MOUNT_FLOOR := 120.0  # even mounted, the envelope takes minutes end-to-end


func _graph() -> Dictionary:
	var f := FileAccess.open(FLIGHT_PATH, FileAccess.READ)
	assert_not_null(f, "flight graph opens")
	var doc: Variant = JSON.parse_string(f.get_as_text())
	assert_true(doc is Dictionary, "flight graph parses to a dict")
	return doc


func _nodes_by_id(doc: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for raw in doc.get("nodes", []):
		out[str(raw["id"])] = raw
	return out


func _coord(node: Dictionary) -> Vector2:
	var c: Array = node["coords"]
	return Vector2(float(c[0]), float(c[1]))


# Undirected unique edges as {a, b, cost, dist}, a<b lexically so each pair counts once.
func _unique_edges(nodes: Dictionary) -> Array:
	var seen: Dictionary = {}
	var edges: Array = []
	for id in nodes:
		var src := str(id)
		for e in nodes[id].get("connections", []):
			var dest := str(e["dest"])
			var key := src + "|" + dest if src < dest else dest + "|" + src
			if seen.has(key):
				continue
			seen[key] = true
			(
				edges
				. append(
					{
						"a": src,
						"b": dest,
						"cost": int(e["cost"]),
						"dist": _coord(nodes[id]).distance_to(_coord(nodes[dest])),
					}
				)
			)
	return edges


# ---- flight-graph integrity ------------------------------------------------------------------


func test_every_phase1_zone_owns_a_flight_node() -> void:
	var nodes := _nodes_by_id(_graph())
	for zone in P1_ZONE_NODES:
		assert_true(nodes.has(zone), "P1 zone '%s' has a flight node" % zone)


func test_graph_is_connected_with_no_orphan_nodes() -> void:
	var nodes := _nodes_by_id(_graph())
	# adjacency (undirected reachability)
	var adj: Dictionary = {}
	for id in nodes:
		adj[id] = []
	for id in nodes:
		for e in nodes[id].get("connections", []):
			var dest := str(e["dest"])
			adj[id].append(dest)
			adj[dest].append(id)
	for id in nodes:
		assert_gt((adj[id] as Array).size(), 0, "node '%s' is not an orphan" % id)
	# BFS from the capital reaches every node
	var seen: Dictionary = {"highkeep": true}
	var queue: Array = ["highkeep"]
	while not queue.is_empty():
		var cur: String = queue.pop_front()
		for nb in adj[cur]:
			if not seen.has(nb):
				seen[nb] = true
				queue.append(nb)
	assert_eq(seen.size(), nodes.size(), "every node is reachable from the Highkeep hub")


func test_capital_highkeep_is_the_web_hub() -> void:
	var nodes := _nodes_by_id(_graph())
	var degree: Dictionary = {}
	for id in nodes:
		degree[id] = (nodes[id].get("connections", []) as Array).size()
	var best := ""
	var best_deg := -1
	for id in degree:
		if degree[id] > best_deg:
			best_deg = degree[id]
			best = id
	assert_eq(best, "highkeep", "the capital carries the most spokes (it is the hub)")
	assert_gte(best_deg, 3, "the hub reaches at least three destinations")


func test_edges_are_bidirectional_with_matching_cost() -> void:
	var nodes := _nodes_by_id(_graph())
	for id in nodes:
		for e in nodes[id].get("connections", []):
			var dest := str(e["dest"])
			var back := -1
			for be in nodes[dest].get("connections", []):
				if str(be["dest"]) == id:
					back = int(be["cost"])
			assert_eq(back, int(e["cost"]), "%s<->%s hop is symmetric in cost" % [id, dest])


# ---- cost / timing monotonicity vs distance --------------------------------------------------


func test_route_cost_and_timing_rise_monotonically_with_distance() -> void:
	var doc := _graph()
	var nodes := _nodes_by_id(doc)
	var edges := _unique_edges(nodes)
	edges.sort_custom(func(x, y): return x["dist"] < y["dist"])
	var flight_speed := float(doc.get("flight_speed", 0.0))
	assert_gt(flight_speed, 0.0, "flight graph declares a positive flight_speed")
	var prev_cost := -1
	var prev_time := -1.0
	for e in edges:
		assert_gte(
			e["cost"],
			prev_cost,
			(
				"cost is non-decreasing with distance (%s<->%s d=%.0f cost=%d)"
				% [e["a"], e["b"], e["dist"], e["cost"]]
			)
		)
		var t: float = e["dist"] / flight_speed
		assert_gt(
			t, prev_time, "flight time strictly rises with distance (%s<->%s)" % [e["a"], e["b"]]
		)
		prev_cost = e["cost"]
		prev_time = t


# ---- flightmaster NPC per hub ----------------------------------------------------------------


func test_every_node_has_a_flightmaster_npc_at_its_coords() -> void:
	var nodes := _nodes_by_id(_graph())
	var npcs: Dictionary = _CR.load_all(ProjectSettings.globalize_path("res://data"))["npcs"]
	for id in nodes:
		var npc_id := str(nodes[id]["npc_id"])
		var npc = npcs.get(npc_id)
		assert_not_null(npc, "node '%s' has flightmaster NPC %s" % [id, npc_id])
		if npc != null:
			assert_eq(npc.service, "flight", "%s is a flight-service NPC" % npc_id)
			var c := _coord(nodes[id])
			assert_almost_eq(npc.x, c.x, 0.01, "%s sits at its roost x" % npc_id)
			assert_almost_eq(npc.y, c.y, 0.01, "%s sits at its roost y" % npc_id)


# ---- travel-time budget audit (walk / mount / flight vs §3 targets) --------------------------


# All-pairs shortest path (Floyd-Warshall) over the undirected graph, weighted by planar node
# distance. Small graph, so O(n^3) is fine.
func _diameter_distance(nodes: Dictionary) -> float:
	var ids: Array = nodes.keys()
	var n := ids.size()
	var idx: Dictionary = {}
	for i in n:
		idx[ids[i]] = i
	var dist: Array = []
	for i in n:
		var row: Array = []
		for j in n:
			row.append(INF if i != j else 0.0)
		dist.append(row)
	for id in nodes:
		for e in nodes[id].get("connections", []):
			var a: int = idx[id]
			var b: int = idx[str(e["dest"])]
			var w := _coord(nodes[id]).distance_to(_coord(nodes[str(e["dest"])]))
			dist[a][b] = minf(dist[a][b], w)
			dist[b][a] = minf(dist[b][a], w)
	for k in n:
		for i in n:
			for j in n:
				if dist[i][k] + dist[k][j] < dist[i][j]:
					dist[i][j] = dist[i][k] + dist[k][j]
	var diameter := 0.0
	for i in n:
		for j in n:
			if dist[i][j] != INF:
				diameter = maxf(diameter, dist[i][j])
	return diameter


func test_travel_time_budget_no_commute_no_trivial_hops() -> void:
	var doc := _graph()
	var nodes := _nodes_by_id(doc)
	var walk := float(_SC.PLAYER_RUN_SPEED)
	var mount := float(_SC.PLAYER_RUN_SPEED_MOUNTED)
	var flight := float(doc["flight_speed"])
	assert_gt(mount, walk, "a mount is faster than a runner")
	assert_gt(flight, mount, "flight is faster than a mount")

	# No single authored hop is an unbroken foot slog, and every hop stays inside the hub-flight
	# ceiling once earned.
	for e in _unique_edges(nodes):
		var foot: float = e["dist"] / walk
		var air: float = e["dist"] / flight
		assert_lte(
			foot, FOOT_LEG_CEIL, "hop %s<->%s is <=4 min on foot (%.0fs)" % [e["a"], e["b"], foot]
		)
		assert_lte(
			air, HUB_FLIGHT_CEIL, "hop %s<->%s flies in <=3 min (%.0fs)" % [e["a"], e["b"], air]
		)

	# The whole P1 envelope: flight crosses it under the continent ceiling (not a commute), while
	# foot/mount crossing it stays a genuine journey (not trivially short).
	var diameter := _diameter_distance(nodes)
	assert_gt(diameter, 0.0, "the flight web spans real ground")
	assert_lte(
		diameter / flight,
		CONTINENT_FLIGHT_CEIL,
		(
			"the continent flies corner-to-corner within the 10-min ceiling (%.0fs)"
			% (diameter / flight)
		)
	)
	assert_gte(
		diameter / walk,
		WORLD_FOOT_FLOOR,
		"crossing the envelope on foot is a real journey, not a commute (%.0fs)" % (diameter / walk)
	)
	assert_gte(
		diameter / mount,
		WORLD_MOUNT_FLOOR,
		"even mounted the envelope takes minutes end-to-end (%.0fs)" % (diameter / mount)
	)
