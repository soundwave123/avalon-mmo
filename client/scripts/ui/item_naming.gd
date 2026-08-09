class_name ItemNaming
extends RefCounted

# T-571 (report #31): the vendor Wares/Sell/Buyback tabs showed raw internal ids
# (itm_potion_minor_healing) whenever a server row carried no display name — the same class of
# bug T-557 already fixed for the Wardrobe's equipped-slot preview. One shared humanizer so every
# "resolve an item id for display" site degrades the same truthful way instead of leaking ids.

const _PREFIX := "itm_"


# Prefer a real server-supplied name; humanize the id only when the name is blank.
static func display_name(item_id: String, server_name: String, fallback: String = "Item") -> String:
	var trimmed := server_name.strip_edges()
	if trimmed != "":
		return trimmed
	return humanize_item_id(item_id, fallback)


# "itm_potion_minor_healing" -> "Potion Minor Healing": drop the "itm_" prefix, underscores to
# spaces, title-case. A blank/absent id degrades to `fallback` rather than an empty gap.
static func humanize_item_id(item_id: String, fallback: String = "Item") -> String:
	var trimmed := item_id.strip_edges()
	if trimmed == "":
		return fallback
	return trimmed.trim_prefix(_PREFIX).replace("_", " ").strip_edges().capitalize()
