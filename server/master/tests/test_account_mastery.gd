extends "res://addons/gut/test.gd"
# T-395: the permanent account-mastery floor — pure unbounded level curve, monotonic
# server-observed accrual, horizontal-ONLY rewards (the no-power-stat charter guard),
# the exactly-once T-394 season-snapshot feed, the live T-410 commendation feed, survival
# across a season rollover (the whole point), and the adversarial guarantee that no client
# input can set mastery xp/level or mint a reward.

const _CM = preload("res://scripts/character_manager.gd")
const AccountMastery = preload("res://scripts/account_mastery.gd")
const RiftLadder = preload("res://scripts/rift_ladder.gd")
const RiftSeason = preload("res://scripts/rift_season.gd")
const PvpSeason = preload("res://scripts/pvp_season.gd")
const PvpHonor = preload("res://scripts/pvp_honor.gd")
const PvpStore = preload("res://scripts/pvp_store.gd")
const WardrobeOps = preload("res://scripts/wardrobe_ops.gd")
const AchievementStore = preload("res://scripts/achievement_store.gd")  # T-676: PvP ach feed

var _s1_now := 0  # a clock inside season 1
var _s2_now := 0  # a clock inside season 2 (one rollover past _s1_now)
var _vet := 0


func before_each() -> void:
	_CM._test_skip_db = true
	_CM.reset_for_test()
	AccountMastery.reset_for_test()
	AchievementStore.reset_for_test()  # T-676: PvP wins now also earn achievements that feed mastery
	RiftLadder.reset_for_test()
	RiftSeason.reset_for_test()
	WardrobeOps.reset_for_test()
	PvpHonor.reset_for_test()
	PvpStore.reset_for_test()
	_s1_now = PvpSeason.EPOCH_UNIX + 100
	_s2_now = PvpSeason.EPOCH_UNIX + PvpSeason.SEASON_SECS + 100
	_CM.ensure_character("vet")
	_vet = int(_CM.get_character("vet")["id"])


# T-507/T-547: add an alt to `account`'s roster with an explicit character name + slot, mirroring
# the shape migration 044 gives every character (distinct id, shared username = the account).
func _add_alt(account: String, name: String, slot: int) -> int:
	var rows: Dictionary = _CM.test_characters_ref()
	var cid := 2000 + rows.size()
	rows[name] = {
		"id": cid,
		"username": account,
		"name": name,
		"slot": slot,
		"class": "warrior",
		"class_locked": false,
		"gender": "",
		"xp": 0,
		"level": 1,
	}
	return cid


# ---- pure curve ------------------------------------------------------------------


func test_level_curve_is_monotonic_and_unbounded() -> void:
	var prev_cost := 0
	var prev_total := -1
	for l in range(0, 200):
		var cost: int = AccountMastery.cost_for_next(l)
		var total: int = AccountMastery.xp_to_reach(l)
		assert_true(cost >= prev_cost, "per-level cost never decreases (earned but reachable)")
		assert_true(total > prev_total, "cumulative threshold strictly climbs")
		prev_cost = cost
		prev_total = total
	# The closed-form inverse agrees with the thresholds exactly at every boundary.
	for l in range(0, 60):
		var at: int = AccountMastery.xp_to_reach(l)
		assert_eq(AccountMastery.level_for_xp(at), l, "threshold xp lands exactly on level %d" % l)
		if at > 0:
			assert_eq(
				int(AccountMastery.level_for_xp(at - 1)), l - 1, "one xp short is a level short"
			)
	# Unbounded: an enormous total still resolves to a bigger number, no wall, no stall.
	assert_true(
		AccountMastery.level_for_xp(1000 * 1000 * 1000) > AccountMastery.level_for_xp(1000 * 1000),
		"the number always climbs — no hard cap (D4)"
	)


# ---- accrual (monotonic, server-observed, fail-closed) ---------------------------


func test_accrual_is_monotonic_and_fail_closed() -> void:
	var r1: Dictionary = AccountMastery.observe("vet", _vet, "commendation", 1)
	assert_true(bool(r1.get("ok", false)))
	var xp1 := int(r1["xp"])
	assert_true(xp1 > 0, "a published source credits xp")
	# Unknown source / non-positive units / bad identity all write NOTHING.
	assert_true(AccountMastery.observe("vet", _vet, "made_up_source", 5).has("error"))
	assert_true(AccountMastery.observe("vet", _vet, "commendation", 0).has("error"))
	assert_true(AccountMastery.observe("vet", _vet, "commendation", -10).has("error"))
	assert_true(AccountMastery.observe("vet", 0, "commendation", 1).has("error"))
	var p: Dictionary = AccountMastery.progress(AccountMastery.subject_for("vet", _vet))
	assert_eq(int(p["xp"]), xp1, "rejected observations moved nothing")
	# More play only ever adds — xp is monotonic and every accrual is ledgered with its source.
	var r2: Dictionary = AccountMastery.observe("vet", _vet, "pvp_match", 3)
	assert_true(int(r2["xp"]) > xp1, "xp only climbs")
	assert_eq(AccountMastery.test_ledger().size(), 2, "one ledger row per credited observation")


func test_commendation_purchase_feeds_mastery_live() -> void:
	PvpHonor._adjust(_vet, 1, PvpHonor.commendation_cost(), "test_seed")
	var r: Dictionary = PvpHonor._buy_commendation(_vet, 1)
	assert_true(bool(r.get("ok", false)), "the seeded honor buys one commendation")
	var p: Dictionary = AccountMastery.progress(AccountMastery.subject_for("vet", _vet))
	assert_eq(
		int(p["xp"]),
		AccountMastery.source_weight("commendation"),
		"the T-410 sink is a live mastery feed at the published weight"
	)


# ---- T-536: the newly-wired PvE/PvP feeds actually mint mastery --------------------


func test_quest_complete_feeds_mastery_at_published_weight() -> void:
	# The quest turn-in seam (main.gd _turn_in) routes the server-observed completion here.
	var r: Dictionary = AccountMastery.observe("vet", _vet, "quest_complete", 1)
	assert_true(bool(r.get("ok", false)), "a quest completion credits the floor")
	var p: Dictionary = AccountMastery.progress(AccountMastery.subject_for("vet", _vet))
	assert_eq(
		int(p["xp"]),
		AccountMastery.source_weight("quest_complete"),
		"quest_complete is a live, non-zero mastery feed at the published weight"
	)
	# A forged source name on the same seam mints nothing (fail-closed).
	assert_true(AccountMastery.observe("vet", _vet, "quest_turnin", 1).has("error"))


func test_pvp_match_feeds_both_participants_via_record_match() -> void:
	# record_match is the server-observed settle; T-536 wires BOTH participants (win OR lose).
	_CM.ensure_character("foe")
	var foe := int(_CM.get_character("foe")["id"])
	var res: Dictionary = PvpStore.record_match({"winner": "vet", "loser": "foe", "now": _s1_now})
	assert_true(bool(res.get("ok", false)), "the match settles")
	var w := AccountMastery.source_weight("pvp_match")
	assert_true(w > 0, "pvp_match is a published, non-zero weight")
	# T-676: a settled match also EARNS PvP achievements (a first-duel win, a rating milestone) which
	# separately feed mastery, so the total xp is no longer pvp_match alone — assert the specific
	# pvp_match credit lands for BOTH participants via the mastery ledger (source-scoped, robust to
	# the added achievement feed).
	assert_eq(
		_ledger_amount(AccountMastery.subject_for("vet", _vet), "pvp_match"),
		w,
		"the winner's account is credited one pvp_match"
	)
	assert_eq(
		_ledger_amount(AccountMastery.subject_for("foe", foe), "pvp_match"),
		w,
		"the loser's account is credited one pvp_match too (reward-for-effort)"
	)


# Sum the mastery-ledger amount credited to `subject` from exactly one `source` (T-676 helper).
func _ledger_amount(subject: String, source: String) -> int:
	var total := 0
	for e: Dictionary in AccountMastery.test_ledger():
		if str(e.get("subject", "")) == subject and str(e.get("source", "")) == source:
			total += int(e.get("amount", 0))
	return total


# ---- T-547: the season feed credits the account's MAX best-tier across ALL alts ----


func test_season_feed_credits_account_max_across_alts_not_first() -> void:
	# One account, three alts, each with a season-1 rift snapshot; the MAIN pushed the highest tier.
	var main_cid := _vet  # alt at slot 0 (== account "vet")
	var alt_a := _add_alt("vet", "vet_alt_a", 1)
	var alt_b := _add_alt("vet", "vet_alt_b", 2)
	# Best tiers: a low alt is iterated first (lowest id), the MAIN is NOT the first row.
	RiftSeason._test_snapshots["%d|1" % alt_a] = {
		"character_id": alt_a, "season_id": 1, "best_tier": 3
	}
	RiftSeason._test_snapshots["%d|1" % main_cid] = {
		"character_id": main_cid, "season_id": 1, "best_tier": 20
	}
	RiftSeason._test_snapshots["%d|1" % alt_b] = {
		"character_id": alt_b, "season_id": 1, "best_tier": 7
	}
	AccountMastery.consume_season(1)
	var want := 20 * AccountMastery.source_weight("season_best_tier")
	assert_eq(
		int(AccountMastery.progress("vet")["xp"]),
		want,
		"the account is credited its MAX best-tier (20), not the first-iterated alt (3)"
	)
	# Idempotent under the account-scoped claim: a re-drain credits nothing more.
	AccountMastery.consume_season(1)
	assert_eq(int(AccountMastery.progress("vet")["xp"]), want, "re-draining the season is a no-op")


func test_season_feed_single_char_account_unchanged() -> void:
	# Regression: a lone character is credited exactly as before (its own best tier).
	RiftSeason._test_snapshots["%d|1" % _vet] = {
		"character_id": _vet, "season_id": 1, "best_tier": 9
	}
	AccountMastery.consume_season(1)
	assert_eq(
		int(AccountMastery.progress("vet")["xp"]),
		9 * AccountMastery.source_weight("season_best_tier"),
		"a single-character account is credited identically to before"
	)


# ---- T-548: account-earned mastery cosmetics are wearable on EVERY alt -------------


func test_mastery_reward_is_account_wide_wearable_on_all_alts() -> void:
	var alt := _add_alt("vet", "vet_alt", 1)
	# The account (via its main) earns enough mastery to clear several authored reward levels.
	AccountMastery.observe("vet", _vet, "commendation", 40)
	var level := int(AccountMastery.progress("vet")["level"])
	assert_true(level >= 3, "the account reaches at least level 3")
	# Every reached reward is wearable on the alt that did NOT trigger the level-up (account-owned).
	var alt_owned: Array = WardrobeOps.unlocks_for(alt)
	for t: Dictionary in AccountMastery.config().get("reward_levels", []):
		if level >= int(t["level"]):
			assert_has(
				alt_owned, str(t["unlock"]), "the alt can wear the account-earned reward %s" % t
			)
	# ...and it is the SAME set the triggering character sees (one account-wide wardrobe).
	assert_eq(
		WardrobeOps.unlocks_for(_vet), alt_owned, "both alts of the account see one unlock set"
	)


func test_character_scope_keeps_mastery_rewards_per_character() -> void:
	# Under the owner's character scope the track is per-character, so grants stay per-character.
	AccountMastery._cfg = {
		"scope": "character",
		"sources": {"commendation": 25},
		"reward_levels": [{"level": 1, "unlock": "title:solo"}],
	}
	var alt := _add_alt("vet", "vet_alt2", 1)
	AccountMastery.observe("vet", _vet, "commendation", 40)
	assert_has(WardrobeOps.unlocks_for(_vet), "title:solo", "the earning character gets its reward")
	assert_does_not_have(
		WardrobeOps.unlocks_for(alt), "title:solo", "character scope does not leak to the alt"
	)


# ---- horizontal rewards (and the no-power-stat charter guard) --------------------


func test_levels_grant_horizontal_rewards_idempotently() -> void:
	# Enough commendation weight to clear several authored reward levels in one observation.
	AccountMastery.observe("vet", _vet, "commendation", 40)
	var level := int(AccountMastery.progress(AccountMastery.subject_for("vet", _vet))["level"])
	assert_true(level >= 3, "the test accrual reaches at least level 3")
	var owned: Array = WardrobeOps.unlocks_for(_vet)
	for t: Dictionary in AccountMastery.config().get("reward_levels", []):
		if level >= int(t["level"]):
			assert_has(owned, str(t["unlock"]), "every reached level's reward is granted")
	# Re-walking the table at the same level is idempotent — the unlock seam never duplicates.
	var n := owned.size()
	AccountMastery._grant_rewards("vet", _vet, level)
	assert_eq(WardrobeOps.unlocks_for(_vet).size(), n, "re-grants are no-ops")


func test_no_mastery_reward_is_ever_a_power_stat() -> void:
	# The SHIPPED table is horizontal-only shaped: exactly {level, unlock}, cosmetic namespace.
	var authored: Array = AccountMastery.config().get("reward_levels", [])
	assert_true(authored.size() > 0, "the published table exists")
	for t: Dictionary in authored:
		assert_true(
			AccountMastery._is_horizontal_reward(t),
			"authored reward %s is a title/skin and nothing else" % str(t)
		)
	# The guard is ENFORCED, not advisory: a poisoned config row carrying a stat never pays out.
	AccountMastery._cfg = {
		"scope": "account",
		"sources": {"commendation": 25},
		"reward_levels":
		[
			{"level": 1, "unlock": "title:legit"},
			{"level": 1, "unlock": "skin_ok", "stat_bonus": 50},
			{"level": 1, "unlock": "attack_power_500"},
		]
	}
	AccountMastery.observe("vet", _vet, "commendation", 40)
	var owned: Array = WardrobeOps.unlocks_for(_vet)
	assert_has(owned, "title:legit", "the horizontal reward lands")
	assert_does_not_have(owned, "skin_ok", "a row smuggling a stat key is refused whole")
	assert_does_not_have(owned, "attack_power_500", "a non-cosmetic namespace is refused")


# ---- the T-394 season-snapshot feed ----------------------------------------------


func test_season_snapshot_feeds_mastery_exactly_once() -> void:
	RiftLadder._write_tier(_vet, 21)
	RiftLadder._write_best(_vet, 1, 21)
	# First sighting in season 2: T-394 settles season 1, then the snapshot feeds mastery.
	var read: Dictionary = AccountMastery.dispatch(
		{"action": "read", "username": "vet", "now": _s2_now}
	)
	var want := 21 * AccountMastery.source_weight("season_best_tier")
	assert_eq(int(read["xp"]), want, "best tier 21 credits at the published weight")
	# Re-dispatch (and a direct re-consume) credit NOTHING — the feed claim is exactly-once.
	AccountMastery.dispatch({"action": "read", "username": "vet", "now": _s2_now})
	AccountMastery.consume_season(1)
	var p: Dictionary = AccountMastery.progress(AccountMastery.subject_for("vet", _vet))
	assert_eq(int(p["xp"]), want, "the season feed can never double-credit")


# ---- survival across the T-394 soft reset (the whole point) ----------------------


func test_mastery_survives_a_season_rollover_intact() -> void:
	AccountMastery.observe("vet", _vet, "commendation", 10)
	var before: Dictionary = AccountMastery.progress(AccountMastery.subject_for("vet", _vet))
	RiftLadder._write_tier(_vet, 21)
	RiftLadder._write_best(_vet, 1, 21)
	# Two full T-394 rollovers: the keystone regresses (the seasonal layer resets)...
	RiftSeason.ensure_rollover(_s2_now)
	RiftSeason.ensure_rollover(_s2_now + PvpSeason.SEASON_SECS)
	assert_true(int(RiftLadder.keystone(_vet)["tier"]) < 21, "the SEASONAL layer regressed")
	# ...while mastery is structurally untouchable (not season-keyed, not in the write-set).
	var after: Dictionary = AccountMastery.progress(AccountMastery.subject_for("vet", _vet))
	assert_eq(int(after["xp"]), int(before["xp"]), "mastery xp survives every rollover")
	assert_eq(int(after["level"]), int(before["level"]), "mastery level survives every rollover")
	# And once the settled seasons are consumed, the permanent number only went UP.
	AccountMastery.dispatch({"action": "read", "username": "vet", "now": _s2_now})
	var fed: Dictionary = AccountMastery.progress(AccountMastery.subject_for("vet", _vet))
	assert_true(int(fed["xp"]) > int(before["xp"]), "a finished season raises the floor")


# ---- owner scope dial ------------------------------------------------------------


func test_scope_is_owner_tunable_between_account_and_character() -> void:
	assert_eq(AccountMastery.subject_for("vet", _vet), "vet", "default scope keys the account")
	AccountMastery._cfg = {"scope": "character", "sources": {"commendation": 25}}
	assert_eq(
		AccountMastery.subject_for("vet", _vet), "char:%d" % _vet, "character scope keys the id"
	)
	AccountMastery.observe("vet", _vet, "commendation", 1)
	assert_eq(
		int(AccountMastery.progress("char:%d" % _vet)["xp"]),
		25,
		"accrual lands on the scoped subject"
	)


# ---- adversarial (no client input moves mastery) ---------------------------------


func test_forged_mastery_intents_are_rejected() -> void:
	AccountMastery.observe("vet", _vet, "commendation", 1)
	var before: Dictionary = AccountMastery.progress(AccountMastery.subject_for("vet", _vet))
	var unlocks := WardrobeOps.unlocks_for(_vet).size()
	for forged: Dictionary in [
		{"action": "set_xp", "username": "vet", "xp": 999999, "now": _s1_now},
		{"action": "set_level", "username": "vet", "level": 99, "now": _s1_now},
		{"action": "observe", "username": "vet", "source": "commendation", "units": 99},
		{"action": "grant", "username": "vet", "unlock": "title:forged", "now": _s1_now},
		{"action": "consume_season", "username": "vet", "season": 1, "now": _s1_now},
		{"action": "", "username": "vet", "now": _s1_now},
	]:
		assert_eq(
			str(AccountMastery.dispatch(forged).get("error", "")),
			"unknown_action",
			"forged '%s' is rejected" % str(forged.get("action"))
		)
	var after: Dictionary = AccountMastery.progress(AccountMastery.subject_for("vet", _vet))
	assert_eq(int(after["xp"]), int(before["xp"]), "no forged action moved xp")
	assert_eq(int(after["level"]), int(before["level"]), "no forged action moved level")
	assert_eq(WardrobeOps.unlocks_for(_vet).size(), unlocks, "no forged action minted a reward")
	# The read surface itself never trusts packet identity fields beyond the session username,
	# and a forged xp/level field on a legit read is simply never consulted.
	var read: Dictionary = AccountMastery.dispatch(
		{"action": "read", "username": "vet", "xp": 999999, "level": 99, "now": _s1_now}
	)
	assert_eq(int(read["xp"]), int(before["xp"]), "a forged xp field is never read")
	assert_eq(int(read["level"]), int(before["level"]), "a forged level field is never read")
