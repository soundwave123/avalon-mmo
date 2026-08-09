extends "res://addons/gut/test.gd"
# T-358/T-620: pure mob-kill XP grant math (mob_xp.gd) — gray cutoff + party split + group bonus +
# T-620's level-weighted split. The kill-XP FORMULA itself (mobLevel*5+45, elite x2) is computed by
# mob_loader.gd (see server/world/tests/test_mob_elite.gd) — this module only takes the resulting
# pool and decides how much of it ONE recipient earns.

const MX = preload("res://scripts/mob_xp.gd")


func test_solo_kill_grants_full_value() -> void:
	assert_eq(MX.share(40, 22, 22, 1), 40, "solo = the full authored value, no split")


func test_zero_or_negative_xp_grants_nothing() -> void:
	assert_eq(MX.share(0, 22, 22, 1), 0, "an xp-less mob (the dummy) grants nothing")
	assert_eq(MX.share(-5, 22, 22, 1), 0, "negative is floored to nothing")


# T-620: WoW classic 6-49 band grey formula: grey = charLevel - floor(charLevel/10) - 5. Replaces
# the old flat GRAY_DELTA=8 gap rule (session-22's reconcile target).
func test_grey_level_formula_table() -> void:
	assert_eq(MX.grey_level(6), 1, "just inside the 6-49 band")
	assert_eq(MX.grey_level(10), 4)
	assert_eq(MX.grey_level(20), 13)
	assert_eq(MX.grey_level(22), 15)
	assert_eq(MX.grey_level(30), 22)
	assert_eq(MX.grey_level(49), 40, "top of the authored band")
	# Below level 6 there is no meaningful gray range yet — clamped to 0, never negative.
	assert_eq(MX.grey_level(1), 0)
	assert_eq(MX.grey_level(5), 0)


func test_gray_mob_cutoff_grants_zero() -> void:
	# A L22 char's grey_level is 15 — at or below that, the kill is worth nothing.
	assert_eq(MX.share(40, 15, 22, 1), 0, "exactly at grey_level(22)=15 = gray")
	assert_eq(MX.share(40, 5, 22, 1), 0, "well below the cutoff = gray")


func test_grey_cutoff_boundary_exact() -> void:
	# One level ABOVE the formula's exact cutoff still pays full — the boundary is inclusive-zero.
	var char_level := 22
	var grey := MX.grey_level(char_level)  # 15
	assert_eq(MX.share(40, grey, char_level, 1), 0, "mob at the grey boundary pays zero")
	assert_eq(MX.share(40, grey + 1, char_level, 1), 40, "one level above grey still pays full")


func test_lower_level_player_gets_full_value() -> void:
	# An under-level player killing a higher mob is never gray.
	assert_eq(MX.share(55, 26, 22, 1), 55, "a red mob pays full")


func test_party_split_with_group_bonus() -> void:
	# 2-member group: pool * 1.16, split in half. 40*116/200 = 23 (floored).
	assert_eq(MX.share(40, 22, 22, 2), 23)
	# 3-member: 40*130/300 = 17.
	assert_eq(MX.share(40, 22, 22, 3), 17)


func test_group_split_never_beats_solo_per_member() -> void:
	# Each member's share in a group is <= the solo value (the bonus softens, not inverts, the split).
	for n in range(2, 6):
		assert_lte(MX.share(40, 22, 22, n), 40, "%d-member share <= solo" % n)


# T-472: raid sizes 6-10 are real table entries (+6%/member past 5).
func test_raid_sized_snapshots_use_the_raid_bonus_table() -> void:
	assert_eq(MX.share(40, 22, 22, 6), (40 * 156) / (100 * 6), "6-man uses the +56% entry")
	assert_eq(MX.share(100, 22, 22, 10), 18, "full 10-raid: 100 * 180% / 10 = 18 each")


# T-472: a snapshot larger than the raid cap falls back to the 10-member bonus.
func test_oversized_snapshot_reuses_ten_member_bonus() -> void:
	assert_eq(MX.share(100, 22, 22, 11), (100 * 180) / (100 * 11), "size>10 reuses +80%")
	assert_eq(MX.share(100, 22, 22, 12), 15, "100 * 180% / 12 = 15")


# T-472 anti-inflation rule: per-capita share STRICTLY decreases as the group grows, so a raid
# can never out-earn a party per head (and a party never out-earns solo).
func test_per_capita_share_strictly_decreases_with_size() -> void:
	var prev: int = MX.share(10000, 22, 22, 1)
	for n in range(2, 13):
		var cur: int = MX.share(10000, 22, 22, n)
		assert_lt(cur, prev, "%d-member per-capita share below %d-member" % [n, n - 1])
		prev = cur


func test_raid_split_is_below_party_split_per_member() -> void:
	assert_lt(
		MX.share(40, 22, 22, 10), MX.share(40, 22, 22, 5), "10-raid pays less per head than 5-party"
	)


func test_party_grants_zero_when_gray_regardless_of_size() -> void:
	assert_eq(MX.share(40, 20, 30, 3), 0, "gray cutoff applies before the split")


# T-452: persisted L40 sees a L5 mob as gray; the authoritative L5 sync makes it appropriate.
func test_synced_mentor_earns_level_appropriate_kill_xp() -> void:
	assert_eq(MX.share(40, 5, 40, 1), 0, "unsynced veteran gets no gray-mob XP")
	assert_eq(MX.share(40, 5, 40, 1, 5), 40, "synced mentor earns the authored reward")


func test_mentor_reward_level_is_cap_only_and_never_boosts_true_level() -> void:
	assert_eq(MX.share(40, 5, 5, 1, 40), 40, "upward sync clamps to persisted true level")
	assert_eq(MX.share(40, 5, 40, 1, 0), 0, "invalid sync falls back to persisted truth")


# ---- T-620: level-weighted party split -----------------------------------------------------
# Session-22 finding: there was NO level-weighting — an L2 and an L8 got an identical absolute
# share of any credited kill, both directions. party_level_sum (the CREDITED party's summed
# level, resolved master-side from persisted characters) fixes that: each recipient's cut of the
# bonused pool is proportional to their OWN level's fraction of the sum.


func test_level_weighted_split_favors_the_higher_level_member() -> void:
	# L8 + L2 duo (sum 10) split a mob's pool: L8 gets 8/10, L2 gets 2/10 of the bonused pool.
	var l8_share: int = MX.share(100, 5, 8, 2, -1, 10)
	var l2_share: int = MX.share(100, 5, 2, 2, -1, 10)
	assert_gt(l8_share, l2_share, "the L8 mentor earns more absolute XP than the L2 rider")


func test_level_weighted_split_matches_the_level_fraction_of_the_bonused_pool() -> void:
	# pool_total = 100 * 116% = 116 (the 2-member GROUP_BONUS_PCT). L8's cut = floor(116*8/10) = 92;
	# L2's cut = floor(116*2/10) = 23.
	assert_eq(MX.share(100, 5, 8, 2, -1, 10), 92)
	assert_eq(MX.share(100, 5, 2, 2, -1, 10), 23)


func test_level_weighted_split_still_respects_the_gray_cutoff() -> void:
	# The L8's own grey_level is 0 (below the 6-49 band never applies, but the mob here is level 5
	# which the L2 in this pair is NOT gray to either) — weighting never bypasses the per-recipient
	# gray check; a mob gray to ONE member still pays that member zero regardless of the pool.
	assert_eq(MX.share(100, 5, 40, 2, -1, 42), 0, "an L40 in this pair still sees a L5 mob as gray")


func test_missing_party_level_sum_falls_back_to_legacy_equal_split() -> void:
	# No party_level_sum supplied (-1, the default) -> old behavior: naive equal 1/N of the pool.
	assert_eq(MX.share(40, 22, 22, 2), 23, "unchanged legacy 2-member split")
	assert_eq(MX.share(40, 22, 22, 2, -1, -1), 23, "explicit -1 is identical to omitting it")
	assert_eq(MX.share(40, 22, 22, 2, -1, 0), 23, "0 (no real sum) also falls back to equal split")
