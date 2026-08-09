class_name ItemLevelGate
extends RefCounted

# T-681: THE shared required_level validator — one gate, every path that puts an item to use.
#
# ADR 0011 blessed the WoW-style permanent gear ladder as canon, which makes a level gate correct:
# a piece is worn by the level that earned it. Gear reaches characters from outside their own kills
# (trade_logic.gd, auction_logic.gd/T-670, mail, guild bank), so the gate has to be SERVER-SIDE —
# and it has to sit on every path, not just one.
#
# WHY A MODULE AND NOT A LINE INSIDE equip(). There are TWO independent paths that resolve an item
# definition and act on it:
#   1. inventory_logic.equip()      — moves a bag item into an equip slot
#   2. craft_ops.use_item_op()      — reads `registry.get(item_id).get("use_effect")` and fires it
# The second never touches equip() at all. A check written inside equip() would leave consumables
# (and any future enchant/augment that resolves the same way) ungated — the twink hole reopening
# through a different door. Both callers ask THIS module instead, so a gate added here is a gate
# everywhere.
#
# FAIL-OPEN, deliberately, in exactly two cases (mirroring T-063's empty-`char_class` convention):
#   - an item definition with no `required_level` is ungated (level 1); back-compat for any item a
#     data migration has not reached, and for the injected fixture registries the unit tests build.
#   - a char_level <= 0 means the caller could not resolve a character (tests, non-character
#     callers); the level dimension does not apply.
# Every REAL server path resolves the level from the persisted character row, never from the wire.
#
# Pure: no DB, no OS time, no global state, inputs never mutated. Same inputs -> same answer.

# The refusal reason, routed to the client on the same seam as T-063's "wrong_armor_type".
const REASON := "too_low_level"


# The gate an item definition asks for. Absent/garbage field = 1 (ungated).
static func required_level(item_def: Dictionary) -> int:
	return maxi(1, int(item_def.get("required_level", 1)))


# The power budget the item was authored for (T-681 ledger dimension). Absent = 1.
static func item_level(item_def: Dictionary) -> int:
	return maxi(1, int(item_def.get("item_level", 1)))


# May a character of `char_level` equip/use this item? char_level <= 0 = unresolved, no gate.
static func meets(item_def: Dictionary, char_level: int) -> bool:
	if char_level <= 0:
		return true
	return char_level >= required_level(item_def)


# "" when allowed, else REASON — the shape both call sites fold into their own failure returns.
static func refusal(item_def: Dictionary, char_level: int) -> String:
	return "" if meets(item_def, char_level) else REASON
