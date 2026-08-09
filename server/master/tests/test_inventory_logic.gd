extends "res://addons/gut/test.gd"
# T-036: Pure bag/equip/stacking inventory model.

const IL = preload("res://scripts/inventory_logic.gd")


func _registry() -> Dictionary:
	return {
		"itm_wolf_pelt": {"slot": "none", "stackable": true, "max_stack": 20},
		"itm_iron_sword": {"slot": "weapon", "stackable": false, "max_stack": 1},
		"itm_leather_cap": {"slot": "head", "stackable": false, "max_stack": 1},
	}


func _bag(slot_index: int, item_id: String, count: int) -> Dictionary:
	return {"slot_type": "bag", "slot_index": slot_index, "item_id": item_id, "item_count": count}


func test_add_stackable_into_empty_bag() -> void:
	var r := IL.add_items([], [{"item_id": "itm_wolf_pelt", "count": 5}], _registry())
	assert_true(r["ok"])
	assert_eq(r["slots"].size(), 1)
	assert_eq(r["slots"][0]["slot_type"], "bag")
	assert_eq(r["slots"][0]["item_count"], 5)


func test_add_stackable_tops_up_then_spills() -> void:
	var slots := [_bag(0, "itm_wolf_pelt", 18)]
	var r := IL.add_items(slots, [{"item_id": "itm_wolf_pelt", "count": 5}], _registry())
	assert_true(r["ok"])
	var total: int = IL.bag_item_counts(r["slots"]).get("itm_wolf_pelt", 0)
	assert_eq(total, 23)  # 18 + 5 conserved
	# slot 0 tops to max_stack 20, remaining 3 spill to a second slot
	assert_eq(r["slots"].size(), 2)


func test_add_non_stackable_takes_one_slot_each() -> void:
	var r := IL.add_items([], [{"item_id": "itm_iron_sword", "count": 2}], _registry())
	assert_true(r["ok"])
	assert_eq(r["slots"].size(), 2)
	for entry: Dictionary in r["slots"]:
		assert_eq(int(entry["item_count"]), 1)


func test_add_bag_full_fails_unchanged() -> void:
	var slots: Array = []
	for i in range(IL.BAG_SLOTS):
		slots.append(_bag(i, "itm_iron_sword", 1))
	var r := IL.add_items(slots, [{"item_id": "itm_iron_sword", "count": 1}], _registry())
	assert_false(r["ok"])
	assert_eq(r["reason"], "bag_full")
	assert_eq(r["slots"].size(), IL.BAG_SLOTS)  # unchanged


func test_add_unknown_item_fails_unchanged() -> void:
	var r := IL.add_items([], [{"item_id": "itm_ghost", "count": 1}], _registry())
	assert_false(r["ok"])
	assert_eq(r["reason"], "unknown_item")
	assert_eq(r["slots"].size(), 0)


func test_equip_weapon_from_bag() -> void:
	var slots := [_bag(3, "itm_iron_sword", 1)]
	var r := IL.equip(slots, 3, _registry())
	assert_true(r["ok"])
	var equipped := false
	for entry: Dictionary in r["slots"]:
		if entry["slot_type"] == "weapon":
			equipped = true
			assert_eq(int(entry["slot_index"]), 0)
			assert_eq(entry["item_id"], "itm_iron_sword")
	assert_true(equipped)
	# bag slot 3 no longer holds the sword
	assert_eq(IL.bag_item_counts(r["slots"]).get("itm_iron_sword", 0), 0)
	# T-426: a successful equip reports the equipped item id so the caller can credit a tutorial verb.
	assert_eq(r.get("equipped_item", ""), "itm_iron_sword")


# T-420: the shoulders slot (pauldrons). It joins EQUIP_SLOTS so a shoulders item equips + swaps +
# unequips like head/chest/legs; migration 025's slot_type CHECK admits it for persistence.
func test_equip_shoulders_slot_round_trips() -> void:
	assert_true("shoulders" in IL.EQUIP_SLOTS, "shoulders is an equip slot (T-420)")
	var reg := _registry()
	reg["itm_ironward_pauldrons"] = {"slot": "shoulders", "stackable": false, "max_stack": 1}
	var slots := [_bag(4, "itm_ironward_pauldrons", 1)]
	var r := IL.equip(slots, 4, reg)
	assert_true(r["ok"], "a shoulders item equips")
	var worn := false
	for entry: Dictionary in r["slots"]:
		if entry["slot_type"] == "shoulders":
			worn = true
			assert_eq(entry["item_id"], "itm_ironward_pauldrons")
	assert_true(worn, "the pauldrons occupy the shoulders slot")
	var back := IL.unequip(r["slots"], "shoulders")
	assert_true(back["ok"], "the shoulders slot unequips back to the bag")


func test_equip_swaps_when_slot_occupied() -> void:
	var slots := [
		{"slot_type": "weapon", "slot_index": 0, "item_id": "itm_iron_sword", "item_count": 1},
		_bag(2, "itm_iron_sword", 1),
	]
	# Pretend the bag holds a *different* weapon to swap in; reuse iron_sword id is fine for slot test
	var r := IL.equip(slots, 2, _registry())
	assert_true(r["ok"])
	# old equipped weapon must now sit in the vacated bag slot 2
	var bag2_filled := false
	for entry: Dictionary in r["slots"]:
		if entry["slot_type"] == "bag" and int(entry["slot_index"]) == 2:
			bag2_filled = true
	assert_true(bag2_filled)


func test_equip_non_equippable_fails() -> void:
	var slots := [_bag(0, "itm_wolf_pelt", 1)]
	var r := IL.equip(slots, 0, _registry())
	assert_false(r["ok"])
	assert_eq(r["reason"], "not_equippable")


func test_equip_empty_slot_fails() -> void:
	var r := IL.equip([], 0, _registry())
	assert_false(r["ok"])
	assert_eq(r["reason"], "empty_slot")


func test_unequip_returns_to_bag() -> void:
	var slots := [
		{"slot_type": "weapon", "slot_index": 0, "item_id": "itm_iron_sword", "item_count": 1},
	]
	var r := IL.unequip(slots, "weapon")
	assert_true(r["ok"])
	assert_eq(IL.bag_item_counts(r["slots"]).get("itm_iron_sword", 0), 1)


func test_unequip_nothing_equipped_fails() -> void:
	var r := IL.unequip([], "weapon")
	assert_false(r["ok"])
	assert_eq(r["reason"], "nothing_equipped")


func test_unequip_bag_full_fails() -> void:
	var slots: Array = [
		{"slot_type": "weapon", "slot_index": 0, "item_id": "itm_iron_sword", "item_count": 1},
	]
	for i in range(IL.BAG_SLOTS):
		slots.append(_bag(i, "itm_wolf_pelt", 1))
	var r := IL.unequip(slots, "weapon")
	assert_false(r["ok"])
	assert_eq(r["reason"], "bag_full")


func test_remove_count_aware() -> void:
	var slots := [_bag(0, "itm_wolf_pelt", 5)]
	var partial := IL.remove(slots, "bag", 0, 2)
	assert_true(partial["ok"])
	assert_eq(IL.bag_item_counts(partial["slots"]).get("itm_wolf_pelt", 0), 3)
	var full := IL.remove(partial["slots"], "bag", 0, 3)
	assert_true(full["ok"])
	assert_eq(full["slots"].size(), 0)  # slot dropped


func test_bag_item_counts_sums_and_ignores_equip() -> void:
	var slots := [
		_bag(0, "itm_wolf_pelt", 4),
		_bag(1, "itm_wolf_pelt", 6),
		{"slot_type": "weapon", "slot_index": 0, "item_id": "itm_iron_sword", "item_count": 1},
	]
	var counts := IL.bag_item_counts(slots)
	assert_eq(counts.get("itm_wolf_pelt", 0), 10)
	assert_false(counts.has("itm_iron_sword"))


func test_inputs_not_mutated() -> void:
	var slots := [_bag(0, "itm_wolf_pelt", 5)]
	IL.add_items(slots, [{"item_id": "itm_wolf_pelt", "count": 5}], _registry())
	IL.remove(slots, "bag", 0, 2)
	IL.equip([_bag(0, "itm_iron_sword", 1)], 0, _registry())
	assert_eq(slots.size(), 1)
	assert_eq(int(slots[0]["item_count"]), 5)  # original untouched


# T-063: armor proficiency gate (class can only equip armor types it's proficient with).


func _armor_registry() -> Dictionary:
	return {
		"itm_leather_cap":
		{"slot": "head", "stackable": false, "max_stack": 1, "armor_type": "leather"},
		"itm_iron_sword":
		{"slot": "weapon", "stackable": false, "max_stack": 1, "armor_type": "none"},
	}


func test_equip_armor_proficiency_blocks_off_class() -> void:
	var r := IL.equip([_bag(0, "itm_leather_cap", 1)], 0, _armor_registry(), "mage")
	assert_false(r["ok"], "a mage can't wear leather")
	assert_eq(r["reason"], "wrong_armor_type")


func test_equip_armor_proficiency_allows_class() -> void:
	var r := IL.equip([_bag(0, "itm_leather_cap", 1)], 0, _armor_registry(), "warrior")
	assert_true(r["ok"], "a warrior can wear leather")


# T-224 (mage + priest sets): each caster class is proficient with its own dedicated armor family
# (mage=robe, priest=vestment) so the new wearable sets equip, but cross-class is still blocked.
func _caster_registry() -> Dictionary:
	return {
		"itm_arcanist_robe":
		{"slot": "chest", "stackable": false, "max_stack": 1, "armor_type": "robe"},
		"itm_sanctified_vestment":
		{"slot": "chest", "stackable": false, "max_stack": 1, "armor_type": "vestment"},
	}


func test_equip_caster_sets_gated_by_class() -> void:
	assert_true(
		IL.equip([_bag(0, "itm_arcanist_robe", 1)], 0, _caster_registry(), "mage")["ok"],
		"a mage can wear its robe set"
	)
	assert_true(
		IL.equip([_bag(0, "itm_sanctified_vestment", 1)], 0, _caster_registry(), "priest")["ok"],
		"a priest can wear its vestment set"
	)
	assert_eq(
		IL.equip([_bag(0, "itm_sanctified_vestment", 1)], 0, _caster_registry(), "mage")["reason"],
		"wrong_armor_type",
		"a mage can't wear priest vestments"
	)
	assert_false(
		IL.equip([_bag(0, "itm_arcanist_robe", 1)], 0, _caster_registry(), "warrior")["ok"],
		"a warrior can't wear a mage robe"
	)


func test_equip_weapon_not_armor_gated() -> void:
	var r := IL.equip([_bag(0, "itm_iron_sword", 1)], 0, _armor_registry(), "mage")
	assert_true(r["ok"], "weapons (armor_type none) are never armor-gated")


func test_equip_no_class_no_gate() -> void:
	var r := IL.equip([_bag(0, "itm_leather_cap", 1)], 0, _armor_registry())
	assert_true(r["ok"], "empty char_class = no gate (backward compat)")


# ---- T-058: remove_item_id (provided-items removal) ----


func test_remove_item_id_across_stacks_and_partial() -> void:
	var slots := [
		{"slot_type": "bag", "slot_index": 0, "item_id": "itm_x", "item_count": 2},
		{"slot_type": "bag", "slot_index": 1, "item_id": "itm_x", "item_count": 3},
		{"slot_type": "head", "slot_index": 0, "item_id": "itm_x", "item_count": 1},
	]
	var r: Dictionary = IL.remove_item_id(slots, "itm_x", 4)
	assert_eq(int(r["removed"]), 4)
	var bag_total := 0
	for s: Dictionary in r["slots"]:
		if str(s["slot_type"]) == "bag" and str(s["item_id"]) == "itm_x":
			bag_total += int(s["item_count"])
	assert_eq(bag_total, 1, "5 in bags - 4 removed = 1 left")
	assert_eq(r["slots"].size(), 2, "emptied stack removed; equipped copy untouched")
	assert_eq(slots.size(), 3, "input never mutated")


func test_remove_item_id_removes_what_exists() -> void:
	var slots := [{"slot_type": "bag", "slot_index": 0, "item_id": "itm_x", "item_count": 1}]
	var r: Dictionary = IL.remove_item_id(slots, "itm_x", 5)
	assert_eq(int(r["removed"]), 1, "a dropped/consumed provided item just removes fewer")
	assert_eq(r["slots"].size(), 0)


# ---- T-661 (#51): remove_item_ids (carved out of character_manager's remove_provided_items) ----


func test_remove_item_ids_removes_each_row() -> void:
	var slots := [_bag(0, "itm_wolf_pelt", 5), _bag(1, "itm_iron_sword", 1)]
	var out := IL.remove_item_ids(
		slots, [{"item": "itm_wolf_pelt", "count": 2}, {"item": "itm_iron_sword", "count": 1}]
	)
	var counts := IL.bag_item_counts(out)
	assert_eq(counts.get("itm_wolf_pelt", 0), 3)
	assert_false(counts.has("itm_iron_sword"), "fully-removed stack drops the slot")
	assert_eq(slots.size(), 2, "input never mutated")


func test_remove_item_ids_empty_list_is_a_no_op() -> void:
	var slots := [_bag(0, "itm_wolf_pelt", 5)]
	var out := IL.remove_item_ids(slots, [])
	assert_eq(IL.bag_item_counts(out).get("itm_wolf_pelt", 0), 5)


# ---- T-661 (#51): remove_collect_objective_items (quest turn-in item consume) ----


func test_remove_collect_objective_items_removes_exactly_the_required_count() -> void:
	var slots := [_bag(0, "itm_practice_token", 3)]
	var objectives := [{"type": "collect", "target": "itm_practice_token", "count": 1}]
	var out := IL.remove_collect_objective_items(slots, objectives)
	assert_eq(
		IL.bag_item_counts(out).get("itm_practice_token", 0),
		2,
		"only the objective's own count is consumed, not the whole stack"
	)


func test_remove_collect_objective_items_ignores_non_collect_objectives() -> void:
	var slots := [_bag(0, "itm_wolf_pelt", 2)]
	var objectives := [{"type": "kill", "target": "mob_wolf", "count": 5}]
	var out := IL.remove_collect_objective_items(slots, objectives)
	assert_eq(
		IL.bag_item_counts(out).get("itm_wolf_pelt", 0), 2, "a kill objective removes nothing"
	)


func test_remove_collect_objective_items_handles_multiple_collect_rows() -> void:
	var slots := [_bag(0, "itm_copper_ore", 5), _bag(1, "itm_rugged_fiber", 5)]
	var objectives := [
		{"type": "collect", "target": "itm_copper_ore", "count": 5},
		{"type": "collect", "target": "itm_rugged_fiber", "count": 5},
	]
	var out := IL.remove_collect_objective_items(slots, objectives)
	var counts := IL.bag_item_counts(out)
	assert_false(counts.has("itm_copper_ore"))
	assert_false(counts.has("itm_rugged_fiber"))


func test_remove_collect_objective_items_missing_stack_removes_what_exists() -> void:
	# The gathered item was already dropped/consumed elsewhere — best-effort, not an error.
	var out := IL.remove_collect_objective_items(
		[], [{"type": "collect", "target": "itm_practice_token", "count": 1}]
	)
	assert_eq(out.size(), 0)


# T-720: the tutorial chain is MANDATORY and auto-offered (T-710), so anything it hands you to wear
# must be wearable by every class — a mage handed a leather cap hits a hard wall at ~minute 3 with
# no visible rejection (the equip intent's ack is fire-and-forget). Guards the DATA, not the gate:
# read the real quest + item files so a future reward edit re-breaks the tutorial here, not live.
func test_every_tutorial_granted_wearable_fits_all_three_classes() -> void:
	var items_file := FileAccess.open("res://../world/data/items/items.json", FileAccess.READ)
	assert_not_null(items_file, "items.json must be readable from the master test project")
	var items: Array = JSON.parse_string(items_file.get_as_text())["items"]
	var by_id := {}
	for entry: Dictionary in items:
		by_id[str(entry.get("id", ""))] = entry

	for quest_file in ["q_tut_01_first_steps", "q_tut_02_kit_up", "q_tut_03_read_the_fight"]:
		var path := "res://../world/data/quests/%s.json" % quest_file
		var qf := FileAccess.open(path, FileAccess.READ)
		assert_not_null(qf, "%s must be readable" % quest_file)
		var quest: Dictionary = JSON.parse_string(qf.get_as_text())
		var granted: Array = quest.get("rewards", {}).get("items", [])
		for grant: Dictionary in granted:
			var item_id := str(grant.get("item", ""))
			var armor_type := str(by_id.get(item_id, {}).get("armor_type", "none"))
			if armor_type == "none":
				continue  # weapons/misc are never armor-gated
			for char_class in ["warrior", "mage", "priest"]:
				assert_true(
					IL._ARMOR_PROFICIENCY[char_class].has(armor_type),
					(
						"%s grants %s (%s) which %s cannot wear — the tutorial is mandatory"
						% [quest_file, item_id, armor_type, char_class]
					)
				)
