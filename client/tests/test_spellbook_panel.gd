extends GutTest

# T-422b: the spellbook — lists the class kit's abilities (icon + name) and, on select, shows a
# WoW-style rich tooltip derived from the ability metadata (cast / range / cost / damage|heal /
# effect). Read-only, headless; mirrors test_action_bar / test_recipe_panel.

const SpellbookPanel = preload("res://scripts/ui/spellbook_panel.gd")


func _make() -> SpellbookPanel:
	var panel := SpellbookPanel.new()
	add_child_autofree(panel)  # runs _ready -> builds the list + detail
	return panel


# A realistic slice of a mage kit as the server ships it in the class_kit payload (T-422b fields
# forwarded by kit_helper.build_kit): a cast-time nuke and an instant, plus a heal for coverage.
func _kit() -> Array:
	return [
		{
			"id": 204,
			"name": "Frostbolt",
			"icon": "frostbolt",
			"effect": "damage",
			"cast_ticks": 30,
			"resource_cost": 0,
			"mana_cost": 10,
			"range_units": 30.0,
			"base_damage": 24,
			"attacker_stat_coeffs": {"int": 0.5},
			"variance_min": 0.9,
			"variance_max": 1.0,
		},
		{
			"id": 202,
			"name": "Fire Blast",
			"icon": "fire_blast",
			"effect": "damage",
			"cast_ticks": 0,
			"resource_cost": 0,
			"mana_cost": 12,
			"range_units": 20.0,
			"base_damage": 18,
			"attacker_stat_coeffs": {"int": 0.4},
			"variance_min": 0.85,
			"variance_max": 1.0,
		},
	]


func _heal_ability() -> Dictionary:
	return {
		"id": 305,
		"name": "Greater Heal",
		"icon": "greater_heal",
		"effect": "heal",
		"cast_ticks": 30,
		"resource_cost": 0,
		"mana_cost": 18,
		"range_units": 30.0,
		"heal_base": 40,
		"attacker_stat_coeffs": {},
		"variance_min": 0.9,
		"variance_max": 1.0,
	}


func test_starts_hidden() -> void:
	assert_false(_make().visible)


func test_lists_kit_abilities_with_names() -> void:
	var panel := _make()
	panel.set_kit(_kit())
	assert_eq(panel.ability_count(), 2, "one row per kit ability")
	assert_eq(panel.row_name(0), "Frostbolt")
	assert_eq(panel.row_name(1), "Fire Blast")


func test_rows_carry_icon_textures() -> void:
	var panel := _make()
	panel.set_kit(_kit())
	# Slice A shipped res://assets/icons/abilities/frostbolt.png; the row renders it.
	assert_not_null(panel.row_icon_texture(0), "the ability icon renders in the list row")


func test_rebuild_replaces_rows() -> void:
	var panel := _make()
	panel.set_kit(_kit())
	panel.set_kit([_heal_ability()])
	assert_eq(panel.ability_count(), 1, "re-issuing a kit rebuilds the list cleanly")
	assert_eq(panel.row_name(0), "Greater Heal")


func test_first_ability_selected_by_default() -> void:
	var panel := _make()
	panel.set_kit(_kit())
	assert_eq(panel.selected_index(), 0, "a fresh kit selects the first ability")


func test_selected_tooltip_shows_cast_range_cost_and_damage() -> void:
	var panel := _make()
	panel.set_resource_kind("mana")
	panel.set_kit(_kit())
	panel.select_ability(0)  # Frostbolt
	var t := panel.get_detail_text()
	assert_string_contains(t, "Frostbolt")
	assert_string_contains(t, "1.5 sec cast")  # 30 ticks / 20 Hz
	assert_string_contains(t, "30 yd range")
	assert_string_contains(t, "10 Mana")  # mana_cost + class resource name
	assert_string_contains(t, "22–24 damage")  # 24 × 0.9..1.0
	assert_string_contains(t, "+50% Intellect")  # int coefficient


func test_instant_ability_reads_instant() -> void:
	var panel := _make()
	panel.set_kit(_kit())
	panel.select_ability(1)  # Fire Blast, cast_ticks 0
	assert_string_contains(panel.get_detail_text(), "Instant")


func test_heal_ability_shows_healing_range() -> void:
	var panel := _make()
	panel.set_resource_kind("mana")
	panel.set_kit([_heal_ability()])
	panel.select_ability(0)
	var t := panel.get_detail_text()
	assert_string_contains(t, "36–40 healing")  # 40 × 0.9..1.0
	assert_string_contains(t, "18 Mana")


# ---- pure formatting helpers (no Control instantiation) ----


func test_cast_label_instant_vs_timed() -> void:
	assert_eq(SpellbookPanel.cast_label({"cast_ticks": 0}), "Instant")
	assert_eq(SpellbookPanel.cast_label({"cast_ticks": 30}), "1.5 sec cast")


func test_range_label_melee_self_and_yards() -> void:
	assert_eq(SpellbookPanel.range_label({"range_units": 0.0}), "Self")
	assert_eq(SpellbookPanel.range_label({"range_units": 2.5}), "Melee range")
	assert_eq(SpellbookPanel.range_label({"range_units": 30.0}), "30 yd range")


func test_cost_label_names_class_resource() -> void:
	assert_string_contains(SpellbookPanel.cost_label({"resource_cost": 20}, "rage"), "20 Rage")
	assert_string_contains(SpellbookPanel.cost_label({"mana_cost": 10}, "mana"), "10 Mana")
	assert_string_contains(SpellbookPanel.cost_label({}, "mana"), "No cost")


func test_coeff_label_formats_percent_and_stat_name() -> void:
	assert_eq(SpellbookPanel.coeff_label({"int": 0.5}), "+50% Intellect")
	assert_eq(SpellbookPanel.coeff_label({"str": 0.6}), "+60% Strength")
	assert_eq(SpellbookPanel.coeff_label({}), "")


func test_toggle_opens_and_closes() -> void:
	var panel := _make()
	assert_false(panel.visible)
	panel.toggle()
	assert_true(panel.visible, "B opens the spellbook")
	panel.toggle()
	assert_false(panel.visible, "B again closes it")


func test_uses_solidwindow_frame_not_colorrect() -> void:
	var panel := _make()
	var frame := panel.get_node_or_null("Frame") as PanelContainer
	assert_not_null(frame, "a PanelContainer frame roots the window")
	assert_eq(frame.theme_type_variation, &"SolidWindow", "opaque deliberate-window variation")
	for child in panel.get_children():
		assert_false(child is ColorRect, "no hand-rolled ColorRect box (T-400 idiom)")


func test_row_clickable_area_matches_visible_row_height() -> void:
	# T-584: the clickable hitbox must cover the full visible row (icon 28px + row content).
	# Regression test: ensure a future layout change can't silently shrink the hitbox again.
	var panel := _make()
	panel.set_kit(_kit())
	for i in range(panel.ability_count()):
		var row_btn := panel._rows[i] as Button
		assert_not_null(row_btn, "row %d button exists" % i)
		# The button's custom_minimum_size height must be at least as tall as the visible row content.
		# Icon is 28px, so minimum height should be >= 28px.
		assert_true(
			row_btn.custom_minimum_size.y >= 28.0,
			(
				"row %d clickable height (%f) >= icon height (28px)"
				% [i, row_btn.custom_minimum_size.y]
			)
		)
		# Verify the button contains the row HBoxContainer.
		var row_hbox := row_btn.get_child(0) as HBoxContainer
		assert_not_null(row_hbox, "row %d contains HBoxContainer child" % i)
		# The HBoxContainer should have the icon and label children with MOUSE_FILTER_IGNORE
		# so clicks pass through to the button.
		for child in row_hbox.get_children():
			var child_ctrl := child as Control
			if child_ctrl:
				assert_eq(
					child_ctrl.mouse_filter,
					Control.MOUSE_FILTER_IGNORE,
					(
						"row %d child %s has mouse_filter=IGNORE to pass clicks to button"
						% [i, child.name]
					)
				)
