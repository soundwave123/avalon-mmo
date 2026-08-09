extends GutTest

# Report #15: npc_obstacles.json (solid-prop footprints generated from props.json + GLB wall
# bands) must stay consistent with the authored ambient routes in npcs.json — a route leg that
# crosses a wall or a post inside a footprint means an NPC statue or a clip-through regression.
# This suite is the authoring gate: it uses the SAME oracle code the live director runs.

const _MCOL = preload("res://scripts/movement_collision.gd")

var _oracle
var _npcs: Array


func before_all() -> void:
	_oracle = _MCOL.new("res://data/regions/npc_obstacles.json")
	var f := FileAccess.open("res://data/npcs/npcs.json", FileAccess.READ)
	_npcs = JSON.parse_string(f.get_as_text())["npcs"]


func test_obstacle_data_loads_with_real_footprints() -> void:
	# Walled BUILDINGS only (tools/npc/gen_npc_obstacles.py allowlist), four wall segments
	# each — small steppable props / natural features must NOT be walls (Report #15: they
	# trapped Hale and Geld in wall pockets on ground NPCs are authored to pace).
	assert_gt(_oracle.wall_count(), 50, "building footprint walls present")
	assert_lt(_oracle.wall_count(), 100, "obstacle set stays buildings-only, not street props")


func test_known_buildings_actually_block() -> void:
	assert_true(_oracle.segment_blocked(4.0, -3.0, 13.0, -3.0), "through the tavern is blocked")
	assert_true(_oracle.segment_blocked(3.0, 12.6, 10.0, 12.6), "through the cottage is blocked")
	assert_true(_oracle.segment_blocked(-12.0, 13.0, -5.0, 13.0), "through house A is blocked")
	assert_false(_oracle.segment_blocked(0.0, 1.5, 3.0, 1.5), "the open plaza lane stays open")


func test_every_wander_post_is_outside_all_footprints() -> void:
	for npc in _npcs:
		var w: Variant = npc.get("wander", null)
		if not (w is Dictionary):
			continue
		var post := [float(npc["x"]), float(npc["y"])]
		if (w as Dictionary).get("anchor", null) is Array:
			var a: Array = w["anchor"]
			post = [float(a[0]), float(a[1])]
		assert_false(
			_oracle.point_inside(post[0], post[1]),
			"%s posts outside geometry (%.1f, %.1f)" % [npc["id"], post[0], post[1]]
		)


func test_no_mob_spawn_sits_inside_a_building_footprint() -> void:
	# T-663: a building footprint that CONTAINS a mob spawn is a world-authoring overlap — the
	# camera SpringArm wall-avoids off the building it thinks the target is inside (T-656 live
	# trace: prop_cottage_v2 fully contained the training dummy at (10,10)). Buildings and mob
	# spawns must not co-occupy space; this uses the SAME oracle the ambient director runs.
	var f := FileAccess.open("res://data/mobs/spawns.json", FileAccess.READ)
	assert_not_null(f, "spawns.json present")
	var spawns: Array = JSON.parse_string(f.get_as_text())["spawns"]
	for entry in spawns:
		var mob_file := str((entry as Dictionary).get("mob_file", ""))
		for pos in (entry as Dictionary).get("positions", []):
			var px := float(pos[0])
			var pz := float(pos[1])
			assert_false(
				_oracle.point_inside(px, pz),
				"%s spawn (%.1f, %.1f) outside all building footprints" % [mob_file, px, pz]
			)


func test_every_waypoint_route_is_fully_walkable() -> void:
	# Consecutive legs (including the loop-closing leg) must not cross a wall, and no waypoint
	# may sit inside a footprint — else the wanderer turns around forever instead of patrolling.
	for npc in _npcs:
		var w: Variant = npc.get("wander", null)
		if not (w is Dictionary) or str((w as Dictionary).get("mode", "")) != "waypoints":
			continue
		var wps: Array = w.get("waypoints", [])
		for i in range(wps.size()):
			var a: Array = wps[i]
			var b: Array = wps[(i + 1) % wps.size()]
			assert_false(
				_oracle.point_inside(float(a[0]), float(a[1])),
				"%s waypoint %d clear of geometry" % [npc["id"], i]
			)
			assert_false(
				_oracle.segment_blocked(float(a[0]), float(a[1]), float(b[0]), float(b[1])),
				"%s leg %d->%d walkable" % [npc["id"], i, (i + 1) % wps.size()]
			)
