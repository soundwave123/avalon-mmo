extends "res://addons/gut/test.gd"
# T-295 / T-422d / T-640: CharacterSheetPanel — the WoW character window (live paperdoll model +
# WoW slot layout + sectioned stats: header/Attributes/Combat/Durability). Headless.

var _panel: CharacterSheetPanel = null


func before_each() -> void:
	_panel = CharacterSheetPanel.new()
	add_child(_panel)
	await get_tree().process_frame


func after_each() -> void:
	_panel.queue_free()


func _payload(level: int, s: Dictionary, d: Dictionary) -> Dictionary:
	return {"type": "player_stats", "level": level, "primaries": s, "derived": d}


func test_renders_primaries_and_derived() -> void:
	(
		_panel
		. update_stats(
			_payload(
				5,
				{"str": 22, "stamina": 22, "dex": 14, "int": 10, "spirit": 10},
				{
					"max_hp": 160,
					"max_mana": 150,
					"endurance": 104,
					"spell_power": 8,
					"mana_regen": 2
				},
			)
		)
	)
	var text := _panel.get_text()
	assert_string_contains(text, "Strength")
	assert_string_contains(text, "22")
	assert_string_contains(text, "Intellect")
	assert_string_contains(text, "Max Health")
	assert_string_contains(text, "160")
	assert_string_contains(text, "Level")


func test_level_up_shows_primary_gains() -> void:
	_panel.update_stats(
		_payload(1, {"str": 13, "stamina": 13, "dex": 11, "int": 10, "spirit": 10}, {"max_hp": 115})
	)
	# Level up: warrior gains +3 STR / +3 STA — the sheet should annotate the gain.
	_panel.update_stats(
		_payload(2, {"str": 16, "stamina": 16, "dex": 12, "int": 10, "spirit": 10}, {"max_hp": 130})
	)
	assert_string_contains(_panel.get_text(), "(+3)", "level-up gain shown on grown primaries")


func test_partial_payload_ignored() -> void:
	# An older player_stats (level/XP only, no primaries) must not blank the sheet or crash.
	_panel.update_stats(
		_payload(3, {"str": 10, "stamina": 10, "dex": 10, "int": 10, "spirit": 10}, {"max_hp": 100})
	)
	_panel.update_stats({"type": "player_stats", "level": 3})
	assert_string_contains(_panel.get_text(), "Strength", "kept the last full render")


func test_toggle_visibility() -> void:
	var was := _panel.visible
	_panel.toggle()
	assert_ne(_panel.visible, was)


# ---- T-422d / T-640: paperdoll ----


func test_has_a_slot_frame_for_each_equip_slot() -> void:
	for slot in ["head", "shoulders", "chest", "legs", "weapon", "offhand"]:
		var cell := _panel.get_slot_cell(slot)
		assert_not_null(cell, "paperdoll frame for %s" % slot)
		assert_true(cell is ItemCell, "%s frame is an ItemCell" % slot)


func test_empty_paperdoll_slot_hints_are_compact() -> void:
	for slot in ["head", "shoulders", "chest", "legs", "weapon", "offhand"]:
		var hint := _panel.get_slot_cell(slot).get_node("Hint") as Label
		assert_lte(hint.text.length(), 5, "%s hint fits inside its frame" % slot)


func test_empty_slots_start_unequipped() -> void:
	for slot in ["head", "weapon"]:
		assert_true(_panel.get_slot_cell(slot).get_entry().is_empty(), "%s empty by default" % slot)


func test_update_equipment_fills_worn_slots() -> void:
	(
		_panel
		. update_equipment(
			{
				"weapon":
				{"slot_type": "weapon", "name": "Iron Sword", "count": 1, "rarity": "common"},
				"head":
				{"slot_type": "head", "name": "Leather Cap", "count": 1, "rarity": "uncommon"},
			}
		)
	)
	assert_eq(str(_panel.get_slot_cell("weapon").get_entry().get("name")), "Iron Sword")
	assert_eq(str(_panel.get_slot_cell("head").get_entry().get("name")), "Leather Cap")
	assert_true(_panel.get_slot_cell("chest").get_entry().is_empty(), "unworn slot stays empty")


func test_worn_slot_hover_emits_item_hover_started() -> void:  # T-233
	var sword := {"slot_type": "weapon", "name": "Iron Sword", "count": 1, "rarity": "common"}
	_panel.update_equipment({"weapon": sword})
	watch_signals(_panel)
	_panel.get_slot_cell("weapon").hovered.emit(sword)
	assert_signal_emitted_with_parameters(_panel, "item_hover_started", [sword])


# T-400 / T-422d: the window roots on the theme's SolidWindow frame with an internal scroll.
func test_uses_solidwindow_frame_with_scroll() -> void:
	assert_not_null(_panel.theme, "carries the shared UiTheme so SolidWindow resolves")
	var frame := _panel.get_node_or_null("Frame") as PanelContainer
	assert_not_null(frame, "a PanelContainer frame roots the window")
	assert_eq(frame.theme_type_variation, &"SolidWindow", "opaque deliberate-window variation")
	assert_not_null(frame.get_node_or_null("Scroll"), "internal scroll caps the window to 720p")
	for child in _panel.get_children():
		assert_false(child is ColorRect, "the hand-rolled ColorRect box is gone")


# ---- T-640: WoW chrome slots (visible-but-disabled placeholders) ----


func test_chrome_slots_cover_the_wow_reference_layout() -> void:
	var chrome := [
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
	for slot in chrome:
		var cell := _panel.get_chrome_cell(slot)
		assert_not_null(cell, "chrome frame for %s" % slot)
		assert_eq(cell.mouse_filter, Control.MOUSE_FILTER_IGNORE, "%s takes no input" % slot)
		assert_true(cell.modulate.a < 1.0, "%s reads visibly dim" % slot)
	assert_null(_panel.get_slot_cell("neck"), "chrome slots never join the live/interactive map")


# ---- T-640: click-to-unequip / drag-to-equip round trips (existing equip intents) ----


func test_click_worn_slot_emits_unequip_action() -> void:
	watch_signals(_panel)
	_panel.get_slot_cell("weapon").activated.emit(MOUSE_BUTTON_LEFT)
	assert_signal_emitted_with_parameters(_panel, "action_selected", ["unequip|weapon"])


func test_dragging_a_bag_item_onto_a_live_slot_emits_equip_action() -> void:
	watch_signals(_panel)
	var cell := _panel.get_slot_cell("head")
	cell._drop_cell(Vector2.ZERO, {"source": "bag", "index": 3})
	assert_signal_emitted_with_parameters(_panel, "action_selected", ["equip|3"])


func test_live_slot_rejects_a_non_bag_drop() -> void:
	var cell := _panel.get_slot_cell("chest")
	assert_false(cell._can_drop_cell(Vector2.ZERO, {"source": "bar", "slot": 0}))
	assert_true(cell._can_drop_cell(Vector2.ZERO, {"source": "bag", "index": 0}))


# ---- T-640: sectioned stats (header + Combat + Durability) ----


func test_header_shows_username_level_and_class() -> void:
	_panel.update_preview({"username": "roy", "char_class": "warrior", "gear": {}})
	_panel.update_stats(_payload(4, {"str": 15, "stamina": 15}, {"max_hp": 120}))
	var text := _panel.get_text()
	assert_string_contains(text, "roy")
	assert_string_contains(text, "Warrior")
	assert_string_contains(text, "Combat")


func test_header_falls_back_before_identity_is_known() -> void:
	_panel.update_stats(_payload(1, {"str": 10}, {"max_hp": 100}))
	var text := _panel.get_text()
	assert_string_contains(text, "Character")
	assert_string_contains(text, "Adventurer")


func test_durability_line_reports_worn_slot_count_honestly() -> void:
	_panel.update_stats(_payload(1, {"str": 10}, {"max_hp": 100}))
	assert_string_contains(_panel.get_text(), "0/6 slots worn")
	assert_string_contains(_panel.get_text(), "Durability")
	_panel.update_equipment(
		{"weapon": {"slot_type": "weapon", "name": "Iron Sword", "count": 1, "rarity": "common"}}
	)
	_panel.update_stats(_payload(1, {"str": 10}, {"max_hp": 100}))
	assert_string_contains(_panel.get_text(), "1/6 slots worn")


# ---- T-640: live model preview (headless-safe) ----


func test_preview_headless_fallback_keeps_the_framed_placeholder() -> void:
	var preview := _panel.get_preview()
	assert_not_null(preview)
	assert_true(preview.is_headless(), "the GUT runner has no display")
	assert_false(preview.has_model(), "no SubViewport/3D model built without a display")


func test_update_preview_tracks_class_and_gear_headlessly() -> void:
	var p := {"char_class": "mage", "gear": {"head": "itm_mage_cowl"}, "username": "roy"}
	_panel.update_preview(p)
	var preview := _panel.get_preview()
	assert_eq(preview.get_model_class(), "mage")
	assert_eq(preview.get_last_gear(), {"head": "itm_mage_cowl"})


# ---- T-640: safe-zone at 1280x720 (T-608/T-634 lesson: never overlap Vitals or the hotbar) ----


func test_panel_rect_clears_vitals_and_hotbar_at_720p() -> void:
	# The panel is statically anchored (left 0, bottom 1), so its 720p rect is pure offset math.
	var top := _panel.offset_top
	var bottom := 720.0 + _panel.offset_bottom
	# Vitals frame ends at y=90 and its autoattack pip at y=116 (player_hud.gd explicit offsets).
	assert_true(top >= 116.0, "panel opens below the vitals block (top %s >= 116)" % top)
	# The action bar's top edge is 720 - ActionBar._SLOT - 88 = 580 (action_bar.gd), and at
	# MAX_SLOTS its left edge (x=379) reaches inside this panel's right edge (380) — so the panel
	# must END above the hotbar band rather than rely on horizontal clearance.
	assert_true(bottom <= 580.0, "panel ends above the hotbar top (bottom %s <= 580)" % bottom)
	assert_true(bottom - top >= 300.0, "still a usable window; the internal scroll does the rest")


# ---- T-640: mount() — main.gd's single-call wiring idiom ----


class _FakeTooltip:
	extends RefCounted
	var shown: Array = []
	var hidden := 0

	func show_for(item: Dictionary) -> void:
		shown.append(item)

	func hide_tooltip() -> void:
		hidden += 1


func test_mount_wires_equipment_from_the_inventory_panel() -> void:
	var hud := Control.new()
	add_child(hud)
	var inv := InventoryPanel.new()
	hud.add_child(inv)
	await get_tree().process_frame
	var tooltip = _FakeTooltip.new()
	var panel := CharacterSheetPanel.mount(hud, tooltip, inv)
	await get_tree().process_frame
	(
		inv
		. render(
			[
				{
					"slot_type": "weapon",
					"slot_index": 0,
					"item_id": "itm_iron_sword",
					"name": "Iron Sword",
					"count": 1,
				}
			]
		)
	)
	assert_eq(str(panel.get_slot_cell("weapon").get_entry().get("name")), "Iron Sword")
	hud.queue_free()


func test_mount_wires_hover_to_the_shared_tooltip() -> void:
	var hud := Control.new()
	add_child(hud)
	var inv := InventoryPanel.new()
	hud.add_child(inv)
	await get_tree().process_frame
	var tooltip = _FakeTooltip.new()
	var panel := CharacterSheetPanel.mount(hud, tooltip, inv)
	await get_tree().process_frame
	var sword := {"slot_type": "weapon", "name": "Iron Sword", "count": 1, "rarity": "common"}
	panel.update_equipment({"weapon": sword})
	panel.get_slot_cell("weapon").hovered.emit(sword)
	assert_eq(tooltip.shown, [sword])
	panel.get_slot_cell("weapon").unhovered.emit()
	assert_eq(tooltip.hidden, 1)
	hud.queue_free()


# ---- T-755: the header name is player text on a bbcode surface -----------------
#
# Lowest severity of the sweep — the name here is the VIEWER'S OWN, arriving on their own row of
# the positions broadcast, so there is no attacker. It is escaped anyway: the point of a sweep is
# to leave no bbcode site whose safety has to be re-derived from context by the next reader, and
# an unclosed tag would swallow the whole stat block below the header regardless of who typed it.
func test_header_name_is_escaped_and_cannot_swallow_the_stat_block() -> void:
	_panel.update_preview({"username": "[color=#000000]ghost", "char_class": "warrior"})
	_panel.update_stats(
		_payload(
			5,
			{"str": 22, "stamina": 22, "dex": 14, "int": 10, "spirit": 10},
			{"max_hp": 160, "max_mana": 150, "endurance": 104, "spell_power": 8, "mana_regen": 2}
		)
	)
	var body := _panel.get_text()
	assert_false(body.contains("[color=#000000]"), "the name never reaches the label as a live tag")
	var rtl := RichTextLabel.new()
	rtl.bbcode_enabled = true
	add_child_autofree(rtl)
	rtl.text = body
	var parsed := rtl.get_parsed_text()
	assert_string_contains(parsed, "[color=#000000]ghost", "the header name renders literally")
	assert_string_contains(parsed, "160", "the stat block below the header is not swallowed")
