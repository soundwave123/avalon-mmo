extends GutTest

# T-430: master-owned vendor authority. The client may name a bag slot or stocked item desire;
# identity, ownership, stock, price, capacity, coin balance, and buyback state are all server truth.

const CharacterManager = preload("res://scripts/character_manager.gd")
const CoinLedger = preload("res://scripts/coin_ledger.gd")
const VendorOps = preload("res://scripts/vendor_ops.gd")

const REG := {
	"junk":
	{
		"name": "Bent Spoon",
		"slot": "none",
		"stackable": true,
		"max_stack": 20,
		"vendor_value": 3,
	},
	"potion":
	{
		"name": "Minor Healing Potion",
		"slot": "none",
		"stackable": true,
		"max_stack": 20,
		"vendor_value": 8,
	},
	"sword":
	{
		"name": "Iron Sword",
		"slot": "weapon",
		"armor_type": "none",
		"stackable": false,
		"max_stack": 1,
		"vendor_value": 35,
	},
}
const WARES := ["potion"]

var _ops = null


func before_each() -> void:
	CharacterManager.reset_for_test()
	_ops = VendorOps.new()


func _cid(username: String) -> int:
	CharacterManager.ensure_character(username)
	return int(CharacterManager.get_character(username)["id"])


func _count(cid: int, item_id: String) -> int:
	var total := 0
	for row: Dictionary in CharacterManager.get_inventory(cid):
		if str(row.get("item_id", "")) == item_id:
			total += int(row.get("item_count", 0))
	return total


func _params(username: String, action: String) -> Dictionary:
	return {
		"username": username,
		"action": action,
		"wares": WARES,
		"item_registry": REG,
	}


func test_sell_clamps_to_owned_uses_registry_price_and_ledgers_faucet() -> void:
	var cid := _cid("alice")
	CharacterManager.add_item_to_bag(cid, "junk", 4, 2)
	var p := _params("alice", "sell")
	p.merge({"slot_index": 2, "count": 999, "price": 999999})
	var r: Dictionary = _ops.op(p)
	assert_true(bool(r.get("ok", false)), "owned junk sells")
	assert_eq(int(r.get("count", 0)), 4, "requested count is clamped to the owned stack")
	# T-475 spread: vendor_value 3 sells at max(1, 25%) = 1 per unit, x4 units.
	assert_eq(int(r.get("price", 0)), 4, "SERVER spread sell price x count names the proceeds")
	assert_eq(ServicesStore.get_coins(cid), 104, "sale credits exactly the server price")
	assert_eq(_count(cid, "junk"), 0, "sold stack is removed")
	assert_eq((r.get("buyback", []) as Array).size(), 1, "successful sale enters buyback")
	var rows := CoinLedger.test_move_rows()
	assert_eq(rows.size(), 1)
	assert_eq(str(rows[0]["reason"]), "vendor_sell")
	assert_eq(int(rows[0]["delta"]), 4)


func test_sell_rejects_forged_or_equipped_slot_without_touching_other_character() -> void:
	var alice := _cid("alice")
	var bob := _cid("bob")
	CharacterManager.add_item_to_bag(bob, "junk", 2, 5)
	var forged := _params("alice", "sell")
	forged.merge({"slot_index": 5, "count": 2, "character_id": bob, "slot_type": "bag"})
	var denied: Dictionary = _ops.op(forged)
	assert_eq(str(denied.get("error", "")), "empty_slot", "slot is resolved in Alice's bag only")
	assert_eq(_count(bob, "junk"), 2, "Bob's same-index row is untouched")

	CharacterManager.add_item_to_bag(alice, "sword", 1, 0)
	assert_true(CharacterManager.try_equip(alice, 0, REG)["ok"])
	var equipped := _params("alice", "sell")
	equipped["slot_index"] = 0
	assert_eq(
		str(_ops.op(equipped).get("error", "")),
		"must_unequip",
		"equipped gear must return to a bag before sale"
	)
	assert_eq(_count(alice, "sword"), 1, "rejected equipped sale loses nothing")
	assert_eq(CoinLedger.test_move_rows().size(), 0, "rejections never write faucet rows")


func test_buy_stocked_item_debits_server_price_grants_and_ledgers_sink() -> void:
	var cid := _cid("buyer")
	var p := _params("buyer", "buy")
	p.merge({"item_id": "potion", "price": 1, "count": 99})
	var r: Dictionary = _ops.op(p)
	assert_true(bool(r.get("ok", false)), "stocked item buys")
	assert_eq(int(r.get("price", 0)), 8, "client price/count are ignored; one costs vendor_value")
	assert_eq(ServicesStore.get_coins(cid), 92)
	assert_eq(_count(cid, "potion"), 1)
	var rows := CoinLedger.test_move_rows()
	assert_eq(rows.size(), 1)
	assert_eq(str(rows[0]["reason"]), "vendor_buy")
	assert_eq(int(rows[0]["delta"]), -8)


func test_buy_rejects_unstocked_overdraft_and_full_bag_without_partial_state() -> void:
	var cid := _cid("buyer")
	var unstocked := _params("buyer", "buy")
	unstocked["item_id"] = "junk"
	assert_eq(str(_ops.op(unstocked).get("error", "")), "not_stocked")

	ServicesStore.adjust_coins(cid, -95)  # 5 remain; potion costs 8.
	var potion := _params("buyer", "buy")
	potion["item_id"] = "potion"
	assert_eq(str(_ops.op(potion).get("error", "")), "insufficient_coins")
	assert_eq(ServicesStore.get_coins(cid), 5, "overdraft rejection does not debit")
	ServicesStore.adjust_coins(cid, 100)
	for i in range(16):
		CharacterManager.add_item_to_bag(cid, "sword", 1, i)
	assert_eq(str(_ops.op(potion).get("error", "")), "bag_full")
	assert_eq(ServicesStore.get_coins(cid), 105, "bag-full rejection does not debit")
	assert_eq(_count(cid, "potion"), 0, "bag-full rejection does not grant")
	assert_eq(CoinLedger.test_move_rows().size(), 0, "no rejected purchase is ledgered")


func test_buyback_rebuys_the_server_saved_sale_at_same_price_per_character() -> void:
	var alice := _cid("alice")
	_cid("bob")
	CharacterManager.add_item_to_bag(alice, "junk", 2, 4)
	var sale := _params("alice", "sell")
	sale.merge({"slot_index": 4, "count": 2})
	var sold: Dictionary = _ops.op(sale)
	assert_eq(int(sold.get("price", 0)), 2, "spread sell price (1/unit) x 2 units")

	var bob_buyback := _params("bob", "buyback")
	bob_buyback.merge({"buyback_index": 0, "item_id": "junk", "price": 0})
	assert_eq(str(_ops.op(bob_buyback).get("error", "")), "invalid_buyback")

	var repurchase := _params("alice", "buyback")
	repurchase.merge({"buyback_index": 0, "item_id": "potion", "price": 1})
	var bought: Dictionary = _ops.op(repurchase)
	assert_true(bool(bought.get("ok", false)))
	assert_eq(int(bought.get("price", 0)), 2, "saved server sale price is charged unchanged")
	assert_eq(_count(alice, "junk"), 2, "the saved item/count, not forged item_id, is restored")
	assert_eq((bought.get("buyback", []) as Array).size(), 0, "repurchased row leaves shortlist")
	assert_eq(ServicesStore.get_coins(alice), 100, "sale then same-price buyback is coin-neutral")
	var reasons := CoinLedger.test_move_rows().map(func(row): return str(row["reason"]))
	assert_eq(reasons, ["vendor_sell", "vendor_buy"])


func test_browse_returns_only_server_named_stock_bag_and_bounded_buyback() -> void:
	var cid := _cid("alice")
	for i in range(VendorOps.MAX_BUYBACK + 2):
		CharacterManager.add_item_to_bag(cid, "junk", 1, 0)
		var sale := _params("alice", "sell")
		sale["slot_index"] = 0
		_ops.op(sale)
	var view: Dictionary = _ops.op(_params("alice", "browse"))
	assert_eq((view.get("wares", []) as Array).size(), 1)
	assert_eq(str(view["wares"][0]["item_id"]), "potion")
	assert_eq(int(view["wares"][0]["price"]), 8)
	assert_eq((view.get("buyback", []) as Array).size(), VendorOps.MAX_BUYBACK)
	assert_true(view.has("bag"), "browse carries the authoritative sellable bag view")


# ---- T-475: the vendor spread (sell = 25% of buy; the passive round-trip sink) ----


func test_spread_sell_pays_quarter_of_buy_floored_at_one() -> void:
	var ops: VendorOps = _ops
	assert_eq(ops.sell_unit_price(35), 8, "35 -> floor(8.75) = 8")
	assert_eq(ops.sell_unit_price(8), 2, "8 -> exactly 25%")
	assert_eq(ops.sell_unit_price(3), 1, "sub-4 values floor to the 1-copper minimum")
	assert_eq(ops.sell_unit_price(1), 1, "anything sellable is worth at least 1")


func test_round_trip_burns_the_spread_and_bag_view_quotes_sell_price() -> void:
	var cid := _cid("alice")
	CharacterManager.add_item_to_bag(cid, "potion", 1, 3)
	var view: Dictionary = _ops.op(_params("alice", "browse"))
	assert_eq(int(view["wares"][0]["price"]), 8, "buy side quotes full vendor_value")
	assert_eq(int(view["bag"][0]["vendor_value"]), 2, "bag side quotes the honest sell price")
	var sale := _params("alice", "sell")
	sale.merge({"slot_index": 3, "count": 1})
	assert_eq(int(_ops.op(sale).get("price", 0)), 2, "sale pays the spread price")
	var buy := _params("alice", "buy")
	buy["item_id"] = "potion"
	assert_eq(int(_ops.op(buy).get("price", 0)), 8, "repurchase from stock costs full price")
	assert_eq(ServicesStore.get_coins(cid), 94, "the round trip burned the 6-copper spread")
