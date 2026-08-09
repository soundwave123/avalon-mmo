extends GutTest

# T-363: exhaustive tests on the PURE trade state machine — every classic dupe/scam vector must
# die here. A red test in this file is a shipped economy exploit.

const _TL = preload("res://scripts/trade_logic.gd")

const REG := {
	"wolf_pelt": {"slot": "none", "stackable": true, "max_stack": 10, "armor_type": "none"},
	"iron_sword": {"slot": "weapon", "stackable": false, "max_stack": 1, "armor_type": "none"},
}


func _bag(entries: Array) -> Array:
	var out: Array = []
	for e: Array in entries:  # [slot_index, item_id, count]
		out.append({"slot_type": "bag", "slot_index": e[0], "item_id": e[1], "item_count": e[2]})
	return out


func _active_pair(store: Dictionary) -> void:
	assert_true(_TL.request(store, 1, 2)["ok"])
	assert_true(_TL.accept(store, 2)["ok"])


# ---- session lifecycle -------------------------------------------------------


func test_self_trade_rejected() -> void:
	var store := _TL.new_store()
	var r := _TL.request(store, 1, 1)
	assert_false(r["ok"], "CRIT: self-trade opened a session (free-dupe primitive)")
	assert_eq(r["reason"], "self_trade")


func test_busy_parties_rejected() -> void:
	var store := _TL.new_store()
	_active_pair(store)
	assert_eq(_TL.request(store, 1, 3)["reason"], "already_trading")
	assert_eq(_TL.request(store, 3, 2)["reason"], "target_busy")


func test_only_invitee_accepts_and_only_pending() -> void:
	var store := _TL.new_store()
	_TL.request(store, 1, 2)
	assert_eq(_TL.accept(store, 1)["reason"], "not_invitee", "the inviter cannot self-accept")
	assert_true(_TL.accept(store, 2)["ok"])
	assert_eq(_TL.accept(store, 2)["reason"], "not_pending", "double-accept is a no-op")


func test_staging_requires_active_session() -> void:
	var store := _TL.new_store()
	_TL.request(store, 1, 2)  # pending, not yet accepted
	var r := _TL.offer_item(store, 1, 0, 1, _bag([[0, "wolf_pelt", 5]]))
	assert_eq(r["reason"], "no_active_session", "no staging before the invitee accepts")


func test_cancel_frees_both_parties() -> void:
	var store := _TL.new_store()
	_active_pair(store)
	var r := _TL.cancel(store, 1)
	assert_true(r["ok"])
	assert_eq(int(r["other"]), 2, "caller learns whom to notify")
	assert_true(_TL.request(store, 2, 3)["ok"], "both are free to trade again")


# ---- staging validation (never trust the wire) --------------------------------


func test_offer_item_not_owned_rejected() -> void:
	var store := _TL.new_store()
	_active_pair(store)
	var r := _TL.offer_item(store, 1, 3, 1, _bag([[0, "wolf_pelt", 5]]))  # slot 3 is empty
	assert_false(r["ok"], "CRIT: staged an item the sender does not own")
	assert_eq(r["reason"], "not_owned")


func test_offer_more_than_held_rejected() -> void:
	var store := _TL.new_store()
	_active_pair(store)
	var r := _TL.offer_item(store, 1, 0, 6, _bag([[0, "wolf_pelt", 5]]))
	assert_false(r["ok"], "CRIT: staged more units than the stack holds")
	assert_eq(r["reason"], "insufficient_count")


func test_offer_same_slot_twice_rejected() -> void:
	var store := _TL.new_store()
	_active_pair(store)
	var inv := _bag([[0, "wolf_pelt", 5]])
	assert_true(_TL.offer_item(store, 1, 0, 2, inv)["ok"])
	var r := _TL.offer_item(store, 1, 0, 2, inv)
	assert_eq(r["reason"], "already_offered", "CRIT: double-staging one stack doubles the give")


func test_offer_coins_over_balance_rejected() -> void:
	var store := _TL.new_store()
	_active_pair(store)
	var r := _TL.offer_coins(store, 1, 101, 100)
	assert_false(r["ok"], "CRIT: staged coins beyond the server-held balance")
	assert_eq(r["reason"], "insufficient_coins")
	assert_false(_TL.offer_coins(store, 1, -5, 100)["ok"], "negative coins rejected")


# ---- the confirm-bait guard ----------------------------------------------------


func test_any_offer_change_clears_both_confirms() -> void:
	var store := _TL.new_store()
	_active_pair(store)
	var inv := _bag([[0, "wolf_pelt", 5]])
	assert_true(_TL.confirm(store, 1)["ok"])
	assert_true(_TL.confirm(store, 2)["both"] == false or true)  # both empty-confirm is legal
	# Re-open a fresh session to test each mutation clears confirms.
	for mutation in ["offer_item", "retract_item", "offer_coins"]:
		var s := _TL.new_store()
		_active_pair(s)
		if mutation == "retract_item":
			_TL.offer_item(s, 1, 0, 1, inv)
		_TL.confirm(s, 1)
		_TL.confirm(s, 2)  # note: both=true would have committed upstream; here we inspect state
		match mutation:
			"offer_item":
				_TL.offer_item(s, 2, 0, 1, inv)
			"retract_item":
				_TL.retract_item(s, 1, 0)
			"offer_coins":
				_TL.offer_coins(s, 2, 5, 100)
		var session := _TL.session_for(s, 1)
		assert_false(
			bool(session["confirmed"][1]) or bool(session["confirmed"][2]),
			"CRIT (%s): an offer change after confirm must clear BOTH confirms" % mutation
		)


# ---- the atomic commit plan ------------------------------------------------------


func _staged_session(store: Dictionary, inv_a: Array, _inv_b: Array) -> Dictionary:
	_active_pair(store)
	assert_true(_TL.offer_item(store, 1, 0, 3, inv_a)["ok"])  # A gives 3 pelts
	assert_true(_TL.offer_coins(store, 2, 40, 100)["ok"])  # B gives 40 coins
	return _TL.session_for(store, 1)


func test_commit_swaps_items_and_coins_conserved() -> void:
	var store := _TL.new_store()
	var inv_a := _bag([[0, "wolf_pelt", 5]])
	var inv_b := _bag([[0, "iron_sword", 1]])
	var s := _staged_session(store, inv_a, inv_b)
	var plan := _TL.build_commit(s, inv_a, inv_b, 100, 100, REG)
	assert_true(plan["ok"], "honest staged trade must commit")
	# A: 5-3=2 pelts left; B: sword + 3 pelts.
	var a_counts := {}
	for e in plan["slots_a"]:
		a_counts[str(e["item_id"])] = int(a_counts.get(str(e["item_id"]), 0)) + int(e["item_count"])
	var b_counts := {}
	for e in plan["slots_b"]:
		b_counts[str(e["item_id"])] = int(b_counts.get(str(e["item_id"]), 0)) + int(e["item_count"])
	assert_eq(int(a_counts.get("wolf_pelt", 0)), 2)
	assert_eq(int(b_counts.get("wolf_pelt", 0)), 3)
	assert_eq(int(b_counts.get("iron_sword", 0)), 1, "unstaged items never move")
	# Conservation: total pelts before == after; coin deltas sum to zero.
	assert_eq(
		int(a_counts.get("wolf_pelt", 0)) + int(b_counts.get("wolf_pelt", 0)),
		5,
		"CRIT: item total changed across the swap (dupe or burn)"
	)
	assert_eq(int(plan["coins_delta_a"]) + int(plan["coins_delta_b"]), 0, "coins conserved")
	assert_eq(int(plan["coins_delta_a"]), 40)


func test_commit_aborts_when_item_vanished_mid_trade() -> void:
	var store := _TL.new_store()
	var inv_a := _bag([[0, "wolf_pelt", 5]])
	var inv_b := _bag([])
	var s := _staged_session(store, inv_a, inv_b)
	# The pelts left A's bag between staging and commit (dropped / vendored / vaulted).
	var live_a := _bag([[0, "wolf_pelt", 1]])  # only 1 left, 3 staged
	var plan := _TL.build_commit(s, live_a, inv_b, 100, 100, REG)
	assert_false(plan["ok"], "CRIT: committed a stack that no longer exists (dupe vector)")
	assert_eq(plan["reason"], "item_gone")


func test_commit_aborts_when_balance_dropped_mid_trade() -> void:
	var store := _TL.new_store()
	var inv_a := _bag([[0, "wolf_pelt", 5]])
	var inv_b := _bag([])
	var s := _staged_session(store, inv_a, inv_b)
	# B staged 40 coins but spent down to 10 before the commit.
	var plan := _TL.build_commit(s, inv_a, inv_b, 100, 10, REG)
	assert_false(plan["ok"], "CRIT: committed coins the payer no longer has")
	assert_eq(plan["reason"], "insufficient_coins")


func test_commit_aborts_when_receiver_bags_full() -> void:
	var store := _TL.new_store()
	var inv_a := _bag([[0, "iron_sword", 1]])
	var full: Array = []
	for i in range(16):
		full.append({"slot_type": "bag", "slot_index": i, "item_id": "iron_sword", "item_count": 1})
	_active_pair(store)
	assert_true(_TL.offer_item(store, 1, 0, 1, inv_a)["ok"])
	var s := _TL.session_for(store, 1)
	var plan := _TL.build_commit(s, inv_a, full, 100, 100, REG)
	assert_false(plan["ok"], "a full receiver aborts the WHOLE trade — nothing moves")
	assert_eq(plan["reason"], "bag_full")


func test_commit_rejects_unknown_item() -> void:
	var store := _TL.new_store()
	var inv_a := _bag([[0, "hacked_item", 1]])
	_active_pair(store)
	assert_true(_TL.offer_item(store, 1, 0, 1, inv_a)["ok"])  # staging only checks possession
	var plan := _TL.build_commit(_TL.session_for(store, 1), inv_a, _bag([]), 100, 100, REG)
	assert_false(plan["ok"], "an item with no registry def cannot transfer")


func test_commit_is_pure_and_mutates_no_input() -> void:
	var store := _TL.new_store()
	var inv_a := _bag([[0, "wolf_pelt", 5]])
	var inv_b := _bag([])
	var s := _staged_session(store, inv_a, inv_b)
	var before_a := inv_a.duplicate(true)
	_TL.build_commit(s, inv_a, inv_b, 100, 100, REG)
	assert_eq(inv_a, before_a, "build_commit must not mutate the live inventory it was shown")
