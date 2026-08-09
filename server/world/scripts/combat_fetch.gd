# T-426: behaviour-preserving carve of world main._fetch_combat's RPC (main.gd sits at the
# 1000-line cap; this banks the room for the slice-4 interrupt hook). Just the get_character_combat
# call shape — the master resolves the character + injects the world-given talent/item registries.
extends RefCounted


static func fetch(
	master_client, talent_defs: Dictionary, item_stats: Dictionary, username: String
) -> Dictionary:
	return await master_client.call_master(
		"get_character_combat",
		{"username": username, "talent_defs": talent_defs, "item_stats": item_stats}
	)
