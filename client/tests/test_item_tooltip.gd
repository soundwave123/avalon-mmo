extends "res://addons/gut/test.gd"
# T-233: ItemTooltip — the hover-an-item tooltip fed by the inventory panel's enriched slot dict.
# build_lines() is the pure Dictionary -> Array[String] builder; asserted here without a live tree.
# The live-mouse-follow (_process/_follow_mouse) is proven visually (docs/verification/t233/).

var _tooltip: ItemTooltip = null


func before_each() -> void:
	_tooltip = ItemTooltip.new()
	add_child(_tooltip)
	await get_tree().process_frame


func after_each() -> void:
	_tooltip.queue_free()


func _weapon() -> Dictionary:
	return {
		"name": "Iron Sword",
		"rarity": "uncommon",
		"slot": "weapon",
		"stats": {"attack": 8},
		"vendor_value": 35,
	}


func test_starts_hidden() -> void:
	assert_false(_tooltip.visible)


func test_build_lines_header_is_rarity_colored_name() -> void:
	var lines := ItemTooltip.build_lines(_weapon())
	assert_eq(lines[0], Rarity.colorize("Iron Sword", "uncommon"))
	assert_eq(lines[0], "[color=#1eff00]Iron Sword[/color]")


func test_build_lines_body_has_slot_stat_and_value() -> void:
	var lines := ItemTooltip.build_lines(_weapon())
	assert_true(lines.has("Weapon"), "slot line")
	assert_true(lines.has("Damage: 8"), "attack stat -> Damage line")
	assert_true(lines.has("Sell: 35c"), "vendor_value -> Sell line")


func test_build_lines_armor_stat() -> void:
	var cap := {
		"name": "Leather Cap",
		"rarity": "uncommon",
		"slot": "head",
		"stats": {"armor": 3},
		"vendor_value": 12,
	}
	var lines := ItemTooltip.build_lines(cap)
	assert_true(lines.has("Armor: 3"))


func test_build_lines_no_slot_line_for_bag_only_item() -> void:
	var pelt := {
		"name": "Wolf Pelt",
		"rarity": "common",
		"slot": "none",
		"stats": {},
		"vendor_value": 2,
	}
	var lines := ItemTooltip.build_lines(pelt)
	assert_false(lines.has("None"), "slot=none is not shown as a body line")
	assert_true(lines.has("Sell: 2c"))


func test_show_for_makes_tooltip_visible_with_built_text() -> void:
	_tooltip.show_for(_weapon())
	assert_true(_tooltip.visible)


func test_hide_tooltip_hides_it() -> void:
	_tooltip.show_for(_weapon())
	_tooltip.hide_tooltip()
	assert_false(_tooltip.visible)


# ---- T-422e: equipped comparison deltas ----


func _bag_sword(attack: int) -> Dictionary:
	return {
		"name": "Bag Sword",
		"rarity": "rare",
		"slot": "weapon",
		"slot_type": "bag",
		"stats": {"attack": attack},
		"vendor_value": 50
	}


func _worn(slot: String, stats: Dictionary) -> Dictionary:
	return {"name": "Worn " + slot, "slot": slot, "slot_type": slot, "stats": stats}


func test_delta_upgrade_is_positive() -> void:
	var d := ItemTooltip.stat_deltas(_bag_sword(17), {"stats": {"attack": 8}})
	assert_eq(int(d["attack"]), 9, "17 - 8 = +9")


func test_delta_downgrade_is_negative() -> void:
	var d := ItemTooltip.stat_deltas(_bag_sword(6), {"stats": {"attack": 8}})
	assert_eq(int(d["attack"]), -2, "6 - 8 = -2")


func test_delta_empty_slot_is_all_positive() -> void:
	# Nothing equipped -> the item's own stats are the full gain.
	var d := ItemTooltip.stat_deltas(_bag_sword(11), {})
	assert_eq(int(d["attack"]), 11)


func test_delta_union_of_stats() -> void:
	var item := {"stats": {"attack": 5}}
	var eq := {"stats": {"armor": 4}}
	var d := ItemTooltip.stat_deltas(item, eq)
	assert_eq(int(d["attack"]), 5, "gain attack the equipped lacked")
	assert_eq(int(d["armor"]), -4, "lose armor the item lacks")


func test_compare_lines_upgrade_green() -> void:
	var lines := ItemTooltip.compare_lines(_bag_sword(17), {"stats": {"attack": 8}})
	assert_true(lines.has("[color=#5fe36b]+9 Damage[/color]"), "green +9 Damage")
	assert_eq(lines[0], "[color=#9aa0a6]vs equipped[/color]", "header present")


func test_compare_lines_downgrade_red() -> void:
	var lines := ItemTooltip.compare_lines(_bag_sword(6), {"stats": {"attack": 8}})
	assert_true(lines.has("[color=#ff5555]-2 Damage[/color]"), "red -2 Damage")


func test_compare_lines_empty_slot_shows_full_gain() -> void:
	var lines := ItemTooltip.compare_lines(_bag_sword(11), {})
	assert_true(lines.has("[color=#5fe36b]+11 Damage[/color]"))


func test_compare_lines_identical_is_empty() -> void:
	# Same-slot swap into an identical item -> no net change -> no comparison block.
	var lines := ItemTooltip.compare_lines(_bag_sword(8), {"stats": {"attack": 8}})
	assert_eq(lines.size(), 0, "zero deltas render nothing")


func test_show_for_bag_item_appends_comparison() -> void:
	_tooltip.set_equipment({"weapon": {"stats": {"attack": 8}}})
	_tooltip.show_for(_bag_sword(17))
	assert_true(_tooltip.visible)


func test_show_for_equipped_item_does_not_self_compare() -> void:
	# Hovering the worn cell itself (slot_type == its equip slot) -> no "vs equipped" block, even
	# though it has stats (guards against a bogus all-positive gain on gear you already wear).
	_tooltip.set_equipment({"weapon": _worn("weapon", {"attack": 8})})
	assert_false(
		_tooltip._should_compare(_worn("weapon", {"attack": 8})), "worn cell isn't compared"
	)


func test_show_for_bag_item_into_empty_slot_compares() -> void:
	_tooltip.set_equipment({})  # nothing worn
	assert_true(_tooltip._should_compare(_bag_sword(11)), "a bag weapon still compares (vs empty)")


# T-681: the gear ladder's level dimension. The SERVER owns the gate (item_level_gate.gd); these
# lines only tell the player what it will say, before they click.


func _epic() -> Dictionary:
	return {
		"name": "Dirgemother's Knell",
		"rarity": "epic",
		"slot": "weapon",
		"stats": {"attack": 27},
		"vendor_value": 400,
		"item_level": 22,
		"required_level": 17,
	}


func after_all() -> void:
	ItemTooltip.set_character_level(0)  # static state: leave it as we found it


func test_level_lines_render_for_a_levelled_item() -> void:
	ItemTooltip.set_character_level(20)
	var lines := ItemTooltip.build_lines(_epic())
	assert_true(lines.has("[color=#9aa0a6]Item Level 22[/color]"), "item_level line")
	assert_true(lines.has("Requires Level 17"), "requirement is plain text when met")


func test_requirement_turns_red_when_under_level() -> void:
	ItemTooltip.set_character_level(5)
	var lines := ItemTooltip.build_lines(_epic())
	assert_true(lines.has("[color=#ff5555]Requires Level 17[/color]"), "unmet requirement is red")


func test_requirement_is_not_red_before_the_level_is_known() -> void:
	# Pre-login there is no player_stats yet; a 0 level must not paint every item red.
	ItemTooltip.set_character_level(0)
	var lines := ItemTooltip.build_lines(_epic())
	assert_true(lines.has("Requires Level 17"), "unknown level renders neutral, not red")


func test_ungated_item_renders_no_level_lines() -> void:
	# 1/1 is the ungated default — starter gear and materials look exactly as they did in T-233.
	ItemTooltip.set_character_level(1)
	var lines := ItemTooltip.build_lines(_weapon())
	for line: String in lines:
		assert_false(line.contains("Item Level"), "no item_level line on an ungated item")
		assert_false(line.contains("Requires Level"), "no requirement line on an ungated item")
