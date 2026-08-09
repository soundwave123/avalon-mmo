extends GutTest

# T-681: the shared required_level gate — one validator, BOTH doors.
#
# The point of these tests is not that `equip()` grew an `if`. It is that the gate is reachable
# through every path that acts on an item definition:
#   1. inventory_logic.equip()   (bag -> equip slot)
#   2. craft_ops.use_item_op()   (the use_effect path, which never touches equip() at all)
# and that a piece moved by the AUCTION receive path or the TRADE commit path can be HELD by an
# under-level character but not WORN (ADR 0011's ladder; hold-but-not-wear is intended behavior —
# binding/BoP is deliberately out of scope, see the ticket).

const CharacterManager = preload("res://scripts/character_manager.gd")
const _ILG = preload("res://scripts/item_level_gate.gd")
const _IL = preload("res://scripts/inventory_logic.gd")
const _CO = preload("res://scripts/craft_ops.gd")
const _TL = preload("res://scripts/trade_logic.gd")

# An epic a level-19 boss drops (required_level 17), a starter weapon, and a level-gated potion.
const REGISTRY := {
	"itm_dirgemother_knell":
	{
		"slot": "weapon",
		"stackable": false,
		"max_stack": 1,
		"armor_type": "none",
		"rarity": "epic",
		"item_level": 22,
		"required_level": 17,
	},
	"itm_starter_sword":
	{
		"slot": "weapon",
		"stackable": false,
		"max_stack": 1,
		"armor_type": "none",
		"rarity": "common",
		"item_level": 1,
		"required_level": 1,
	},
	# No level fields at all — the back-compat fail-open case (an item a migration never reached).
	"itm_legacy_blade": {"slot": "weapon", "stackable": false, "max_stack": 1},
	"itm_potion_potent_healing":
	{
		"slot": "none",
		"stackable": true,
		"max_stack": 20,
		"item_level": 12,
		"required_level": 10,
		"use_effect": {"kind": "heal", "amount": 500},
	},
}


func before_each() -> void:
	CharacterManager.reset_for_test()


func _bag(slot_index: int, item_id: String) -> Dictionary:
	return {"slot_type": "bag", "slot_index": slot_index, "item_id": item_id, "item_count": 1}


func _cid(username: String, level: int) -> int:
	CharacterManager.ensure_character(username)
	var cid := int(CharacterManager.get_character(username)["id"])
	if level > 1:
		# leveling.gd: total_xp(L) == 50*(L-1)*L. Award exactly that to land on `level`.
		CharacterManager.award_xp_to_character(cid, 50 * (level - 1) * level)
	assert_eq(int(CharacterManager.get_character_by_id(cid)["level"]), level, "test fixture level")
	return cid


# ---- the validator itself -------------------------------------------------------------


func test_defaults_are_ungated() -> void:
	assert_eq(_ILG.required_level({}), 1)
	assert_eq(_ILG.item_level({}), 1)
	assert_true(_ILG.meets({}, 1), "a definition with no fields gates nothing")


func test_unresolved_character_level_fails_open() -> void:
	# char_level <= 0 means the caller could not resolve a character (tests / non-character
	# callers) — the same fail-open convention T-063's empty char_class uses.
	assert_true(_ILG.meets(REGISTRY["itm_dirgemother_knell"], 0))
	assert_eq(_ILG.refusal(REGISTRY["itm_dirgemother_knell"], 0), "")


func test_refusal_reason_is_the_routed_string() -> void:
	assert_eq(_ILG.refusal(REGISTRY["itm_dirgemother_knell"], 5), "too_low_level")
	assert_eq(_ILG.refusal(REGISTRY["itm_dirgemother_knell"], 17), "", "exactly at the gate passes")


# ---- door 1: equip() ------------------------------------------------------------------


func test_equip_rejects_under_level_and_leaves_slots_untouched() -> void:
	var slots := [_bag(0, "itm_dirgemother_knell")]
	var r := _IL.equip(slots, 0, REGISTRY, "warrior", 5)
	assert_false(r["ok"])
	assert_eq(r["reason"], "too_low_level")
	assert_eq_deep(r["slots"], slots)  # a refused equip never moves a row


func test_equip_allows_at_the_gate() -> void:
	var r := _IL.equip([_bag(0, "itm_dirgemother_knell")], 0, REGISTRY, "warrior", 17)
	assert_true(r["ok"], "the level that earned it wears it")
	assert_eq(r["equipped_item"], "itm_dirgemother_knell")


func test_equip_of_unmigrated_item_is_ungated() -> void:
	assert_true(_IL.equip([_bag(0, "itm_legacy_blade")], 0, REGISTRY, "warrior", 1)["ok"])


func test_equip_armor_gate_still_precedes_the_level_gate() -> void:
	# Both gates live; the armor refusal is unchanged by T-681 (existing behavior preserved).
	var reg := REGISTRY.duplicate(true)
	reg["itm_plate_helm"] = {
		"slot": "head",
		"stackable": false,
		"max_stack": 1,
		"armor_type": "plate",
		"item_level": 20,
		"required_level": 18,
	}
	var r := _IL.equip([_bag(0, "itm_plate_helm")], 0, reg, "mage", 1)
	assert_eq(r["reason"], "wrong_armor_type", "the armor gate fires first, as before")


func test_try_equip_resolves_the_level_from_the_persisted_row() -> void:
	# The gate's input is server-authoritative: character_manager reads the `level` column, the
	# client never names it.
	var cid := _cid("lowbie", 5)
	CharacterManager.add_item_to_bag(cid, "itm_dirgemother_knell", 1, 0)
	var refused := CharacterManager.try_equip(cid, 0, REGISTRY)
	assert_false(refused["ok"])
	assert_eq(refused["reason"], "too_low_level")

	var capped := _cid("raider", 17)
	CharacterManager.add_item_to_bag(capped, "itm_dirgemother_knell", 1, 0)
	assert_true(CharacterManager.try_equip(capped, 0, REGISTRY)["ok"])


# ---- door 2: the use_effect path (never touches equip()) --------------------------------


func test_use_item_rejects_under_level_without_consuming() -> void:
	var cid := _cid("lowbie", 5)
	CharacterManager.add_item_to_bag(cid, "itm_potion_potent_healing", 2, 0)
	var r := _CO.use_item_op({"username": "lowbie", "slot_index": 0, "item_registry": REGISTRY})
	assert_eq(str(r.get("error", "")), "too_low_level")
	assert_eq(
		int(
			_IL.bag_item_counts(CharacterManager.get_inventory(cid)).get(
				"itm_potion_potent_healing", 0
			)
		),
		2,
		"a refused use consumes nothing"
	)


func test_use_item_allows_at_the_gate() -> void:
	var cid := _cid("veteran", 12)
	CharacterManager.add_item_to_bag(cid, "itm_potion_potent_healing", 2, 0)
	var r := _CO.use_item_op({"username": "veteran", "slot_index": 0, "item_registry": REGISTRY})
	assert_true(bool(r.get("ok", false)), "at level the effect fires")
	assert_eq(int(r["effect"]["amount"]), 500)
	assert_eq(
		int(
			_IL.bag_item_counts(CharacterManager.get_inventory(cid)).get(
				"itm_potion_potent_healing", 0
			)
		),
		1,
		"exactly one consumed"
	)


# ---- the twink vectors: HELD, not WORN ---------------------------------------------------


func test_auction_receive_delivers_the_item_but_it_cannot_be_worn() -> void:
	# auction_ops.gd's receive is literally CharacterManager.try_add_items — a bought BiS piece
	# reaches a level-5 alt's bag. That transfer is INTENDED to succeed; the equip is what stops.
	var cid := _cid("lowbie", 5)
	var granted := CharacterManager.try_add_items(
		cid, [{"item_id": "itm_dirgemother_knell", "count": 1}], REGISTRY
	)
	assert_true(granted["ok"], "the auction house still hands the item over (hold is intended)")
	assert_eq(
		int(
			_IL.bag_item_counts(CharacterManager.get_inventory(cid)).get("itm_dirgemother_knell", 0)
		),
		1,
		"held"
	)
	assert_eq(CharacterManager.try_equip(cid, 0, REGISTRY)["reason"], "too_low_level", "not worn")


func test_trade_commit_delivers_the_item_but_it_cannot_be_worn() -> void:
	# The real trade_logic.build_commit plan, then the same persist trade_ops performs.
	var giver := _cid("main", 20)
	var taker := _cid("alt", 5)
	CharacterManager.add_item_to_bag(giver, "itm_dirgemother_knell", 1, 0)
	var store := _TL.new_store()
	_TL.request(store, giver, taker)
	_TL.accept(store, taker)
	_TL.offer_item(store, giver, 0, 1, CharacterManager.get_inventory(giver))
	_TL.confirm(store, giver)
	_TL.confirm(store, taker)
	var session := _TL.session_for(store, giver)
	var plan := _TL.build_commit(
		session,
		CharacterManager.get_inventory(giver),
		CharacterManager.get_inventory(taker),
		0,
		0,
		REGISTRY
	)
	assert_true(bool(plan.get("ok", false)), "the trade itself is not level-gated: %s" % plan)
	CharacterManager._persist_inventory(giver, plan["slots_a"])
	CharacterManager._persist_inventory(taker, plan["slots_b"])
	assert_eq(
		int(
			_IL.bag_item_counts(CharacterManager.get_inventory(taker)).get(
				"itm_dirgemother_knell", 0
			)
		),
		1,
		"the twinked epic arrived"
	)
	assert_eq(
		CharacterManager.try_equip(taker, 0, REGISTRY)["reason"],
		"too_low_level",
		"...and stays in the bag"
	)
