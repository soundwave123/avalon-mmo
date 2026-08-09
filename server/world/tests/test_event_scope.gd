extends GutTest
# T-699: region-scoped combat/death/respawn event recipients (broadcast_builder.event_recipients,
# pure). Before T-699 these were all-peers reliable broadcasts (O(events × CCU), cross-region — an
# Ashmoor player received every Wold swing). The recipient set is now the SAME instance + era region
# as the event origin (the positions path's own bucketing) UNION the involved players + their whole
# party, so a cross-region party-mate or the event's own target still gets it while a far-region
# bystander does not. Netcode hides from unit tests — the live proof is scripts/test-aoi-e2e.sh.

const _BB = preload("res://scripts/broadcast_builder.gd")


func _at(x: float, z: float, iid: int = 0) -> Dictionary:
	return {"username": "u", "x": x, "y": 0.0, "z": z, "instance_id": iid}


# Region anchors (broadcast_builder.REGION_ANCHORS): era-1 at (0,0), Ashmoor at (-420,0).


func test_same_region_receives_far_region_does_not() -> void:
	var pos := {1: _at(0, 0), 2: _at(50, 0), 3: _at(-420, 0)}  # 1,2 era-1; 3 Ashmoor
	# Player 1 dies (involved = [1]); origin derived from player 1's live position (region 0).
	var r: Array = _BB.event_recipients(pos, [1], {}, {}, {})
	assert_true(1 in r, "the dying player receives its own death event")
	assert_true(2 in r, "a same-region peer receives it")
	assert_false(3 in r, "the far-region Ashmoor peer does NOT receive it")


func test_cross_region_party_member_still_receives() -> void:
	var pos := {1: _at(0, 0), 2: _at(-420, 0)}  # party-mate 2 is in Ashmoor (a far region)
	var party_of := {1: 7, 2: 7}
	var parties := {7: {"members": [1, 2]}}
	var r: Array = _BB.event_recipients(pos, [1], party_of, parties, {})
	assert_true(2 in r, "a party-mate in another region still gets the event (union)")


func test_involved_caster_and_target_always_receive_across_region() -> void:
	# A cross-region ability result: caster (era-1) hits target (Ashmoor). Both are involved.
	var pos := {1: _at(0, 0), 2: _at(-420, 0)}
	var r: Array = _BB.event_recipients(pos, [1, 2], {}, {}, {})
	assert_true(1 in r and 2 in r, "both the caster and the target receive it regardless of region")


func test_mob_entity_id_in_involved_is_not_a_recipient() -> void:
	# A combat relay passes [caster, target]; when one side is a mob its entity_id is NOT a peer.
	var pos := {1: _at(0, 0)}
	var r: Array = _BB.event_recipients(pos, [1, 5001], {}, {}, {})
	assert_eq(r, [1], "the non-peer mob entity_id drops out — never an rpc_id to a non-peer")


func test_explicit_origin_scopes_the_region_for_a_mob_event() -> void:
	# Mob death/respawn have no involved player — the origin is the mob's world point.
	var pos := {1: _at(5, -3), 2: _at(-420, 0)}  # 1 near the village mob, 2 in Ashmoor
	var r: Array = _BB.event_recipients(pos, [], {}, {}, {"iid": 0, "x": 5.0, "z": -3.0})
	assert_true(1 in r, "the same-region peer sees the mob event")
	assert_false(2 in r, "the Ashmoor peer does not")


func test_instance_isolation_holds_for_events() -> void:
	# Two peers co-located but in different instances — a mob event in instance 0 reaches only inst-0.
	var pos := {1: _at(0, 0, 0), 2: _at(0, 0, 5)}
	var r: Array = _BB.event_recipients(pos, [], {}, {}, {"iid": 0, "x": 0.0, "z": 0.0})
	assert_eq(r, [1], "only the same-instance peer receives the event")


func test_offline_party_member_is_never_a_recipient() -> void:
	# A party record may name a peer that is not in the live positions snapshot — guard the rpc.
	var pos := {1: _at(0, 0)}
	var party_of := {1: 7}
	var parties := {7: {"members": [1, 99]}}  # 99 is not connected
	var r: Array = _BB.event_recipients(pos, [1], party_of, parties, {})
	assert_eq(r, [1], "an absent party member is not returned (only connected peers)")
