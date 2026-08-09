extends GutTest

# T-571 (report #31): the shared item-id humanizer — vendor Wares/Sell/Buyback and the Wardrobe
# (T-557) both resolve through this so a missing server display name never leaks a raw
# "itm_potion_minor_healing" id to the player.

const ItemNaming = preload("res://scripts/ui/item_naming.gd")


func test_humanize_drops_prefix_and_title_cases() -> void:
	assert_eq(ItemNaming.humanize_item_id("itm_potion_minor_healing"), "Potion Minor Healing")


func test_humanize_blank_id_degrades_to_fallback() -> void:
	assert_eq(ItemNaming.humanize_item_id(""), "Item")
	assert_eq(ItemNaming.humanize_item_id("", "Equipped"), "Equipped")


func test_humanize_id_without_prefix_still_title_cases() -> void:
	assert_eq(ItemNaming.humanize_item_id("wolf_pelt"), "Wolf Pelt")


func test_display_name_prefers_server_name_verbatim() -> void:
	assert_eq(ItemNaming.display_name("itm_iron_sword", "Recruit's Sword"), "Recruit's Sword")


func test_display_name_falls_back_to_humanized_id_when_name_blank() -> void:
	assert_eq(ItemNaming.display_name("itm_potion_minor_healing", ""), "Potion Minor Healing")
	assert_false(
		ItemNaming.display_name("itm_potion_minor_healing", "").contains("itm_"),
		"the raw item id never surfaces"
	)


func test_display_name_ignores_whitespace_only_server_name() -> void:
	assert_eq(ItemNaming.display_name("itm_iron_sword", "   "), "Iron Sword")
