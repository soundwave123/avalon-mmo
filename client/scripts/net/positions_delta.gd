extends RefCounted
# T-372: client mirror of broadcast_builder.positions_delta_frames. The world now sends per-peer
# DELTA position frames (only changed / new players) with a periodic full KEYFRAME, instead of the
# full player row for every neighbour every 100 ms. This layer merges each incoming frame into a
# maintained full view and hands the rest of the client a COMPLETE `positions` dict — so
# remote_entities_layer, the T-334 pilot `last_positions` truth, the T-283 target frame and the
# T-285 party frames (join-by-username) all keep consuming the full player list exactly as before,
# with zero delta-awareness. It sits inside ClientNet, ahead of the "positions" handler dispatch.
#
#   keyframe == true (or a legacy frame with no flag): `players` is the whole interest set → REPLACE
#     the view (peers absent from a keyframe are reaped — matches the pre-T-372 all-in-one frame).
#   keyframe == false: merge each entry's fields onto the stored row (a peer NEW to interest carries
#     a full row); `removed` peers are dropped. A player absent from a delta is UNCHANGED, not gone.
#
# Netcode hides from unit tests — the merge invariants are covered by test_positions_delta.gd + the
# server side by test_broadcast_delta.gd; the live spawn/despawn E2E is scripts/test-aoi-e2e.sh.

var _players: Dictionary = {}  # peer_id -> full player row (the reconstructed interest set)
var _mobs: Dictionary = {}  # T-699: mob_id -> full mob row (mobs ride the same delta contract)


# Merge one incoming positions frame into the view and return a full positions dict (full player +
# mob list, keyframe/removed bookkeeping stripped) for the ordinary downstream consumers.
func reconstruct(data: Dictionary) -> Dictionary:
	if bool(data.get("keyframe", true)):
		_players = {}
		for e in data.get("players", []):
			_players[int(e.get("peer_id", -1))] = e
		_mobs = {}  # T-699: a keyframe carries the full mob set → REPLACE the mob view
		for m in data.get("mobs", []):
			_mobs[m.get("mob_id")] = m
	else:
		for e in data.get("players", []):
			var id := int(e.get("peer_id", -1))
			var row: Dictionary = (
				(_players[id] as Dictionary).duplicate() if _players.has(id) else {}
			)
			for k in e:
				row[k] = e[k]
			_players[id] = row
		for id in data.get("removed", []):
			_players.erase(int(id))
		_merge_mobs(data)  # T-699: mobs merge changed rows + drop mobs_removed, mirroring players
	var full: Dictionary = data.duplicate()  # keeps type / npcs; players + mobs + flags rewritten
	full["players"] = _players.values()
	full["mobs"] = _mobs.values()  # T-699: hand downstream the reconstructed full mob view
	full.erase("keyframe")
	full.erase("removed")
	full.erase("mobs_removed")
	return full


# T-699: merge a mob delta (changed/new rows keyed by mob_id) and reap `mobs_removed`. A mob NEW to
# interest carries its full row; an existing mob's changed mutable fields overwrite the stored row.
func _merge_mobs(data: Dictionary) -> void:
	for m in data.get("mobs", []):
		var id = m.get("mob_id")
		var row: Dictionary = (_mobs[id] as Dictionary).duplicate() if _mobs.has(id) else {}
		for k in m:
			row[k] = m[k]
		_mobs[id] = row
	for id in data.get("mobs_removed", []):
		_mobs.erase(id)


func player_count() -> int:  # headless-test accessor: entities in the reconstructed view
	return _players.size()


func mob_count() -> int:  # T-699 headless-test accessor: mobs in the reconstructed view
	return _mobs.size()
