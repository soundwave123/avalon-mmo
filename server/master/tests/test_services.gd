extends GutTest

# T-208: the three Highkeep services — state-machine units against the pure logic +
# the in-memory store (same test-mode discipline as character_manager).

const CharacterManager = preload("res://scripts/character_manager.gd")
const ServicesStore = preload("res://scripts/services_store.gd")  # T-422c: bar-layout persistence
const _VL = preload("res://scripts/vault_logic.gd")
const _AL = preload("res://scripts/auction_logic.gd")
const _TL = preload("res://scripts/trainer_logic.gd")
const _SC = preload("res://scripts/server_config.gd")  # T-412: sink tunables
const _VO = preload("res://scripts/vault_ops.gd")  # T-412: vault tier ladder op
const _CL = preload("res://scripts/coin_ledger.gd")  # T-412: sink ledger proof
const _IL = preload("res://scripts/inventory_logic.gd")  # T-609: BAG_SLOTS for full-bag sweep tests
# T-426 carve: auction ops moved to auction_ops.gd (class_name AuctionOps); tests call it directly.


func before_each() -> void:
	CharacterManager.reset_for_test()


func _char(username: String) -> int:
	CharacterManager.ensure_character(username)
	return int(CharacterManager.get_character(username)["id"])


# ---- vault -------------------------------------------------------------------


func test_vault_deposit_and_withdraw_roundtrip() -> void:
	var cid := _char("alice")
	CharacterManager.add_item_to_bag(cid, "wolf_pelt", 3, 0)
	var plan := _VL.plan_move(CharacterManager.get_inventory(cid), "bag", 0)
	assert_true(plan["ok"], "deposit plans")
	assert_eq(plan["plan"]["to_type"], "vault")
	CharacterManager.apply_vault_move(cid, plan["plan"])
	var vault := _VL.vault_view(CharacterManager.get_inventory(cid))
	assert_eq(vault.size(), 1, "stack is in the vault")
	assert_eq(str(vault[0]["item_id"]), "wolf_pelt")
	# withdraw back
	var back := _VL.plan_move(
		CharacterManager.get_inventory(cid), "vault", int(vault[0]["slot_index"])
	)
	assert_true(back["ok"], "withdraw plans")
	CharacterManager.apply_vault_move(cid, back["plan"])
	assert_eq(_VL.vault_view(CharacterManager.get_inventory(cid)).size(), 0, "vault empty again")


func test_vault_rejects_empty_slot_and_full_vault() -> void:
	var cid := _char("bob")
	assert_false(_VL.plan_move(CharacterManager.get_inventory(cid), "bag", 0)["ok"], "empty slot")
	for index in range(_VL.VAULT_SLOTS):
		CharacterManager.add_item_to_bag(cid, "rock_%d" % index, 1, index)
		var plan := _VL.plan_move(CharacterManager.get_inventory(cid), "bag", index)
		CharacterManager.apply_vault_move(cid, plan["plan"])
	CharacterManager.add_item_to_bag(cid, "one_too_many", 1, 0)
	var overflow := _VL.plan_move(CharacterManager.get_inventory(cid), "bag", 0)
	assert_false(overflow["ok"], "vault full rejects")
	assert_eq(str(overflow["reason"]), "vault_full")


# ---- T-412: vault capacity TIER ladder (non-punitive coin sink) -----------------


func test_vault_tier_capacity_and_ladder_math() -> void:
	assert_eq(_VL.capacity_for_tier(0, 12, 6), 12, "tier 0 == base (identity with shipped cap)")
	assert_eq(_VL.capacity_for_tier(2, 12, 6), 24, "each tier adds `per` slots")
	var costs := [500, 1500, 4000]
	assert_eq(_VL.next_tier_cost(0, costs), 500, "cost to reach tier 1")
	assert_eq(_VL.next_tier_cost(2, costs), 4000, "cost to reach the last tier")
	assert_eq(_VL.next_tier_cost(3, costs), -1, "past the ladder = no further tier")


func test_vault_plan_upgrade_guards_overdraft_and_max_tier() -> void:
	var costs := [500, 1500, 4000]
	var ok := _VL.plan_upgrade(0, 500, costs)
	assert_true(ok["ok"], "affordable upgrade plans")
	assert_eq(int(ok["new_tier"]), 1)
	assert_eq(int(ok["cost"]), 500)
	assert_false(_VL.plan_upgrade(0, 499, costs)["ok"], "one coin short is rejected")
	assert_eq(str(_VL.plan_upgrade(0, 499, costs)["reason"]), "insufficient_coins")
	assert_eq(
		str(_VL.plan_upgrade(3, 999999, costs)["reason"]), "max_tier", "top tier can't upgrade"
	)


func test_vault_upgrade_op_debits_bumps_tier_and_ledgers() -> void:
	var cid := _char("tina")
	ServicesStore.adjust_coins(cid, 1000)  # reasonless top-up -> 1100, stays out of the ledger
	var before := ServicesStore.get_coins(cid)
	var r: Dictionary = _VO.op({"username": "tina", "action": "upgrade"})
	assert_eq(int(r["vault_tier"]), 1, "tier advances by one")
	assert_eq(
		int(r["vault_slots"]), _SC.VAULT_TIER_BASE_SLOTS + _SC.VAULT_TIER_SLOTS_PER, "cap grows"
	)
	assert_eq(ServicesStore.get_coins(cid), before - _SC.VAULT_TIER_COSTS[0], "cost debited")
	assert_eq(ServicesStore.get_vault_tier(cid), 1, "tier persisted")
	var found := false
	for row in _CL.test_rows():
		if str(row["reason"]) == "vault_upgrade":
			found = true
			assert_eq(int(row["delta"]), -_SC.VAULT_TIER_COSTS[0], "ledger records the tier debit")
	assert_true(found, "upgrade wrote a reason='vault_upgrade' SINK row")


func test_vault_upgrade_op_rejects_overdraft_without_charging() -> void:
	var cid := _char("wendy")  # 100 default coins, far under the 500 tier-1 cost
	var r: Dictionary = _VO.op({"username": "wendy", "action": "upgrade"})
	assert_eq(str(r.get("error", "")), "insufficient_coins", "can't afford tier 1")
	assert_eq(ServicesStore.get_coins(cid), 100, "no coins moved on a rejected upgrade")
	assert_eq(ServicesStore.get_vault_tier(cid), 0, "tier unchanged")
	for row in _CL.test_rows():
		assert_ne(str(row["reason"]), "vault_upgrade", "a rejected upgrade never ledgers")


# T-611: the panel ack advertises the next tier (cost + resulting capacity) so the client can
# render the upgrade button without mirroring the cost table; 0 marks max tier (no button).
func test_vault_panel_carries_next_tier_cost_and_slots() -> void:
	var cid := _char("nadia")
	var r: Dictionary = _VO.op({"username": "nadia", "action": "list"})
	assert_eq(int(r["vault_next_cost"]), int(_SC.VAULT_TIER_COSTS[0]), "tier 0 advertises tier 1")
	assert_eq(
		int(r["vault_next_slots"]),
		_SC.VAULT_TIER_BASE_SLOTS + _SC.VAULT_TIER_SLOTS_PER,
		"resulting capacity states the post-upgrade cap"
	)
	ServicesStore.set_vault_tier(cid, _SC.VAULT_TIER_COSTS.size())  # jump to max tier
	var maxed: Dictionary = _VO.op({"username": "nadia", "action": "list"})
	assert_eq(int(maxed["vault_next_cost"]), 0, "max tier advertises no further upgrade")


func test_vault_upgrade_op_ignores_client_supplied_cost_and_tier() -> void:
	# Server-authority: the target tier AND its price come from the data ladder, never the payload.
	var cid := _char("uma")
	ServicesStore.adjust_coins(cid, 1000)
	var r: Dictionary = _VO.op({"username": "uma", "action": "upgrade", "cost": 1, "tier": 99})
	assert_eq(int(r["vault_tier"]), 1, "server advances exactly one tier, ignoring forged tier 99")
	assert_eq(ServicesStore.get_coins(cid), 1100 - _SC.VAULT_TIER_COSTS[0], "charged the real cost")


func test_vault_upgrade_enlarges_usable_capacity() -> void:
	# Integration: past the base 12, a deposit that would overflow tier 0 succeeds after an upgrade.
	var cid := _char("vic")
	ServicesStore.adjust_coins(cid, 1000)
	_VO.op({"username": "vic", "action": "upgrade"})  # tier 1 -> 18 slots
	for i in range(13):
		CharacterManager.add_item_to_bag(cid, "rock_%d" % i, 1, i)
		var mv: Dictionary = _VO.op(
			{"username": "vic", "action": "move", "from_type": "bag", "from_index": i}
		)
		assert_false(mv.has("error"), "deposit %d fits the enlarged vault" % i)
	assert_eq(_VL.vault_view(CharacterManager.get_inventory(cid)).size(), 13, "13 > base 12")


# ---- T-412: auction listing fee (non-punitive coin sink) ------------------------


func test_listing_fee_math_flat_plus_bps() -> void:
	assert_eq(_AL.listing_fee(100, 5, 200), 7, "5 flat + 2% of 100 = 7")
	assert_eq(_AL.listing_fee(0, 0, 0), 0, "both zero -> disabled")
	assert_eq(_AL.listing_fee(10000, 5, 200), 205, "5 + 2% of 10000 = 205")


func test_auction_list_charges_fee_and_ledgers() -> void:
	var cid := _char("nora")
	CharacterManager.add_item_to_bag(cid, "iron_ingot", 2, 0)
	var before := ServicesStore.get_coins(cid)
	var r: Dictionary = AuctionOps.op(
		{"username": "nora", "action": "list", "from_index": 0, "min_bid": 100, "duration_s": 3600}
	)
	assert_gt(int(r.get("listed", 0)), 0, "the lot was listed")
	assert_eq(int(r["fee"]), 7, "fee = 5 + 2% of the 100 min bid")
	assert_eq(ServicesStore.get_coins(cid), before - 7, "the fee was debited (coin sink)")
	var found := false
	for row in _CL.test_rows():
		if str(row["reason"]) == "auction_fee":
			found = true
			assert_eq(int(row["delta"]), -7, "ledger records the -7 listing fee")
	assert_true(found, "listing wrote a reason='auction_fee' SINK row")


func test_auction_list_rejects_when_fee_unaffordable_without_losing_item() -> void:
	var cid := _char("opal")  # 100 default coins
	CharacterManager.add_item_to_bag(cid, "iron_ingot", 1, 0)
	# min_bid 5000 -> fee = 5 + 2% of 5000 = 105 > 100 coins.
	var r: Dictionary = AuctionOps.op(
		{"username": "opal", "action": "list", "from_index": 0, "min_bid": 5000, "duration_s": 3600}
	)
	assert_eq(str(r.get("error", "")), "insufficient_coins", "can't cover the listing fee")
	assert_eq(ServicesStore.get_coins(cid), 100, "no coins moved")
	var still_in_bag := false
	for entry in CharacterManager.get_inventory(cid):
		if str(entry["slot_type"]) == "bag" and int(entry["slot_index"]) == 0:
			still_in_bag = true
	assert_true(still_in_bag, "the stack never left the bag (checked BEFORE removal)")


# ---- auction logic -------------------------------------------------------------


func test_bid_escrow_and_outbid_refund_math() -> void:
	var auction := {"state": "live", "seller_id": 1, "min_bid": 10, "high_bid": 0}
	var first := _AL.apply_bid(auction, 2, 10, 100)
	assert_true(first["ok"], "opening bid at min")
	assert_eq(int(first["escrow_debit"]), 10)
	assert_eq(int(first["refund_amount"]), 0, "nobody to refund yet")
	auction["high_bid"] = 10
	auction["high_bidder_id"] = 2
	var second := _AL.apply_bid(auction, 3, 15, 100)
	assert_true(second["ok"], "outbid")
	assert_eq(int(second["refund_to"]), 2, "prior bidder refunded")
	assert_eq(int(second["refund_amount"]), 10)
	assert_false(_AL.apply_bid(auction, 3, 10, 100)["ok"], "bid below current high rejected")
	assert_false(_AL.apply_bid(auction, 1, 20, 100)["ok"], "seller cannot bid own lot")
	assert_false(_AL.apply_bid(auction, 4, 20, 5)["ok"], "insufficient coins rejected")


func test_buyout_pays_seller_and_refunds_bidder() -> void:
	var auction := {
		"state": "live",
		"seller_id": 1,
		"min_bid": 10,
		"buyout": 50,
		"high_bid": 12,
		"high_bidder_id": 2,
	}
	var buy := _AL.apply_buyout(auction, 3, 100)
	assert_true(buy["ok"])
	assert_eq(int(buy["buyer_pays"]), 50)
	assert_eq(int(buy["refund_to"]), 2)
	assert_eq(int(buy["refund_amount"]), 12)
	assert_eq(int(buy["seller_gets"]), 50)


func test_expiry_resolution() -> void:
	assert_eq(
		str(_AL.resolve_expiry({"high_bid": 20, "high_bidder_id": 5})["outcome"]),
		"sold",
		"bid at expiry sells"
	)
	assert_eq(
		str(_AL.resolve_expiry({"high_bid": 0, "high_bidder_id": 0})["outcome"]),
		"returned",
		"no bids returns the lot"
	)


func test_listing_validation() -> void:
	assert_true(_AL.can_list(10, 50, 3600, 0)["ok"])
	assert_false(_AL.can_list(0, 0, 3600, 0)["ok"], "min bid >= 1")
	assert_false(_AL.can_list(10, 5, 3600, 0)["ok"], "buyout under min")
	assert_false(_AL.can_list(10, 0, 5, 0)["ok"], "too short")
	assert_false(_AL.can_list(10, 0, 3600, 10)["ok"], "listing cap")


# ---- auction store escrow round-trip (in-memory) --------------------------------


func test_store_auction_lifecycle() -> void:
	var seller := _char("carol")
	var aid := ServicesStore.auction_insert(seller, "iron_ingot", 2, 10, 40, 3600)
	assert_gt(aid, 0, "listing stored")
	assert_eq(ServicesStore.auction_rows(true).size(), 1)
	ServicesStore.auction_set_bid(aid, 99, 15)
	assert_eq(int(ServicesStore.auction_get(aid)["high_bid"]), 15)
	ServicesStore.auction_close(aid, "sold")
	assert_eq(ServicesStore.auction_rows(true).size(), 0, "closed lots leave the live view")


# ---- T-609: sweep_expired fail-closed settlement (no mail system fallback) ------
# A lot may only be CLOSED, and only a sale only PAID, once its deliverable is durably granted.
# A full destination bag at sweep time must never destroy the item or (for a sale) dupe the
# seller's payout — the lot stays open ("pending_*") and the NEXT sweep retries it.


func _auction_item_registry() -> Dictionary:
	return {
		"iron_ingot": {"slot": "none", "stackable": true, "max_stack": 99},
		"itm_iron_sword": {"slot": "weapon", "stackable": false, "max_stack": 1},
	}


func _fill_bag(cid: int, reg: Dictionary) -> void:
	var fill: Array = []
	for i in range(_IL.BAG_SLOTS):
		fill.append({"item": "itm_iron_sword", "count": 1})
	assert_true(CharacterManager.try_add_items(cid, fill, reg)["ok"], "test setup: bag filled")


func test_sweep_expired_unsold_full_bag_survives_and_retries_after_space_frees() -> void:
	var reg := _auction_item_registry()
	var seller := _char("quinn")
	_fill_bag(seller, reg)
	# duration_s = -1 -> already expired the instant it's inserted; no bids -> "returned" (unsold).
	var aid := ServicesStore.auction_insert(seller, "iron_ingot", 3, 10, 0, -1)

	AuctionOps.sweep_expired(reg)
	var row := ServicesStore.auction_get(aid)
	assert_eq(
		str(row["state"]), "pending_expired", "bag-full return leaves the lot open, not closed"
	)
	assert_eq(int(row["item_count"]), 3, "the lot still carries the un-destroyed stack")

	# a second sweep with a still-full bag must not move or lose anything either (retry is safe).
	AuctionOps.sweep_expired(reg)
	assert_eq(str(ServicesStore.auction_get(aid)["state"]), "pending_expired", "still pending")

	# free one bag slot, then retry: the return completes and the lot closes exactly once.
	assert_true(CharacterManager.remove_item(seller, "bag", 0), "free a bag slot")
	AuctionOps.sweep_expired(reg)
	assert_eq(str(ServicesStore.auction_get(aid)["state"]), "expired", "retry closes the lot")
	var found := false
	for entry in CharacterManager.get_inventory(seller):
		if str(entry.get("item_id", "")) == "iron_ingot":
			found = true
			assert_eq(int(entry["item_count"]), 3, "the full stack landed, not a partial grant")
	assert_true(found, "the returned stack reached the seller's bag")


func test_sweep_expired_sold_winner_bag_full_no_payout_no_destruction_then_settles_once() -> void:
	var reg := _auction_item_registry()
	var seller := _char("rex")
	var winner := _char("sam")
	_fill_bag(winner, reg)
	var aid := ServicesStore.auction_insert(seller, "iron_ingot", 2, 10, 0, -1)
	ServicesStore.auction_set_bid(aid, winner, 50)
	var seller_before := ServicesStore.get_coins(seller)

	AuctionOps.sweep_expired(reg)
	assert_eq(
		str(ServicesStore.auction_get(aid)["state"]),
		"pending_sold",
		"bag-full delivery leaves the sale open, not closed"
	)
	assert_eq(
		ServicesStore.get_coins(seller), seller_before, "seller not paid until delivery lands"
	)
	for entry in CharacterManager.get_inventory(winner):
		assert_ne(str(entry.get("item_id", "")), "iron_ingot", "winner never received the item yet")

	# free a slot for the winner, then retry: item lands AND the seller is paid, exactly once.
	assert_true(CharacterManager.remove_item(winner, "bag", 0), "free a bag slot")
	AuctionOps.sweep_expired(reg)
	assert_eq(str(ServicesStore.auction_get(aid)["state"]), "sold", "retry settles the sale")
	assert_eq(ServicesStore.get_coins(seller), seller_before + 50, "seller paid exactly once")
	var delivered := false
	for entry in CharacterManager.get_inventory(winner):
		if str(entry.get("item_id", "")) == "iron_ingot":
			delivered = true
			assert_eq(int(entry["item_count"]), 2, "the full stack landed")
	assert_true(delivered, "the winner received the item")

	# idempotency: a third sweep (lot is now closed, no longer live or pending) must not double-pay.
	AuctionOps.sweep_expired(reg)
	assert_eq(ServicesStore.get_coins(seller), seller_before + 50, "no double-pay on a later sweep")


func test_sweep_expired_happy_paths_settle_immediately_with_room_in_bag() -> void:
	var reg := _auction_item_registry()
	var seller1 := _char("tara")
	var aid1 := ServicesStore.auction_insert(seller1, "iron_ingot", 1, 10, 0, -1)
	AuctionOps.sweep_expired(reg)
	assert_eq(
		str(ServicesStore.auction_get(aid1)["state"]), "expired", "unsold settles immediately"
	)

	var seller2 := _char("ursula")
	var winner2 := _char("victor")
	var aid2 := ServicesStore.auction_insert(seller2, "iron_ingot", 1, 10, 0, -1)
	ServicesStore.auction_set_bid(aid2, winner2, 30)
	var before := ServicesStore.get_coins(seller2)
	AuctionOps.sweep_expired(reg)
	assert_eq(str(ServicesStore.auction_get(aid2)["state"]), "sold", "sale settles immediately")
	assert_eq(ServicesStore.get_coins(seller2), before + 30, "seller paid on the happy path")


# ---- trainer --------------------------------------------------------------------


func test_trainer_gates() -> void:
	assert_eq(_TL.class_for_service("trainer:mage"), "mage")
	assert_eq(_TL.class_for_service("bank"), "", "non-trainer service")
	assert_false(_TL.can_train("mage", 1, 100, 203, [])["ok"], "level gate")
	assert_false(_TL.can_train("mage", 5, 10, 203, [])["ok"], "coin gate")
	assert_false(_TL.can_train("mage", 5, 100, 104, [])["ok"], "wrong class ability")
	assert_false(_TL.can_train("mage", 5, 100, 203, [203])["ok"], "already known")
	var ok := _TL.can_train("mage", 5, 100, 203, [])
	assert_true(ok["ok"], "valid purchase")
	assert_eq(int(ok["cost"]), 60)


# T-365: the trainer schedule spans MULTIPLE levels across the 1–15 band (not just L2), so a class
# has a new ability to look forward to across the band. Each class offers >=2 unlocks at >=2 levels.
func test_trainer_schedule_spans_multiple_levels() -> void:
	for cls in ["warrior", "mage", "priest"]:
		var rows := _TL.catalog_for(cls)
		assert_true(rows.size() >= 2, "%s should offer more than one trainer unlock" % cls)
		var levels := {}
		for row in rows:
			levels[int(row["min_level"])] = true
		assert_true(levels.size() >= 2, "%s unlocks must land at 2+ distinct levels" % cls)
		assert_true(levels.has(2), "%s keeps an early (L2) unlock" % cls)
	# The L8 unlock is genuinely gated: a L5 mage can't buy Scorch yet, a funded L8 mage can.
	assert_false(_TL.can_train("mage", 5, 500, 205, [])["ok"], "L8 ability locked at L5")
	var late := _TL.can_train("mage", 8, 500, 205, [])
	assert_true(late["ok"], "L8 mage with coin buys the banded ability")
	assert_eq(int(late["cost"]), 150, "banded unlock costs more (T-366 coin sink)")


# T-715: Kessa's starter tag teaches EVERY class, so it resolves to the buyer's own class — it can
# never be used to name someone else's catalog, and a non-trainer service still resolves to "".
func test_starter_trainer_tag_resolves_to_the_buyers_own_class() -> void:
	for cls in ["warrior", "mage", "priest"]:
		assert_eq(_TL.class_for_service(_TL.STARTER_SERVICE, cls), cls, "%s trains here" % cls)
	assert_eq(_TL.class_for_service("bank", "mage"), "", "a non-trainer service still teaches none")
	# A capital tag ignores the buyer's class entirely — it is the tag's class that must match.
	assert_eq(_TL.class_for_service("trainer:warrior", "mage"), "warrior")


# T-715: the starter trainer sells the L2 tier ONLY. Every class can buy its 60-coin L2 ability at
# the hamlet the moment it dings; the 150-coin L8 tier stays a reason to walk to Highkeep.
func test_starter_trainer_sells_only_the_l2_tier_for_every_class() -> void:
	var l2_by_class := {"warrior": 104, "mage": 203, "priest": 304}
	var l8_by_class := {"warrior": 105, "mage": 205, "priest": 305}
	for cls in l2_by_class:
		var rows := _TL.catalog_for(cls, _TL.STARTER_SERVICE)
		assert_eq(rows.size(), 1, "%s sees exactly the starter tier at Kessa" % cls)
		assert_eq(int(rows[0]["min_level"]), 2, "%s starter offer is the L2 unlock" % cls)
		# The L2 buy is the whole point: a fresh L2 holding 165 coins can afford it on the spot.
		var buy := _TL.can_train(cls, 2, 165, int(l2_by_class[cls]), [], _TL.STARTER_SERVICE)
		assert_true(buy["ok"], "%s buys its L2 ability from Kessa" % cls)
		assert_eq(int(buy["cost"]), 60, "%s L2 unlock still costs 60c" % cls)
		# The L8 ability is not on her board at all — refused as untaught, not as under-levelled.
		var late := _TL.can_train(cls, 8, 500, int(l8_by_class[cls]), [], _TL.STARTER_SERVICE)
		assert_false(late["ok"], "%s cannot buy the L8 tier at the hamlet" % cls)
		assert_eq(str(late["reason"]), "not_taught_here", "the capital keeps the L8 tier")
		# ...and the capital trainer still sells it (the starter cap is tag-scoped, not global).
		assert_true(
			_TL.can_train(cls, 8, 500, int(l8_by_class[cls]), [], "trainer:%s" % cls)["ok"],
			"%s still trains the L8 tier in Highkeep" % cls,
		)


# T-715: the level gate survives the tier cap — dinging is still what unlocks the purchase.
func test_starter_trainer_still_level_gates_the_l2_ability() -> void:
	var early := _TL.can_train("warrior", 1, 165, 104, [], _TL.STARTER_SERVICE)
	assert_false(early["ok"], "an L1 warrior cannot pre-buy Revenge")
	assert_eq(str(early["reason"]), "level_too_low")
	var broke := _TL.can_train("warrior", 2, 10, 104, [], _TL.STARTER_SERVICE)
	assert_eq(str(broke["reason"]), "insufficient_coins", "the 60c price still applies")


func test_coins_never_go_negative() -> void:
	var cid := _char("dave")
	assert_eq(ServicesStore.get_coins(cid), 100, "starting purse")
	assert_true(ServicesStore.adjust_coins(cid, -60))
	assert_false(ServicesStore.adjust_coins(cid, -60), "overdraft rejected")
	assert_eq(ServicesStore.get_coins(cid), 40)


# T-422c: an unset character has no custom layout; a saved order round-trips through the store, and
# a resave overwrites (last-write-wins — the whole ordered list is replaced, not merged).
func test_bar_layout_persists_and_reloads() -> void:
	var cid := _char("erin")
	assert_eq(ServicesStore.get_bar_layout(cid), [], "no custom layout by default")
	assert_true(ServicesStore.save_bar_layout(cid, [204, 201, 1, 202]))
	assert_eq(ServicesStore.get_bar_layout(cid), [204, 201, 1, 202], "saved order reloads verbatim")
	assert_true(ServicesStore.save_bar_layout(cid, [1, 202, 204, 201]))
	assert_eq(ServicesStore.get_bar_layout(cid), [1, 202, 204, 201], "resave replaces the order")
