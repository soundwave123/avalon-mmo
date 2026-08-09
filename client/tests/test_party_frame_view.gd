extends "res://addons/gut/test.gd"
# T-511 carve: PartyFrameView.build_rows — the pure party-frame row builder pulled out of main.gd.

const PARTY_RANGE := 40.0
const READY_RADIUS := 6.0


func _players() -> Dictionary:
	return {
		"players":
		[
			{"username": "me", "peer_id": 1, "x": 0.0, "y": 0.0, "z": 0.0, "hp": 50, "max_hp": 100},
			{
				"username": "far",
				"peer_id": 2,
				"x": 500.0,
				"y": 0.0,
				"z": 0.0,
				"hp": 30,
				"max_hp": 60
			},
		]
	}


func test_builds_one_row_per_member_with_leader_and_range_flags() -> void:
	var rows: Array = PartyFrameView.build_rows(
		_players(), ["me", "far"], 1, "me", {}, READY_RADIUS, PARTY_RANGE
	)
	assert_eq(rows.size(), 2, "one row per party member")
	assert_eq(str(rows[0]["name"]), "me")
	assert_true(bool(rows[0]["leader"]), "the leader flag is set for the party leader")
	assert_true(bool(rows[0]["in_range"]), "the local player is in range of itself")
	assert_false(bool(rows[1]["leader"]), "non-leaders are not flagged leader")
	assert_false(bool(rows[1]["in_range"]), "a member 500m away is out of range")
	assert_eq(int(rows[0]["hp"]), 50)
	assert_eq(int(rows[0]["max_hp"]), 100)


func test_ready_flag_set_when_member_stands_at_the_crypt_stair() -> void:
	const CryptGate = preload("res://scripts/world/crypt_gate.gd")
	var stair := CryptGate.ENTER_POINT
	var data := {
		"players": [{"username": "me", "peer_id": 1, "x": stair.x, "y": stair.y, "z": 0.0}]
	}
	var rows: Array = PartyFrameView.build_rows(
		data, ["me"], 1, "me", {}, READY_RADIUS, PARTY_RANGE
	)
	assert_true(bool(rows[0]["ready"]), "standing on the crypt stair marks the member ready")


func test_subgroup_column_reads_from_the_raid_map() -> void:
	var rows: Array = PartyFrameView.build_rows(
		_players(), ["me", "far"], 1, "me", {"far": 3}, READY_RADIUS, PARTY_RANGE
	)
	assert_eq(int(rows[1]["subgroup"]), 3, "raid subgroup comes from the subgroups map")
	assert_eq(int(rows[0]["subgroup"]), 0, "members absent from the map default to subgroup 0")
