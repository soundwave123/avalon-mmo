extends GutTest

# T-762: the four T-698 optimisations T-699 orphaned — CALL-SITE tests.
#
# T-698 wired four helpers into server/world/scripts/main.gd. T-699 (broadcast scaling) was authored
# off a pre-T-698 copy of main.gd and, when it landed, clobbered the whole file — reverting all four
# call sites while leaving the helpers themselves (and their unit tests) fully intact and passing.
# For 17 days every one of them was dead code that no test could notice, because every existing test
# called the helper DIRECTLY. T-749 restored the tick cap; these are the remaining four.
#
# So these tests never assert that a helper WORKS (test_sleeping_zones / test_t698_hot_paths /
# test_t698_region_gates already do, and they kept passing throughout the outage). They assert that
# main.gd actually CALLS it — each one fails if its wiring line is deleted again:
#
#   1. _SZ.is_mob_awake_cached / _mob_regions  -> the mob gate does no per-mob region scan
#   2. world_rpc.set_regions + tick_npcs(awake) -> the awake set reaches the NPC/gather-node gate
#   3. world_rpc._forget_peer                   -> disconnect drops the reach-throttle checkpoint
#   4. the per-instance player filter memo      -> filtered once per INSTANCE, not once per mob
#
# Every rewire is a pure perf change, so each test also pins PARITY: the same mobs tick, the same
# players are visible to them, and the NPC stream is unchanged wherever a region is awake.

const _SZ = preload("res://scripts/sleeping_zones.gd")
const _WR = preload("res://scripts/world_regions.gd")
const _ML = preload("res://scripts/combat/mob_loader.gd")
const _MD = preload("res://scripts/combat/mob_data.gd")
const _BB = preload("res://scripts/broadcast_builder.gd")
const _TT = preload("res://scripts/combat/threat_table.gd")
const _MAI = preload("res://scripts/combat/mob_ai.gd")
const _PLC = preload("res://scripts/peer_lifecycle.gd")
const _WRPC = preload("res://scripts/world_rpc.gd")
const PlayerSessions = preload("res://scripts/player_sessions.gd")
const ServerConfig = preload("res://scripts/server_config.gd")

const MOBS_DIR := "res://data/mobs"
const PEER := 77
const TOKEN := "dddddddddddddddddddddddddddddd77"  # gitleaks:allow — 32-char hex
const WOLD := Vector3(0.0, 0.0, 0.0)  # the Wold origin (region 0)
const ASHMOOR := Vector3(-440.0, 20.0, 0.0)  # deep in the Ashmoor March


# Counts every region_index probe so a per-mob-per-tick scan is visible as a NUMBER. Delegates to
# the real table, so the gate's DECISIONS are identical either way — only the cost differs.
class _CountingRegions:
	extends RefCounted

	var probes: int = 0
	var _real

	func _init(real) -> void:
		_real = real

	func region_count() -> int:
		return _real.region_count()

	func origin_of(i: int) -> Vector2:
		return _real.origin_of(i)

	func region_index(x: float, y: float) -> int:
		probes += 1
		return _real.region_index(x, y)


# Records what main hands the NPC seam, and stands in for world_rpc where a real one is overkill.
class _RecordingRpc:
	extends RefCounted

	var regions_set = null
	var set_regions_calls: int = 0
	var forgotten: Array = []
	var awake_seen: Array = []  # one entry per tick_npcs call (null included — that is the bug)

	func set_regions(regions) -> void:
		regions_set = regions
		set_regions_calls += 1

	func _forget_peer(peer_id: int) -> void:
		forgotten.append(peer_id)

	func tick_npcs(_now: int, _hz: int, _rng, awake = null) -> Array:
		awake_seen.append(awake)
		return []


# The world main with the clock scripted and the wire stubbed (the T-749 _TickHarness idiom).
class _Harness:
	extends "res://scripts/main.gd"

	var scripted_tick: int = 100
	var sent: Array = []
	var filter_calls: int = 0  # how many times the tick reached the per-instance player filter

	func _now_tick() -> int:
		return scripted_tick

	func _send_to_peer(peer_id: int, data: Dictionary) -> void:
		sent.append({"peer": peer_id, "data": data})

	func _players_in_instance(players: Dictionary, instance_id: int) -> Dictionary:
		filter_calls += 1
		return super(players, instance_id)


# The two teardown collaborators that need a full setup() before they will accept a peer. They are
# not what this ticket wired, and release_local_state calls them before it reaches world_rpc — so
# they stand in as no-ops and the assertion stays on the line T-699 deleted.
class _NoopPeerSink:
	extends RefCounted

	func on_peer_gone(_peer_id: int) -> void:
		pass

	func peer_gone(_peer_id: int) -> void:
		pass


func before_each() -> void:
	PlayerSessions._reset_for_test()


func after_each() -> void:
	PlayerSessions._reset_for_test()


func _harness() -> _Harness:
	var m := _Harness.new()
	autofree(m)
	autofree(m._world_clock)  # T-734 Node the stubbed wiring never reparents — no orphan
	m._rng = RandomNumberGenerator.new()
	m._rng.seed = 4242
	m._threat_table = _TT.new()
	return m


# A harness whose two full-setup() teardown collaborators are no-ops (see _NoopPeerSink) — every
# OTHER member release_local_state touches is usable straight from main.gd's declarations.
func _teardown_harness() -> _Harness:
	var m := _harness()
	m._instance_svc = _NoopPeerSink.new()
	m._mentor_svc = _NoopPeerSink.new()
	return m


# One live player standing at `pos`, visible to both PlayerSessions and the mob-AI snapshot.
func _add_player(m, pos: Vector3) -> void:
	PlayerSessions.add_player(PEER, TOKEN, "pilot", pos)
	m._connected_players[PEER] = {"username": "pilot"}
	m._combat_states[PEER] = CombatState.new()


# ---- 1. the mob gate reads the cached map, never a per-mob region scan ----------------------


func test_mob_gate_does_not_rescan_a_region_per_mob_per_tick() -> void:
	# The shipped spawn table (43 mobs) against the shipped region table. The awake-set build costs
	# one probe per PLAYER; the gate itself must cost ZERO, because every mob's region was mapped
	# once at boot. Restore the uncached _SZ.is_mob_awake here and this count becomes 1 + 43.
	var m := _harness()
	m._mobs = _ML.load_spawn_table(MOBS_DIR)
	assert_gt(
		m._mobs.size(), 10, "the shipped spawn table is big enough for this to mean something"
	)
	var counting := _CountingRegions.new(_WR.load_default())
	m._world_regions = counting
	m._world_rpc = _RecordingRpc.new()
	_add_player(m, WOLD)

	m._wire_regions()  # boot-time precompute (probes the table once per mob, off the hot path)
	counting.probes = 0
	m._run_mob_ai_tick(100)

	assert_eq(
		counting.probes,
		1,
		(
			"one probe for the single player's awake region and NOT ONE MORE — the per-mob gate must "
			+ "read the precomputed _mob_regions map (T-698 fix 3, reverted by T-699)"
		)
	)


func test_the_cached_gate_wakes_exactly_the_mobs_the_uncached_scan_would() -> void:
	# PARITY, mob for mob: the rewire may only make the same decision more cheaply. Checked from
	# both a Wold player and an Ashmoor player, so both the awake and the asleep branch are proved.
	var wr = _WR.load_default()
	var mobs: Dictionary = _ML.load_spawn_table(MOBS_DIR)
	var cache: Dictionary = _SZ.mob_regions(mobs, wr)
	for stand in [WOLD, ASHMOOR]:
		var awake: Dictionary = _SZ.awake_regions([Vector2(stand.x, stand.y)], wr, 0.0)
		var cached_ids: Array = []
		var scanned_ids: Array = []
		for eid in mobs:
			if _SZ.is_mob_awake_cached(mobs[eid], awake, cache):
				cached_ids.append(eid)
			if _SZ.is_mob_awake(mobs[eid], awake, wr):
				scanned_ids.append(eid)
		assert_gt(
			scanned_ids.size(), 0, "a player at %s wakes something (else this is inert)" % stand
		)
		assert_lt(
			scanned_ids.size(), mobs.size(), "...and leaves some zone asleep (the whole point)"
		)
		assert_eq(
			cached_ids, scanned_ids, "cached gate wakes exactly the same mob set at %s" % stand
		)


func test_boot_wiring_builds_both_static_region_maps() -> void:
	# _wire_regions is the ONE seam that injects the region table into every sleeping-zone consumer.
	# Deleting either line here strands one of the two gates in always-tick — silently, and fast.
	var m := _harness()
	m._mobs = _ML.load_spawn_table(MOBS_DIR)
	var rpc := _RecordingRpc.new()
	m._world_rpc = rpc

	m._wire_regions()

	assert_eq(m._mob_regions.size(), m._mobs.size(), "every open-world mob mapped to its region")
	assert_eq(rpc.set_regions_calls, 1, "boot must inject the region table into world_rpc ONCE")
	assert_eq(rpc.regions_set, m._world_regions, "...and it must be the live table main owns")


# ---- 2. the awake set reaches the NPC + gather-node gate ------------------------------------


func test_broadcast_forwards_the_live_awake_set_to_the_npc_tick() -> void:
	# T-699 dropped the 4th argument, so tick_npcs took `awake = null` forever: npc_director._is_awake
	# and craft_service._node_awake both read null as "always tick" and the gate never once fired.
	var m := _harness()
	m._mobs = _ML.load_spawn_table(MOBS_DIR)
	var rpc := _RecordingRpc.new()
	m._world_rpc = rpc
	_add_player(m, WOLD)
	m._wire_regions()

	m._run_mob_ai_tick(100)  # publishes _awake_regions
	m._broadcast_positions()  # consumes it

	assert_eq(rpc.awake_seen.size(), 1, "the broadcast ticked the NPCs exactly once")
	var forwarded = rpc.awake_seen[0]
	assert_not_null(forwarded, "tick_npcs must receive the awake set, not null (the T-699 revert)")
	assert_eq(forwarded, m._awake_regions, "and it must be THIS tick's set, not a stale one")
	assert_true(
		(forwarded as Dictionary).has(m._world_regions.region_index(WOLD.x, WOLD.y)),
		"the player's own region is awake in the set the NPC gate receives"
	)


func test_a_sleeping_region_freezes_its_npcs_through_the_real_broadcast_path() -> void:
	# End-to-end through a REAL world_rpc (real content, real npc_director): with the only player in
	# Ashmoor, the Wold's NPCs must hold station, and with the player in the Wold they must move.
	# This is the test that fails if ANY link in the chain breaks — set_regions, the _awake_regions
	# publication, or the tick_npcs argument.
	var m := _harness()
	m._mobs = _ML.load_spawn_table(MOBS_DIR)
	var rpc = _WRPC.new()
	assert_eq(rpc.setup(null, func(_p, _d): pass, "res://data"), "", "content + wander setup clean")
	m._world_rpc = rpc
	m._wire_regions()

	var geld = rpc._content_npcs["npc_farmer_geld"]  # a Wold wanderer
	assert_true(rpc._npc_director.is_tracked("npc_farmer_geld"), "Geld actually wanders")

	# (a) the only player is in Ashmoor -> the Wold sleeps -> Geld does not move.
	_add_player(m, ASHMOOR)
	var frozen := Vector2(geld.x, geld.y)
	for t in range(60):
		m.scripted_tick = 100 + t  # the broadcast reads the clock; npc_director is per-tick idempotent
		m._run_mob_ai_tick(m.scripted_tick)
		m._broadcast_positions()
	assert_almost_eq(geld.x, frozen.x, 0.0001, "a Wold NPC does not tick while the Wold sleeps")
	assert_almost_eq(geld.y, frozen.y, 0.0001, "...on y either")

	# (b) the player walks into the Wold -> it wakes -> Geld resumes wandering, still leashed.
	PlayerSessions.update_position(PEER, WOLD)
	for t in range(60, 400):
		m.scripted_tick = 100 + t
		m._run_mob_ai_tick(m.scripted_tick)
		m._broadcast_positions()
	var post: Vector3 = rpc._npc_director.post_of("npc_farmer_geld")
	assert_gt(
		Vector2(geld.x, geld.y).distance_to(frozen), 0.05, "a woken NPC resumes ambient movement"
	)
	assert_lt(
		Vector3(geld.x, geld.y, 0.0).distance_to(post),
		10.0,
		"and stays leashed to its post — the sleep window deferred its ticks, it never lost them"
	)


func test_no_gated_entity_is_ever_inside_a_players_broadcast_radius() -> void:
	# THE parity proof for the whole rewire: the sleeping gate may only skip work no client can see.
	# AOI is 80 m and region origins sit >=420 m apart — but membership is NEAREST-ORIGIN, so two
	# regions meet at a boundary where a sleeping mob could in principle stand next to a player. That
	# makes this a property of the SHIPPED LAYOUT, not of arithmetic, so assert it against the data:
	# stand a player on every mob spawn in the world and check that everything the gate puts to sleep
	# is farther away than the AOI radius. Spawning content near a region boundary then fails loudly
	# instead of silently changing what a player sees.
	var wr = _WR.load_default()
	var mobs: Dictionary = _ML.load_spawn_table(MOBS_DIR)
	var cache: Dictionary = _SZ.mob_regions(mobs, wr)
	var rpc = _WRPC.new()
	assert_eq(rpc.setup(null, func(_p, _d): pass, "res://data"), "", "content setup clean")
	var aoi: float = ServerConfig.get_aoi_radius()
	assert_gt(aoi, 0.0, "AOI is on, else there is nothing to prove")

	# Every tracked (ticking) NPC's post and its static region — the same map set_regions builds.
	var npc_posts: Dictionary = {}
	for npc_id in rpc._content_npcs:
		if rpc._npc_director.is_tracked(npc_id):
			npc_posts[npc_id] = rpc._npc_director.post_of(npc_id)

	var gated_seen := 0  # how many sleep decisions this sweep actually exercised
	for eid in mobs:
		var stand: Vector3 = mobs[eid].position
		var here := Vector2(stand.x, stand.y)
		var awake: Dictionary = _SZ.awake_regions([here], wr, 0.0)
		for other in mobs:  # every mob the gate skips must be out of this player's sight
			if _SZ.is_mob_awake_cached(mobs[other], awake, cache):
				continue
			gated_seen += 1
			var mp: Vector3 = mobs[other].position
			assert_gt(
				Vector2(mp.x, mp.y).distance_to(here),
				aoi,
				"asleep mob %s is inside the AOI of a player standing at mob %s" % [other, eid]
			)
		for npc_id in npc_posts:  # ...and so must every NPC the gate stops ticking
			var post: Vector3 = npc_posts[npc_id]
			if awake.has(wr.region_index(post.x, post.y)):
				continue
			gated_seen += 1
			assert_gt(
				Vector2(post.x, post.y).distance_to(here),
				aoi,
				"asleep NPC %s is inside the AOI of a player standing at mob %s" % [npc_id, eid]
			)
	assert_gt(gated_seen, 0, "the sweep actually exercised the gate (else this proves nothing)")


# ---- 3. disconnect drops the reach-throttle checkpoint --------------------------------------


func test_disconnect_teardown_forgets_the_peer_in_world_rpc() -> void:
	# peer_lifecycle.release_local_state forgets the peer in six other services; T-699 removed the
	# world_rpc one, so reach_service._checkpoint kept an entry per peer_id for the process lifetime.
	var m := _teardown_harness()
	var rpc := _RecordingRpc.new()
	m._world_rpc = rpc
	_add_player(m, WOLD)

	_PLC.release_local_state(m, PEER)

	assert_eq(rpc.forgotten, [PEER], "the disconnect path must forget the peer in world_rpc")


func test_the_forgotten_peer_actually_loses_its_reach_checkpoint() -> void:
	# ...and the wrapper must reach the real store, not just be called. Proves the leak is closed.
	var m := _teardown_harness()
	var rpc = _WRPC.new()
	assert_eq(rpc.setup(null, func(_p, _d): pass, "res://data"), "", "content setup clean")
	m._world_rpc = rpc
	_add_player(m, WOLD)
	rpc._reach._checkpoint[PEER] = {"msec": 1000, "pos": WOLD}

	_PLC.release_local_state(m, PEER)

	assert_false(
		rpc._reach._checkpoint.has(PEER),
		"the per-peer reach-throttle checkpoint must die with the session (T-698 fix 1)"
	)


# ---- 4. the per-instance player filter is memoised per instance, not per mob ----------------


func test_player_filter_is_built_once_per_instance_not_once_per_mob() -> void:
	# broadcast_builder.positions_in_instance walks EVERY player to build one filtered dict. T-698
	# hoisted it out of the per-mob loop (mobs share an instance en masse); T-699 put it back, so a
	# 43-mob world rebuilt the identical dict 43 times a tick. The memo is per TICK, keyed by
	# instance_id — so after one tick it holds exactly one entry per distinct instance present.
	var m := _harness()
	m._world_rpc = _RecordingRpc.new()
	m._mobs = {
		1: _mob_at(1, WOLD, 0),
		2: _mob_at(2, WOLD, 0),
		3: _mob_at(3, WOLD, 0),
		4: _mob_at(4, WOLD, 7),  # a crypt party's instance
		5: _mob_at(5, WOLD, 7),
	}
	_add_player(m, WOLD)
	m._wire_regions()

	m._run_mob_ai_tick(100)

	assert_eq(
		m.filter_calls, 2, "5 mobs across 2 instances must BUILD 2 filtered player views, not 5"
	)
	assert_eq(m._scoped_cache.size(), 2, "...and the memo holds exactly one view per instance")
	# PARITY: each memoised view is exactly what the per-mob call produced before.
	var players: Dictionary = _SZ.snapshot_players(
		m._connected_players, m._combat_states, m._combat_resources, m._char_stats, {}
	)
	for iid in m._scoped_cache:
		assert_eq(
			m._scoped_cache[iid],
			_BB.positions_in_instance(players, int(iid)),
			"the memoised view for instance %d is byte-identical to the unmemoised filter" % iid
		)
	assert_eq(m._scoped_cache[0].size(), 1, "the open-world view sees the live player")
	assert_eq(m._scoped_cache[7].size(), 0, "the crypt view sees nobody — the player is outside")


func test_the_memo_does_not_leak_across_ticks() -> void:
	# It is a per-TICK memo: a player who walks into the crypt between ticks must be visible to the
	# crypt's mobs on the very next tick, never fenced out by last tick's cached view.
	var m := _harness()
	m._world_rpc = _RecordingRpc.new()
	m._mobs = {1: _mob_at(1, WOLD, 7)}
	_add_player(m, WOLD)
	m._wire_regions()

	m._run_mob_ai_tick(100)
	assert_eq(m._scoped_cache[7].size(), 0, "tick 1: the player is not in the instance yet")

	PlayerSessions.set_instance(PEER, 7)
	m._run_mob_ai_tick(101)
	assert_eq(m.filter_calls, 2, "the memo is per TICK: tick 2 rebuilds rather than reusing tick 1")
	assert_eq(m._scoped_cache.size(), 1, "tick 2 rebuilt the memo from scratch")
	assert_eq(m._scoped_cache[7].size(), 1, "tick 2: the crypt's mobs see the player who entered")


# An IDLE mob standing at `pos`, scoped to `instance_id` (0 = open world). Mirrors the _idle_mob
# shape test_t698_hot_paths uses — a mob the AI tick can actually advance.
func _mob_at(eid: int, pos: Vector3, instance_id: int) -> Object:
	var mob = _MD.new()
	mob.entity_id = eid
	mob.mob_type_id = 1
	mob.position = pos
	mob.spawn_position = pos
	mob.instance_id = instance_id
	mob.patrol_radius = 0.0  # no ambient patrol: the tick is a pure no-op, so parity is exact
	mob.aggro_radius = 5.0
	mob.leash_radius = 15.0
	mob.melee_range = 2.0
	mob.mob_level = 5
	mob.ai_state = _MAI.MobAIState.IDLE
	mob.current_target_id = -1
	mob.combat_state = CombatState.new()
	var cr := CombatResources.new()
	cr.hp = 50
	cr.max_hp = 50
	mob.resources = cr
	return mob
