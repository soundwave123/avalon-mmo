class_name Rarity
# T-231: rarity color language — the single source of truth for item-name colors, mirroring the
# WoW read: grey/white/green/blue/purple/orange for junk/common/uncommon/rare/epic/legendary.
# Every UI that renders an item name (inventory, vendor/auction listings) should go through
# color_hex()/colorize() here rather than hardcoding hex values.

extends RefCounted

const COLORS := {
	"junk": "9d9d9d",
	"common": "ffffff",
	"uncommon": "1eff00",
	"rare": "0070dd",
	"epic": "a335ee",
	"legendary": "ff8000",
}


# Returns the hex (no leading '#') for a rarity tier; unknown tiers fall back to common/white.
static func color_hex(rarity: String) -> String:
	return str(COLORS.get(rarity, COLORS["common"]))


# Wraps text in a [color=#hex]...[/color] bbcode tag for the given rarity.
static func colorize(text: String, rarity: String) -> String:
	return "[color=#%s]%s[/color]" % [color_hex(rarity), text]
