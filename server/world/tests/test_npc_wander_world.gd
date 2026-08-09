extends GutTest

# T-311: world_rpc ambient-NPC integration — tick_npcs writes live positions into _content_npcs so
# the INTERACT_RADIUS talk/turn-in gate follows a moving quest-giver, and npc_positions_array
# carries only the tracked NPCs into the positions broadcast. Untracked NPCs never tick.

const _WRPC = preload("res://scripts/world_rpc.gd")
const _CQ = preload("res://scripts/content/content_query.gd")
const _MCOL = preload("res://scripts/movement_collision.gd")  # Report #15: footprint oracle


func _rpc() -> Object:
	var w = _WRPC.new()
	# setup makes no master calls (content load + wander seed only) — null master is fine here.
	var err: String = w.setup(null, func(_p, _d): pass, "res://data")
	assert_eq(err, "", "content + wander setup clean")
	return w


func _rng() -> RandomNumberGenerator:
	var r := RandomNumberGenerator.new()
	r.seed = 99
	return r


func test_wander_npcs_are_seeded_from_data() -> void:
	var w = _rpc()
	assert_gt(w._npc_director.mover_count(), 0, "some NPCs carry a wander block")
	assert_true(w._npc_director.is_tracked("npc_farmer_geld"), "Farmer Geld ambles")
	assert_false(
		w._npc_director.is_tracked("npc_hk_throne_guard_west"),
		"throne guards stay rooted (no block)"
	)


func test_tick_moves_the_live_npc_position() -> void:
	var w = _rpc()
	var geld = w._content_npcs["npc_farmer_geld"]
	var start := Vector3(geld.x, geld.y, 0.0)
	var rng := _rng()
	for t in range(2000):  # ~100 s — enough to clear the long idle pauses and take real steps
		w.tick_npcs(t, 20, rng)
	var moved := Vector3(geld.x, geld.y, 0.0)
	assert_gt(moved.distance_to(start), 0.3, "the NPC's live position actually moved")


func test_talk_proximity_still_resolves_while_wandering() -> void:
	# A player standing at the quest-giver's post stays inside INTERACT_RADIUS the whole time — the
	# small wander radius keeps the talk gate honest even as the NPC ambles.
	var w = _rpc()
	var post: Vector3 = w._npc_director.post_of("npc_farmer_geld")
	var rng := _rng()
	var always_reachable := true
	for t in range(2000):
		w.tick_npcs(t, 20, rng)
		if not _CQ.near_npc(w._content_npcs, "npc_farmer_geld", post, _WRPC.INTERACT_RADIUS):
			always_reachable = false
			break
	assert_true(always_reachable, "a player at the post can always talk to the wandering NPC")


func test_positions_array_carries_movers_only() -> void:
	var w = _rpc()
	var rng := _rng()
	w.tick_npcs(1, 20, rng)
	var arr: Array = w.npc_positions_array()
	assert_eq(
		arr.size(), w._npc_director.mover_count(), "one entry per mover, none for rooted NPCs"
	)
	var ids := {}
	for e in arr:
		ids[str(e["npc_id"])] = true
		assert_true(e.has("x") and e.has("y"), "each entry carries live x/y")
	assert_true(ids.has("npc_farmer_geld"), "the mover is present in the broadcast payload")


# ---- T-446: anti-clump + workplace anchors + idle life ----


func test_idle_only_npcs_are_tracked_and_broadcast() -> void:
	# Smith Dorrun has no wander block but an `idle` block — he rides the positions stream so the
	# client can face/animate him, yet stays leashed at the anvil.
	var w = _rpc()
	assert_true(w._npc_director.is_tracked("npc_blacksmith"), "idle-only NPC is tracked")
	var rng := _rng()
	w.tick_npcs(1, 20, rng)
	var found := false
	for e in w.npc_positions_array():
		if str(e["npc_id"]) == "npc_blacksmith":
			found = true
			assert_true(e.has("f"), "idle NPC row carries a facing")
	assert_true(found, "idle-only NPC present in the broadcast payload")


func test_hub_npcs_never_share_a_footprint() -> void:
	# The audit clump (Hale/Loreth/Ansa + the trainers at the tutorial hub): after settling, every
	# pair of tracked hub NPCs keeps personal space — no interpenetration.
	var w = _rpc()
	var rng := _rng()
	for t in range(4000):  # ~200 s of wandering across the hub
		w.tick_npcs(t, 20, rng)
	var hub := ["npc_drillmaster", "npc_arcanist", "npc_cleric", "npc_trainer", "npc_scout_mira"]
	for i in range(hub.size()):
		for j in range(i + 1, hub.size()):
			var a = w._content_npcs[hub[i]]
			var b = w._content_npcs[hub[j]]
			var d := Vector2(a.x, a.y).distance_to(Vector2(b.x, b.y))
			assert_gt(d, 0.9, "%s vs %s occupy distinct footprints" % [hub[i], hub[j]])


func test_drillmaster_is_anchored_at_the_training_ring() -> void:
	# wander.anchor re-posts Hale at the ring edge (T-444 loc_training_ring is 14,10) — he paces
	# the ring. Report #15: his spawn row moved to the anchor too — the old (10,10) road spawn
	# sits INSIDE the prop_cottage_v2 footprint, and a first-tick spawn->anchor step that crosses
	# a wall gets dropped by the separation guard, trapping him in the building he spawned in.
	var w = _rpc()
	var post: Vector3 = w._npc_director.post_of("npc_drillmaster")
	assert_eq(Vector2(post.x, post.y), Vector2(12.5, 9.0), "post = the authored ring anchor")
	var rng := _rng()
	var ring := Vector2(14.0, 10.0)
	for t in range(4000):
		w.tick_npcs(t, 20, rng)
		var hale = w._content_npcs["npc_drillmaster"]
		assert_lt(Vector2(hale.x, hale.y).distance_to(ring), 4.0, "Hale stays on the ring beat")


# T-577 (portal report #45): Hale is a `waypoints`-mode wanderer with NO leash (npc_director's
# _leash_radius returns INF for that mode) — his live position roams the whole ring, which can put
# him further than INTERACT_RADIUS from a player standing at his post. Confirms the drift is real
# (a player at the post is NOT always in range of the live npc.x/npc.y)...
func test_drillmaster_live_position_drifts_out_of_interact_radius_from_his_post() -> void:
	var w = _rpc()
	var post: Vector3 = w._npc_director.post_of("npc_drillmaster")
	var rng := _rng()
	var ever_out_of_range := false
	for t in range(4000):
		w.tick_npcs(t, 20, rng)
		if not _CQ.near_npc(w._content_npcs, "npc_drillmaster", post, _WRPC.INTERACT_RADIUS):
			ever_out_of_range = true
			break
	assert_true(
		ever_out_of_range,
		"Hale's live wander position leaves INTERACT_RADIUS of his own post at least once"
	)


# ...and the fix: measuring against the ANCHOR (what _npc_anchor/_turn_in/_talk now do) instead of
# the live position stays true the entire time, regardless of where Hale is in his patrol.
func test_turnin_and_talk_proximity_deterministic_at_the_anchor_despite_wander_drift() -> void:
	var w = _rpc()
	var post: Vector3 = w._npc_director.post_of("npc_drillmaster")
	var quest = w._content_quests["q007"]  # turnin_npc: npc_drillmaster
	assert_eq(str(quest.turnin_npc), "npc_drillmaster")
	var rng := _rng()
	for t in range(4000):
		w.tick_npcs(t, 20, rng)
		var anchor = w._npc_anchor("npc_drillmaster")
		assert_true(
			_CQ.near_npc(w._content_npcs, "npc_drillmaster", post, _WRPC.INTERACT_RADIUS, anchor),
			"talk proximity at the post is anchor-stable regardless of wander phase (t=%d)" % t
		)
		assert_true(
			_CQ.at_turnin_npc(w._content_npcs, quest, post, _WRPC.INTERACT_RADIUS, anchor),
			"turn-in proximity at the post is anchor-stable regardless of wander phase (t=%d)" % t
		)


# A player genuinely far from where the NPC lives still gets rejected — the anchor fix must not
# blow the interaction range open.
func test_turnin_far_player_still_rejected_despite_anchor_fix() -> void:
	var w = _rpc()
	var quest = w._content_quests["q007"]
	var far := Vector3(200.0, 200.0, 0.0)
	var rng := _rng()
	for t in range(200):
		w.tick_npcs(t, 20, rng)
		var anchor = w._npc_anchor("npc_drillmaster")
		assert_false(
			_CQ.at_turnin_npc(w._content_npcs, quest, far, _WRPC.INTERACT_RADIUS, anchor),
			"a genuinely distant player is still refused"
		)


func test_smith_pulses_a_hammer_act_over_time() -> void:
	var w = _rpc()
	var rng := _rng()
	var saw_hammer := false
	for t in range(4000):  # ~200 s >> the 4-9 s act window
		w.tick_npcs(t, 20, rng)
		for e in w.npc_positions_array():
			if str(e["npc_id"]) == "npc_blacksmith" and str(e.get("act", "")) == "hammer":
				saw_hammer = true
	assert_true(saw_hammer, "the smith's work idle rides the broadcast")


func test_separation_never_breaks_the_talk_gate_for_an_idle_npc() -> void:
	# The leash: even with neighbours shoving, an idle-only quest-giver stays findable at its post.
	var w = _rpc()
	var post: Vector3 = w._npc_director.post_of("npc_blacksmith")
	var rng := _rng()
	for t in range(4000):
		w.tick_npcs(t, 20, rng)
		assert_true(
			_CQ.near_npc(w._content_npcs, "npc_blacksmith", post, _WRPC.INTERACT_RADIUS),
			"a player at the anvil can always talk to the smith"
		)


func test_courier_walks_a_real_route() -> void:
	# Regent's Courier Edric now loops waypoints between hamlet anchors (ticket leg 3).
	var w = _rpc()
	var rng := _rng()
	var min_x := INF
	var max_x := -INF
	for t in range(6000):
		w.tick_npcs(t, 20, rng)
		var edric = w._content_npcs["npc_regents_courier"]
		min_x = minf(min_x, edric.x)
		max_x = maxf(max_x, edric.x)
	assert_gt(max_x - min_x, 3.0, "the courier visibly travels, not a shuffle in place")


# ---- Report #15: ambient NPCs respect world geometry (no more walking through buildings) ----


func test_wanderers_never_enter_a_building_footprint() -> void:
	# The live defect: Courier Edric + village NPCs clipped straight through the tavern/cottage.
	# With the wall oracle wired at setup, a long simulated stroll must keep every tracked village
	# NPC OUTSIDE every solid-prop footprint the whole time.
	var w = _rpc()
	var oracle = _MCOL.new("res://data/regions/npc_obstacles.json")
	assert_gt(oracle.wall_count(), 0, "obstacle data present")
	var town := [
		"npc_regents_courier", "npc_courier", "npc_farmer_geld", "npc_drillmaster", "npc_child_nell"
	]
	var rng := _rng()
	for t in range(6000):  # ~300 s — many full route loops + pauses
		w.tick_npcs(t, 20, rng)
		if t % 5 != 0:  # sample the invariant (a wall crossing cannot out-run a 0.25 s window)
			continue
		for id in town:
			var npc = w._content_npcs[id]
			assert_false(
				oracle.point_inside(npc.x, npc.y),
				"%s stays outside building footprints (t=%d at %.2f,%.2f)" % [id, t, npc.x, npc.y]
			)


func test_tick_is_idempotent_within_a_server_tick() -> void:
	# Uncapped headless FPS calls _process many times per server tick; a repeat tick must be a no-op.
	var w = _rpc()
	var rng := _rng()
	w.tick_npcs(5, 20, rng)
	var geld = w._content_npcs["npc_farmer_geld"]
	var after_first := Vector3(geld.x, geld.y, 0.0)
	w.tick_npcs(5, 20, rng)  # same tick number → no movement
	assert_eq(Vector3(geld.x, geld.y, 0.0), after_first, "same tick does not double-step")
