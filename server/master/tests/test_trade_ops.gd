extends GutTest

# T-363: the master trade coordinator end-to-end against the in-memory store — the race/atomicity
# vectors that live ABOVE the pure state machine: double-confirm commits exactly once, an aborted
# commit moves nothing, cancel/disconnect moves nothing, identity is whatever the world resolved.

const CharacterManager = preload("res://scripts/character_manager.gd")
const TradeOpsScript = preload("res://scripts/trade_ops.gd")

const REG := {
	"wolf_pelt": {"slot": "none", "stackable": true, "max_stack": 10, "armor_type": "none"},
	"iron_sword": {"slot": "weapon", "stackable": false, "max_stack": 1, "armor_type": "none"},
}

var _ops = null


func before_each() -> void:
	CharacterManager.reset_for_test()
	_ops = TradeOpsScript.new()


func _cid(username: String) -> int:
	CharacterManager.ensure_character(username)
	return int(CharacterManager.get_character(username)["id"])


func _pelts(cid: int) -> int:
	var n := 0
	for e in CharacterManager.get_inventory(cid):
		if str(e["item_id"]) == "wolf_pelt":
			n += int(e["item_count"])
	return n


# alice(5 pelts, offers 3) <-> bob(100 coins, offers 40); both confirmed by the end.
func _staged_trade() -> Dictionary:
	var a := _cid("alice")
	var b := _cid("bob")
	CharacterManager.add_item_to_bag(a, "wolf_pelt", 5, 0)
	assert_false(_ops.op({"username": "alice", "action": "request"}).has("views"), "needs target")
	var r: Dictionary = _ops.op(
		{"username": "alice", "action": "request", "target_username": "bob"}
	)
	assert_true(r.has("views"), "request opens a session: %s" % str(r))
	assert_true(_ops.op({"username": "bob", "action": "accept"}).has("views"))
	r = _ops.op({"username": "alice", "action": "offer_item", "slot_index": 0, "count": 3})
	assert_true(r.has("views"), "offer_item accepted: %s" % str(r))
	r = _ops.op({"username": "bob", "action": "offer_coins", "amount": 40})
	assert_true(r.has("views"), "offer_coins accepted: %s" % str(r))
	return {"a": a, "b": b}


func test_double_confirm_commits_exactly_once() -> void:
	var ids := _staged_trade()
	var r1: Dictionary = _ops.op({"username": "alice", "action": "confirm", "item_registry": REG})
	assert_false(bool(r1.get("completed", false)), "first confirm must NOT commit")
	var r2: Dictionary = _ops.op({"username": "bob", "action": "confirm", "item_registry": REG})
	assert_true(bool(r2.get("completed", false)), "second confirm commits: %s" % str(r2))
	# The swap happened once: 3 pelts moved, 40 coins moved.
	assert_eq(_pelts(int(ids["a"])), 2)
	assert_eq(_pelts(int(ids["b"])), 3)
	assert_eq(ServicesStore.get_coins(int(ids["a"])), 140)
	assert_eq(ServicesStore.get_coins(int(ids["b"])), 60)
	# The RACE: a third confirm (replayed packet / double-click) finds no session — no re-commit.
	var r3: Dictionary = _ops.op({"username": "alice", "action": "confirm", "item_registry": REG})
	assert_true(r3.has("error"), "CRIT: a replayed confirm after commit must be rejected")
	assert_eq(_pelts(int(ids["a"])), 2, "CRIT: replay must not move items again (dupe)")
	assert_eq(ServicesStore.get_coins(int(ids["a"])), 140, "CRIT: replay must not re-pay")


func test_item_vanishing_mid_trade_aborts_with_nothing_moved() -> void:
	var ids := _staged_trade()
	_ops.op({"username": "alice", "action": "confirm", "item_registry": REG})
	# Alice's pelts vanish between her confirm and Bob's (e.g. a parallel vendor/vault op).
	CharacterManager.try_remove_item(int(ids["a"]), "bag", 0, 5)
	var r: Dictionary = _ops.op({"username": "bob", "action": "confirm", "item_registry": REG})
	assert_true(bool(r.get("ended", false)))
	assert_false(bool(r.get("completed", false)), "CRIT: committed a vanished stack")
	assert_eq(str(r.get("reason", "")), "aborted_item_gone")
	assert_eq(ServicesStore.get_coins(int(ids["b"])), 100, "coins untouched on abort")
	assert_eq(_pelts(int(ids["b"])), 0, "items untouched on abort")


func test_cancel_mid_trade_moves_nothing_and_frees_both() -> void:
	var ids := _staged_trade()
	_ops.op({"username": "alice", "action": "confirm", "item_registry": REG})
	var r: Dictionary = _ops.op({"username": "bob", "action": "cancel"})
	assert_true(bool(r.get("ended", false)))
	assert_eq(_pelts(int(ids["a"])), 5, "staging is never an escrow — cancel costs nothing")
	assert_eq(ServicesStore.get_coins(int(ids["b"])), 100)
	# Both can trade again.
	var again: Dictionary = _ops.op(
		{"username": "bob", "action": "request", "target_username": "alice"}
	)
	assert_true(again.has("views"), "both parties freed after cancel")


func test_offer_rejections_ride_through_ops() -> void:
	_staged_trade()
	var r: Dictionary = _ops.op(
		{"username": "alice", "action": "offer_item", "slot_index": 9, "count": 1}
	)
	assert_eq(str(r.get("error", "")), "not_owned", "unowned slot rejected at the op layer")
	r = _ops.op({"username": "bob", "action": "offer_coins", "amount": 99999})
	assert_eq(str(r.get("error", "")), "insufficient_coins")
	r = _ops.op({"username": "alice", "action": "request", "target_username": "alice"})
	assert_true(r.has("error"), "self-trade rejected (already_trading here; self_trade when free)")


func test_unknown_target_and_actor_rejected() -> void:
	_cid("alice")
	var r: Dictionary = _ops.op(
		{"username": "alice", "action": "request", "target_username": "nobody"}
	)
	assert_eq(str(r.get("error", "")), "unknown_target", "target must be a persisted character")
	r = _ops.op({"username": "", "action": "confirm"})
	assert_true(r.has("error"), "empty/unresolved actor is rejected")


func test_view_carries_only_server_truth() -> void:
	_staged_trade()
	var r: Dictionary = _ops.op({"username": "alice", "action": "unconfirm"})
	var view: Dictionary = {}
	for entry in r.get("views", []):
		if str(entry["username"]) == "alice":
			view = entry["view"]
	assert_eq(str(view.get("partner", "")), "bob")
	assert_eq(int(view["mine"]["items"][0]["count"]), 3)
	assert_eq(str(view["mine"]["items"][0]["item_id"]), "wolf_pelt", "resolved from SERVER bag")
	assert_eq(int(view["theirs"]["coins"]), 40)
	assert_eq(view["my_bag"].size(), 1, "own-bag snapshot rides the view (server-fed panel)")
