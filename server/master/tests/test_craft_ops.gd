extends GutTest

# T-414: crafting ops against the in-memory backend (same test-mode discipline as test_services).
# Covers: gather yield path, recipe learn (ledgered "recipe" coin sink), craft all-or-nothing
# (partial materials leave inventory UNTOUCHED), each consumable effect (heal from item data /
# rested cap-clamped / field repair pct), and the forged-input rejections (client-named output,
# effect, or item are never read).

const CharacterManager = preload("res://scripts/character_manager.gd")
const _CO = preload("res://scripts/craft_ops.gd")
const _CL = preload("res://scripts/coin_ledger.gd")
const _IL = preload("res://scripts/inventory_logic.gd")

const REGISTRY := {
	"itm_herb_bloodthorn": {"slot": "none", "stackable": true, "max_stack": 50, "use_effect": {}},
	"itm_herb_marshmint": {"slot": "none", "stackable": true, "max_stack": 50, "use_effect": {}},
	"itm_reagent_venom_gland":
	{"slot": "none", "stackable": true, "max_stack": 20, "use_effect": {}},
	"itm_potion_minor_healing":
	{
		"slot": "none",
		"stackable": true,
		"max_stack": 20,
		"use_effect": {"kind": "heal", "amount": 120}
	},
	"itm_ration_travelers":
	{
		"slot": "none",
		"stackable": true,
		"max_stack": 20,
		"use_effect": {"kind": "rested", "amount": 400}
	},
	"itm_field_repair_kit":
	{
		"slot": "none",
		"stackable": true,
		"max_stack": 10,
		"use_effect": {"kind": "repair", "pct": 0.35}
	},
	"itm_ore_iron": {"slot": "none", "stackable": true, "max_stack": 50, "use_effect": {}},
	"itm_timber_rough": {"slot": "none", "stackable": true, "max_stack": 50, "use_effect": {}},
	"itm_smith_broadsword":
	{"slot": "weapon", "stackable": false, "max_stack": 1, "use_effect": {}},
	"itm_smiths_repair_kit":
	{
		"slot": "none",
		"stackable": true,
		"max_stack": 10,
		"use_effect": {"kind": "repair", "pct": 0.5}
	},
}

const RECIPE_MINOR := {
	"id": "rec_minor_healing",
	"profession": "alchemy",
	"trainer_id": "npc_alchemist",
	"coin_cost": 40,
	"inputs": [{"item": "itm_herb_bloodthorn", "count": 2}],
	"output": {"item": "itm_potion_minor_healing", "count": 1},
}

# T-414 slice 2: a multi-input smithing recipe — same craft_op, zero new code paths.
const RECIPE_BROADSWORD := {
	"id": "rec_forgehand_broadsword",
	"profession": "smithing",
	"trainer_id": "npc_blacksmith",
	"coin_cost": 60,
	"inputs": [{"item": "itm_ore_iron", "count": 3}, {"item": "itm_timber_rough", "count": 1}],
	"output": {"item": "itm_smith_broadsword", "count": 1},
}


func before_each() -> void:
	CharacterManager.reset_for_test()


func _cid(username: String) -> int:
	CharacterManager.ensure_character(username)
	return int(CharacterManager.get_character(username)["id"])


func _bag_count(cid: int, item_id: String) -> int:
	return int(_IL.bag_item_counts(CharacterManager.get_inventory(cid)).get(item_id, 0))


func _ledger_rows(cid: int) -> Array:
	var out: Array = []
	for row: Dictionary in _CL.test_move_rows():
		if int(row["character_id"]) == cid:
			out.append(row)
	return out


# ---- gather -------------------------------------------------------------


func test_gather_mints_world_named_yield() -> void:
	var cid := _cid("alice")
	var r := _CO.gather_op(
		{
			"username": "alice",
			"item_id": "itm_herb_bloodthorn",
			"count": 1,
			"item_registry": REGISTRY
		}
	)
	assert_true(bool(r.get("ok", false)), "gather yields")
	assert_eq(_bag_count(cid, "itm_herb_bloodthorn"), 1, "herb landed in the bag")
	# material faucet is item-tracked, NOT coin — the coin ledger must be untouched
	assert_eq(_ledger_rows(cid).size(), 0, "no coin-ledger row for a material faucet")


func test_gather_rejects_unknown_item() -> void:
	var r := _CO.gather_op(
		{"username": "alice", "item_id": "itm_forged", "count": 1, "item_registry": REGISTRY}
	)
	assert_false(bool(r.get("ok", false)), "unknown item rejected by the registry gate")


# ---- recipe learn (trainer surface; ledgered coin sink) -------------------


func test_learn_recipe_debits_ledgered_recipe_sink() -> void:
	var cid := _cid("bob")
	var before := ServicesStore.get_coins(cid)
	var r := _CO.recipe_op({"username": "bob", "action": "learn", "recipe": RECIPE_MINOR})
	assert_true("rec_minor_healing" in r.get("known", []), "recipe now known")
	assert_eq(int(r.get("coins", -1)), before - 40, "coin cost debited")
	var rows := _ledger_rows(cid)
	assert_eq(rows.size(), 1, "one ledger row")
	assert_eq(str(rows[0]["reason"]), "recipe", "ledgered under reason 'recipe'")
	assert_eq(int(rows[0]["delta"]), -40, "sink delta")


func test_learn_recipe_rejects_already_known_and_broke() -> void:
	var cid := _cid("cara")
	_CO.recipe_op({"username": "cara", "action": "learn", "recipe": RECIPE_MINOR})
	var again := _CO.recipe_op({"username": "cara", "action": "learn", "recipe": RECIPE_MINOR})
	assert_eq(str(again.get("error", "")), "already_known")
	ServicesStore.adjust_coins(cid, -ServicesStore.get_coins(cid))  # drain
	var broke := (
		_CO
		. recipe_op(
			{
				"username": "cara",
				"action": "learn",
				"recipe": {"id": "rec_other", "coin_cost": 40},
			}
		)
	)
	assert_eq(str(broke.get("error", "")), "insufficient_coins")
	assert_false("rec_other" in ServicesStore.get_known_recipes(cid), "no grant on failed debit")


# ---- craft (all-or-nothing) ------------------------------------------------


func _learn(username: String) -> int:
	var cid := _cid(username)
	ServicesStore.grant_recipe(cid, "rec_minor_healing")
	return cid


func test_craft_consumes_inputs_and_grants_output() -> void:
	var cid := _learn("dana")
	CharacterManager.add_item_to_bag(cid, "itm_herb_bloodthorn", 3, 0)
	var r := _CO.craft_op({"username": "dana", "recipe": RECIPE_MINOR, "item_registry": REGISTRY})
	assert_true(bool(r.get("ok", false)), "craft succeeds")
	assert_eq(_bag_count(cid, "itm_herb_bloodthorn"), 1, "2 of 3 herbs consumed")
	assert_eq(_bag_count(cid, "itm_potion_minor_healing"), 1, "potion granted")


func test_craft_partial_materials_leaves_inventory_untouched() -> void:
	var cid := _learn("erin")
	CharacterManager.add_item_to_bag(cid, "itm_herb_bloodthorn", 1, 0)  # needs 2
	var before: Array = CharacterManager.get_inventory(cid).duplicate(true)
	var r := _CO.craft_op({"username": "erin", "recipe": RECIPE_MINOR, "item_registry": REGISTRY})
	assert_eq(str(r.get("error", "")), "missing_materials")
	assert_eq_deep(CharacterManager.get_inventory(cid), before)
	assert_eq(_bag_count(cid, "itm_potion_minor_healing"), 0, "no output on failure")


func test_craft_rejects_unknown_recipe() -> void:
	var cid := _cid("finn")
	CharacterManager.add_item_to_bag(cid, "itm_herb_bloodthorn", 2, 0)
	var r := _CO.craft_op({"username": "finn", "recipe": RECIPE_MINOR, "item_registry": REGISTRY})
	assert_eq(str(r.get("error", "")), "recipe_not_known", "unlearned recipe cannot craft")
	assert_eq(_bag_count(cid, "itm_potion_minor_healing"), 0)


func test_craft_output_is_server_named_from_recipe() -> void:
	# A forged params "output" key is never read — the output comes off the recipe def only.
	var cid := _learn("gail")
	CharacterManager.add_item_to_bag(cid, "itm_herb_bloodthorn", 2, 0)
	var forged := RECIPE_MINOR.duplicate(true)
	var r := (
		_CO
		. craft_op(
			{
				"username": "gail",
				"recipe": forged,
				"item_registry": REGISTRY,
				"output": {"item": "itm_field_repair_kit", "count": 99},
			}
		)
	)
	assert_true(bool(r.get("ok", false)))
	assert_eq(_bag_count(cid, "itm_field_repair_kit"), 0, "forged top-level output ignored")
	assert_eq(_bag_count(cid, "itm_potion_minor_healing"), 1, "recipe-named output granted")


# ---- use_item (effect from ITEM DATA, never the client) --------------------


func test_use_heal_potion_consumes_and_returns_data_effect() -> void:
	var cid := _cid("hana")
	CharacterManager.add_item_to_bag(cid, "itm_potion_minor_healing", 2, 0)
	var r := _CO.use_item_op({"username": "hana", "slot_index": 0, "item_registry": REGISTRY})
	assert_true(bool(r.get("ok", false)))
	assert_eq(str(r["effect"]["kind"]), "heal")
	assert_eq(int(r["effect"]["amount"]), 120, "amount is the ITEM DATA amount")
	assert_eq(_bag_count(cid, "itm_potion_minor_healing"), 1, "one potion consumed")


func test_use_item_forged_effect_param_is_ignored() -> void:
	var cid := _cid("iris")
	CharacterManager.add_item_to_bag(cid, "itm_potion_minor_healing", 1, 0)
	var r := (
		_CO
		. use_item_op(
			{
				"username": "iris",
				"slot_index": 0,
				"item_registry": REGISTRY,
				"effect": {"kind": "heal", "amount": 999999},
			}
		)
	)
	assert_eq(int(r["effect"]["amount"]), 120, "forged effect param never read")


func test_use_item_rejects_empty_slot_and_non_consumable() -> void:
	var cid := _cid("jack")
	var r := _CO.use_item_op({"username": "jack", "slot_index": 3, "item_registry": REGISTRY})
	assert_eq(str(r.get("error", "")), "empty_slot")
	CharacterManager.add_item_to_bag(cid, "itm_herb_bloodthorn", 1, 5)
	var r2 := _CO.use_item_op({"username": "jack", "slot_index": 5, "item_registry": REGISTRY})
	assert_eq(str(r2.get("error", "")), "not_usable")
	assert_eq(_bag_count(cid, "itm_herb_bloodthorn"), 1, "nothing consumed on rejection")


func test_use_ration_grants_rested_capped() -> void:
	var cid := _cid("kate")
	CharacterManager.add_item_to_bag(cid, "itm_ration_travelers", 1, 0)
	var character0 := CharacterManager.get_character("kate")
	var cap0 := preload("res://scripts/rested_persist.gd").cap(
		int(character0.get("level", 1)), int(character0.get("xp", 0))
	)
	var r := _CO.use_item_op({"username": "kate", "slot_index": 0, "item_registry": REGISTRY})
	assert_true(bool(r.get("ok", false)))
	var pool := int(r.get("rested_remaining", -1))
	assert_eq(pool, mini(400, cap0), "ration banked its rested amount, clamped to the level cap")
	assert_eq(CharacterManager.get_rested_remaining(cid), pool, "persisted")
	# anti-abuse: repeated eating never exceeds the level-scaled cap
	for i in range(50):
		CharacterManager.add_item_to_bag(cid, "itm_ration_travelers", 1, 1)
		var rr := _CO.use_item_op({"username": "kate", "slot_index": 1, "item_registry": REGISTRY})
		pool = int(rr.get("rested_remaining", pool))
	var character := CharacterManager.get_character("kate")
	var ceiling := preload("res://scripts/rested_persist.gd").cap(
		int(character.get("level", 1)), int(character.get("xp", 0))
	)
	assert_true(pool <= ceiling, "pool %d clamped to cap %d" % [pool, ceiling])


# ---- smithing (T-414 slice 2 — the same ops, exercised on the new data shapes) ----


func test_craft_smithing_gear_consumes_multi_inputs() -> void:
	var cid := _cid("mona")
	ServicesStore.grant_recipe(cid, "rec_forgehand_broadsword")
	CharacterManager.add_item_to_bag(cid, "itm_ore_iron", 4, 0)
	CharacterManager.add_item_to_bag(cid, "itm_timber_rough", 1, 1)
	var r := _CO.craft_op(
		{"username": "mona", "recipe": RECIPE_BROADSWORD, "item_registry": REGISTRY}
	)
	assert_true(bool(r.get("ok", false)), "smithing craft succeeds")
	assert_eq(_bag_count(cid, "itm_ore_iron"), 1, "3 of 4 ore consumed")
	assert_eq(_bag_count(cid, "itm_timber_rough"), 0, "timber consumed")
	assert_eq(_bag_count(cid, "itm_smith_broadsword"), 1, "gear piece granted (real item id)")


func test_craft_smithing_insufficient_ore_leaves_inventory_untouched() -> void:
	# Has the timber but only 2 of 3 ore — the multi-input shortfall must abort all-or-nothing.
	var cid := _cid("nils")
	ServicesStore.grant_recipe(cid, "rec_forgehand_broadsword")
	CharacterManager.add_item_to_bag(cid, "itm_ore_iron", 2, 0)
	CharacterManager.add_item_to_bag(cid, "itm_timber_rough", 3, 1)
	var before: Array = CharacterManager.get_inventory(cid).duplicate(true)
	var r := _CO.craft_op(
		{"username": "nils", "recipe": RECIPE_BROADSWORD, "item_registry": REGISTRY}
	)
	assert_eq(str(r.get("error", "")), "missing_materials")
	assert_eq_deep(CharacterManager.get_inventory(cid), before)
	assert_eq(_bag_count(cid, "itm_smith_broadsword"), 0, "no output on failure")


func test_use_smiths_repair_kit_restores_half_of_max() -> void:
	# The capstone: the smith's kit rides the SAME T-412 partial-repair hook, just a deeper pct.
	var cid := _cid("olga")
	ServicesStore.set_durability(cid, "weapon", 0, 40, 100)
	CharacterManager.add_item_to_bag(cid, "itm_smiths_repair_kit", 1, 0)
	var r := _CO.use_item_op({"username": "olga", "slot_index": 0, "item_registry": REGISTRY})
	assert_true(bool(r.get("ok", false)))
	assert_eq(int(r.get("repaired", 0)), 1, "one worn slot improved")
	var dur: Dictionary = ServicesStore.get_durability(cid)
	assert_eq(int(dur["weapon|0"]["current"]), 90, "40 + ceil(0.5*100) = 90 (partial, not full)")
	assert_eq(_bag_count(cid, "itm_smiths_repair_kit"), 0, "kit consumed")


func test_use_repair_kit_restores_pct_of_max() -> void:
	var cid := _cid("liam")
	ServicesStore.set_durability(cid, "weapon", 0, 40, 100)
	CharacterManager.add_item_to_bag(cid, "itm_field_repair_kit", 1, 0)
	var r := _CO.use_item_op({"username": "liam", "slot_index": 0, "item_registry": REGISTRY})
	assert_true(bool(r.get("ok", false)))
	assert_eq(int(r.get("repaired", 0)), 1, "one worn slot improved")
	var dur: Dictionary = ServicesStore.get_durability(cid)
	assert_eq(int(dur["weapon|0"]["current"]), 75, "40 + ceil(0.35*100) = 75 (partial, not full)")
	assert_eq(_bag_count(cid, "itm_field_repair_kit"), 0, "kit consumed")
