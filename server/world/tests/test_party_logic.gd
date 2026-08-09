extends GutTest
# T-280: server party roster ops (pure) — invite/accept/leave/disband, the WoW rules.

const _PL = preload("res://scripts/party_logic.gd")


func test_invite_accept_forms_a_party() -> void:
	var s := _PL.new_store()
	assert_true(_PL.invite(s, 1, 2)["ok"], "leader-less invite is allowed")
	assert_eq(s["pending"].get(2, {}).get("from"), 1, "invitee has a pending invite")
	var r := _PL.accept(s, 2)
	assert_true(r["ok"])
	var pid: int = int(r["party_id"])
	assert_eq(s["party_of"][1], pid, "inviter joined its own new party")
	assert_eq(s["party_of"][2], pid, "invitee joined")
	assert_eq(s["parties"][pid]["members"].size(), 2)
	assert_eq(int(s["parties"][pid]["leader"]), 1, "inviter is leader")


func test_cannot_invite_someone_already_partied() -> void:
	var s := _PL.new_store()
	_PL.accept(s, 2) if false else _PL.invite(s, 1, 2)
	_PL.accept(s, 2)
	assert_false(_PL.invite(s, 5, 2)["ok"], "already-partied target rejected")


func test_party_full_at_five() -> void:
	var s := _PL.new_store()
	for m in [2, 3, 4]:
		_PL.invite(s, 1, m)
		_PL.accept(s, m)  # 1,2,3,4 = 4 members
	_PL.invite(s, 1, 5)
	_PL.accept(s, 5)  # 5 members
	assert_eq(_PL.invite(s, 1, 6)["reason"], "party_full")


func test_non_leader_cannot_invite() -> void:
	var s := _PL.new_store()
	_PL.invite(s, 1, 2)
	_PL.accept(s, 2)
	assert_eq(_PL.invite(s, 2, 3)["reason"], "not_leader")


func test_leave_promotes_leader_then_autodisbands_at_one() -> void:
	var s := _PL.new_store()
	for m in [2, 3]:
		_PL.invite(s, 1, m)
		_PL.accept(s, m)  # party of 1(leader),2,3
	var pid: int = int(s["party_of"][1])
	_PL.leave(s, 1)  # leader leaves -> promote 2
	assert_eq(int(s["parties"][pid]["leader"]), 2, "next member promoted to leader")
	assert_false(s["party_of"].has(1))
	_PL.leave(s, 2)  # down to just member 3 -> auto-disband
	assert_false(s["parties"].has(pid), "party of one auto-disbands")
	assert_false(s["party_of"].has(3), "the lone member is released")


func test_disband_only_by_leader() -> void:
	var s := _PL.new_store()
	_PL.invite(s, 1, 2)
	_PL.accept(s, 2)
	assert_eq(_PL.disband(s, 2)["reason"], "not_leader")
	assert_true(_PL.disband(s, 1)["ok"])
	assert_true(s["parties"].is_empty() and s["party_of"].is_empty())


func test_decline_leaves_no_party() -> void:
	var s := _PL.new_store()
	_PL.invite(s, 1, 2)
	_PL.decline(s, 2)
	assert_false(s["pending"].has(2))
	assert_true(s["parties"].is_empty(), "a declined invite creates no party")


# ---- T-293: party-wide kill credit --------------------------------------


func _party_of_two() -> Dictionary:
	var s := _PL.new_store()
	_PL.invite(s, 1, 2)
	_PL.accept(s, 2)  # party = {1 (leader), 2}
	return s


func test_credit_attacker_with_no_party_is_solo() -> void:
	var s := _PL.new_store()
	var r: Array = _PL.credit_recipients(s, [1], {1: Vector3.ZERO}, [1], Vector3.ZERO, 60.0)
	assert_eq(r, [1], "a partyless attacker credits only themselves")


func test_credit_shares_to_alive_in_range_partymate() -> void:
	var s := _party_of_two()
	# Only peer 1 tagged the mob; peer 2 is a party-mate standing 10m away, alive.
	var r: Array = _PL.credit_recipients(
		s, [1], {1: Vector3(1, 0, 0), 2: Vector3(10, 0, 0)}, [1, 2], Vector3.ZERO, 60.0
	)
	assert_true(r.has(1) and r.has(2), "the untagged but present party-mate is credited")
	assert_eq(r.size(), 2)


func test_credit_excludes_dead_partymate() -> void:
	var s := _party_of_two()
	var r: Array = _PL.credit_recipients(
		s, [1], {1: Vector3(1, 0, 0), 2: Vector3(10, 0, 0)}, [1], Vector3.ZERO, 60.0
	)
	assert_eq(r, [1], "a dead party-mate (not in alive list) earns no credit")


func test_credit_excludes_out_of_range_partymate() -> void:
	var s := _party_of_two()
	var r: Array = _PL.credit_recipients(
		s, [1], {1: Vector3(1, 0, 0), 2: Vector3(500, 0, 0)}, [1, 2], Vector3.ZERO, 60.0
	)
	assert_eq(r, [1], "a party-mate beyond the credit radius earns no credit")


func test_credit_two_parties_both_earn() -> void:
	# Two separate parties both engage the same elite — participation, not first-tap: both credited.
	var s := _PL.new_store()
	_PL.invite(s, 1, 2)
	_PL.accept(s, 2)  # party A = {1,2}
	_PL.invite(s, 3, 4)
	_PL.accept(s, 4)  # party B = {3,4}
	var pos := {1: Vector3.ZERO, 2: Vector3(5, 0, 0), 3: Vector3(5, 0, 0), 4: Vector3(8, 0, 0)}
	# One attacker from each party tagged the mob.
	var r: Array = _PL.credit_recipients(s, [1, 3], pos, [1, 2, 3, 4], Vector3.ZERO, 60.0)
	for pid in [1, 2, 3, 4]:
		assert_true(r.has(pid), "both parties' members credited: %d" % pid)
