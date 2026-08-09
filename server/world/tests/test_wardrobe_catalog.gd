extends GutTest

const WardrobeCatalog = preload("res://scripts/wardrobe_catalog.gd")


func test_catalog_combines_item_looks_with_authored_store_looks_and_dyes() -> void:
	var registry := {
		"itm_sword":
		{
			"name": "Iron Sword",
			"slot": "weapon",
			"armor_type": "none",
			"rarity": "uncommon",
			"stats": {"attack": 8},
		},
		"itm_iron_sword":
		{
			"name": "Iron Sword",
			"slot": "weapon",
			"armor_type": "none",
			"rarity": "uncommon",
			"stats": {"attack": 8},
		},
		# The display items backing the T-476 store rows in wardrobe.json.
		"itm_smith_broadsword": {"name": "Broadsword", "slot": "weapon", "armor_type": "none"},
		"itm_arcanist_cowl": {"name": "Cowl", "slot": "head", "armor_type": "robe"},
		"itm_ironward_cuirass": {"name": "Cuirass", "slot": "chest", "armor_type": "plate"},
		# T-679: shoulders backing for the guild-earned crest mantle.
		"itm_ironward_pauldrons": {"name": "Pauldrons", "slot": "shoulders", "armor_type": "plate"},
		"itm_ore": {"name": "Ore", "slot": "none", "stats": {}},
	}
	var cat := WardrobeCatalog.new()
	assert_eq(cat.setup("res://data/wardrobe.json", registry), "")
	assert_eq(cat.appearance("itm_sword")["display_item"], "itm_sword", "drop look is data-derived")
	assert_true(
		cat.appearance("cos_gilded_blade").has("display_item"), "store look is data-authored"
	)
	assert_eq(
		cat.appearance("mentor_sigil_blade")["display_item"],
		"itm_iron_sword",
		"mentor threshold lands on a real cataloged presentation-only look"
	)
	assert_true(cat.appearance("itm_ore").is_empty(), "non-wearable item is never a look")
	assert_true(cat.dye("dye_crimson").has("color"), "dye is data-authored")
	for look: Dictionary in cat.all_appearances():
		assert_false(look.has("stats"), "catalog strips every power field")


func test_new_authored_ids_are_resolved_without_code_branches() -> void:
	var cat := WardrobeCatalog.new()
	assert_eq(cat.setup("res://data/wardrobe.json", {}), "")
	var look := cat.appearance("cos_gilded_blade")
	assert_eq(look["slot"], "weapon")
	assert_eq(look["dye_mask"], "all")


# --- T-482 charter content lint: the store can never outrank or out-power earned ---------------


func test_shipped_store_rows_obey_the_charter() -> void:
	var cat := WardrobeCatalog.new()
	assert_eq(cat.setup("res://data/wardrobe.json", {}), "")
	var board := cat.store_appearances()
	assert_gt(board.size(), 0, "the store actually has something to sell (no dead currency)")
	for look: Dictionary in board:
		assert_true(bool(look.get("store", false)), "browse returns store rows only")
		assert_gt(int(look.get("price", 0)), 0, "every store row carries an honest positive price")
		# Bought never outranks earned: held strictly below the earned marquee tier.
		assert_lt(
			int(look.get("prestige_tier", 0)),
			WardrobeCatalog.MARQUEE_TIER,
			"a store look never reaches the earned marquee tier"
		)
		assert_lte(int(look.get("prestige_tier", 0)), WardrobeCatalog.STORE_CEILING)
		for field in ["stats", "attack", "armor", "damage", "power", "discount", "was_price"]:
			assert_false(
				look.has(field), "no power or fake-discount field on a store row: %s" % field
			)


func test_store_row_at_marquee_tier_fails_content_load() -> void:
	# The ceiling is enforced at load, not just at purchase — a mis-authored store row is loud.
	var offending := WardrobeCatalog._validate_store(
		{"id": "cos_bad", "store": true, "price": 50, "prestige_tier": WardrobeCatalog.MARQUEE_TIER}
	)
	assert_ne(offending, "", "a store row at the marquee tier is a rejected content error")


func test_store_appearance_resolver_refuses_earned_and_unpriced_looks() -> void:
	var cat := WardrobeCatalog.new()
	assert_eq(cat.setup("res://data/wardrobe.json", {}), "")
	assert_false(cat.store_appearance("cos_gilded_blade").is_empty(), "a real store look resolves")
	assert_true(
		cat.store_appearance("mentor_sigil_blade").is_empty(),
		"an EARNED look is never resolvable as a store purchase"
	)
	assert_true(cat.store_appearance("cos_nonexistent").is_empty(), "an unknown id sells nothing")


# T-679: the guild-earned tabard/crest/regalia are marquee-tier EARN-ONLY looks — the store can
# never sell guild identity (the charter's "earned marquee unreachable by purchase" rule).
func test_guild_earned_cosmetics_are_marquee_tier_and_unsellable() -> void:
	var cat := WardrobeCatalog.new()
	assert_eq(cat.setup("res://data/wardrobe.json", {}), "")
	for gid: String in ["guild_tabard_vanguard", "guild_crest_shoulders", "guild_regalia_head"]:
		var look := cat.appearance(gid)
		assert_false(look.is_empty(), "%s is a real cataloged look" % gid)
		assert_eq(
			int(look.get("prestige_tier", 0)),
			WardrobeCatalog.MARQUEE_TIER,
			"%s sits at the earned marquee tier" % gid,
		)
		assert_false(bool(look.get("store", false)), "%s is never a store row" % gid)
		assert_true(cat.store_appearance(gid).is_empty(), "%s can never be purchased" % gid)
