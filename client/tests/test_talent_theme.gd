extends "res://addons/gut/test.gd"
# T-508: TalentTheme — the pure display layer. Role theming (tree -> role -> era-palette accent),
# icon slug derivation, and the lock-state math that MIRRORS the server gate (talent_logic).


# A faithful slice of server/world/data/talents/warrior.json — the two prereq chains + a tier-3
# node, enough to exercise every branch of node_state and the tree helpers.
func _war_defs() -> Array:
	return [
		{"id": "tal_war_might", "tree": "arms", "tier": 1, "max_ranks": 3, "prereq": null},
		{"id": "tal_war_imp_heroic", "tree": "arms", "tier": 1, "max_ranks": 3, "prereq": null},
		{
			"id": "tal_war_deep_wounds",
			"tree": "arms",
			"tier": 2,
			"max_ranks": 3,
			"prereq": "tal_war_imp_heroic",
		},
		{"id": "tal_war_executioner", "tree": "arms", "tier": 3, "max_ranks": 1, "prereq": null},
		{
			"id": "tal_war_shield_wall",
			"tree": "protection",
			"tier": 1,
			"max_ranks": 3,
			"prereq": null
		},
	]


func test_tree_role_mirror() -> void:
	assert_eq(TalentTheme.role_for_tree("protection"), "tank")
	assert_eq(TalentTheme.role_for_tree("arms"), "dps")
	assert_eq(TalentTheme.role_for_tree("arcane"), "utility")
	assert_eq(TalentTheme.role_for_tree("holy"), "healer")
	assert_eq(TalentTheme.role_for_tree("unknown_tree"), "dps", "unknown falls back to dps")


func test_trees_meta_overrides_mirror() -> void:
	var meta := [{"id": "arms", "role": "tank"}]
	assert_eq(
		TalentTheme.role_for_tree("arms", meta), "tank", "a live trees block wins over the mirror"
	)


func test_role_colors_distinct() -> void:
	var colors := [
		TalentTheme.role_color("tank"),
		TalentTheme.role_color("dps"),
		TalentTheme.role_color("healer"),
		TalentTheme.role_color("utility"),
	]
	for i in range(colors.size()):
		for j in range(i + 1, colors.size()):
			assert_ne(colors[i], colors[j], "each role reads as a distinct accent")


func test_slug_strips_class_prefix() -> void:
	assert_eq(TalentTheme.slug_for({"id": "tal_war_might"}), "might")
	assert_eq(TalentTheme.slug_for({"id": "tal_mag_imp_fireball"}), "imp_fireball")


func test_explicit_icon_slug_wins() -> void:
	assert_eq(TalentTheme.slug_for({"id": "tal_war_might", "icon": "authored"}), "authored")


func test_points_in_tree() -> void:
	var spent := {"tal_war_might": 2, "tal_war_shield_wall": 1}
	assert_eq(TalentTheme.points_in_tree(spent, _war_defs(), "arms"), 2)
	assert_eq(TalentTheme.points_in_tree(spent, _war_defs(), "protection"), 1)


func test_tier_unlock_gate() -> void:
	# T-523: 5 points/tier for the L60-cap 7-tier shape (mirror of server talent_logic).
	assert_true(TalentTheme.is_tier_unlocked(0, 1), "tier 1 always open")
	assert_false(TalentTheme.is_tier_unlocked(4, 2), "tier 2 needs 5 points in tree")
	assert_true(TalentTheme.is_tier_unlocked(5, 2))
	assert_false(TalentTheme.is_tier_unlocked(9, 3), "tier 3 needs 10 points")
	assert_true(TalentTheme.is_tier_unlocked(10, 3))
	assert_false(TalentTheme.is_tier_unlocked(29, 7), "tier-7 capstone needs 30 points")
	assert_true(TalentTheme.is_tier_unlocked(30, 7))


func test_node_state_tier1_spendable() -> void:
	var defs := _war_defs()
	var tal: Dictionary = defs[0]
	assert_eq(
		TalentTheme.node_state(tal, {}, 0, 3, TalentTheme.defs_by_id(defs)),
		TalentTheme.SPENDABLE,
	)


func test_node_state_no_points_is_available_not_locked() -> void:
	var defs := _war_defs()
	assert_eq(
		TalentTheme.node_state(defs[0], {}, 0, 0, TalentTheme.defs_by_id(defs)),
		TalentTheme.AVAILABLE_NO_POINTS,
		"unlocked tier + prereq met but broke reads as available, not gated",
	)


func test_node_state_tier2_tier_locked() -> void:
	var defs := _war_defs()
	var deep: Dictionary = defs[2]  # tier 2
	assert_eq(
		TalentTheme.node_state(deep, {}, 0, 5, TalentTheme.defs_by_id(defs)),
		TalentTheme.LOCKED,
		"tier 2 with an empty tree is gated",
	)


func test_node_state_prereq_must_be_maxed() -> void:
	# The server rule (talent_logic.validate_spend) is prereq at MAX ranks — not merely > 0.
	var defs := _war_defs()
	var deep: Dictionary = defs[2]  # prereq tal_war_imp_heroic (max 3)
	var by_id := TalentTheme.defs_by_id(defs)
	# T-523: 5 arms points (tier 2 unlocked at the new gate) but prereq at 2/3 -> LOCKED.
	assert_eq(
		TalentTheme.node_state(deep, {"tal_war_imp_heroic": 2, "tal_war_might": 3}, 5, 5, by_id),
		TalentTheme.LOCKED,
		"a partially-ranked prereq must still gate the dependent",
	)
	# imp_heroic at 3/3 -> prereq maxed, tier unlocked (5 pts in arms), points free -> SPENDABLE.
	assert_eq(
		TalentTheme.node_state(deep, {"tal_war_imp_heroic": 3, "tal_war_might": 2}, 5, 5, by_id),
		TalentTheme.SPENDABLE,
		"a maxed prereq unlocks the dependent",
	)


func test_node_state_maxed() -> void:
	var defs := _war_defs()
	assert_eq(
		TalentTheme.node_state(defs[0], {"tal_war_might": 3}, 3, 5, TalentTheme.defs_by_id(defs)),
		TalentTheme.MAXED,
	)


func test_tree_ids_preserves_order() -> void:
	assert_eq(TalentTheme.tree_ids(_war_defs()), ["arms", "protection"])
