class_name ItemIcons
# T-422 slice E: resolves an enriched inventory slot -> an item-icon slug under
# res://assets/icons/items/<slug>.png. The slug set is a curated pack of CC-BY 3.0 game-icons.net
# art (see docs/CREDITS.md), shared across many items so the catalog stays small. Resolution order
# used by ItemCell: an explicit server `icon` slug or a per-item-id art file wins first; this module
# is the TYPE FALLBACK so every item — including newly authored ones the pack never named — still
# lights up with a sensible default (a plate helm reads as a helm, an unmapped weapon as a sword).
#
# Pure + static: no Node/tree state, unit-tested directly. Inputs are the enrich_inventory fields
# the client already has (item_id, slot, armor_type); no server round-trip.

extends RefCounted

# Curated slug pack (the PNG basenames that ship). Kept here so tests can assert coverage.
const SLUGS := [
	"w_sword",
	"w_staff",
	"w_mace",
	"w_wand",
	"w_censer",
	"w_knuckles",
	"a_helm_heavy",
	"a_helm_light",
	"a_chest_heavy",
	"a_chest_light",
	"a_legs",
	"a_shoulders",
	"a_shield",
	"a_charm",
	"c_potion",
	"c_food",
	"c_repair",
	"c_antidote",
	"c_book",
	"c_scroll",
	"m_ore",
	"m_ingot",
	"m_wood",
	"m_hide",
	"m_herb",
	"m_flower",
	"m_bone",
	"m_dust",
	"m_coin",
	"m_claw",
	"m_organ",
	"m_ghost",
	"m_bottle",
	"m_pentacle",
	"m_cloak",
]

# Explicit per-item choices where slot/armor_type alone can't tell the intent apart (a mace vs a
# sword, a censer-focus vs a blade, a shield vs a signet, a potion vs a repair kit).
const ID_TO_SLUG := {
	# weapons — subtype isn't in the item data, so name the ones that aren't plain swords
	"itm_starter_staff": "w_staff",
	"itm_starter_mace": "w_mace",
	"itm_occult_sigil_cane": "w_wand",
	"itm_vharis_censer": "w_censer",
	"itm_medium_reliquary": "w_censer",
	"itm_osric_ward_censer": "w_censer",
	"itm_brass_knuckles": "w_knuckles",
	"itm_bent_truncheon": "w_knuckles",
	"itm_leadpipe": "w_knuckles",
	# offhands that aren't shields
	"itm_vharis_flooded_signet": "a_charm",
	"itm_hollowing_ward_charm": "a_charm",
	# materials / consumables (slot == none, so keyed by intent)
	"itm_wolf_pelt": "m_hide",
	"itm_copper_ore": "m_ore",
	"itm_ore_iron": "m_ore",
	"itm_copper": "m_ingot",
	"itm_timber_rough": "m_wood",
	"itm_rugged_fiber": "m_herb",
	"itm_bloodthorn": "m_flower",
	"itm_bone_fragment": "m_bone",
	"itm_grave_dust": "m_dust",
	"itm_tarnished_coin": "m_coin",
	"itm_clipped_shilling": "m_coin",
	"itm_ghoul_claw": "m_claw",
	"itm_spectral_essence": "m_ghost",
	"itm_reagent_venom_gland": "m_organ",
	"itm_bootleg_gin": "m_bottle",
	"itm_seance_sigil_chalk": "m_pentacle",
	"itm_novice_cloak": "m_cloak",
	"itm_antidote": "c_antidote",
	"itm_salvaging_kit": "c_repair",
	"itm_field_repair_kit": "c_repair",
	"itm_smiths_repair_kit": "c_repair",
	"itm_skill_book": "c_book",
	"itm_recipe_healing_potion": "c_book",
	"itm_trail_rations": "c_food",
	"itm_ration_travelers": "c_food",
	"itm_outpost_parcel": "c_scroll",
	"itm_letter_of_introduction": "c_scroll",
	"itm_vault_voucher": "c_scroll",
}

# Caster armor families read as robes/hoods; martial families as plate/mail silhouettes.
const _LIGHT_ARMOR := ["cloth", "robe", "vestment", "leather"]

# id-substring -> slug, the last-ditch fallback so any future material still gets a themed icon.
const _KEYWORD_SLUG := [
	["potion", "c_potion"],
	["repair", "c_repair"],
	["antidote", "c_antidote"],
	["ration", "c_food"],
	["recipe", "c_book"],
	["book", "c_book"],
	["primer", "c_book"],
	["letter", "c_scroll"],
	["parcel", "c_scroll"],
	["voucher", "c_scroll"],
	["scroll", "c_scroll"],
	["herb", "m_herb"],
	["bloodthorn", "m_herb"],
	["marshmint", "m_herb"],
	["emberroot", "m_herb"],
	["flower", "m_flower"],
	["blossom", "m_flower"],
	["ore", "m_ore"],
	["timber", "m_wood"],
	["wood", "m_wood"],
	["ingot", "m_ingot"],
	["pelt", "m_hide"],
	["hide", "m_hide"],
	["leather_scrap", "m_hide"],
	["bone", "m_bone"],
	["dust", "m_dust"],
	["coin", "m_coin"],
	["shilling", "m_coin"],
	["claw", "m_claw"],
	["gland", "m_organ"],
	["essence", "m_ghost"],
	["spectral", "m_ghost"],
	["gin", "m_bottle"],
	["bottle", "m_bottle"],
	["chalk", "m_pentacle"],
	["sigil", "m_pentacle"],
	["cloak", "m_cloak"],
]


# entry: an enriched inventory slot ({item_id, slot, armor_type, ...}). Returns a slug whose PNG the
# cell should try, or "" to fall back to the initials placeholder.
static func slug_for(entry: Dictionary) -> String:
	var item_id := str(entry.get("item_id", ""))
	if ID_TO_SLUG.has(item_id):
		return ID_TO_SLUG[item_id]
	var slot := str(entry.get("slot", ""))
	var light := _is_light(str(entry.get("armor_type", "")))
	match slot:
		"weapon":
			return "w_sword"  # plain-blade default; named exceptions handled above
		"head":
			return "a_helm_light" if light else "a_helm_heavy"
		"chest":
			return "a_chest_light" if light else "a_chest_heavy"
		"legs":
			return "a_legs"
		"shoulders":
			return "a_shoulders"
		"offhand":
			return "a_shield"  # signets/charms are named in ID_TO_SLUG
	# Non-equippable: keyword the id.
	for pair: Array in _KEYWORD_SLUG:
		if item_id.find(pair[0]) != -1:
			return pair[1]
	return ""


static func _is_light(armor_type: String) -> bool:
	return _LIGHT_ARMOR.has(armor_type)
