extends "res://addons/gut/test.gd"
# T-231: Rarity — single source of truth for the WoW-style item-name color language. Asserts the
# tier->color mapping is total (all 6 tiers, distinct hex) and colorize() wraps bbcode correctly.

const _TIERS := ["junk", "common", "uncommon", "rare", "epic", "legendary"]


func test_all_six_tiers_are_mapped() -> void:
	for tier: String in _TIERS:
		assert_true(Rarity.COLORS.has(tier), "missing color for tier %s" % tier)


func test_all_six_colors_are_distinct() -> void:
	var seen: Array = []
	for tier: String in _TIERS:
		var hex: String = Rarity.color_hex(tier)
		assert_false(seen.has(hex), "duplicate color %s for tier %s" % [hex, tier])
		seen.append(hex)
	assert_eq(seen.size(), _TIERS.size())


func test_color_hex_matches_wow_reference() -> void:
	assert_eq(Rarity.color_hex("junk"), "9d9d9d")
	assert_eq(Rarity.color_hex("common"), "ffffff")
	assert_eq(Rarity.color_hex("uncommon"), "1eff00")
	assert_eq(Rarity.color_hex("rare"), "0070dd")
	assert_eq(Rarity.color_hex("epic"), "a335ee")
	assert_eq(Rarity.color_hex("legendary"), "ff8000")


func test_color_hex_unknown_falls_back_to_common() -> void:
	assert_eq(Rarity.color_hex("bogus"), Rarity.color_hex("common"))


func test_colorize_wraps_text_in_bbcode() -> void:
	var out := Rarity.colorize("Sword of Testing", "epic")
	assert_eq(out, "[color=#a335ee]Sword of Testing[/color]")


func test_colorize_unknown_rarity_wraps_common() -> void:
	var out := Rarity.colorize("Mystery Item", "nonsense")
	assert_eq(out, "[color=#ffffff]Mystery Item[/color]")
