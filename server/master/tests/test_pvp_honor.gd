extends "res://addons/gut/test.gd"
# T-391: honor economy — grant math off published rates, ledger discipline, overdraft-guarded
# track spends landing cosmetics on the T-375 seam, idempotent season payout, and the charter
# guardrail (no PvP reward exceeds RARE — power is never for sale).

const _CM = preload("res://scripts/character_manager.gd")
const PvpStore = preload("res://scripts/pvp_store.gd")
const PvpHonor = preload("res://scripts/pvp_honor.gd")

var _cid := 0


func before_each() -> void:
	_CM._test_skip_db = true
	_CM.reset_for_test()
	PvpStore.reset_for_test()
	PvpHonor.reset_for_test()
	_CM.ensure_character("hunter")
	_CM.ensure_character("prey")
	_cid = int(_CM.get_character("hunter")["id"])


func _rates() -> Dictionary:
	return PvpHonor.config()["honor"]


func test_match_honor_published_rates() -> void:
	var h := _rates()
	var base := int(h["participation_base"])
	# even-rating win: base + win bonus (no rating bonus at 1000, no upset)
	assert_eq(PvpHonor.match_honor(true, 1000, 1000), base + int(h["win_bonus"]))
	# 1500-rated winner: +5 rating bonus (500 over / 100)
	assert_eq(
		PvpHonor.match_honor(true, 1500, 1500), base + int(h["win_bonus"]) + 5, "rating bonus"
	)
	# rating bonus capped
	assert_eq(
		PvpHonor.match_honor(true, 3000, 3000),
		base + int(h["win_bonus"]) + int(h["rating_bonus_cap"]),
		"cap holds"
	)
	# upset pays the winner who fought UP
	assert_eq(
		PvpHonor.match_honor(true, 1000, 1400),
		base + int(h["win_bonus"]) + int(h["upset_bonus"]),
		"upset bonus"
	)
	# a healthy-rating loser earns the participation base — never zero (GW2-pips rule)
	assert_eq(PvpHonor.match_honor(false, 1200, 1000), base)
	# a struggling loser gets the catch-up multiplier
	assert_eq(
		PvpHonor.match_honor(false, 800, 1000),
		int(roundf(base * float(h["catchup_multiplier"]))),
		"catch-up band"
	)


func test_record_match_grants_and_ledgers_both_sides() -> void:
	var r: Dictionary = PvpStore.record_match({"winner": "hunter", "loser": "prey", "now": 100})
	assert_true(bool(r.get("ok", false)))
	assert_true(r.has("honor"), "honor rides the match result")
	var sid := int(r["season"])
	assert_gt(int(PvpHonor.balance(_cid, sid)["balance"]), 0, "winner banked honor")
	var reasons := PvpHonor.test_ledger().map(func(e): return str(e["reason"]))
	assert_eq(reasons.count("match"), 2, "one ledger row per participant")


func test_track_spend_overdraft_guarded_and_lands_unlock() -> void:
	var sid := 3
	PvpHonor._adjust(_cid, sid, 120, "match")  # seed a balance
	assert_eq(
		str(
			(
				PvpHonor
				. track_op(
					{
						"username": "hunter",
						"action": "activate",
						"track": "gaslight_regalia",
						"season": sid
					}
				)
				. get("active", "")
			)
		),
		"gaslight_regalia"
	)
	var spend: Dictionary = PvpHonor.track_op(
		{"username": "hunter", "action": "spend", "season": sid}
	)
	assert_true(bool(spend.get("ok", false)), "tier 0 affordable at 120")
	assert_eq(str(spend["unlock"]), "skin_gaslight_coat")
	assert_true("skin_gaslight_coat" in PvpHonor.test_unlocks(_cid), "cosmetic seam landed")
	assert_eq(int(spend["honor"]), 20, "cost deducted")
	var again: Dictionary = PvpHonor.track_op(
		{"username": "hunter", "action": "spend", "season": sid}
	)
	assert_eq(str(again.get("error", "")), "insufficient_honor", "overdraft refused")
	var reasons := PvpHonor.test_ledger().map(func(e): return str(e["reason"]))
	assert_eq(reasons.count("track_spend"), 1, "refused spend never ledgers")


func test_season_payout_idempotent() -> void:
	# a rated participant in season 7
	PvpStore.record_match({"winner": "hunter", "loser": "prey", "now": 100})
	var parts := [{"character_id": _cid, "rating": 1450}]  # Silver
	assert_eq(PvpHonor.season_payout(parts, 7), 1, "first settlement pays")
	assert_true("title:Silver Blade" in PvpHonor.test_unlocks(_cid))
	assert_eq(PvpHonor.season_payout(parts, 7), 0, "re-entry grants nothing (idempotent)")


func test_forged_track_actions_fail_closed() -> void:
	var bad: Dictionary = PvpHonor.track_op(
		{"username": "hunter", "action": "grant_honor", "amount": 99999, "season": 1}
	)
	assert_eq(str(bad.get("error", "")), "bad_action", "no grant verb exists on this surface")
	var ghost: Dictionary = PvpHonor.track_op(
		{"username": "hunter", "action": "activate", "track": "not_a_track", "season": 1}
	)
	assert_eq(str(ghost.get("error", "")), "unknown_track")
	# T-410: the terminal sink is a SPEND, never a grant. A broke caller cannot commend into the
	# negative (overdraft-guarded like every spend), and the refused buy ledgers nothing.
	var broke: Dictionary = PvpHonor.track_op(
		{"username": "hunter", "action": "commend", "season": 1}
	)
	assert_eq(str(broke.get("error", "")), "insufficient_honor", "commend cannot overdraft honor")
	assert_eq(PvpHonor.balance(_cid, 1)["balance"], 0, "a refused commend never moves honor")
	assert_eq(
		PvpHonor.test_ledger().filter(func(e): return str(e["reason"]) == "commendation").size(),
		0,
		"a refused commend writes no ledger row"
	)


# T-410: the reward tracks are the affordable content, and their total honor must keep a nightly
# dueler busy for WEEKS, not nights. This data lint locks the pacing contract so future authoring
# can't quietly shrink the chase back below the acceptance floor (extinction-burst guard).
func test_track_depth_paces_to_weeks_not_nights() -> void:
	var cfg := PvpHonor.config()
	var pacing: Dictionary = cfg.get("pacing", {})
	var per_night := int(pacing.get("observed_honor_per_night", 0))
	var target_weeks := int(pacing.get("target_weeks_to_clear_tracks", 0))
	assert_gt(per_night, 0, "the observed nightly honor rate is published")
	assert_gt(target_weeks, 0, "the target weeks-to-clear is published")
	var total := 0
	for t: Dictionary in cfg.get("tracks", []):
		for tier: Dictionary in t.get("tiers", []):
			total += int(tier.get("cost", 0))
	var weeks := float(total) / float(per_night) / 7.0
	assert_gte(
		weeks,
		float(target_weeks),
		(
			"total track honor %d / %d per night = %.2f weeks — below the %d-week chase floor"
			% [total, per_night, weeks, target_weeks]
		)
	)
	# Pay-something-early: a track's opening tier must be affordable inside night 2 (~2 nights honor).
	for t: Dictionary in cfg.get("tracks", []):
		var tiers: Array = t.get("tiers", [])
		if not tiers.is_empty():
			assert_lte(
				int((tiers[0] as Dictionary).get("cost", 0)),
				per_night * 2,
				"track %s pays its first tier by night 2" % t["id"]
			)


# T-410: the terminal commendation sink NEVER exhausts — a player who owns every affordable cosmetic
# still has an evergreen honor use. Each buy overdraft-guards, ledgers reason "commendation", and
# advances the count the T-395 mastery floor will consume; it grants no cosmetic (no power creep).
func test_commendation_sink_is_terminal_and_never_exhausts() -> void:
	var sid := 5
	var cost := PvpHonor.commendation_cost()
	assert_gt(cost, 0, "the commendation cost is positive (never free)")
	PvpHonor._adjust(_cid, sid, cost * 3, "match")  # enough for exactly three buys
	for i in range(3):
		var r: Dictionary = PvpHonor.track_op(
			{"username": "hunter", "action": "commend", "season": sid}
		)
		assert_true(
			bool(r.get("ok", false)), "commendation buy %d succeeds — the sink never completes" % i
		)
		assert_eq(int(r["count"]), i + 1, "the commendation count climbs each buy")
		assert_false("track_complete" in str(r), "the terminal sink has no completion state")
	assert_eq(
		int(PvpHonor.balance(_cid, sid)["balance"]), 0, "three buys drained exactly three costs"
	)
	assert_eq(
		PvpHonor.commendation_count(_cid, sid), 3, "the ledger-derived count matches the buys"
	)
	var rows := PvpHonor.test_ledger().filter(func(e): return str(e["reason"]) == "commendation")
	assert_eq(rows.size(), 3, "one 'commendation' ledger row per buy")
	for row: Dictionary in rows:
		assert_eq(
			int(row["delta"]), -cost, "each commendation ledgers a negative spend (never a grant)"
		)
	# Nothing cosmetic landed — the sink is a horizontal mastery seam, not a reward unlock.
	assert_eq(PvpHonor.test_unlocks(_cid).size(), 0, "commendations grant no cosmetic")


# T-401: set_title fails closed unless the id is a `title:` unlock the character actually owns.
func test_set_title_requires_an_owned_title_unlock() -> void:
	# Forged: a title the player has never earned is rejected, and nothing is stored.
	var forged: Dictionary = PvpHonor.track_op(
		{"username": "hunter", "action": "set_title", "title": "title:Grand Champion", "season": 1}
	)
	assert_eq(str(forged.get("error", "")), "not_unlocked", "an unowned title is rejected")
	assert_eq(
		str(_CM.get_character("hunter").get("chosen_title", "")), "", "rejected title never stored"
	)
	# A non-title unlock the player DOES own (a skin) still cannot be worn as a title.
	PvpHonor.grant_unlock(_cid, "skin_gaslight_coat")
	var skin_as_title: Dictionary = PvpHonor.track_op(
		{"username": "hunter", "action": "set_title", "title": "skin_gaslight_coat", "season": 1}
	)
	assert_eq(str(skin_as_title.get("error", "")), "not_a_title", "a skin is not a wearable title")
	# Grant a real title, then it can be worn — and stored.
	PvpHonor.grant_unlock(_cid, "title:Gaslight Duelist")
	var ok: Dictionary = PvpHonor.track_op(
		{
			"username": "hunter",
			"action": "set_title",
			"title": "title:Gaslight Duelist",
			"season": 1
		}
	)
	assert_true(bool(ok.get("ok", false)), "an owned title is accepted")
	assert_eq(str(ok.get("title", "")), "title:Gaslight Duelist")
	assert_eq(
		str(_CM.get_character("hunter").get("chosen_title", "")),
		"title:Gaslight Duelist",
		"the chosen title is persisted on the character"
	)
	# Clearing (empty title) is always allowed and wipes the stored choice.
	var cleared: Dictionary = PvpHonor.track_op(
		{"username": "hunter", "action": "set_title", "title": "", "season": 1}
	)
	assert_true(bool(cleared.get("ok", false)), "clearing the title is always allowed")
	assert_eq(
		str(_CM.get_character("hunter").get("chosen_title", "")), "", "clear wipes the choice"
	)


func test_charter_guardrail_no_reward_exceeds_rare() -> void:
	var cfg := PvpHonor.config()
	for t: Dictionary in cfg.get("tracks", []):
		for tier: Dictionary in t.get("tiers", []):
			assert_true(
				str(tier.get("rarity", "")) in PvpHonor.RARITY_ORDER,
				"track %s tier rarity '%s' within the rare cap" % [t["id"], tier.get("rarity")]
			)
	for tier_name: String in cfg.get("season_payout", {}):
		var grant: Dictionary = cfg["season_payout"][tier_name]
		assert_true(
			str(grant.get("rarity", "")) in PvpHonor.RARITY_ORDER,
			"season payout %s within the rare cap" % tier_name
		)


# ---- T-413: battleground ("bg" bracket) honor -------------------------------


func test_bg_match_honor_uses_published_bg_rates() -> void:
	var hb: Dictionary = PvpHonor.config()["honor_bg"]
	var base := int(hb["participation_base"])
	assert_eq(PvpHonor.match_honor(true, 1000, 1000, "bg"), base + int(hb["win_bonus"]))
	assert_eq(PvpHonor.match_honor(false, 1200, 1000, "bg"), base, "bg loser still earns the base")
	assert_eq(
		PvpHonor.match_honor(false, 800, 1000, "bg"),
		int(roundf(base * float(hb["catchup_multiplier"]))),
		"bg catch-up band applies"
	)
	# fail-safe: an unknown bracket falls back to the PUBLISHED duel rates, never hidden numbers
	assert_eq(
		PvpHonor.match_honor(true, 1000, 1000, "nonsense"),
		PvpHonor.match_honor(true, 1000, 1000, "duel"),
		"unknown bracket falls back to base rates"
	)


func test_bg_record_match_ledgers_distinct_reason() -> void:
	var r: Dictionary = PvpStore.record_match(
		{"winner": "hunter", "loser": "prey", "bracket": "bg", "now": 100}
	)
	assert_true(bool(r.get("ok", false)))
	var reasons := PvpHonor.test_ledger().map(func(e): return str(e["reason"]))
	assert_eq(reasons.count("bg_match"), 2, "both bg participants ledger reason 'bg_match'")
	assert_eq(reasons.count("match"), 0, "a bg match never writes the duel reason")


# T-413: the battleground must not blow the T-410 pacing floor — a BG-only night (published
# bg_matches_per_night at ~50% win on honor_bg rates) has to keep weeks-to-clear >= the target,
# same extinction-burst guard as the duel lint above.
func test_bg_rates_hold_the_track_pacing_floor() -> void:
	var cfg := PvpHonor.config()
	var pacing: Dictionary = cfg.get("pacing", {})
	var hb: Dictionary = cfg.get("honor_bg", {})
	var matches := int(pacing.get("bg_matches_per_night", 0))
	var target_weeks := int(pacing.get("target_weeks_to_clear_tracks", 0))
	assert_gt(matches, 0, "the bg nightly match estimate is published")
	assert_false(hb.is_empty(), "the bg rate block is published")
	# ~50% win rate: every match pays the base, half add the win bonus (rating/upset excluded —
	# they are capped extras; the lint holds the SUSTAINED average).
	var per_night := matches * int(hb["participation_base"]) + matches * int(hb["win_bonus"]) / 2
	var total := 0
	for t: Dictionary in cfg.get("tracks", []):
		for tier: Dictionary in t.get("tiers", []):
			total += int(tier.get("cost", 0))
	var duel_night := int(pacing.get("observed_honor_per_night", 0))
	var weeks := float(total) / float(maxi(per_night, duel_night)) / 7.0
	assert_gte(
		weeks,
		float(target_weeks),
		(
			"bg night %d honor (duel night %d) clears %d track honor in %.2f weeks — below the %d-week floor"
			% [per_night, duel_night, total, weeks, target_weeks]
		)
	)
