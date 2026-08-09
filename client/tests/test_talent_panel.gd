extends "res://addons/gut/test.gd"
# T-065 / T-508: TalentPanel — the tabbed talent-tree UI. Verifies tabs-per-tree from data, the
# node-graph + prerequisite connectors, server-mirrored lock display, rank-up/unlock feedback, the
# prominent points readout, and the respec-confirm intent. SolidWindow chrome kept.

var _panel: TalentPanel = null


func before_each() -> void:
	_panel = TalentPanel.new()
	add_child(_panel)
	await get_tree().process_frame


func after_each() -> void:
	_panel.queue_free()


# Three role-distinct trees mirroring server/world/data/talents/warrior.json (arms/fury = dps,
# protection = tank) with a prereq chain (deep_wounds needs a MAXED imp_heroic).
func _defs() -> Array:
	return [
		{
			"id": "tal_war_might",
			"name": "Might",
			"tree": "arms",
			"tier": 1,
			# T-523: 5 ranks so one talent can cross the (now 5-point) tier-2 gate in tests.
			"max_ranks": 5,
			"prereq": null,
			"desc": "+2 Strength per rank",
		},
		{
			"id": "tal_war_imp_heroic",
			"name": "Improved Heroic Strike",
			"tree": "arms",
			"tier": 1,
			"max_ranks": 3,
			"prereq": null,
			"desc": "+5% per rank",
		},
		{
			"id": "tal_war_deep_wounds",
			"name": "Deep Wounds",
			"tree": "arms",
			"tier": 2,
			"max_ranks": 3,
			"prereq": "tal_war_imp_heroic",
			"desc": "+2% per rank",
		},
		{
			"id": "tal_war_bloodrage",
			"name": "Bloodrage",
			"tree": "fury",
			"tier": 1,
			"max_ranks": 3,
			"prereq": null,
			"desc": "-8% cost per rank",
		},
		{
			"id": "tal_war_shield_wall",
			"name": "Iron Skin",
			"tree": "protection",
			"tier": 1,
			"max_ranks": 3,
			"prereq": null,
			"desc": "+3 Stamina per rank",
		},
	]


func _state(spent: Dictionary, available: int) -> Dictionary:
	var used := 0
	for k in spent:
		used += int(spent[k])
	return {
		"talents": spent,
		"points_available": available,
		"points_spent": used,
		"defs": _defs(),
		"trees":
		[
			{"id": "arms", "role": "dps"},
			{"id": "fury", "role": "dps"},
			{"id": "protection", "role": "tank"},
		],
	}


func test_starts_hidden() -> void:
	assert_false(_panel.visible)


func test_one_tab_per_tree_from_data() -> void:
	_panel.render(_state({}, 5))
	assert_eq(_panel.tab_count(), 3, "arms + fury + protection = 3 tabs")
	assert_eq(_panel.get_talent_count(), 5)


func test_default_active_tree_is_first() -> void:
	_panel.render(_state({}, 5))
	assert_eq(_panel.active_tree(), "arms")


func test_select_tree_switches_active() -> void:
	_panel.render(_state({}, 5))
	_panel.select_tree("protection")
	assert_eq(_panel.active_tree(), "protection")
	assert_true(_panel.tree_view("protection").visible)
	assert_false(_panel.tree_view("arms").visible)


func test_active_tab_preserved_across_render() -> void:
	_panel.render(_state({}, 5))
	_panel.select_tree("fury")
	_panel.render(_state({"tal_war_might": 1}, 5))  # a spend re-renders — keep the player's tab
	assert_eq(_panel.active_tree(), "fury")


func test_tree_view_lays_out_all_tree_nodes() -> void:
	_panel.render(_state({}, 5))
	assert_eq(_panel.tree_view("arms").node_count(), 3, "arms has 3 talents in the graph")
	assert_eq(_panel.tree_view("protection").node_count(), 1)


func test_prereq_renders_a_connector() -> void:
	_panel.render(_state({}, 5))
	assert_eq(
		_panel.tree_view("arms").connector_count(), 1, "deep_wounds->imp_heroic is one connector"
	)
	assert_eq(_panel.tree_view("protection").connector_count(), 0)


func test_tier_gated_node_is_locked() -> void:
	_panel.render(_state({}, 5))
	assert_eq(
		_panel.tree_view("arms").state_of("tal_war_deep_wounds"),
		TalentTheme.LOCKED,
		"tier 2 with an empty tree renders darkened + locked",
	)
	assert_eq(_panel.tree_view("arms").state_of("tal_war_might"), TalentTheme.SPENDABLE)


func test_spendable_node_emits_spend_intent() -> void:
	var got: Array = []
	_panel.action_selected.connect(func(meta): got.append(meta))
	_panel.render(_state({}, 5))
	_panel.tree_view("arms").spend_requested.emit("tal_war_might")
	assert_eq(got, ["spend_talent|tal_war_might"])


func test_points_remaining_is_shown() -> void:
	_panel.render(_state({"tal_war_might": 2}, 5))
	assert_eq(_panel.get_points_left(), 3)
	assert_string_contains(_panel.points_text(), "3 points")


func test_respec_confirm_emits_reroll() -> void:
	var got: Array = []
	_panel.action_selected.connect(func(meta): got.append(meta))
	_panel.render(_state({"tal_war_might": 1}, 5))
	_panel.confirm_respec_for_test()
	assert_eq(got, ["reroll_talents"])


func test_rank_up_feedback_flags_the_node() -> void:
	_panel.render(_state({}, 5))
	_panel.render(_state({"tal_war_might": 1}, 5))  # a point just went into Might
	assert_eq(
		_panel.tree_view("arms").last_ranked_up_id(),
		"tal_war_might",
		"the just-ranked node is flagged for the fill tick",
	)


func test_newly_unlocked_tier_glows() -> void:
	# T-523: the tier-2 gate is now 5 points in tree.
	_panel.render(_state({"tal_war_might": 4}, 6))  # arms tree = 4 pts, tier 2 still locked
	_panel.render(_state({"tal_war_might": 5}, 6))  # arms tree = 5 pts, tier 2 just opened
	assert_true(
		_panel.tree_view("arms").newly_unlocked_tiers().has(2),
		"crossing the tier-2 threshold glows that tier",
	)


func test_tree_view_carries_role() -> void:
	_panel.render(_state({}, 5))
	assert_eq(_panel.tree_view("protection").role(), "tank")
	assert_eq(_panel.tree_view("arms").role(), "dps")


# T-400/T-508: still the theme's SolidWindow frame (not a hand-rolled ColorRect box).
func test_uses_solidwindow_frame_not_colorrect() -> void:
	assert_not_null(_panel.theme, "carries the shared UiTheme so SolidWindow resolves")
	var frame := _panel.get_node_or_null("Frame") as PanelContainer
	assert_not_null(frame, "a PanelContainer frame roots the window")
	assert_eq(frame.theme_type_variation, &"SolidWindow", "opaque deliberate-window variation")
	for child in _panel.get_children():
		assert_false(child is ColorRect, "no hand-rolled ColorRect box")


# ---- T-608: safe-zone at 1280x720 (shared HudSafeZone — never overlap Vitals or the hotbar) -----


func test_panel_rect_clears_the_hotbar_at_720p_regardless_of_slot_count() -> void:
	# Talents is RIGHT-anchored and wider than its siblings (left edge x=720 at 1280 width) — wide
	# enough that its left edge used to cross into the hotbar's x-range at MAX_SLOTS (x=379..901),
	# half-covering slot 5 and fully hiding slot 6. Fixed via VERTICAL clearance (shared
	# HudSafeZone constants) so it's provably clear regardless of the hotbar's current slot count.
	var top := _panel.offset_top
	var bottom := 720.0 + _panel.offset_bottom
	assert_eq(top, HudSafeZone.PANEL_SAFE_TOP, "reads the shared safe-zone constant")
	assert_eq(bottom, 720.0 + HudSafeZone.PANEL_SAFE_BOTTOM, "reads the shared safe-zone constant")
	assert_true(bottom <= HudSafeZone.ACTION_BAR_RECT.position.y, "panel ends above the hotbar top")
