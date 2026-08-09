extends GutTest
# T-372: per-peer DELTA position broadcast (pure), capacity lever 3 on top of the T-370/T-371 AOI
# frames. Proves the server sends only what changed since a peer's last frame, with a full keyframe
# on first sight and every keyframe_interval frames, and that removals are explicit — so the client
# (test_positions_delta.gd) can reconstruct the exact full view from a keyframe + a stream of deltas
# without ever reaping a still-present peer or keeping a departed one. Netcode hides from tests.
# the round-trip invariants split across the two suites and the live E2E is test-aoi-e2e.sh.

const _BB = preload("res://scripts/broadcast_builder.gd")

const KEY := 20  # default keyframe interval (ServerConfig.DEFAULT_KEYFRAME_FRAMES)


# One per-peer AOI-style frame: peer `pid` receiving the given full player rows.
func _frame(pid: int, players: Array, mobs: Array = [], npcs: Array = []) -> Dictionary:
	return {
		"peers": [pid],
		"payload": {"type": "positions", "players": players, "mobs": mobs, "npcs": npcs}
	}


func _row(pid: int, x: float, z: float, extra: Dictionary = {}) -> Dictionary:
	var r := {
		"peer_id": pid, "username": "u%d" % pid, "x": x, "y": 0.0, "z": z, "char_class": "mage"
	}
	r.merge(extra)
	return r


# T-699: a full mob row as broadcast_builder.mobs_array emits it (static + mutable fields).
func _mrow(mid: int, x: float, z: float, extra: Dictionary = {}) -> Dictionary:
	var r := {
		"mob_id": mid,
		"kind": "mob_wolf",
		"name": "Wolf",
		"level": 3,
		"elite": false,
		"render_scale": 1.0,
		"x": x,
		"y": 0.0,
		"z": z,
		"ai_state": 0,
		"hostile": true,
		"target_id": -1,
		"hp": 10,
		"max_hp": 10,
	}
	r.merge(extra, true)
	return r


# --- keyframe semantics -------------------------------------------------------------------------


func test_first_frame_is_always_a_keyframe() -> void:
	var frames := [_frame(1, [_row(1, 0, 0), _row(2, 5, 0)])]
	var out := _BB.positions_delta_frames(frames, {}, KEY)
	var payload: Dictionary = out["frames"][0]["payload"]
	assert_true(payload["keyframe"], "a peer with no prior state gets a full keyframe")
	assert_eq(
		(payload["players"] as Array).size(), 2, "the keyframe carries the whole interest set"
	)
	assert_false(payload.has("removed"), "a keyframe needs no removed list")


func test_keyframe_recurs_every_interval_frames() -> void:
	var frames := [_frame(1, [_row(1, 0, 0)])]
	var state: Dictionary = {}
	var key_count := 0
	# Frame 0 = keyframe; then interval-1 deltas; the interval-th frame is a keyframe again.
	for i in range(KEY + 1):
		var out := _BB.positions_delta_frames(frames, state, KEY)
		state = out["state"]
		if bool(out["frames"][0]["payload"]["keyframe"]):
			key_count += 1
	assert_eq(key_count, 2, "keyframes at frame 0 and frame %d (every %d frames)" % [KEY, KEY])


func test_keyframe_interval_1_disables_deltas() -> void:
	var frames := [_frame(1, [_row(1, 0, 0)])]
	var out1 := _BB.positions_delta_frames(frames, {}, 1)
	var out2 := _BB.positions_delta_frames(frames, out1["state"], 1)
	assert_true(out2["frames"][0]["payload"]["keyframe"], "interval 1 → every frame is a keyframe")


# --- delta semantics ----------------------------------------------------------------------------


func test_unchanged_player_is_omitted_from_a_delta() -> void:
	var frames := [_frame(1, [_row(1, 0, 0), _row(2, 5, 0)])]
	var key := _BB.positions_delta_frames(frames, {}, KEY)
	# Nothing moved — the follow-up delta carries NO player entries (fully additive omission).
	var delta := _BB.positions_delta_frames(frames, key["state"], KEY)
	var payload: Dictionary = delta["frames"][0]["payload"]
	assert_false(payload["keyframe"], "the second frame is a delta")
	assert_eq(
		(payload["players"] as Array).size(), 0, "an unchanged interest set sends no player rows"
	)
	assert_eq(payload["removed"], [], "nobody left interest")


func test_moved_player_sends_only_changed_fields_plus_peer_id() -> void:
	var key := _BB.positions_delta_frames([_frame(1, [_row(1, 0, 0), _row(2, 5, 0)])], {}, KEY)
	# Peer 2 walks; its static fields (username/class) must NOT ride the delta.
	var delta := _BB.positions_delta_frames(
		[_frame(1, [_row(1, 0, 0), _row(2, 7, 3)])], key["state"], KEY
	)
	var players: Array = delta["frames"][0]["payload"]["players"]
	assert_eq(players.size(), 1, "only the mover is in the delta")
	var e: Dictionary = players[0]
	assert_eq(int(e["peer_id"]), 2, "the mover, keyed by peer_id")
	assert_true(e.has("x") and e.has("z"), "changed position fields ride")
	assert_false(e.has("username"), "the static username is NOT re-sent")
	assert_false(e.has("char_class"), "the static class is NOT re-sent")


func test_new_entrant_in_a_delta_carries_its_full_row() -> void:
	var key := _BB.positions_delta_frames([_frame(1, [_row(1, 0, 0)])], {}, KEY)
	# Peer 2 enters peer 1's interest between keyframes — it must arrive with ALL fields so the client
	# can spawn it, never a partial row.
	var delta := _BB.positions_delta_frames(
		[_frame(1, [_row(1, 0, 0), _row(2, 5, 0)])], key["state"], KEY
	)
	var players: Array = delta["frames"][0]["payload"]["players"]
	assert_eq(players.size(), 1, "only the newcomer is in the delta")
	var e: Dictionary = players[0]
	assert_eq(int(e["peer_id"]), 2, "the newcomer")
	assert_true(e.has("username") and e.has("char_class"), "a new entrant carries its full row")


func test_departed_player_is_flagged_removed_not_omitted() -> void:
	var key := _BB.positions_delta_frames([_frame(1, [_row(1, 0, 0), _row(2, 5, 0)])], {}, KEY)
	# Peer 2 leaves peer 1's interest — deltas are additive, so its absence must be an EXPLICIT remove.
	var delta := _BB.positions_delta_frames([_frame(1, [_row(1, 0, 0)])], key["state"], KEY)
	var payload: Dictionary = delta["frames"][0]["payload"]
	assert_eq(payload["removed"], [2], "the departed peer is explicitly removed")
	assert_eq((payload["players"] as Array).size(), 0, "and sends no player row")


func test_dropped_optional_field_is_cleared_not_left_stale() -> void:
	# Peer 2 was casting (a `cast` dict); the cast ends so the new row omits `cast`. The delta must
	# emit an empty cast so the client CLEARS the bar rather than holding the stale one forever.
	var casting := _row(2, 5, 0, {"cast": {"ability_id": 7, "remaining_s": 1.0}})
	var key := _BB.positions_delta_frames([_frame(1, [_row(1, 0, 0), casting])], {}, KEY)
	var delta := _BB.positions_delta_frames(
		[_frame(1, [_row(1, 0, 0), _row(2, 5, 0)])], key["state"], KEY
	)
	var players: Array = delta["frames"][0]["payload"]["players"]
	assert_eq(players.size(), 1, "peer 2 changed (its cast ended)")
	assert_eq(players[0]["cast"], {}, "the ended cast is explicitly cleared to {}")


func test_gear_transmog_swap_rides_the_delta() -> void:
	# T-375: a cosmetic override changes the `gear` dict a peer already has — the delta must carry the
	# new gear so a transmog propagates without a keyframe (equipped_from_slots keeps gear a plain
	# {slot: id} map, so the value-compare marks the entity dirty for free).
	var worn := _row(2, 5, 0, {"gear": {"weapon": "itm_iron_sword"}})
	var key := _BB.positions_delta_frames([_frame(1, [_row(1, 0, 0), worn])], {}, KEY)
	var transmogged := _row(2, 5, 0, {"gear": {"weapon": "cos_gilded_blade"}})
	var delta := _BB.positions_delta_frames(
		[_frame(1, [_row(1, 0, 0), transmogged])], key["state"], KEY
	)
	var players: Array = delta["frames"][0]["payload"]["players"]
	assert_eq(players.size(), 1, "only peer 2 changed (its look)")
	assert_eq(
		players[0]["gear"], {"weapon": "cos_gilded_blade"}, "the new transmog rides the delta"
	)


# --- T-699: mob delta semantics (mirror the player delta; npcs stay full-frame) -----------------


func test_npcs_ride_full_every_frame_while_mobs_delta() -> void:
	# NPCs keep full-frame (their static kind/name is out-of-band via npc_indicators); mobs now delta.
	var mobs := [_mrow(9, 1, 2)]
	var npcs := [{"npc_id": "townsfolk", "x": 3.0, "y": 0.0, "z": 4.0}]
	var frames := [_frame(1, [_row(1, 0, 0)], mobs, npcs)]
	var key := _BB.positions_delta_frames(frames, {}, KEY)
	assert_eq((key["frames"][0]["payload"]["mobs"] as Array).size(), 1, "mobs full on the keyframe")
	assert_eq((key["frames"][0]["payload"]["npcs"] as Array).size(), 1, "npcs full on the keyframe")
	var delta := _BB.positions_delta_frames(frames, key["state"], KEY)
	assert_eq(
		(delta["frames"][0]["payload"]["mobs"] as Array).size(),
		0,
		"an unchanged mob is omitted from the delta"
	)
	assert_eq(
		(delta["frames"][0]["payload"]["npcs"] as Array).size(),
		1,
		"npcs still ride full on the delta"
	)


func test_mob_keyframe_full_then_delta_sends_only_mutables() -> void:
	var key := _BB.positions_delta_frames([_frame(1, [_row(1, 0, 0)], [_mrow(9, 1, 2)])], {}, KEY)
	var kf_mob: Dictionary = (key["frames"][0]["payload"]["mobs"] as Array)[0]
	assert_true(
		kf_mob.has("kind") and kf_mob.has("max_hp"), "the keyframe mob carries static fields"
	)
	# The mob walks and takes a hit — only x/z/hp/ai_state (mutable) may ride the delta.
	var moved := [_mrow(9, 4, 5, {"hp": 6, "ai_state": 1})]
	var delta := _BB.positions_delta_frames([_frame(1, [_row(1, 0, 0)], moved)], key["state"], KEY)
	var dmobs: Array = delta["frames"][0]["payload"]["mobs"]
	assert_eq(dmobs.size(), 1, "the changed mob is the only delta row")
	var dm: Dictionary = dmobs[0]
	assert_eq(int(dm["mob_id"]), 9, "keyed by mob_id")
	assert_true(
		dm.has("x") and dm.has("hp") and dm.has("ai_state"), "mutable fields ride the delta"
	)
	assert_false(dm.has("kind"), "static kind is NOT re-sent")
	assert_false(dm.has("name"), "static name is NOT re-sent")
	assert_false(dm.has("max_hp"), "static max_hp is NOT re-sent")
	assert_eq(delta["frames"][0]["payload"]["mobs_removed"], [], "nothing departed")


func test_new_mob_in_a_delta_carries_its_full_row() -> void:
	var key := _BB.positions_delta_frames([_frame(1, [_row(1, 0, 0)], [_mrow(9, 1, 2)])], {}, KEY)
	var delta := _BB.positions_delta_frames(
		[_frame(1, [_row(1, 0, 0)], [_mrow(9, 1, 2), _mrow(10, 3, 4)])], key["state"], KEY
	)
	var dmobs: Array = delta["frames"][0]["payload"]["mobs"]
	assert_eq(dmobs.size(), 1, "only the newcomer mob is in the delta")
	assert_eq(int(dmobs[0]["mob_id"]), 10, "the newcomer")
	assert_true(dmobs[0].has("kind") and dmobs[0].has("max_hp"), "a new mob carries its FULL row")


func test_departed_mob_is_flagged_removed_not_omitted() -> void:
	var key := _BB.positions_delta_frames(
		[_frame(1, [_row(1, 0, 0)], [_mrow(9, 1, 2), _mrow(10, 3, 4)])], {}, KEY
	)
	var delta := _BB.positions_delta_frames(
		[_frame(1, [_row(1, 0, 0)], [_mrow(9, 1, 2)])], key["state"], KEY
	)
	var payload: Dictionary = delta["frames"][0]["payload"]
	assert_eq(payload["mobs_removed"], [10], "the departed mob is explicitly removed")
	assert_eq((payload["mobs"] as Array).size(), 0, "and sends no mob row")


func test_each_peer_tracks_its_own_keyframe_cadence() -> void:
	# Two peers; peer 1 is pre-seeded (mid-cadence) while peer 2 is brand new → they must NOT share a
	# keyframe clock. Peer 2 keyframes on its first frame; peer 1 continues its own delta stream.
	var f1 := _frame(1, [_row(1, 0, 0)])
	var seed := _BB.positions_delta_frames([f1], {}, KEY)  # peer 1 now has state, since_key 0
	var frames := [f1, _frame(2, [_row(2, 300, 0)])]
	var out := _BB.positions_delta_frames(frames, seed["state"], KEY)
	var by_pid := {}
	for fr in out["frames"]:
		by_pid[int(fr["peers"][0])] = fr["payload"]
	assert_false(by_pid[1]["keyframe"], "peer 1 stays on its delta stream")
	assert_true(by_pid[2]["keyframe"], "the brand-new peer 2 gets its own first-frame keyframe")


func test_disconnected_peer_drops_out_of_state_no_leak() -> void:
	# Peer 2 present, then gone from the frames entirely (disconnected). Its per-peer state must not
	# persist — the returned state has only the peers still receiving frames.
	var key := _BB.positions_delta_frames(
		[_frame(1, [_row(1, 0, 0)]), _frame(2, [_row(2, 5, 0)])], {}, KEY
	)
	var out := _BB.positions_delta_frames([_frame(1, [_row(1, 0, 0)])], key["state"], KEY)
	assert_true((out["state"] as Dictionary).has(1), "the live peer keeps its state")
	assert_false((out["state"] as Dictionary).has(2), "the disconnected peer's state is dropped")
