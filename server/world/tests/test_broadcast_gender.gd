extends GutTest
# T-535: gender rides the positions broadcast so a female player's BODY mesh is picked by every
# remote client, not just the local one. A plain string sent only when set — it rides the T-372
# delta for free and remote mobs / ungendered rows stay untouched.

const _BB = preload("res://scripts/broadcast_builder.gd")


func _positions() -> Dictionary:
	return {
		1: {"username": "u1", "x": 0.0, "y": 0.0, "z": 0.0, "instance_id": 0},
		2: {"username": "u2", "x": 1.0, "y": 0.0, "z": 0.0, "instance_id": 0},
	}


func test_players_array_carries_gender_when_set() -> void:
	var out := _BB.players_array(
		_positions(), {}, {1: "mage", 2: "warrior"}, {}, {}, {}, {}, {1: "female"}
	)
	var by_pid := {}
	for e in out:
		by_pid[int(e["peer_id"])] = e
	assert_eq(str(by_pid[1].get("gender", "")), "female", "a female player's gender rides the row")
	assert_false(by_pid[2].has("gender"), "a peer with no gender entry omits the field")


func test_players_array_omits_gender_when_absent_or_empty() -> void:
	# no genders map at all -> no gender field anywhere (lean delta, pre-T-535 wire shape)
	var a := _BB.players_array(_positions(), {}, {1: "mage"})
	assert_false(a[0].has("gender"), "no gender map -> no gender field")
	# an explicit empty gender (an ungendered / male character) is also omitted
	var b := _BB.players_array(_positions(), {}, {1: "mage"}, {}, {}, {}, {}, {1: ""})
	assert_false(b[0].has("gender"), "empty gender -> field omitted (male default)")


func test_positions_frames_aoi_threads_gender_end_to_end() -> void:
	var frames := _BB.positions_frames_aoi(
		_positions(), {}, {1: "warrior", 2: "mage"}, {}, {}, {}, {}, [], 80.0, 50, {}, {1: "female"}
	)
	var saw_female := false
	for f in frames:
		for pl in f["payload"]["players"]:
			if int(pl["peer_id"]) == 1:
				assert_eq(
					str(pl.get("gender", "")), "female", "peer 1's gender reached the AOI frame"
				)
				saw_female = true
	assert_true(saw_female, "the female player appeared in an AOI frame")
