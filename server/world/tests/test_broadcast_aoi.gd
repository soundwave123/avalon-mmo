extends GutTest
# T-370: the AOI (area-of-interest) positions broadcast filter (pure). Proves the per-peer distance
# interest that bounds broadcast bytes by LOCAL density instead of global CCU (T-355 spike), while
# keeping every isolation invariant the all-peers/instance broadcast held:
#   - instance bucketing stays the HARD seam (different instances never share a frame, any dist);
#   - era regions at distant offsets (crypt +420, Ashmoor -420) never leak across ~840 m;
#   - a peer always receives itself; in-range peers see each other, out-of-range don't;
#   - a crowd is bounded by the nearest-N cap;
#   - mobs/NPCs stay instance-scoped (unchanged by the distance filter).
# Netcode hides from unit tests — the live spawn/despawn/re-entry proof is scripts/test-aoi-e2e.sh.

const _BB = preload("res://scripts/broadcast_builder.gd")
const _MD = preload("res://scripts/combat/mob_data.gd")
const _CR = preload("res://scripts/combat/combat_resources.gd")

const R := 80.0  # default interest radius (T-355 measured lever value)
const CAP := 50  # default nearest-N cap


func _at(x: float, z: float, iid: int = 0) -> Dictionary:
	return {"username": "u", "x": x, "y": 0.0, "z": z, "instance_id": iid}


func _mob(eid: int, iid: int):
	var m = _MD.new()
	m.entity_id = eid
	m.instance_id = iid
	m.mob_id = "mob_test"
	m.name = "Test"
	m.position = Vector3(3.0, 0.0, 4.0)
	var cr = _CR.new()
	cr.hp = 10
	cr.max_hp = 10
	m.resources = cr
	return m


# --- peers_in_range: the pure interest primitive -----------------------------------------------


func test_self_always_included_even_when_alone() -> void:
	var pos := {1: _at(0, 0)}
	var got: Array = _BB.peers_in_range(pos, 1, R, CAP).keys()
	assert_eq(got, [1], "a lone peer still receives itself")


func test_in_range_peers_see_each_other_out_of_range_do_not() -> void:
	# 1 & 2 are 50 m apart (< R); 3 is 300 m away (> R) from both.
	var pos := {1: _at(0, 0), 2: _at(50, 0), 3: _at(300, 0)}
	var near1: Array = _BB.peers_in_range(pos, 1, R, CAP).keys()
	near1.sort()
	assert_eq(near1, [1, 2], "peer 1 sees itself and the in-range peer 2, not the distant 3")
	var near3: Array = _BB.peers_in_range(pos, 3, R, CAP).keys()
	assert_eq(near3, [3], "the distant peer 3 sees only itself")


func test_distance_is_planar_xz_height_never_gates_interest() -> void:
	# Same XZ, wildly different y (height) — must still be in interest.
	var pos := {
		1: _at(0, 0), 2: {"username": "u", "x": 0.0, "y": 500.0, "z": 0.0, "instance_id": 0}
	}
	var near1: Array = _BB.peers_in_range(pos, 1, R, CAP).keys()
	near1.sort()
	assert_eq(near1, [1, 2], "y is height, not an interest axis — the peer is still visible")


func test_radius_boundary_inclusive() -> void:
	var pos := {1: _at(0, 0), 2: _at(R, 0)}  # exactly R away
	var near1: Array = _BB.peers_in_range(pos, 1, R, CAP).keys()
	near1.sort()
	assert_eq(near1, [1, 2], "a peer exactly at the radius is inside interest")


func test_radius_zero_disables_distance_filter() -> void:
	var pos := {1: _at(0, 0), 2: _at(999, 0)}
	var near1: Array = _BB.peers_in_range(pos, 1, 0.0, CAP).keys()
	near1.sort()
	assert_eq(near1, [1, 2], "radius 0 keeps all same-scope peers (pre-T-370 behaviour)")


func test_nearest_n_cap_keeps_the_closest_and_always_self() -> void:
	# Self at origin; peers at 1,2,3,4 m; cap = 3 → self + two nearest (1 m, 2 m), NOT the far ones.
	var pos := {1: _at(0, 0), 2: _at(1, 0), 3: _at(2, 0), 4: _at(3, 0), 5: _at(4, 0)}
	var near1: Array = _BB.peers_in_range(pos, 1, R, 3).keys()
	near1.sort()
	assert_eq(near1, [1, 2, 3], "cap 3 keeps self + the two nearest peers, drops the farther two")


func test_crowd_is_bounded_by_the_cap() -> void:
	# 200 peers all inside a 10 m huddle (everyone in everyone's radius) → each frame is capped.
	var pos := {}
	for i in 200:
		pos[1000 + i] = _at(float(i) * 0.05, 0.0)  # 0..10 m spread, all within R of the first
	var got: Dictionary = _BB.peers_in_range(pos, 1000, R, CAP)
	assert_eq(got.size(), CAP, "a 200-peer huddle is bounded to the nearest-N cap")
	assert_true(got.has(1000), "the peer itself is always in its own frame")


# --- positions_frames_aoi: the full per-peer broadcast ------------------------------------------


func test_frames_are_one_per_peer() -> void:
	var pos := {1: _at(0, 0), 2: _at(10, 0)}
	var frames: Array = _BB.positions_frames_aoi(pos, {}, {}, {}, {}, {}, {}, [], R, CAP)
	assert_eq(frames.size(), 2, "one frame per peer (per-peer AOI payloads)")
	for f in frames:
		assert_eq((f["peers"] as Array).size(), 1, "each AOI frame targets exactly one peer")


func test_instance_isolation_holds_regardless_of_distance() -> void:
	# Two peers at the SAME spot but different instances must never share interest — instance is the
	# hard seam, checked before any distance math.
	var pos := {1: _at(0, 0, 0), 2: _at(0, 0, 5)}
	var frames: Array = _BB.positions_frames_aoi(pos, {}, {}, {}, {}, {}, {}, [], R, CAP)
	for f in frames:
		var players: Array = f["payload"]["players"]
		assert_eq(players.size(), 1, "co-located cross-instance peers never see each other")
		assert_eq(int(players[0]["peer_id"]), int(f["peers"][0]), "each sees only itself")


func test_era_regions_at_distant_offsets_never_leak() -> void:
	# Same open-world instance (0), but crypt-era offset +420 vs Ashmoor -420 → ~840 m apart, far
	# beyond any sane radius. The ticket's regions-must-not-cross invariant, via distance.
	var pos := {1: _at(420, 0, 0), 2: _at(-420, 0, 0)}
	var frames: Array = _BB.positions_frames_aoi(pos, {}, {}, {}, {}, {}, {}, [], R, CAP)
	for f in frames:
		assert_eq(
			(f["payload"]["players"] as Array).size(),
			1,
			"peers in regions 840 m apart never enter each other's interest"
		)


func test_mobs_and_npcs_stay_instance_scoped_and_full() -> void:
	# Two peers far apart in the open world; mobs/npcs are NOT distance-filtered (fixed set, not the
	# O(N) driver) — each peer still gets every open-world mob + the ambient NPCs. Both sit inside the
	# era-1 footprint (|x| < 210) so they share the same region (T-371) — only the AOI radius, not the
	# region domain, separates them.
	var pos := {1: _at(0, 0), 2: _at(150, 0)}
	var mobs := {1001: _mob(1001, 0), 5001: _mob(5001, 5)}  # one world mob, one crypt mob
	var npcs := [{"npc_id": "townsfolk", "x": 0.0, "y": 0.0}]
	var frames: Array = _BB.positions_frames_aoi(pos, {}, {}, {}, {}, {}, mobs, npcs, R, CAP)
	assert_eq(frames.size(), 2, "one frame per open-world peer")
	for f in frames:
		assert_eq((f["payload"]["mobs"] as Array).size(), 1, "each peer sees the one world mob")
		assert_eq((f["payload"]["mobs"] as Array)[0]["mob_id"], 1001, "the crypt mob never leaks")
		assert_eq((f["payload"]["npcs"] as Array).size(), 1, "ambient NPCs ride every world frame")


func test_crypt_peers_still_see_their_party_and_no_npcs() -> void:
	# Regression against T-331: two crypt peers standing together still see each other and their crypt
	# mob, and no ambient townsfolk — AOI does not disturb the instance broadcast for a real group.
	var pos := {1: _at(0, 0, 0), 2: _at(2, 0, 5), 3: _at(3, 0, 5)}  # peer 1 world; 2 & 3 crypt inst 5
	var mobs := {1001: _mob(1001, 0), 5001: _mob(5001, 5)}
	var npcs := [{"npc_id": "townsfolk", "x": 0.0, "y": 0.0}]
	var frames: Array = _BB.positions_frames_aoi(pos, {}, {}, {}, {}, {}, mobs, npcs, R, CAP)
	var crypt_frames: Array = frames.filter(func(f): return f["peers"][0] in [2, 3])
	assert_eq(crypt_frames.size(), 2, "one frame each for the two crypt peers")
	for f in crypt_frames:
		var pids: Array = (f["payload"]["players"] as Array).map(func(p): return int(p["peer_id"]))
		pids.sort()
		assert_eq(
			pids, [2, 3], "each crypt peer sees itself and its nearby party member, not peer 1"
		)
		assert_eq((f["payload"]["mobs"] as Array).size(), 1, "only the crypt mob")
		assert_eq((f["payload"]["mobs"] as Array)[0]["mob_id"], 5001, "the crypt mob")
		assert_eq((f["payload"]["npcs"] as Array).size(), 0, "no townsfolk in the crypt frame")


# --- T-371: per-region broadcast domains (lever 2, on top of the T-370 AOI filter) --------------


func test_region_of_maps_positions_to_the_nearest_era_anchor() -> void:
	assert_eq(_BB.region_of(0.0, 0.0), 0, "the origin is era-1 (region 0)")
	assert_eq(_BB.region_of(200.0, -400.0), 0, "the far village corner is still era-1")
	assert_eq(_BB.region_of(420.0, 0.0), 1, "the crypt offset is region 1")
	assert_eq(_BB.region_of(-420.0, 0.0), 2, "the Ashmoor offset is region 2")
	# Boundary: nearest-anchor splits era-1/crypt at x=210 — 209 stays era-1, 211 is the crypt domain.
	assert_eq(_BB.region_of(209.0, 0.0), 0, "just inside the boundary is era-1")
	assert_eq(_BB.region_of(211.0, 0.0), 1, "just past the boundary is the crypt domain")


func test_region_domains_isolate_even_with_the_distance_filter_off() -> void:
	# THE lever-2 discriminator vs T-370: with radius <= 0 the AOI distance filter is disabled, so a
	# pure T-370 broadcast would let a village peer and an Ashmoor peer (same instance 0) see each
	# other. T-371 buckets them into different era domains BEFORE any radius math, so they never do.
	var pos := {1: _at(0, 0, 0), 2: _at(-420, 0, 0)}  # era-1 vs Ashmoor, same open-world instance
	var frames: Array = _BB.positions_frames_aoi(pos, {}, {}, {}, {}, {}, {}, [], 0.0, CAP)
	assert_eq(frames.size(), 2, "one frame per peer")
	for f in frames:
		var players: Array = f["payload"]["players"]
		assert_eq(
			players.size(), 1, "cross-region peers never share a frame even with AOI radius off"
		)
		assert_eq(int(players[0]["peer_id"]), int(f["peers"][0]), "each peer sees only itself")


func test_open_world_mobs_are_region_scoped_by_position() -> void:
	# A village wolf and an Ashmoor mob BOTH live in instance 0 — only their era region separates
	# them. The village peer must get the village mob, the Ashmoor peer the Ashmoor mob, never both.
	var village_mob = _mob(1001, 0)
	village_mob.position = Vector3(5.0, 0.0, -3.0)  # era-1
	var ashmoor_mob = _mob(1002, 0)
	ashmoor_mob.position = Vector3(-420.0, -5.0, 2.0)  # Ashmoor offset
	var mobs := {1001: village_mob, 1002: ashmoor_mob}
	var pos := {1: _at(0, 0, 0), 2: _at(-420, 0, 0)}
	var frames: Array = _BB.positions_frames_aoi(pos, {}, {}, {}, {}, {}, mobs, [], R, CAP)
	for f in frames:
		var pid: int = int(f["peers"][0])
		var mob_ids: Array = (f["payload"]["mobs"] as Array).map(func(m): return int(m["mob_id"]))
		if pid == 1:
			assert_eq(mob_ids, [1001], "the village peer gets only the village mob")
		else:
			assert_eq(mob_ids, [1002], "the Ashmoor peer gets only the Ashmoor mob")


func test_townsfolk_never_ride_a_foreign_region_frame() -> void:
	# Ambient NPCs sit in the village (era-1). An Ashmoor peer in the same open-world instance must
	# not receive them — region scoping applies to NPCs too, not just players/mobs.
	var pos := {1: _at(0, 0, 0), 2: _at(-420, 0, 0)}
	var npcs := [{"npc_id": "townsfolk", "x": 4.0, "y": 0.0, "z": -2.0}]  # era-1 villager
	var frames: Array = _BB.positions_frames_aoi(pos, {}, {}, {}, {}, {}, {}, npcs, R, CAP)
	for f in frames:
		var pid: int = int(f["peers"][0])
		var got: int = (f["payload"]["npcs"] as Array).size()
		if pid == 1:
			assert_eq(got, 1, "the village peer still gets the ambient townsfolk")
		else:
			assert_eq(got, 0, "the Ashmoor peer gets no village townsfolk")
