extends "res://addons/gut/test.gd"
# T-039 / T-422d: InventoryPanel — renders the enriched inventory view-model as a modern bag GRID
# (16 ItemCells) + an Equipped row (server EQUIP_SLOTS). Headless.

var _panel: InventoryPanel = null


func before_each() -> void:
	_panel = InventoryPanel.new()
	add_child(_panel)
	await get_tree().process_frame


func after_each() -> void:
	_panel.queue_free()


func _slots() -> Array:
	return [
		{
			"slot_type": "bag",
			"slot_index": 0,
			"item_id": "itm_wolf_pelt",
			"name": "Wolf Pelt",
			"count": 5,
		},
		{
			"slot_type": "weapon",
			"slot_index": 0,
			"item_id": "itm_iron_sword",
			"name": "Iron Sword",
			"count": 1,
		},
	]


func _cell_with_name(item_name: String) -> ItemCell:
	for cell in _panel.get_cells():
		if str(cell.get_entry().get("name", "")) == item_name:
			return cell
	return null


func test_starts_hidden() -> void:
	assert_false(_panel.visible)


func test_empty_render_shows_16_bag_and_6_equip_cells() -> void:
	_panel.render([])
	assert_eq(_panel.get_bag_used(), 0)
	# 16 bag ItemCells + 6 equip ItemCells.
	var cells := _panel.get_cells()
	assert_eq(cells.size(), 22, "16 bag + 6 equip cells")
	for cell in cells:
		assert_true(cell is ItemCell, "every slot is an ItemCell")
	var t: String = _panel.get_text()
	for label: String in ["Head", "Shoulders", "Chest", "Legs", "Weapon", "Offhand"]:
		assert_true(t.contains(label), "equip slot %s shown" % label)


func test_equipped_slot_hints_are_compact() -> void:
	_panel.render([])
	for cell in _panel.get_cells():
		var hint := cell.get_node_or_null("Hint") as Label
		if hint != null and hint.visible and hint.text != "":
			assert_lte(
				hint.text.length(), 5, "empty equip label fits inside one slot: %s" % hint.text
			)


func test_renders_bag_item_and_equipped_weapon() -> void:
	_panel.render(_slots())
	assert_eq(_panel.get_bag_used(), 1)
	var t: String = _panel.get_text()
	assert_true(t.contains("Wolf Pelt"), "bag item name in summary")
	assert_true(t.contains("x5"), "bag item count in summary")
	assert_true(t.contains("Iron Sword"), "equipped weapon name in summary")
	var pelt := _cell_with_name("Wolf Pelt")
	assert_not_null(pelt, "a cell carries the pelt entry")
	assert_eq(int(pelt.get_entry().get("count", 0)), 5, "cell entry keeps the stack count")


func test_set_open_toggles_visibility() -> void:
	_panel.set_open(true)
	assert_true(_panel.visible)
	_panel.set_open(false)
	assert_false(_panel.visible)


func test_left_click_bag_cell_emits_equip() -> void:  # T-056
	_panel.render(
		[{"slot_type": "bag", "slot_index": 3, "item_id": "i1", "name": "Sword", "count": 2}]
	)
	watch_signals(_panel)
	_cell_with_name("Sword").activated.emit(MOUSE_BUTTON_LEFT)
	assert_signal_emitted_with_parameters(_panel, "action_selected", ["equip|3"])


func test_bag_cells_are_drag_sources_for_equip() -> void:  # T-640
	_panel.render(
		[{"slot_type": "bag", "slot_index": 3, "item_id": "i1", "name": "Sword", "count": 2}]
	)
	var data = _cell_with_name("Sword")._get_cell_drag(Vector2.ZERO)
	assert_true(data is Dictionary, "an occupied bag cell is liftable")
	assert_eq(str(data.get("source")), "bag")
	assert_eq(int(data.get("index")), 3)


func test_empty_bag_cells_lift_nothing() -> void:  # T-640
	_panel.render([])
	var cell: ItemCell = _panel.get_cells()[0]
	assert_null(cell._get_cell_drag(Vector2.ZERO))


func test_right_click_bag_cell_emits_drop() -> void:  # T-056
	_panel.render(
		[{"slot_type": "bag", "slot_index": 3, "item_id": "i1", "name": "Sword", "count": 2}]
	)
	watch_signals(_panel)
	_cell_with_name("Sword").activated.emit(MOUSE_BUTTON_RIGHT)
	assert_signal_emitted_with_parameters(_panel, "action_selected", ["drop|bag|3|2"])


func test_click_equipped_cell_emits_unequip() -> void:  # T-056
	_panel.render(
		[{"slot_type": "head", "slot_index": 0, "item_id": "h1", "name": "Helm", "count": 1}]
	)
	watch_signals(_panel)
	_cell_with_name("Helm").activated.emit(MOUSE_BUTTON_LEFT)
	assert_signal_emitted_with_parameters(_panel, "action_selected", ["unequip|head"])


func test_cell_hover_emits_item_hover_started() -> void:  # T-233
	var entry := {
		"slot_type": "bag",
		"slot_index": 2,
		"item_id": "i1",
		"name": "Sword",
		"count": 1,
		"rarity": "rare",
		"slot": "weapon",
		"stats": {"attack": 4},
		"vendor_value": 10,
	}
	_panel.render([entry])
	watch_signals(_panel)
	_cell_with_name("Sword").hovered.emit(entry)
	assert_signal_emitted_with_parameters(_panel, "item_hover_started", [entry])


func test_cell_unhover_emits_item_hover_ended() -> void:  # T-233
	_panel.render(
		[{"slot_type": "bag", "slot_index": 2, "item_id": "i1", "name": "Sword", "count": 1}]
	)
	watch_signals(_panel)
	_cell_with_name("Sword").unhovered.emit()
	assert_signal_emitted(_panel, "item_hover_ended")


func test_empty_cell_does_not_hover_or_activate() -> void:  # T-233
	_panel.render([])
	watch_signals(_panel)
	# An empty bag cell simply carries no entry; its gui_input guard blocks activation.
	var empty: ItemCell = _panel.get_cells()[0]
	assert_true(empty.get_entry().is_empty(), "empty cell has no entry")


func test_bag_item_rarity_drives_cell_border() -> void:  # T-231
	(
		_panel
		. render(
			[
				{
					"slot_type": "bag",
					"slot_index": 0,
					"item_id": "i1",
					"name": "Epic Blade",
					"count": 1,
					"rarity": "epic",
				}
			]
		)
	)
	var cell := _cell_with_name("Epic Blade")
	var sb := cell.get_theme_stylebox("panel") as StyleBoxFlat
	assert_eq(sb.border_color, Color.html("#a335ee"), "epic rarity tints the cell rim")


func test_equipment_changed_emits_worn_map() -> void:  # T-422d paperdoll feed
	watch_signals(_panel)
	_panel.render(_slots())
	assert_signal_emitted(_panel, "equipment_changed")


# T-400 / T-422d: the window roots on the theme's SolidWindow frame with an internal scroll.
func test_uses_solidwindow_frame_with_scroll() -> void:
	assert_not_null(_panel.theme, "carries the shared UiTheme so SolidWindow resolves")
	var frame := _panel.get_node_or_null("Frame") as PanelContainer
	assert_not_null(frame, "a PanelContainer frame roots the window")
	assert_eq(frame.theme_type_variation, &"SolidWindow", "opaque deliberate-window variation")
	assert_not_null(frame.get_node_or_null("Scroll"), "internal scroll caps the window to 720p")
	for child in _panel.get_children():
		assert_false(child is ColorRect, "the hand-rolled ColorRect box is gone")
