extends "res://addons/gut/test.gd"
# T-422e: ItemCell icon resolution + the ItemIcons type-fallback map. Occupied cells now light up
# with a shared CC-BY game-icons.net pack (resolved by type), falling back to the initials glyph
# when nothing resolves. Asserts the live cell's Icon/Glyph visibility and the pure slug mapper.

var _cell: ItemCell = null


func before_each() -> void:
	_cell = ItemCell.new()
	add_child(_cell)
	await get_tree().process_frame


func after_each() -> void:
	_cell.queue_free()


func _entry(overrides: Dictionary) -> Dictionary:
	var base := {
		"item_id": "itm_iron_sword",
		"name": "Iron Sword",
		"count": 1,
		"rarity": "uncommon",
		"slot": "weapon",
		"armor_type": "none"
	}
	base.merge(overrides, true)
	return base


# ---- ItemIcons pure mapper ----


func test_slug_explicit_id_mapping() -> void:
	assert_eq(ItemIcons.slug_for({"item_id": "itm_starter_staff"}), "w_staff")
	assert_eq(ItemIcons.slug_for({"item_id": "itm_potion_minor_healing"}), "c_potion")
	assert_eq(ItemIcons.slug_for({"item_id": "itm_tarnished_coin"}), "m_coin")


func test_slug_weapon_default_is_sword() -> void:
	# An unmapped weapon still gets a sensible default so new weapons aren't blank.
	assert_eq(ItemIcons.slug_for({"item_id": "itm_future_blade", "slot": "weapon"}), "w_sword")


func test_slug_armor_routes_by_material_family() -> void:
	assert_eq(ItemIcons.slug_for({"slot": "head", "armor_type": "plate"}), "a_helm_heavy")
	assert_eq(ItemIcons.slug_for({"slot": "head", "armor_type": "robe"}), "a_helm_light")
	assert_eq(ItemIcons.slug_for({"slot": "chest", "armor_type": "mail"}), "a_chest_heavy")
	assert_eq(ItemIcons.slug_for({"slot": "chest", "armor_type": "vestment"}), "a_chest_light")
	assert_eq(ItemIcons.slug_for({"slot": "shoulders", "armor_type": "plate"}), "a_shoulders")


func test_slug_keyword_fallback_for_new_material() -> void:
	# A brand-new item never named in the map still themes off its id keyword.
	assert_eq(ItemIcons.slug_for({"item_id": "itm_mystic_herb_novel", "slot": "none"}), "m_herb")


func test_slug_empty_when_unresolvable() -> void:
	assert_eq(ItemIcons.slug_for({"item_id": "itm_totally_unknown", "slot": "none"}), "")


func test_every_mapped_slug_has_a_shipping_png() -> void:
	for slug: String in ItemIcons.SLUGS:
		assert_true(
			ResourceLoader.exists("res://assets/icons/items/" + slug + ".png"),
			"pack icon present: %s" % slug
		)


# ---- live cell rendering ----


func test_cell_shows_icon_when_file_resolves() -> void:
	_cell.configure(_entry({}))  # weapon -> w_sword.png ships
	assert_true(_cell.get_node("Icon").visible, "icon rect visible")
	assert_not_null(_cell.get_node("Icon").texture, "icon texture loaded")
	assert_false(_cell.get_node("Glyph").visible, "initials hidden when an icon resolves")


func test_cell_falls_back_to_initials_when_no_icon() -> void:
	var e := {"item_id": "itm_totally_unknown", "name": "Mystery Thing", "slot": "none"}
	_cell.configure(_entry(e))
	assert_false(_cell.get_node("Icon").visible, "icon rect hidden")
	assert_true(_cell.get_node("Glyph").visible, "initials shown")
	assert_eq(_cell.get_node("Glyph").text, "MT", "two-word initials")


func test_empty_cell_shows_neither() -> void:
	_cell.configure({}, "Head")
	assert_false(_cell.get_node("Icon").visible)
	assert_false(_cell.get_node("Glyph").visible)
	assert_eq(_cell.get_node("Hint").text, "Head")


# ---- T-640: optional drag source / drop target (bag-drag-to-equip) ----


func test_drag_source_lifts_an_occupied_cell_only() -> void:
	_cell.set_drag_source({"source": "bag", "index": 2})
	assert_null(_cell._get_cell_drag(Vector2.ZERO), "nothing to lift from an empty cell")
	_cell.configure(_entry({}))
	assert_eq(_cell._get_cell_drag(Vector2.ZERO), {"source": "bag", "index": 2})


func test_drop_target_accepts_only_configured_sources() -> void:
	_cell.set_drop_target(["bag"])
	assert_true(_cell._can_drop_cell(Vector2.ZERO, {"source": "bag", "index": 0}))
	assert_false(_cell._can_drop_cell(Vector2.ZERO, {"source": "bar", "slot": 0}))
	assert_false(_cell._can_drop_cell(Vector2.ZERO, "not a dict"))


func test_drop_target_emits_dropped_signal() -> void:
	_cell.set_drop_target(["bag"])
	watch_signals(_cell)
	_cell._drop_cell(Vector2.ZERO, {"source": "bag", "index": 5})
	assert_signal_emitted_with_parameters(_cell, "dropped", [{"source": "bag", "index": 5}])


func test_configure_before_ready_does_not_crash() -> void:
	# The panels configure a cell right after add_child, before its subtree is in the SceneTree and
	# before _ready() runs. A fresh, tree-less cell must build lazily rather than crash on null refs.
	var loose := ItemCell.new()
	loose.configure({}, "Chest")  # would raise "property 'texture' on ... Nil" pre-fix
	assert_eq(loose.get_node("Hint").text, "Chest", "empty hint renders without _ready()")
	loose.configure(_entry({}))
	assert_true(loose.get_node("Icon").visible, "icon resolves on a tree-less cell too")
	loose.free()
