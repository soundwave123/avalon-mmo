extends GutTest

# T-476 + T-482: the earned cosmetic_currency loop and the store's charter guards. Currency is a
# real persisted balance minted by the earn hooks and spent through WardrobeOps.grant_unlock; the
# store may never sell power, a random roll, an already-owned look, or a look that outranks earned.

const CharacterManager = preload("res://scripts/character_manager.gd")
const ServicesStore = preload("res://scripts/services_store.gd")
const CosmeticShop = preload("res://scripts/cosmetic_shop.gd")
const CosmeticLedger = preload("res://scripts/cosmetic_ledger.gd")
const WardrobeOps = preload("res://scripts/wardrobe_ops.gd")
const DailyAppointmentStore = preload("res://scripts/daily_appointment_store.gd")
const TelemetryStore = preload("res://scripts/telemetry_store.gd")

var _cid: int


func before_each() -> void:
	CharacterManager.reset_for_test()  # chains ServicesStore + CosmeticLedger reset
	WardrobeOps.reset_for_test()
	DailyAppointmentStore.reset_for_test()
	TelemetryStore.reset_for_test()
	CharacterManager.ensure_character("shopper")
	_cid = int(CharacterManager.get_character("shopper")["id"])


func _store_look(overrides: Dictionary = {}) -> Dictionary:
	var look := {
		"id": "cos_gilded_blade",
		"name": "Gilded Blade",
		"display_item": "itm_iron_sword",
		"slot": "weapon",
		"armor_type": "none",
		"store": true,
		"price": 120,
		"prestige_tier": 2,
	}
	look.merge(overrides, true)
	return look


# --- currency: mint, persist, ledger ----------------------------------------------------------


func test_currency_mints_persists_and_is_ledgered() -> void:
	assert_eq(ServicesStore.get_cosmetic_currency(_cid), 0, "phantom no more: starts at a real 0")
	assert_true(ServicesStore.adjust_cosmetic_currency(_cid, 50, CosmeticLedger.REASON_DAILY))
	assert_eq(ServicesStore.get_cosmetic_currency(_cid), 50, "mint moves a persisted balance")
	assert_false(
		ServicesStore.adjust_cosmetic_currency(_cid, -80, CosmeticLedger.REASON_PURCHASE),
		"a balance is never driven negative"
	)
	assert_eq(ServicesStore.get_cosmetic_currency(_cid), 50, "the rejected debit left it untouched")
	var rows := CosmeticLedger.test_rows()
	assert_eq(rows.size(), 1, "only the successful move is recorded")
	assert_eq(int(rows[0]["delta"]), 50)
	assert_eq(str(rows[0]["reason"]), CosmeticLedger.REASON_DAILY)


func test_daily_login_mints_the_earned_currency() -> void:
	# The earn half of the loop: a daily claim pays a power-neutral cosmetic payoff into the balance.
	var result := DailyAppointmentStore.login("shopper", "2026-07-17")
	assert_true(result["ok"])
	assert_true(bool(result["claimed"]), "first login of the day claims")
	assert_gt(
		ServicesStore.get_cosmetic_currency(_cid), 0, "the streak minted real cosmetic currency"
	)
	var minted: Array = CosmeticLedger.test_rows().filter(
		func(r: Dictionary) -> bool: return str(r["reason"]) == CosmeticLedger.REASON_DAILY
	)
	assert_eq(minted.size(), 1, "the mint rode the cosmetic-currency ledger")


# --- the spend: browse -> buy -> unlock -> wear -----------------------------------------------


func test_purchase_debits_grants_and_is_idempotent() -> void:
	ServicesStore.adjust_cosmetic_currency(_cid, 200, CosmeticLedger.REASON_DAILY)
	var bought := CosmeticShop.purchase(_cid, _store_look(), "shopper")
	assert_true(bought["ok"], "a funded, valid purchase succeeds")
	assert_eq(int(bought["balance"]), 80, "the price was debited server-side")
	assert_eq(str(bought["appearance_id"]), "cos_gilded_blade")
	assert_true("cos_gilded_blade" in WardrobeOps.unlocks_for(_cid), "the look was granted")
	# Idempotent: buying an owned look is refused WITHOUT a second charge.
	var again := CosmeticShop.purchase(_cid, _store_look(), "shopper")
	assert_false(again["ok"])
	assert_eq(str(again["reason"]), "already_owned")
	assert_eq(ServicesStore.get_cosmetic_currency(_cid), 80, "no double charge on a re-buy")
	assert_eq(WardrobeOps.unlocks_for(_cid).count("cos_gilded_blade"), 1, "granted exactly once")


func test_purchase_rejected_when_underfunded_and_never_charges() -> void:
	ServicesStore.adjust_cosmetic_currency(_cid, 50, CosmeticLedger.REASON_DAILY)
	var bought := CosmeticShop.purchase(_cid, _store_look(), "shopper")
	assert_false(bought["ok"])
	assert_eq(str(bought["reason"]), "insufficient_currency")
	assert_eq(ServicesStore.get_cosmetic_currency(_cid), 50, "a poor purse is a clean rejection")
	assert_false("cos_gilded_blade" in WardrobeOps.unlocks_for(_cid), "nothing granted")


func test_purchase_grants_no_stat_and_never_touches_inventory() -> void:
	# Charter: power is never for sale. The grant adds an unlock only — the stat inventory is unmoved.
	CharacterManager.add_item_to_bag(_cid, "itm_iron_sword", 1, 0)
	ServicesStore.adjust_cosmetic_currency(_cid, 200, CosmeticLedger.REASON_DAILY)
	var before: Array = CharacterManager.get_inventory(_cid).duplicate(true)
	assert_true(CosmeticShop.purchase(_cid, _store_look(), "shopper")["ok"])
	assert_eq(CharacterManager.get_inventory(_cid), before, "no item/stat entered inventory")


func test_full_loop_through_wardrobe_op_returns_balance_and_grant() -> void:
	ServicesStore.adjust_cosmetic_currency(_cid, 200, CosmeticLedger.REASON_DAILY)
	var result := WardrobeOps.op(
		{"username": "shopper", "action": "purchase", "appearance": _store_look()}
	)
	assert_true(result["ok"])
	assert_eq(int(result["cosmetic_currency"]), 80, "the op surfaces the debited balance")
	assert_eq(str(result["purchased"]), "cos_gilded_blade")
	assert_true("cos_gilded_blade" in result["unlocks"], "the refreshed state shows the new unlock")


# --- charter guards (T-482) -------------------------------------------------------------------


func test_store_never_sells_power() -> void:
	ServicesStore.adjust_cosmetic_currency(_cid, 500, CosmeticLedger.REASON_DAILY)
	var forged := _store_look({"stats": {"attack": 9999}})
	var bought := CosmeticShop.purchase(_cid, forged, "shopper")
	assert_false(bought["ok"], "a power-bearing store row is refused")
	assert_eq(str(bought["reason"]), "power_field")
	assert_eq(ServicesStore.get_cosmetic_currency(_cid), 500, "no charge on a rejected forgery")


func test_store_cannot_outrank_earned_marquee_tier() -> void:
	ServicesStore.adjust_cosmetic_currency(_cid, 500, CosmeticLedger.REASON_DAILY)
	var marquee := _store_look({"prestige_tier": CosmeticShop.MARQUEE_TIER})
	var bought := CosmeticShop.purchase(_cid, marquee, "shopper")
	assert_false(bought["ok"], "a store look at the earned marquee tier is refused")
	assert_eq(str(bought["reason"]), "exceeds_earned_tier")
	assert_false("cos_gilded_blade" in WardrobeOps.unlocks_for(_cid))


func test_non_store_and_unpriced_rows_are_never_sold() -> void:
	ServicesStore.adjust_cosmetic_currency(_cid, 500, CosmeticLedger.REASON_DAILY)
	var earned := _store_look({"store": false})
	assert_eq(str(CosmeticShop.purchase(_cid, earned, "shopper")["reason"]), "not_for_sale")
	var free := _store_look({"price": 0})
	assert_eq(str(CosmeticShop.purchase(_cid, free, "shopper")["reason"]), "bad_price")


func test_purchase_is_deterministic_no_roll() -> void:
	# No loot boxes: the same known input always grants the same single id — never a random outcome.
	CharacterManager.ensure_character("shopper_b")
	var cid_b := int(CharacterManager.get_character("shopper_b")["id"])
	ServicesStore.adjust_cosmetic_currency(_cid, 200, CosmeticLedger.REASON_DAILY)
	ServicesStore.adjust_cosmetic_currency(cid_b, 200, CosmeticLedger.REASON_DAILY)
	var a := CosmeticShop.purchase(_cid, _store_look(), "shopper")
	var b := CosmeticShop.purchase(cid_b, _store_look(), "shopper_b")
	assert_eq(str(a["appearance_id"]), str(b["appearance_id"]), "one known id in, the same id out")
	assert_eq(str(a["appearance_id"]), "cos_gilded_blade")


func test_no_randomized_grant_verb_reaches_the_seam() -> void:
	# The seam guard: CosmeticShop exposes exactly one grant path (purchase) and no roll/bundle/random
	# verb, so nothing can route a randomized outcome into grant_unlock.
	for method: Dictionary in CosmeticShop.new().get_method_list():
		var name := str(method.get("name", "")).to_lower()
		for banned in ["roll", "bundle", "lootbox", "loot_box", "gacha", "mystery", "random"]:
			assert_false(name.contains(banned), "no gambling verb on the store: %s" % name)
