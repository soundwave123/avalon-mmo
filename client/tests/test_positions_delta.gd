extends GutTest
# T-372: client-side merge of the server's per-peer DELTA position frames (positions_delta.gd). The
# round-trip contract with the server (test_broadcast_delta.gd): a keyframe REPLACES the view; a
# delta merges changed/new rows and drops `removed` peers; an absent-from-delta peer is UNCHANGED.
# The reconstructed dict must always be a COMPLETE positions payload (full player list, keyframe /
# removed bookkeeping stripped) so remote_entities_layer, the T-334 last_positions truth and the
# T-285 party frames keep working unchanged. Netcode hides from unit tests — this is that net.

const _PD = preload("res://scripts/net/positions_delta.gd")


func _row(pid: int, x: float, z: float, extra: Dictionary = {}) -> Dictionary:
	var r := {
		"peer_id": pid, "username": "u%d" % pid, "x": x, "y": 0.0, "z": z, "char_class": "mage"
	}
	r.merge(extra)
	return r


func _key(players: Array, mobs: Array = [], npcs: Array = []) -> Dictionary:
	return {"type": "positions", "keyframe": true, "players": players, "mobs": mobs, "npcs": npcs}


func _delta(
	players: Array,
	removed: Array = [],
	mobs: Array = [],
	npcs: Array = [],
	mobs_removed: Array = []
) -> Dictionary:
	return {
		"type": "positions",
		"keyframe": false,
		"players": players,
		"removed": removed,
		"mobs": mobs,
		"mobs_removed": mobs_removed,
		"npcs": npcs
	}


# T-699: a full mob row (client mirror of broadcast_builder.mobs_array).
func _mrow(mid: int, x: float, z: float, extra: Dictionary = {}) -> Dictionary:
	var r := {
		"mob_id": mid, "kind": "mob_wolf", "name": "Wolf", "x": x, "y": 0.0, "z": z, "max_hp": 10
	}
	r.merge(extra, true)
	return r


func _mob_by_id(full: Dictionary) -> Dictionary:
	var out := {}
	for m in full["mobs"]:
		out[int(m["mob_id"])] = m
	return out


func _by_pid(full: Dictionary) -> Dictionary:
	var out := {}
	for p in full["players"]:
		out[int(p["peer_id"])] = p
	return out


func test_keyframe_reconstructs_the_full_view() -> void:
	var pd = _PD.new()
	var full := pd.reconstruct(_key([_row(1, 0, 0), _row(2, 5, 0)]))
	assert_eq((full["players"] as Array).size(), 2, "the keyframe view holds both players")
	assert_false(full.has("keyframe"), "the keyframe flag is stripped from the downstream dict")
	assert_false(full.has("removed"), "no removed key leaks downstream")


func test_delta_merges_changed_fields_onto_the_stored_row() -> void:
	var pd = _PD.new()
	pd.reconstruct(_key([_row(1, 0, 0), _row(2, 5, 0)]))
	# Peer 2 moved; the delta carries only peer_id + position (no static username/class).
	var full := pd.reconstruct(_delta([{"peer_id": 2, "x": 7.0, "z": 3.0}]))
	var rows := _by_pid(full)
	assert_eq((full["players"] as Array).size(), 2, "both players still present after a delta")
	assert_eq(float(rows[2]["x"]), 7.0, "the moved position is merged in")
	assert_eq(str(rows[2]["username"]), "u2", "the static username survives (merge, not replace)")
	assert_eq(str(rows[2]["char_class"]), "mage", "the static class survives the delta")


func test_absent_from_delta_means_unchanged() -> void:
	var pd = _PD.new()
	pd.reconstruct(_key([_row(1, 0, 0), _row(2, 5, 0)]))
	var full := pd.reconstruct(_delta([]))  # empty delta: nothing changed
	assert_eq((full["players"] as Array).size(), 2, "an empty delta keeps every prior player")


func test_removed_peer_is_dropped_from_the_view() -> void:
	var pd = _PD.new()
	pd.reconstruct(_key([_row(1, 0, 0), _row(2, 5, 0)]))
	var full := pd.reconstruct(_delta([], [2]))
	var rows := _by_pid(full)
	assert_eq((full["players"] as Array).size(), 1, "the removed peer is gone")
	assert_true(rows.has(1) and not rows.has(2), "peer 1 stays, peer 2 reaped")


func test_new_entrant_full_row_spawns_via_delta() -> void:
	var pd = _PD.new()
	pd.reconstruct(_key([_row(1, 0, 0)]))
	var full := pd.reconstruct(_delta([_row(2, 5, 0)]))  # newcomer carries its full row
	var rows := _by_pid(full)
	assert_eq((full["players"] as Array).size(), 2, "the newcomer joined the view")
	assert_eq(str(rows[2]["username"]), "u2", "the newcomer's full row is present")


func test_cleared_field_overwrites_the_stale_value() -> void:
	var pd = _PD.new()
	pd.reconstruct(_key([_row(1, 0, 0, {"cast": {"ability_id": 7}})]))
	# Server clears the ended cast by sending an empty dict (see _entry_delta / _empty_like).
	var full := pd.reconstruct(_delta([{"peer_id": 1, "cast": {}}]))
	var rows := _by_pid(full)
	assert_eq(rows[1]["cast"], {}, "the cast is cleared, not left stale")


func test_a_frame_without_the_flag_is_treated_as_a_keyframe() -> void:
	# Back-compat / safety: a positions dict with no `keyframe` key (a legacy full frame) must be a
	# full REPLACE, matching the pre-T-372 all-in-one broadcast.
	var pd = _PD.new()
	pd.reconstruct(_key([_row(1, 0, 0), _row(2, 5, 0)]))
	var legacy := {"type": "positions", "players": [_row(1, 0, 0)], "mobs": [], "npcs": []}
	var full := pd.reconstruct(legacy)
	assert_eq(
		(full["players"] as Array).size(), 1, "a flagless frame replaces the view (reaps peer 2)"
	)


func test_npcs_pass_through_the_reconstruction() -> void:
	# T-699: NPCs stay full-frame (no delta) — the reconstruction hands them straight downstream.
	var pd = _PD.new()
	var npcs := [{"npc_id": "townsfolk", "x": 3.0, "y": 0.0, "z": 4.0}]
	var full := pd.reconstruct(_delta([], [], [], npcs))
	assert_eq((full["npcs"] as Array).size(), 1, "npcs pass straight through")


# --- T-699: mob delta reconstruction (mirror of the player merge) -------------------------------


func test_mob_keyframe_then_delta_merges_mutables_keeps_static() -> void:
	var pd = _PD.new()
	pd.reconstruct(_key([_row(1, 0, 0)], [_mrow(9, 1, 2)]))
	# The mob walked + took a hit; the delta carries only mob_id + the mutable fields.
	var full := pd.reconstruct(_delta([], [], [{"mob_id": 9, "x": 4.0, "z": 5.0, "hp": 6}]))
	var mobs := _mob_by_id(full)
	assert_eq((full["mobs"] as Array).size(), 1, "the mob is still present after the delta")
	assert_eq(float(mobs[9]["x"]), 4.0, "the moved position is merged in")
	assert_eq(int(mobs[9]["hp"]), 6, "the new hp is merged in")
	assert_eq(str(mobs[9]["kind"]), "mob_wolf", "the static kind survives (merge, not replace)")
	assert_eq(int(mobs[9]["max_hp"]), 10, "the static max_hp survives the delta")


func test_new_mob_via_delta_carries_its_full_row() -> void:
	var pd = _PD.new()
	pd.reconstruct(_key([_row(1, 0, 0)], [_mrow(9, 1, 2)]))
	var full := pd.reconstruct(_delta([], [], [_mrow(10, 3, 4)]))
	var mobs := _mob_by_id(full)
	assert_eq((full["mobs"] as Array).size(), 2, "the newcomer mob joined the view")
	assert_eq(str(mobs[10]["kind"]), "mob_wolf", "the newcomer's full row is present")


func test_removed_mob_is_dropped_from_the_view() -> void:
	var pd = _PD.new()
	pd.reconstruct(_key([_row(1, 0, 0)], [_mrow(9, 1, 2), _mrow(10, 3, 4)]))
	var full := pd.reconstruct(_delta([], [], [], [], [10]))  # mobs_removed = [10]
	var mobs := _mob_by_id(full)
	assert_eq((full["mobs"] as Array).size(), 1, "the removed mob is gone")
	assert_true(mobs.has(9) and not mobs.has(10), "mob 9 stays, mob 10 reaped")


func test_mob_keyframe_delta_stream_round_trips_identically() -> void:
	# The lossless invariant: a keyframe + a run of mob deltas leaves the view byte-identical to a
	# full broadcast of the final mob state (matches the server test_broadcast_delta round-trip).
	var pd = _PD.new()
	pd.reconstruct(_key([_row(1, 0, 0)], [_mrow(9, 1, 2), _mrow(10, 3, 4)]))
	pd.reconstruct(_delta([], [], [{"mob_id": 9, "x": 5.0, "ai_state": 1}]))  # 9 moves + aggros
	pd.reconstruct(_delta([], [], [_mrow(11, 7, 8)]))  # 11 spawns
	var full := pd.reconstruct(_delta([], [], [{"mob_id": 10, "hp": 2}], [], [9]))  # 10 hurt, 9 dies
	var mobs := _mob_by_id(full)
	assert_eq((full["mobs"] as Array).size(), 2, "final mob view = {10, 11} (9 removed)")
	assert_eq(int(mobs[10]["hp"]), 2, "mob 10's merged hp")
	assert_eq(str(mobs[11]["kind"]), "mob_wolf", "mob 11 spawned with its full row")
	assert_true(not mobs.has(9), "mob 9 reaped via mobs_removed")


func test_full_keyframe_delta_stream_round_trips_a_moving_crowd() -> void:
	# The integration invariant: keyframe, then a run of deltas (moves, a join, a leave), must leave
	# the client view byte-identical to what a full broadcast of the final state would produce.
	var pd = _PD.new()
	pd.reconstruct(_key([_row(1, 0, 0), _row(2, 5, 0), _row(3, 9, 0)]))
	pd.reconstruct(_delta([{"peer_id": 2, "x": 6.0, "z": 1.0}]))  # 2 moves
	pd.reconstruct(_delta([_row(4, 12, 0)]))  # 4 joins
	var full := pd.reconstruct(_delta([{"peer_id": 1, "x": 2.0, "z": 0.0}], [3]))  # 1 moves, 3 leaves
	var rows := _by_pid(full)
	assert_eq((full["players"] as Array).size(), 3, "final view = {1,2,4} (3 left)")
	assert_eq(float(rows[1]["x"]), 2.0, "peer 1's latest position")
	assert_eq(float(rows[2]["x"]), 6.0, "peer 2's merged position held across later deltas")
	assert_true(rows.has(4) and not rows.has(3), "peer 4 joined, peer 3 reaped")
