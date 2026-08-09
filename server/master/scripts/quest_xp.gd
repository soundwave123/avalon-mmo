# T-621: over-level quest-XP decay — pure, deterministic, no I/O (mirrors mob_xp.gd / leveling.gd).
#
# The WoW-shape quest reward contract (docs/design/quest-xp-reference.md §2): a quest pays FULL
# authored XP while the character is at-or-below questLevel+5, then decays in fixed steps as the
# character out-levels it, bottoming out at 10% for grey (trivial) quests — never zero (grey quests
# still pay something + full reputation when rep ships). This is the anti-inflation / anti-dead-
# content rule that stops an L20 farming L1 quests at full value. It is the QUEST-side analogue of
# mob_xp.grey_level's kill-XP cutoff, but softer (decay, not a hard zero) because a quest is a
# one-shot, not a farmable faucet.
#
# `questLevel` is the quest's `min_level` (the authored level band — the same field try_accept gates
# on); `charLevel` is the master's persisted truth (never client-supplied). Under-level characters
# (delta < 0) always get full XP.
#
# GROUP RULE (T-621 item 1): this is applied PER CHARACTER at their own turn-in. Quest XP is NEVER
# reduced by grouping — every party member who holds the quest turns it in individually and gets
# their own (decayed-for-their-own-level) full value. There is deliberately no party term here; the
# social-contract split lives only in mob_xp (group for quests, solo for grind).
#
# HARD CONSTRAINTS: no DB, no OS time, deterministic, inputs never mutated.

extends RefCounted

# Full XP while charLevel <= questLevel + FULL_DELTA; each level past that steps down the table.
const FULL_DELTA := 5
# delta-past-full (charLevel - questLevel - FULL_DELTA) -> percent of authored XP. Index 0 == the
# first over-cap level (+6 over quest). At/under FULL_DELTA is full (100); anything past the
# table tail floors at the last entry (grey quests: 10%, never zero).
const _DECAY_STEPS := [80, 60, 40, 20, 10]


# Percent (0-100) of the authored quest XP a character of `char_level` earns for a quest authored at
# `quest_level`. 100 while at-or-under questLevel+5 (incl. under-level); then 80/60/40/20/10.
static func decay_pct(char_level: int, quest_level: int) -> int:
	var over: int = maxi(1, char_level) - maxi(1, quest_level) - FULL_DELTA
	if over <= 0:
		return 100
	var idx: int = mini(over - 1, _DECAY_STEPS.size() - 1)
	return int(_DECAY_STEPS[idx])


# The actual XP granted at turn-in: authored `base_xp` scaled by decay_pct, integer-floored. A quest
# with no XP (breadcrumb) stays zero; negative is floored to zero.
static func decayed_xp(base_xp: int, char_level: int, quest_level: int) -> int:
	if base_xp <= 0:
		return 0
	return (base_xp * decay_pct(char_level, quest_level)) / 100
