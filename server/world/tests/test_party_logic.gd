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


# ---- T-736: invite expiry, one-pending-per-invitee, decline cooldown ---------


func test_expired_invite_cannot_be_accepted_but_frees_the_slot() -> void:
	var s := _PL.new_store()
	assert_true(_PL.invite(s, 1, 2, 1000, "a>b")["ok"])
	var late: int = 1000 + _PL.INVITE_TTL_MS + 1
	assert_eq(_PL.accept(s, 2, late)["reason"], "invite_expired", "a lapsed offer is gone")
	assert_false(s["pending"].has(2), "the lapsed pending is pruned on accept")
	assert_true(_PL.invite(s, 1, 2, late, "a>b")["ok"], "the slot is free again after the lapse")
	assert_true(_PL.accept(s, 2, late + 10)["ok"], "a fresh invite accepts normally")


func test_second_suitor_refused_while_an_invite_is_pending() -> void:
	var s := _PL.new_store()
	assert_true(_PL.invite(s, 1, 2, 1000, "a>b")["ok"])
	assert_eq(_PL.invite(s, 3, 2, 2000, "c>b")["reason"], "invite_pending", "one at a time")
	# ...but once the first lapses, the second suitor gets through (lapse pruned lazily).
	var late: int = 1000 + _PL.INVITE_TTL_MS + 1
	assert_true(_PL.invite(s, 3, 2, late, "c>b")["ok"], "a lapsed pending no longer blocks")
	assert_eq(int(s["pending"][2]["from"]), 3, "the live offer is the second suitor's")


func test_three_declines_arm_the_cooldown_for_that_pair_only() -> void:
	var s := _PL.new_store()
	for i in range(_PL.DECLINE_LIMIT):
		var t: int = 1000 * (i + 1)
		assert_true(_PL.invite(s, 1, 2, t, "a>b")["ok"], "invite %d allowed" % (i + 1))
		assert_true(_PL.decline(s, 2, t + 10)["ok"])
	var blocked := _PL.invite(s, 1, 2, 5000, "a>b")
	assert_eq(blocked["reason"], "invite_cooldown", "the pair is on cooldown after 3 declines")
	assert_false(s["pending"].has(2), "a blocked invite leaves NOTHING pending for the decliner")
	# The cooldown is per inviter->target pair: another inviter may still ask.
	assert_true(_PL.invite(s, 3, 2, 5000, "c>b")["ok"], "a different inviter is not throttled")
	# ...and the throttled inviter may still ask someone else.
	assert_true(_PL.invite(s, 1, 4, 5000, "a>d")["ok"], "a different target is not throttled")


func test_cooldown_lapses_into_a_fresh_decline_budget() -> void:
	var s := _PL.new_store()
	for i in range(_PL.DECLINE_LIMIT):
		_PL.invite(s, 1, 2, 1000 + i, "a>b")
		_PL.decline(s, 2, 1000 + i)
	var last_decline: int = 1000 + _PL.DECLINE_LIMIT - 1
	var after: int = last_decline + _PL.DECLINE_COOLDOWN_MS + 1
	assert_eq(_PL.invite(s, 1, 2, after - 2, "a>b")["reason"], "invite_cooldown", "still armed")
	assert_true(_PL.invite(s, 1, 2, after, "a>b")["ok"], "a lapsed cooldown unblocks")
	assert_false(s["declines"].has("a>b"), "the lapsed ledger row is pruned (fresh budget)")


func test_timeout_is_not_a_decline() -> void:
	var s := _PL.new_store()
	for i in range(10):  # let 10 invites lapse unanswered — far past DECLINE_LIMIT
		var t: int = 1 + i * (_PL.INVITE_TTL_MS + 5)
		assert_true(_PL.invite(s, 1, 2, t, "a>b")["ok"], "lapse %d never arms a cooldown" % i)
	assert_true(s["declines"].is_empty(), "unanswered invites feed no decline ledger")


func test_stray_decline_with_nothing_pending_bumps_nothing() -> void:
	var s := _PL.new_store()
	assert_true(_PL.decline(s, 2, 1000)["ok"], "a stray /party decline stays a harmless no-op")
	assert_true(s["declines"].is_empty())


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
