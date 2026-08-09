extends "res://addons/gut/test.gd"
# T-640: PaperdollSlots — the WoW-shaped slot layout builder. Only the server's real EQUIP_SLOTS
# (inventory_logic.gd: head/chest/legs/weapon/offhand/shoulders) are LIVE + interactive; every other
# WoW reference slot renders as a dim, no-input chrome placeholder. Headless (pure RefCounted).

var _left: VBoxContainer = null
var _right: VBoxContainer = null
var _bottom: HBoxContainer = null
var _slots: PaperdollSlots = null


func before_each() -> void:
	_left = VBoxContainer.new()
	_right = VBoxContainer.new()
	_bottom = HBoxContainer.new()
	add_child(_left)
	add_child(_right)
	add_child(_bottom)
	await get_tree().process_frame
	_slots = PaperdollSlots.new()
	_slots.build(_left, _right, _bottom)


func after_each() -> void:
	_left.queue_free()
	_right.queue_free()
	_bottom.queue_free()


func test_live_slots_match_the_server_equip_slots() -> void:
	for slot in ["head", "shoulders", "chest", "legs", "weapon", "offhand"]:
		assert_not_null(_slots.get_slot_cell(slot), "%s is live" % slot)
	assert_eq(_slots.live_slot_types().size(), 6)


func test_chrome_slots_cover_the_full_wow_reference_layout() -> void:
	var expected := [
		"neck",
		"back",
		"shirt",
		"tabard",
		"wrist",
		"hands",
		"waist",
		"feet",
		"finger1",
		"finger2",
		"trinket1",
		"trinket2",
		"ranged",
	]
	for slot in expected:
		assert_not_null(_slots.get_chrome_cell(slot), "%s renders as chrome" % slot)
	assert_eq(_slots.chrome_slot_types().size(), expected.size())


func test_chrome_cells_are_dim_and_take_no_input() -> void:
	for slot in _slots.chrome_slot_types():
		var cell: ItemCell = _slots.get_chrome_cell(slot)
		assert_eq(cell.mouse_filter, Control.MOUSE_FILTER_IGNORE, "%s ignores input" % slot)
		assert_true(cell.modulate.a < 1.0, "%s reads dim" % slot)


func test_left_right_bottom_placement_matches_the_wow_reference() -> void:
	assert_eq(_left.get_child_count(), 8, "left column: Head/Neck/Shoulder/Back/Chest/Shirt/…")
	assert_eq(_right.get_child_count(), 8, "right column: Hands/Waist/Legs/Feet/Finger×2/Trinket×2")
	assert_eq(_bottom.get_child_count(), 3, "bottom row: Weapon/Offhand/Ranged")
	assert_eq(_slots.get_slot_cell("head").get_parent(), _left)
	assert_eq(_slots.get_slot_cell("legs").get_parent(), _right)
	assert_eq(_slots.get_slot_cell("weapon").get_parent(), _bottom)


func test_update_equipment_only_touches_live_cells() -> void:
	_slots.update_equipment(
		{"weapon": {"slot_type": "weapon", "name": "Iron Sword", "count": 1, "rarity": "common"}}
	)
	assert_eq(str(_slots.get_slot_cell("weapon").get_entry().get("name")), "Iron Sword")
	assert_true(_slots.get_slot_cell("head").get_entry().is_empty())


func test_empty_slot_hint_survives_repeated_updates() -> void:
	# Frames persist and are reconfigured in place; the empty-slot hint must not get blanked when a
	# slot is unequipped again (configure() only remembers what's re-passed to it each call).
	_slots.update_equipment({"weapon": {"slot_type": "weapon", "name": "Sword", "count": 1}})
	_slots.update_equipment({})
	assert_eq(_slots.get_slot_cell("weapon").get_node("Hint").text, "Weap")


func test_click_live_slot_emits_unequip_action() -> void:
	watch_signals(_slots)
	_slots.get_slot_cell("chest").activated.emit(MOUSE_BUTTON_LEFT)
	assert_signal_emitted_with_parameters(_slots, "action_selected", ["unequip|chest"])


func test_drop_bag_payload_emits_equip_action() -> void:
	watch_signals(_slots)
	_slots.get_slot_cell("legs").dropped.emit({"source": "bag", "index": 7})
	assert_signal_emitted_with_parameters(_slots, "action_selected", ["equip|7"])


func test_hover_forwards_from_a_live_cell() -> void:
	var sword := {"slot_type": "weapon", "name": "Iron Sword", "count": 1, "rarity": "common"}
	_slots.update_equipment({"weapon": sword})
	watch_signals(_slots)
	_slots.get_slot_cell("weapon").hovered.emit(sword)
	assert_signal_emitted_with_parameters(_slots, "item_hover_started", [sword])
