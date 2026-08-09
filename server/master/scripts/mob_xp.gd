# T-358: mob-kill XP grant math — pure, deterministic, no I/O (mirrors leveling.gd's idiom).
#
# The owner blessed a quest+grind blend (owner-input-queue, 2026-07-12): killing a mob grants a
# per-mob XP value, split across the party kill-credit snapshot with a small grouping bonus. This
# module is the single authority on HOW MUCH a given kill grants ONE recipient. The world OBSERVES
# the kill and supplies the snapshot; master resolves the recipient's authoritative level (from the
# session, never the packet) and applies the result via leveling.apply_xp. There is NO client verb
# in this path — the grant is server-observed, so a client can never assert a kill or an XP amount.
#
# HARD CONSTRAINTS: no DB, no OS time, deterministic, inputs never mutated (same contract as
# leveling.gd / rested_logic.gd).

extends RefCounted

# Small-group bonus: the TOTAL XP pool is multiplied by this percent (keyed by eligible-party size)
# before the 1/N split, so grouping is not taxed as hard as a naive 1/N (WoW-classic shape). Solo
# (size 1) takes the full value with no split. Data constant.
# T-472 RAID SPLIT RULE: sizes 6-10 continue the same philosophy with a flat +6%/member (the
# diminishing tail of the 16/14/10/10 party increments), so the pool keeps growing but the
# PER-CAPITA share strictly decreases with size — a 10-raid member earns 18% of a kill vs a
# 5-party member's 30%, so raiding can never out-earn partying per head (the T-472 anti-inflation
# trap) while big groups are still not taxed to a naive 1/N. Sizes past 10 reuse the 10-member
# bonus (the Era-2 20-man widening re-extends this table, not the formula).
const GROUP_BONUS_PCT := {1: 0, 2: 16, 3: 30, 4: 40, 5: 50, 6: 56, 7: 62, 8: 68, 9: 74, 10: 80}
const _MAX_BONUS_SIZE := 10


# T-620: WoW-shape gray-mob cutoff — a mob at/below grey_level(charLevel) grants ZERO XP (the
# anti-farm rule that stops L40s grinding the starter meadow). Replaces the old flat GRAY_DELTA=8
# gap rule with the real WoW classic formula for the 6-49 band: grey = charLevel -
# floor(charLevel/10) - 5. Below level 6 there is no meaningful gray range yet (clamped to 0 so a
# fresh character never sees a negative/zero-or-below cutoff swallow low mobs); 50+ reuses the same
# shape (WoW's own steeper 50-59 table is future hardening — this band is not reachable at Avalon's
# current content cap, see docs/design/quest-xp-reference.md §3/§5).
static func grey_level(char_level: int) -> int:
	var lvl: int = maxi(1, char_level)
	return maxi(0, lvl - (lvl / 10) - 5)  # integer division floors for positive ints


# XP that ONE recipient earns for a kill. `mob_xp` = the kill's authored/formula pool (T-620:
# mob_loader computes it from mobLevel*5+45, doubled for elites); `mob_level` gates the gray cutoff;
# `player_level` is persisted truth. T-452's optional `mentor_level` is computed from the world's
# authoritative party and clamped here so it can reduce the comparison level but never raise it
# above earned level. T-620's optional `party_level_sum` is the SUM of every CREDITED recipient's
# PERSISTED level (main._party_level_sum resolves it from CharacterManager, same snapshot the
# party_size count uses) — when supplied for a group (>1), the bonused pool is split by this
# recipient's LEVEL FRACTION of that sum instead of a naive equal 1/N, so an under-level rider in a
# high-level party earns less absolute XP than their mentor (the boost-abuse surface: previously an
# L2 and an L8 got an identical share). Omitted (<=0) falls back to the legacy equal split for any
# caller that hasn't been updated. Integer-exact (floored); inputs are never mutated.
static func share(
	mob_xp: int,
	mob_level: int,
	player_level: int,
	party_size: int,
	mentor_level: int = -1,
	party_level_sum: int = -1
) -> int:
	if mob_xp <= 0:
		return 0
	var reward_level := maxi(1, player_level)
	if mentor_level > 0:
		reward_level = clampi(mentor_level, 1, reward_level)
	if mob_level <= grey_level(reward_level):
		return 0  # gray mob — out-leveled, no XP
	var n: int = maxi(1, party_size)
	if n == 1:
		return mob_xp
	var bonus: int = int(GROUP_BONUS_PCT.get(n, GROUP_BONUS_PCT[_MAX_BONUS_SIZE]))
	var pool_total: int = (mob_xp * (100 + bonus)) / 100
	if party_level_sum > 0:
		return (pool_total * maxi(1, player_level)) / party_level_sum
	return pool_total / n  # legacy equal floor split
