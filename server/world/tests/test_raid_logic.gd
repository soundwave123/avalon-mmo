extends GutTest
# T-472: raid container ops (raid_logic.gd + the party_logic raid-aware seams) — promotion,
# 10-cap, subgroup seating/moves, assist/kick authority, removal hygiene, raid-wide kill
# credit, and the T-452 mentorship-ceiling composition. Pure store tests, no scene tree.

const _PL = preload("res://scripts/party_logic.gd")
const _RL = preload("res://scripts/raid_logic.gd")
const _SYNC = preload("res://scripts/combat/mentorship_sync.gd")


# A party of `n` peers 1..n led by 1.
func _party_of(n: int) -> Dictionary:
	var s := _PL.new_store()
	for m in range(2, n + 1):
		_PL.invite(s, 1, m)
		_PL.accept(s, m)
	return s


# A full 10-man raid of peers 1..10 (led by 1, converted at 5, grown to 10).
func _raid_of_ten() -> Dictionary:
	var s := _party_of(5)
	_RL.convert(s, 1)
	for m in range(6, 11):
		_PL.invite(s, 1, m)
		_PL.accept(s, m)
	return s


func test_convert_promotes_the_party_in_place() -> void:
	var s := _party_of(3)
	var pid: int = int(s["party_of"][1])
	var r := _RL.convert(s, 1)
	assert_true(r["ok"])
	assert_eq(int(r["party_id"]), pid, "a raid keeps the SAME party_id (promotion, not new object)")
	assert_true(_RL.is_raid(s, 2), "every member is now raid-flagged")
	var party: Dictionary = s["parties"][pid]
	assert_eq(int(party["cap"]), _RL.MAX_RAID)
	for m in [1, 2, 3]:
		assert_eq(int(party["subgroup"][m]), 0, "existing members all seat in subgroup 0")


func test_convert_requires_leader_and_a_party() -> void:
	var s := _party_of(3)
	assert_eq(_RL.convert(s, 2)["reason"], "not_leader", "a member cannot promote the party")
	assert_eq(_RL.convert(s, 99)["reason"], "not_in_party", "an outsider cannot promote anything")
	_RL.convert(s, 1)
	assert_eq(_RL.convert(s, 1)["reason"], "already_raid", "double-convert rejected")


func test_raid_grows_to_ten_and_rejects_the_eleventh() -> void:
	var s := _raid_of_ten()
	var pid: int = int(s["party_of"][1])
	assert_eq(s["parties"][pid]["members"].size(), 10, "raid holds ten")
	_PL.invite(s, 1, 11)
	assert_eq(_PL.invite(s, 1, 11)["reason"], "party_full", "11th invite rejected at cap")
	s["pending"][11] = {"party_id": pid, "from": 1}  # forge a pending invite anyway
	assert_eq(_PL.accept(s, 11)["reason"], "party_full", "11th accept rejected server-side")
	assert_eq(s["parties"][pid]["members"].size(), 10)


func test_joiners_auto_fill_two_subgroups_of_five() -> void:
	var s := _raid_of_ten()
	var party: Dictionary = s["parties"][int(s["party_of"][1])]
	for m in range(1, 6):
		assert_eq(int(party["subgroup"][m]), 0, "first five seat in subgroup 0")
	for m in range(6, 11):
		assert_eq(int(party["subgroup"][m]), 1, "next five overflow into subgroup 1")


func test_plain_party_still_caps_at_five() -> void:
	var s := _party_of(5)
	assert_eq(_PL.invite(s, 1, 6)["reason"], "party_full", "unconverted party keeps MAX_PARTY")


func test_set_subgroup_moves_a_member() -> void:
	var s := _party_of(3)
	_RL.convert(s, 1)
	assert_true(_RL.set_subgroup(s, 1, 3, 1)["ok"])
	var party: Dictionary = s["parties"][int(s["party_of"][1])]
	assert_eq(int(party["subgroup"][3]), 1, "member 3 seated in subgroup 1")
	# The freed seat in group 0 is reused by the next joiner before group 1 grows further.
	_PL.invite(s, 1, 4)
	_PL.accept(s, 4)
	assert_eq(int(party["subgroup"][4]), 0, "auto-fill reuses the open seat in subgroup 0")


func test_set_subgroup_rejects_full_group_and_bad_index() -> void:
	var s := _raid_of_ten()
	assert_eq(_RL.set_subgroup(s, 1, 6, 0)["reason"], "group_full", "no sixth seat in a subgroup")
	assert_eq(_RL.set_subgroup(s, 1, 6, 2)["reason"], "bad_group", "forged group index rejected")
	assert_eq(_RL.set_subgroup(s, 1, 6, -1)["reason"], "bad_group")


func test_set_subgroup_authority_is_leader_or_assist() -> void:
	var s := _raid_of_ten()
	assert_eq(_RL.set_subgroup(s, 6, 6, 0)["reason"], "not_leader", "a member cannot move itself")
	assert_eq(_RL.set_subgroup(s, 99, 6, 0)["reason"], "not_in_party", "an outsider cannot move")
	_RL.set_assist(s, 1, 2, true)
	_RL.set_subgroup(s, 1, 6, 1)  # no-op move to make room deterministic
	assert_true(_RL.set_subgroup(s, 2, 2, 1)["reason"] == "group_full", "assist HAS move authority")


func test_assist_role_is_leader_managed() -> void:
	var s := _party_of(4)
	_RL.convert(s, 1)
	assert_eq(_RL.set_assist(s, 2, 3, true)["reason"], "not_leader", "member cannot grant assist")
	assert_eq(_RL.set_assist(s, 1, 1, true)["reason"], "leader_is_not_assist")
	assert_true(_RL.set_assist(s, 1, 2, true)["ok"])
	assert_true(_PL.invite(s, 2, 5)["ok"], "an assist may invite into the raid")
	assert_true(_RL.set_assist(s, 1, 2, false)["ok"])
	assert_eq(_PL.invite(s, 2, 6)["reason"], "not_leader", "revoked assist loses invite authority")


func test_kick_semantics_leader_and_assist() -> void:
	var s := _raid_of_ten()
	_RL.set_assist(s, 1, 2, true)
	assert_eq(_RL.kick(s, 1, 1)["reason"], "cannot_kick_self")
	assert_eq(_RL.kick(s, 2, 1)["reason"], "cannot_kick_officer", "assist cannot kick the leader")
	_RL.set_assist(s, 1, 3, true)
	assert_eq(_RL.kick(s, 2, 3)["reason"], "cannot_kick_officer", "assist cannot kick an assist")
	assert_eq(_RL.kick(s, 6, 7)["reason"], "not_leader", "rank-and-file cannot kick")
	assert_true(_RL.kick(s, 2, 7)["ok"], "assist kicks rank-and-file")
	assert_true(_RL.kick(s, 1, 3)["ok"], "leader kicks an assist")
	var party: Dictionary = s["parties"][int(s["party_of"][1])]
	assert_eq(party["members"].size(), 8)
	assert_false(s["party_of"].has(7), "kicked peer is out of the store")
	assert_false(party["subgroup"].has(7), "kicked peer's subgroup seat is freed")
	assert_false(party["assists"].has(3), "kicked assist is off the assist list")


func test_leave_cleans_raid_maps_and_promotes_leader() -> void:
	var s := _raid_of_ten()
	_RL.set_assist(s, 1, 2, true)
	var pid: int = int(s["party_of"][1])
	_PL.leave(s, 2)
	var party: Dictionary = s["parties"][pid]
	assert_false(party["subgroup"].has(2), "leaver's seat is freed")
	assert_false(party["assists"].has(2), "leaver's assist role is dropped")
	_PL.leave(s, 1)
	assert_eq(int(party["leader"]), 3, "leader leaving promotes the next member (party rule)")
	assert_true(_RL.is_raid(s, 3), "the raid survives the leader change")


func test_raid_autodisbands_at_one_member_like_a_party() -> void:
	var s := _party_of(2)
	_RL.convert(s, 1)
	var r := _PL.leave(s, 2)
	assert_true(r.has("disbanded"), "dropping to one member disbands the raid record")
	assert_true(s["parties"].is_empty())
	assert_true(s["party_of"].is_empty())


func test_kill_credit_spans_the_whole_raid_once_each() -> void:
	var s := _raid_of_ten()
	var positions := {}
	var alive := []
	for m in range(1, 11):
		positions[m] = Vector3(float(m), 0.0, 0.0)  # everyone within radius
		alive.append(m)
	# Attackers from BOTH subgroups: dedup must hold across the single raid structure.
	var credited := _PL.credit_recipients(s, [1, 6, 1], positions, alive, Vector3.ZERO, 60.0)
	credited.sort()
	assert_eq(credited, [1, 2, 3, 4, 5, 6, 7, 8, 9, 10], "all ten credited exactly once")


func test_kill_credit_excludes_dead_and_far_raid_members() -> void:
	var s := _raid_of_ten()
	var positions := {}
	var alive := []
	for m in range(1, 11):
		positions[m] = Vector3(1000.0, 0.0, 0.0) if m == 10 else Vector3(float(m), 0.0, 0.0)
		if m != 9:
			alive.append(m)
	var credited := _PL.credit_recipients(s, [1], positions, alive, Vector3.ZERO, 60.0)
	credited.sort()
	assert_eq(credited, [1, 2, 3, 4, 5, 6, 7, 8], "dead (9) and out-of-range (10) earn nothing")


# T-452 composition: a synced mentor inside a raid is capped by the lowest TRUE level of the
# WHOLE raid (conservative — a subgroup shuffle can never raise the ceiling).
func test_mentorship_ceiling_spans_the_raid() -> void:
	var s := _raid_of_ten()
	var true_levels := {}
	for m in range(1, 11):
		true_levels[m] = 40
	true_levels[7] = 6  # the lowest true level sits in subgroup 1
	var ceiling: int = _SYNC.ceiling_for(1, s, true_levels, {1: true})
	assert_eq(ceiling, 6, "opted-in mentor in subgroup 0 syncs to subgroup 1's lowbie")
	_RL.set_subgroup(s, 1, 7, 1)  # explicit reseat does not change the raid-wide ceiling
	assert_eq(_SYNC.ceiling_for(1, s, true_levels, {1: true}), 6)
	assert_eq(_SYNC.ceiling_for(2, s, true_levels, {}), 40, "opted-out member keeps true level")
