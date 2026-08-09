extends GutTest
# T-331: the positions-broadcast instance filter (pure) — the one place the "everyone sees
# everyone" rule is narrowed. Proves a peer only receives same-instance players + mobs, the open
# world (instance 0) is unchanged, and ambient NPCs ride only the world frame.

const _BB = preload("res://scripts/broadcast_builder.gd")
const _MD = preload("res://scripts/combat/mob_data.gd")
const _CR = preload("res://scripts/combat/combat_resources.gd")


func _pos(iid: int) -> Dictionary:
	return {"username": "u", "x": 1.0, "y": 2.0, "z": 0.0, "instance_id": iid}


func _mob(eid: int, iid: int):
	var m = _MD.new()
	m.entity_id = eid
	m.instance_id = iid
	m.mob_id = "mob_test"
	m.name = "Test"
	m.mob_level = 7
	m.position = Vector3(3.0, 4.0, 0.0)
	var cr = _CR.new()
	cr.hp = 10
	cr.max_hp = 10
	m.resources = cr
	return m


func test_instances_present_lists_distinct_scopes() -> void:
	var positions := {1: _pos(0), 2: _pos(5), 3: _pos(5)}
	var present: Array = _BB.instances_present(positions)
	present.sort()
	assert_eq(present, [0, 5], "the world and one crypt instance are present")


func test_positions_in_instance_filters_peers() -> void:
	var positions := {1: _pos(0), 2: _pos(5), 3: _pos(5)}
	assert_eq(_BB.positions_in_instance(positions, 0).keys(), [1], "only the world peer")
	var crypt: Array = _BB.positions_in_instance(positions, 5).keys()
	crypt.sort()
	assert_eq(crypt, [2, 3], "only the two crypt peers")


func test_mobs_in_instance_filters_spawns() -> void:
	var mobs := {1001: _mob(1001, 0), 5001: _mob(5001, 5), 5002: _mob(5002, 5)}
	assert_eq(_BB.mobs_in_instance(mobs, 0).keys(), [1001], "the open-world mob only")
	var crypt: Array = _BB.mobs_in_instance(mobs, 5).keys()
	crypt.sort()
	assert_eq(crypt, [5001, 5002], "the two crypt mobs only")


func test_mob_snapshot_carries_server_owned_name_level_and_health() -> void:
	var mob = _mob(1001, 0)
	mob.current_target_id = 42
	var rows: Array = _BB.mobs_array({1001: mob})
	assert_eq(rows.size(), 1)
	assert_eq(rows[0]["mob_id"], 1001)
	assert_eq(rows[0]["name"], "Test")
	assert_eq(rows[0]["level"], 7, "level comes from MobData.mob_level, not any client packet")
	assert_eq(rows[0]["hp"], 10)
	assert_eq(rows[0]["max_hp"], 10)
	assert_true(rows[0]["hostile"], "an ordinary proximity-aggro mob broadcasts hostile")
	assert_eq(rows[0]["target_id"], 42, "authoritative AI target rides the mob row")


func test_passive_mob_snapshot_broadcasts_neutral_relationship() -> void:
	var mob = _mob(1001, 0)
	mob.retaliate_only = true
	var rows: Array = _BB.mobs_array({1001: mob})
	assert_false(rows[0]["hostile"], "a retaliate-only mob broadcasts neutral/passive")


func test_positions_frames_isolate_two_parties() -> void:
	# Peer 1 in the open world; peers 2 & 3 together in crypt instance 5.
	var positions := {1: _pos(0), 2: _pos(5), 3: _pos(5)}
	var mobs := {1001: _mob(1001, 0), 5001: _mob(5001, 5)}
	var npcs := [{"npc_id": "townsfolk", "x": 0.0, "y": 0.0}]
	var frames: Array = _BB.positions_frames(positions, {}, {}, {}, {}, {}, mobs, npcs)
	assert_eq(frames.size(), 2, "one frame per instance")

	var world_frame := {}
	var crypt_frame := {}
	for f in frames:
		if f["peers"].has(1):
			world_frame = f
		else:
			crypt_frame = f

	# World frame: just peer 1, the world mob, and the ambient NPCs.
	assert_eq(world_frame["peers"], [1])
	assert_eq((world_frame["payload"]["players"] as Array).size(), 1, "world peer sees only itself")
	assert_eq((world_frame["payload"]["mobs"] as Array).size(), 1, "and only the world mob")
	assert_eq((world_frame["payload"]["mobs"] as Array)[0]["kind"], "mob_test", "the world mob")
	assert_eq(
		(world_frame["payload"]["npcs"] as Array).size(), 1, "ambient NPCs ride the world frame"
	)

	# Crypt frame: peers 2 & 3, the crypt mob, and NO ambient NPCs.
	var cp: Array = crypt_frame["peers"]
	cp.sort()
	assert_eq(cp, [2, 3], "the crypt frame carries both party members")
	assert_eq(
		(crypt_frame["payload"]["players"] as Array).size(), 2, "each sees the other, not peer 1"
	)
	assert_eq((crypt_frame["payload"]["mobs"] as Array).size(), 1, "and only the crypt mob")
	assert_eq((crypt_frame["payload"]["npcs"] as Array).size(), 0, "no townsfolk in the crypt")


func test_world_only_snapshot_is_unchanged_by_the_filter() -> void:
	# No instances in play — every peer is in the open world, so the frame is the classic broadcast.
	var positions := {1: _pos(0), 2: _pos(0)}
	var mobs := {1001: _mob(1001, 0)}
	var frames: Array = _BB.positions_frames(positions, {}, {}, {}, {}, {}, mobs, [])
	assert_eq(frames.size(), 1, "a single world frame")
	var peers: Array = frames[0]["peers"]
	peers.sort()
	assert_eq(peers, [1, 2], "both players in one frame")
	assert_eq((frames[0]["payload"]["mobs"] as Array).size(), 1, "the world mob is visible to all")
