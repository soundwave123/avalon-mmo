extends "res://addons/gut/test.gd"
# T-394: season windows on the shared T-390 clock, the rollover observer's SOFT reset
# (keystone regresses toward a floor, never a wipe; idempotent via the snapshot claim — the
# T-395 hook), the cosmetic-only seasonal reward track, seasonal-ladder freshness, the
# ETERNAL-HOME guarantee, and the adversarial guarantee that no client input can name a
# season, trigger a rollover, or set a season score.

const _CM = preload("res://scripts/character_manager.gd")
const RiftLadder = preload("res://scripts/rift_ladder.gd")
const RiftSeason = preload("res://scripts/rift_season.gd")
const PvpSeason = preload("res://scripts/pvp_season.gd")
const WardrobeOps = preload("res://scripts/wardrobe_ops.gd")
const ServicesStore = preload("res://scripts/services_store.gd")

var _s1_now := 0  # a clock inside season 1
var _s2_now := 0  # a clock inside season 2 (one rollover past _s1_now)
var _vet := 0  # season-1 veteran: keystone 21, best tier 21
var _mate := 0  # season-1 dabbler: keystone 2, best tier 2


func before_each() -> void:
	_CM._test_skip_db = true
	_CM.reset_for_test()
	RiftLadder.reset_for_test()
	RiftSeason.reset_for_test()
	WardrobeOps.reset_for_test()
	ServicesStore.reset_for_test()
	_s1_now = PvpSeason.EPOCH_UNIX + 100
	_s2_now = PvpSeason.EPOCH_UNIX + PvpSeason.SEASON_SECS + 100
	_CM.ensure_character("vet")
	_CM.ensure_character("mate")
	_vet = int(_CM.get_character("vet")["id"])
	_mate = int(_CM.get_character("mate")["id"])
	RiftLadder._write_tier(_vet, 21)
	RiftLadder._write_best(_vet, 1, 21)
	RiftLadder._write_tier(_mate, 2)
	RiftLadder._write_best(_mate, 1, 2)


# ---- season window / clock ------------------------------------------------------


func test_season_window_derives_from_server_clock_alone() -> void:
	var s1 := RiftSeason.season_read(_s1_now)
	var s2 := RiftSeason.season_read(_s2_now)
	assert_eq(int(s1["season"]), 1, "the epoch clock sits in season 1")
	assert_eq(int(s2["season"]), 2, "one SEASON_SECS later is season 2")
	assert_eq(int(s1["ends_at"]), int(s2["starts_at"]), "windows are contiguous")
	assert_eq(
		int(s1["next_starts_at"]),
		int(s1["ends_at"]),
		"the return-trigger hook points at the boundary"
	)
	assert_eq(int(s1["next_season"]), 2)
	assert_eq(int(s1["season_days"]), PvpSeason.SEASON_DAYS)


func test_cadence_is_owner_tunable_through_the_config_seam() -> void:
	# The shipped clock IS season_for_config under the published constants (one shared brain).
	var via_consts := PvpSeason.season_for(_s2_now)
	var via_seam := PvpSeason.season_for_config(
		_s2_now, PvpSeason.EPOCH_UNIX, PvpSeason.SEASON_SECS
	)
	assert_eq(via_consts, via_seam, "season_for flows through the config seam")
	# Retuning the cadence (owner knob) moves the id/window with no other code involved.
	var monthly := PvpSeason.season_for_config(_s2_now, PvpSeason.EPOCH_UNIX, 30 * 86400)
	assert_eq(int(monthly["id"]), 4, "a 30-day cadence re-derives ids from the same clock")


# ---- soft reset: regression toward a floor, never a wipe ------------------------


func test_rollover_soft_resets_keystone_toward_floor_not_wipe() -> void:
	assert_eq(RiftSeason.ensure_rollover(_s2_now), 2, "both season-1 participants settle")
	var after := int(RiftLadder.keystone(_vet)["tier"])
	assert_eq(after, 11, "floor 1 + half the progress above it (21 -> 11)")
	assert_gt(after, RiftSeason.floor_tier(), "a veteran keeps a head start — NOT a wipe")
	assert_lt(after, 21, "but the competitive score did regress")
	var reset_rows := RiftLadder.test_ledger().filter(
		func(e): return str(e["verdict"]) == "season_reset" and int(e["character_id"]) == _vet
	)
	assert_eq(reset_rows.size(), 1, "the reset is ledgered")
	assert_eq(int(reset_rows[0]["tier_before"]), 21)
	assert_eq(int(reset_rows[0]["tier_after"]), 11)


func test_rollover_never_drops_below_the_floor() -> void:
	RiftSeason.ensure_rollover(_s2_now)
	assert_eq(int(RiftLadder.keystone(_mate)["tier"]), 1, "tier 2 regresses to the floor, no lower")
	assert_eq(RiftSeason.regressed_tier(1), 1, "the floor is a fixed point")


func test_rollover_is_idempotent_per_character() -> void:
	assert_eq(RiftSeason.ensure_rollover(_s2_now), 2)
	assert_eq(RiftSeason.ensure_rollover(_s2_now), 0, "re-entry settles nobody")
	assert_eq(int(RiftLadder.keystone(_vet)["tier"]), 11, "no double regression (11, never 6)")
	assert_eq(RiftSeason.snapshots_for_season(1).size(), 2, "one snapshot per character, ever")


func test_no_rollover_inside_season_one() -> void:
	assert_eq(RiftSeason.ensure_rollover(_s1_now), 0, "there is no prior season to settle")
	assert_eq(int(RiftLadder.keystone(_vet)["tier"]), 21, "nothing moved")


# ---- the T-395 snapshot hook ----------------------------------------------------


func test_snapshot_hook_feeds_t395_permanent_standings() -> void:
	RiftSeason.ensure_rollover(_s2_now)
	var rows := RiftSeason.snapshots_for_season(1)
	assert_eq(rows.size(), 2)
	var top: Dictionary = rows[0]
	assert_eq(int(top["character_id"]), _vet, "best tier first — the prestige read order")
	assert_eq(int(top["season_id"]), 1)
	assert_eq(int(top["best_tier"]), 21, "the season's standing, preserved forever")
	assert_eq(int(top["keystone_before"]), 21, "the soft-reset audit pair rides along")
	assert_eq(int(top["keystone_after"]), 11)


# ---- seasonal ladder freshness ---------------------------------------------------


func test_seasonal_leaderboard_is_fresh_each_season() -> void:
	var s1_board := RiftSeason.dispatch({"action": "leaderboard", "now": _s1_now})
	assert_eq((s1_board["entries"] as Array).size(), 2, "season 1 shows season-1 standings")
	var s2_board := RiftSeason.dispatch({"action": "leaderboard", "now": _s2_now})
	assert_eq((s2_board["entries"] as Array).size(), 0, "the new season's ladder starts EMPTY")
	RiftLadder._write_best(_vet, 2, 12)  # a season-2 clear
	s2_board = RiftSeason.dispatch({"action": "leaderboard", "now": _s2_now})
	var entries: Array = s2_board["entries"]
	assert_eq(entries.size(), 1, "only the current season's scores appear")
	assert_eq(int((entries[0] as Dictionary)["tier"]), 12)


# ---- the eternal home ------------------------------------------------------------


func test_eternal_home_characters_gear_coin_cosmetics_survive_rollover() -> void:
	# Bank a life: xp/level, a bag item, coins, and an earned cosmetic — the player's HOME.
	var c := _CM.get_character("vet")
	c["level"] = 37
	c["xp"] = 12345
	assert_true(_CM.add_item_to_bag(_vet, "itm_heirloom_blade", 1, 0))
	ServicesStore.adjust_coins(_vet, 400, "test_seed")
	var coins_before := ServicesStore.get_coins(_vet)
	WardrobeOps.grant_unlock(_vet, "skin_earned_last_season", "grant")
	RiftSeason.ensure_rollover(_s2_now)
	RiftSeason.ensure_rollover(_s2_now)  # even a redundant settle pass touches nothing
	var home := _CM.get_character("vet")
	assert_false(home.is_empty(), "the character is NEVER destroyed by a rollover")
	assert_eq(int(home["level"]), 37, "level untouched")
	assert_eq(int(home["xp"]), 12345, "xp untouched")
	var bag := _CM.get_inventory(_vet)
	assert_eq(bag.size(), 1, "gear untouched")
	assert_eq(str((bag[0] as Dictionary)["item_id"]), "itm_heirloom_blade")
	assert_eq(ServicesStore.get_coins(_vet), coins_before, "coin untouched")
	assert_has(
		WardrobeOps.unlocks_for(_vet), "skin_earned_last_season", "earned cosmetics are eternal"
	)
	# ONLY the competitive season state regressed.
	assert_eq(int(RiftLadder.keystone(_vet)["tier"]), 11, "the season keystone is all that moved")


# ---- seasonal reward track (cosmetic-only, charter-compliant) --------------------


func test_reward_track_grants_cosmetics_by_best_tier_exactly_once() -> void:
	RiftSeason.ensure_rollover(_s2_now)
	var vet_unlocks := WardrobeOps.unlocks_for(_vet)
	assert_has(vet_unlocks, "title:rift_delver", "best 21 clears the tier-3 threshold")
	assert_has(vet_unlocks, "skin_cloak_riftbound", "and tier 8")
	assert_has(vet_unlocks, "title:rift_conqueror", "and tier 15")
	assert_has(vet_unlocks, "title:rift_ascendant_1", "and the first evergreen milestone (tier 20)")
	assert_eq(WardrobeOps.unlocks_for(_mate).size(), 0, "best 2 reaches no published threshold")
	RiftSeason.ensure_rollover(_s2_now)
	assert_eq(
		WardrobeOps.unlocks_for(_vet).size(), 4, "re-settle grants nothing twice (3 fixed + 1 mile)"
	)


# ---- T-538: the evergreen milestone cadence (there is ALWAYS a next prize past tier 15) ----------


func test_milestone_cadence_grants_at_the_right_tiers() -> void:
	# first_best_tier 20, cadence 5: 20 -> _1, 25 -> _2, 30 -> _3, ...
	assert_eq(RiftSeason.milestone_unlocks(19), [], "below the first milestone, nothing")
	assert_eq(RiftSeason.milestone_unlocks(20), ["title:rift_ascendant_1"], "tier 20 = first mile")
	assert_eq(RiftSeason.milestone_unlocks(24), ["title:rift_ascendant_1"], "24 hasn't reached _2")
	assert_eq(
		RiftSeason.milestone_unlocks(25),
		["title:rift_ascendant_1", "title:rift_ascendant_2"],
		"tier 25 unlocks the second"
	)
	var deep := RiftSeason.milestone_unlocks(40)
	assert_eq(deep.size(), 5, "40 = _1(20) _2(25) _3(30) _4(35) _5(40)")
	assert_eq(str(deep[-1]), "title:rift_ascendant_5", "the last one is numbered by cadence step")


func test_milestone_ladder_never_dead_ends() -> void:
	# The whole point: whatever tier a climber sits at, there is a NEXT milestone above it.
	for best in [20, 47, 123, 480]:
		var here := RiftSeason.milestone_unlocks(best).size()
		var above := RiftSeason.milestone_unlocks(best + 5).size()
		assert_gt(above, here, "a climber at best %d still has a next prize five tiers up" % best)


func test_milestone_cadence_is_data_driven_and_bounded() -> void:
	var m: Dictionary = RiftSeason.config().get("milestones", {})
	assert_gt(int(m.get("first_best_tier", 0)), 15, "milestones start ABOVE the last authored tier")
	assert_gt(int(m.get("cadence", 0)), 0, "a positive repeating cadence")
	assert_ne(str(m.get("unlock_prefix", "")), "", "a named title prefix")
	# The `max` guard keeps a pathological best from looping unbounded (server truth, belt+braces).
	var huge := RiftSeason.milestone_unlocks(10_000_000)
	assert_eq(huge.size(), int(m.get("max", 0)), "the loop is capped at the published max")


func test_milestone_rewards_are_power_neutral_titles() -> void:
	# Every milestone unlock is a cosmetic TITLE id — never an item/stat/coin grant (T-482 charter).
	for u: String in RiftSeason.milestone_unlocks(200):
		assert_true(u.begins_with("title:"), "milestone '%s' is a cosmetic title, not power" % u)
		for bad in ["stat", "power", "item", "coin", "damage", "armor", "attack"]:
			assert_false(u.contains(bad), "no power token in milestone id '%s'" % u)


func test_reward_track_is_power_neutral() -> void:
	var tiers: Array = RiftSeason.config().get("reward_tiers", [])
	assert_gt(tiers.size(), 0, "the published track exists")
	for t: Dictionary in tiers:
		var keys := t.keys()
		keys.sort()
		assert_eq(keys, ["min_best_tier", "unlock"], "a tier is a threshold + a cosmetic id ONLY")
		assert_ne(str(t["unlock"]), "", "every tier grants a named cosmetic")
		for bad in ["stat", "stats", "power", "item", "coins", "damage"]:
			assert_false(t.has(bad), "no power on the seasonal track (T-482 charter)")


# ---- adversarial: no client input names a season or a score ----------------------


func test_forged_season_actions_and_fields_are_rejected() -> void:
	for verb in ["rollover", "set_score", "set_season", "snapshot", "season_reset", "set_tier"]:
		var res := RiftSeason.dispatch({"action": verb, "username": "vet", "now": _s1_now})
		assert_true(res.has("error"), "forged '%s' is rejected" % verb)
	# A forged season id in the read is never consulted — the id derives from `now` alone.
	var read := RiftSeason.dispatch({"action": "season", "season": 99, "now": _s1_now})
	assert_eq(int(read["season"]), 1, "the season is the CLOCK's, not the packet's")
	# And none of the forgeries moved any season state.
	assert_eq(int(RiftLadder.keystone(_vet)["tier"]), 21)
	assert_eq(RiftSeason.snapshots_for_season(1).size(), 0)
	assert_eq(WardrobeOps.unlocks_for(_vet).size(), 0)
