extends GutTest

# T-364: the bounded death penalty (gear wears on death) + the repair coin SINK (closes T-366).
# Proves: (a) death wear applies once per death and is fail-open, (b) a broken (0-durability) item's
# stats drop out while the item itself PERSISTS, (c) repair debits coins + restores durability +
# writes the coin ledger with reason "repair", (d) insufficient coins is rejected, (e) there is NO
# client dispatch verb that reaches death-wear or repair (adversarial).

const CharacterManager = preload("res://scripts/character_manager.gd")
const ServicesStore = preload("res://scripts/services_store.gd")
const CoinLedger = preload("res://scripts/coin_ledger.gd")
const Durability = preload("res://scripts/durability.gd")
const Main = preload("res://scripts/main.gd")


func before_each() -> void:
	CharacterManager.reset_for_test()  # chains into ServicesStore + CoinLedger reset


func _char(username: String) -> int:
	CharacterManager.ensure_character(username)
	return int(CharacterManager.get_character(username)["id"])


# ---- pure module: wear math + effective-stats drop-out --------------------------


func test_wear_math_clamps_at_zero_never_negative() -> void:
	# 10% of 100 = 10 per death; five deaths = 50, ... never below 0, never destroyed.
	var cur := 100
	for i in range(20):
		cur = Durability.wear(cur, 100, 0.10)
	assert_eq(cur, 0, "wear floors at 0, item is never destroyed past broken")
	assert_true(Durability.is_broken(cur), "0 durability reads as broken")


func test_effective_stats_skips_broken_item_but_item_persists() -> void:
	var inv := [
		{"slot_type": "weapon", "slot_index": 0, "item_id": "itm_iron_sword"},
		{"slot_type": "head", "slot_index": 0, "item_id": "itm_leather_cap"},
		{"slot_type": "bag", "slot_index": 0, "item_id": "itm_wolf_pelt"},
	]
	var stats_for := func(item_id: String) -> Dictionary:
		match item_id:
			"itm_iron_sword":
				return {"attack": 8}
			"itm_leather_cap":
				return {"armor": 3}
			_:
				return {}
	# healthy: both worn items contribute; bag item ignored (not an equip slot).
	var full := Durability.effective_stats(inv, {}, stats_for)
	assert_eq(int(full.get("attack", 0)), 8, "healthy weapon contributes attack")
	assert_eq(int(full.get("armor", 0)), 3, "healthy head contributes armor")
	# weapon broken (current 0) → its stats stop contributing; the item row is still in inventory.
	var dur := {Durability.slot_key("weapon", 0): {"current": 0, "max": 100}}
	var broken := Durability.effective_stats(inv, dur, stats_for)
	assert_false(broken.has("attack"), "broken weapon contributes nothing (reads as unequipped)")
	assert_eq(int(broken.get("armor", 0)), 3, "the intact head still contributes")
	assert_eq(inv.size(), 3, "no item was destroyed or unequipped")


# ---- T-399: fold_gear_stats — the item-stat -> combat-vector mapping table -----


func test_fold_gear_stats_adds_attack_armor_without_mutating_base() -> void:
	var base := {"str": 73, "int": 10, "dex": 31, "spirit": 10, "stamina": 73}
	var gear := {"attack": 8, "armor": 32}
	var folded := Durability.fold_gear_stats(base, gear)
	assert_eq(int(folded.get("attack", 0)), 8, "attack folds in as a new combat key")
	assert_eq(int(folded.get("armor", 0)), 32, "armor folds in as a new combat key")
	assert_eq(
		int(folded.get("str", 0)), 73, "existing primaries are untouched by attack/armor gear"
	)
	assert_false(base.has("attack"), "the base stat vector is never mutated (COPY-then-fold)")


func test_fold_gear_stats_maps_wow_primary_names_onto_char_fields() -> void:
	# Item stats authored with WoW primary names map through the table onto the leveling-table keys
	# (strength->str, intellect->int, agility->dex) instead of string-matching into a pool name.
	var base := {"str": 20, "int": 20, "dex": 20, "spirit": 20, "stamina": 20}
	var gear := {"strength": 5, "intellect": 3, "agility": 2, "stamina": 4, "spirit": 1}
	var folded := Durability.fold_gear_stats(base, gear)
	assert_eq(int(folded["str"]), 25, "strength -> str, added onto the primary")
	assert_eq(int(folded["int"]), 23, "intellect -> int")
	assert_eq(int(folded["dex"]), 22, "agility -> dex")
	assert_eq(int(folded["stamina"]), 24, "stamina -> stamina (HP driver)")
	assert_eq(int(folded["spirit"]), 21, "spirit -> spirit")


func test_fold_gear_stats_drops_unmapped_stat_failclosed() -> void:
	var base := {"str": 10}
	# An unknown/typo'd item stat is NOT string-matched into any field — it contributes nothing.
	var folded := Durability.fold_gear_stats(base, {"stanima": 99, "haste": 5})
	assert_false(folded.has("stanima"), "unmapped item stat is dropped (fail-closed)")
	assert_false(folded.has("haste"), "unmapped item stat is dropped (fail-closed)")
	assert_eq(int(folded["str"]), 10, "the base is unchanged when nothing maps")


func test_fold_gear_stats_naked_is_byte_identical() -> void:
	# Empty gear (naked character) => the vector is exactly the base, so pinned naked-stat tests hold.
	var base := {"str": 73, "stamina": 73, "dex": 31, "int": 10, "spirit": 10}
	assert_eq(Durability.fold_gear_stats(base, {}), base, "no gear -> identical stat vector")


func test_repair_cost_is_rate_times_missing() -> void:
	var dur := {
		Durability.slot_key("weapon", 0): {"current": 60, "max": 100},  # missing 40
		Durability.slot_key("head", 0): {"current": 100, "max": 100},  # missing 0
	}
	assert_eq(Durability.missing_total(dur), 40)
	assert_eq(Durability.repair_cost(dur, 1), 40, "rate 1 -> 40 coins")
	assert_eq(Durability.repair_cost(dur, 3), 120, "rate 3 -> 120 coins")


# ---- T-412: rarity-scaled repair cost (identity at base, monotonic in rarity) ----


func test_repair_cost_scaled_identity_at_base_tier() -> void:
	# With every slot at the base ("common") rate the scaled cost equals the flat T-364 number — the
	# shipped behavior IS the base row of the table. An unknown/absent rarity falls back the same way.
	var dur := {
		Durability.slot_key("weapon", 0): {"current": 60, "max": 100},  # missing 40
		Durability.slot_key("head", 0): {"current": 90, "max": 100},  # missing 10
	}
	var table := {"common": 1, "rare": 4}
	var all_common := {
		Durability.slot_key("weapon", 0): "common", Durability.slot_key("head", 0): "common"
	}
	assert_eq(
		Durability.repair_cost_scaled(dur, all_common, table, 1), 50, "base tier == flat cost"
	)
	assert_eq(
		Durability.repair_cost_scaled(dur, {}, table, 1), 50, "no rarity -> base-rate identity"
	)


func test_repair_cost_scaled_is_monotonic_in_rarity() -> void:
	# Same 40 missing priced at each tier: strictly more per point as rarity climbs.
	var dur := {Durability.slot_key("weapon", 0): {"current": 60, "max": 100}}  # missing 40
	var table := {"common": 1, "uncommon": 2, "rare": 4, "epic": 8}
	var costs: Array = []
	for r in ["common", "uncommon", "rare", "epic"]:
		var by_slot := {Durability.slot_key("weapon", 0): r}
		costs.append(Durability.repair_cost_scaled(dur, by_slot, table, 1))
	assert_eq(costs, [40, 80, 160, 320], "40 missing scales 1x/2x/4x/8x by rarity")
	for i in range(1, costs.size()):
		assert_gt(costs[i], costs[i - 1], "repair cost is monotonic in rarity")


func test_repair_cost_scaled_mixed_set_sums_per_slot() -> void:
	# A mixed set: a common cap and a rare weapon each priced at their OWN rate, then summed.
	var dur := {
		Durability.slot_key("weapon", 0): {"current": 90, "max": 100},  # missing 10 (rare)
		Durability.slot_key("head", 0): {"current": 90, "max": 100},  # missing 10 (common)
	}
	var table := {"common": 1, "rare": 4}
	var rarity := {
		Durability.slot_key("weapon", 0): "rare", Durability.slot_key("head", 0): "common"
	}
	assert_eq(Durability.repair_cost_scaled(dur, rarity, table, 1), 50, "10*4 + 10*1 = 50")


# ---- master op: apply_death_wear (fail-open + seeds at max) ----------------------


func _equip(cid: int, slot_type: String, item_id: String) -> void:
	var inv: Array = CharacterManager.get_inventory(cid).duplicate(true)
	inv.append({"slot_type": slot_type, "slot_index": 0, "item_id": item_id, "item_count": 1})
	CharacterManager._persist_inventory(cid, inv)


func test_apply_death_wear_seeds_and_decrements_once() -> void:
	var cid := _char("alice")
	_equip(cid, "weapon", "itm_iron_sword")
	_equip(cid, "chest", "itm_leather_cap")
	# one death: each worn item seeds at 100 then loses 10% -> 90.
	var r1: Dictionary = DurabilityOps.apply_death_wear({"username": "alice"})
	assert_true(bool(r1.get("ok", false)))
	var dur: Dictionary = ServicesStore.get_durability(cid)
	assert_eq(int(dur[Durability.slot_key("weapon", 0)]["current"]), 90, "one death = one 10% wear")
	assert_eq(int(dur[Durability.slot_key("chest", 0)]["current"]), 90)
	# a second death applies exactly one more step (the world gates the edge; the op is one step).
	DurabilityOps.apply_death_wear({"username": "alice"})
	dur = ServicesStore.get_durability(cid)
	assert_eq(
		int(dur[Durability.slot_key("weapon", 0)]["current"]), 80, "second death = second step"
	)


func test_apply_death_wear_failopen_on_no_gear() -> void:
	_char("bob")  # no equipped items
	var r: Dictionary = DurabilityOps.apply_death_wear({"username": "bob"})
	assert_true(bool(r.get("ok", false)), "no gear = clean no-op, not an error")
	assert_eq((r["durability"] as Dictionary).size(), 0, "nothing written (fail-open)")


# ---- master op: repair sink (coins + ledger) ------------------------------------


func test_repair_deducts_coins_restores_and_ledgers() -> void:
	var cid := _char("carol")
	_equip(cid, "weapon", "itm_iron_sword")
	ServicesStore.adjust_coins(cid, 900)  # reasonless top-up, stays out of the ledger
	DurabilityOps.apply_death_wear({"username": "carol"})  # weapon -> 90 (missing 10)
	var before := ServicesStore.get_coins(cid)
	var r: Dictionary = DurabilityOps.repair_op({"username": "carol"})
	assert_true(bool(r.get("ok", false)), "repair succeeds")
	assert_eq(int(r["cost"]), 10, "missing 10 * rate 1 = 10 coins")
	assert_eq(ServicesStore.get_coins(cid), before - 10, "coins deducted")
	var dur := ServicesStore.get_durability(cid)
	assert_eq(int(dur[Durability.slot_key("weapon", 0)]["current"]), 100, "restored to full")
	# ledger proof: a classified "repair" SINK row for exactly the cost.
	var rows := CoinLedger.test_move_rows()
	var found := false
	for row in rows:
		if str(row["reason"]) == "repair":
			found = true
			assert_eq(int(row["delta"]), -10, "ledger records the -10 repair debit")
			assert_eq(int(row["character_id"]), cid)
	assert_true(found, "repair wrote a reason='repair' ledger row (T-366 sink)")


func test_repair_rejected_when_insufficient_coins() -> void:
	var cid := _char("dave")
	_equip(cid, "weapon", "itm_iron_sword")
	DurabilityOps.apply_death_wear({"username": "dave"})  # missing 10, cost 10
	# dave starts at the 100-coin test default; drain below the cost.
	ServicesStore.adjust_coins(cid, -(ServicesStore.get_coins(cid) - 5))  # leave 5 coins
	var r: Dictionary = DurabilityOps.repair_op({"username": "dave"})
	assert_eq(str(r.get("error", "")), "insufficient_coins", "5 coins can't cover a 10 repair")
	var dur := ServicesStore.get_durability(cid)
	assert_eq(
		int(dur[Durability.slot_key("weapon", 0)]["current"]), 90, "durability held on reject"
	)
	# no repair ledger row was written.
	for row in CoinLedger.test_move_rows():
		assert_ne(str(row["reason"]), "repair", "a rejected repair never ledgers")


func test_repair_quote_previews_cost_without_side_effect() -> void:
	var cid := _char("quinn")
	_equip(cid, "weapon", "itm_iron_sword")
	DurabilityOps.apply_death_wear({"username": "quinn"})  # missing 10
	var coins_before := ServicesStore.get_coins(cid)
	var q: Dictionary = DurabilityOps.repair_op({"username": "quinn", "quote": true})
	assert_true(bool(q.get("quote", false)), "quote flag echoed")
	assert_eq(int(q["cost"]), 10, "quote reports the cost")
	assert_eq(ServicesStore.get_coins(cid), coins_before, "a quote never deducts coins")
	var dur := ServicesStore.get_durability(cid)
	assert_eq(int(dur[Durability.slot_key("weapon", 0)]["current"]), 90, "a quote never restores")
	assert_eq(CoinLedger.test_move_rows().size(), 0, "a quote never ledgers")


func test_repair_ignores_client_supplied_cost() -> void:
	# Server-authority: the cost is computed from persisted durability; a forged low cost in the
	# payload must be ignored (the client cannot underpay the sink).
	var cid := _char("mallory")
	_equip(cid, "weapon", "itm_iron_sword")
	DurabilityOps.apply_death_wear({"username": "mallory"})  # real cost = 10
	var r: Dictionary = DurabilityOps.repair_op({"username": "mallory", "cost": 1, "coins": 999999})
	assert_eq(int(r["cost"]), 10, "server computes cost, ignoring the forged payload cost")
	# the debit was the real 10, not the forged 1
	var rows := CoinLedger.test_move_rows()
	assert_eq(
		int(rows[rows.size() - 1]["delta"]), -10, "ledger records the true -10, not a forged -1"
	)


func test_repair_op_scales_cost_with_item_rarity() -> void:
	# T-412 end-to-end: the master reads each worn item's rarity from the WORLD-supplied registry and
	# prices the sink through ServerConfig.DURABILITY_REPAIR_RATE_TABLE — a rare weapon costs 4x base.
	var cid := _char("rhea")
	_equip(cid, "weapon", "itm_iron_sword")
	ServicesStore.adjust_coins(cid, 900)  # reasonless top-up, stays out of the ledger
	DurabilityOps.apply_death_wear({"username": "rhea"})  # weapon -> 90 (missing 10)
	var registry := {"itm_iron_sword": {"rarity": "rare"}}  # world content authority
	var before := ServicesStore.get_coins(cid)
	var r: Dictionary = DurabilityOps.repair_op({"username": "rhea", "item_registry": registry})
	assert_eq(int(r["cost"]), 40, "rare rate 4 * missing 10 = 40 (vs 10 at base)")
	assert_eq(ServicesStore.get_coins(cid), before - 40, "the rarer sink drains 4x")
	var rows := CoinLedger.test_move_rows()
	assert_eq(int(rows[rows.size() - 1]["delta"]), -40, "ledger records the true scaled -40 debit")


func test_repair_op_base_rate_when_no_registry_matches_t364() -> void:
	# Backward-compat: no registry (older callers) => rarity "" => base rate => the exact T-364 number.
	var cid := _char("sam")
	_equip(cid, "weapon", "itm_iron_sword")
	ServicesStore.adjust_coins(cid, 900)
	DurabilityOps.apply_death_wear({"username": "sam"})  # missing 10
	var r: Dictionary = DurabilityOps.repair_op({"username": "sam"})
	assert_eq(int(r["cost"]), 10, "no registry => base rate 1 * missing 10 = 10 (identity)")


func test_repair_noop_when_nothing_worn() -> void:
	_char("erin")
	var r: Dictionary = DurabilityOps.repair_op({"username": "erin"})
	assert_true(bool(r.get("ok", false)))
	assert_eq(int(r.get("cost", -1)), 0, "nothing to repair costs nothing")


# ---- adversarial: no forgeable client verb reaches wear/repair internals --------


func test_no_forged_verb_reaches_durability() -> void:
	var m: Node = Main.new()
	# The world calls apply_death_wear/repair_op as SERVER-OBSERVED master methods; a client that
	# forges obvious durability verbs (or names another player) must hit unknown_method, never a
	# path that wears someone's gear or grants a free repair.
	for forged in ["set_durability", "durability", "wear", "repair", "restore_durability"]:
		var raw := JSON.stringify({"id": 1, "method": forged, "params": {"username": "victim"}})
		var resp: Dictionary = JSON.parse_string(m._handle_message(raw))
		assert_eq(
			str(resp["result"].get("error", "")),
			"unknown_method",
			"forged durability verb '%s' is not a dispatch surface" % forged
		)
	m.free()
