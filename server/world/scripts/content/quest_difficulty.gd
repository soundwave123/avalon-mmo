# T-621: quest difficulty colour — pure mapping of (questLevel - charLevel) to the WoW colour band.
#
# The colours ARE the self-routing pacing UI (docs/design/quest-xp-reference.md §1): a player reads
# the log/tracker/offer card colour and knows whether a quest is above their weight, in the intended
# band, or trivial. The server computes it (it owns questLevel = min_level and the character's true
# level); the client only PAINTS the returned band name. This is the quest analogue of WoW's mob
# difficulty colours.
#
#   delta = questLevel - charLevel
#     >= +5 .......... "red"     (very hard — well above you)
#     +3 .. +4 ....... "orange"  (hard)
#     -2 .. +2 ....... "yellow"  (the intended band)
#     below, not yet trivial .. "green"  (easy)
#     trivial ........ "grey"    (out-levelled — pairs with the T-621 XP decay tail)
#
# The green->grey boundary reuses the WoW-classic grey formula (the shape mob_xp.grey_level uses for
# kill XP): a quest is grey/trivial once questLevel <= charLevel - floor(charLevel/10) - 5. Pure,
# deterministic, no I/O; inputs never mutated.

extends RefCounted

const RED := "red"
const ORANGE := "orange"
const YELLOW := "yellow"
const GREEN := "green"
const GREY := "grey"


# The grey/trivial cutoff: quests at-or-below this level are trivial for the character. Mirrors
# mob_xp.grey_level (WoW classic 6-49 band); clamped to 0 below level 6 so a fresh character never
# sees low quests swallowed as grey.
static func grey_level(char_level: int) -> int:
	var lvl: int = maxi(1, char_level)
	return maxi(0, lvl - (lvl / 10) - 5)  # integer division floors for positive ints


# Band name for a quest of `quest_level` viewed by a character of `char_level`.
static func color(quest_level: int, char_level: int) -> String:
	var ql: int = maxi(1, quest_level)
	var cl: int = maxi(1, char_level)
	var delta: int = ql - cl
	if delta >= 5:
		return RED
	if delta >= 3:
		return ORANGE
	if delta >= -2:
		return YELLOW
	if ql <= grey_level(cl):
		return GREY
	return GREEN
