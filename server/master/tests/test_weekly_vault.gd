extends GutTest

# T-480: the weekly appointment vault — rollover, per-track credit, choice scaling, idempotent
# deterministic claim, and the power-neutral allow-list. All pure/test-mode: no DB, no OS-time
# dependence in any assertion (every date key is injected).

const Weekly = preload("res://scripts/weekly_vault.gd")
const WeeklyStore = preload("res://scripts/weekly_vault_store.gd")
const Daily = preload("res://scripts/daily_appointment.gd")
const CharacterManager = preload("res://scripts/character_manager.gd")
const ServicesStore = preload("res://scripts/services_store.gd")
const TelemetryStore = preload("res://scripts/telemetry_store.gd")
const Main = preload("res://scripts/main.gd")

# 2026-07-13 is a Monday; WED/SUN sit inside its ISO week, MON_NEXT starts the following one.
const WED := "2026-07-15"
const SUN := "2026-07-19"
const MON_NEXT := "2026-07-20"


func before_each() -> void:
	CharacterManager.reset_for_test()
	WeeklyStore.reset_for_test()
	TelemetryStore.reset_for_test()
	CharacterManager.ensure_character("alice")


func _fill_track(track: String, date_key: String) -> void:
	for _i in range(int((Weekly.TRACKS[track] as Dictionary)["goal"])):
		WeeklyStore.credit("alice", track, date_key)


func test_week_key_maps_any_weekday_to_iso_monday_and_rolls_over() -> void:
	assert_eq(Weekly.week_key(WED), "2026-07-13", "mid-week maps to its ISO Monday")
	assert_eq(Weekly.week_key(SUN), "2026-07-13", "Sunday still belongs to Monday's week")
	assert_eq(Weekly.week_key(MON_NEXT), "2026-07-20", "next Monday opens a fresh window")
	assert_eq(Weekly.previous_week_key(MON_NEXT), "2026-07-13", "the new week vaults the old one")
	_fill_track("quests", WED)
	var same_week := WeeklyStore.status("alice", SUN)
	var next_week := WeeklyStore.status("alice", MON_NEXT)
	assert_eq(int(same_week["completed"]), 1, "weekend progress counts in the same window")
	assert_eq(int(next_week["completed"]), 0, "rollover starts the new week's tracks at zero")
	assert_eq(
		int(next_week["vault"]["completed"]), 1, "last week's effort waits in the vault, not lost"
	)


func test_per_track_credit_is_track_scoped_and_caps_at_goal() -> void:
	var goal := int((Weekly.TRACKS["quests"] as Dictionary)["goal"])
	for _i in range(goal + 3):  # over-play never builds a surplus chore bank
		WeeklyStore.credit("alice", "quests", WED)
	var status := WeeklyStore.status("alice", WED)
	for row: Dictionary in status["tracks"]:
		if str(row["track"]) == "quests":
			assert_eq(int(row["progress"]), goal, "progress caps at the goal")
			assert_true(bool(row["complete"]))
		else:
			assert_eq(int(row["progress"]), 0, "credit never bleeds across tracks")
	assert_eq(WeeklyStore.credit("alice", "not_a_track", WED), {}, "unknown track is a no-op")


func test_choices_scale_with_tracks_completed_and_one_track_guarantees_one() -> void:
	assert_eq(Weekly.offers_for(0).size(), 0, "an empty week offers nothing to grieve")
	assert_eq(Weekly.offers_for(1).size(), 1, "one completed track always earns a choice")
	assert_eq(Weekly.offers_for(2).size(), 2)
	assert_eq(Weekly.offers_for(4).size(), 3, "agency grows with effort, capped at the board")
	_fill_track("quests", WED)
	_fill_track("dungeons", WED)
	var vault: Dictionary = WeeklyStore.status("alice", MON_NEXT)["vault"]
	assert_eq((vault["offers"] as Array).size(), 2, "the rollover vault offers what was earned")


func test_claim_is_a_deterministic_choice_and_idempotent() -> void:
	_fill_track("quests", WED)
	var coins_before := ServicesStore.get_coins(1)
	var claim := WeeklyStore.claim("alice", MON_NEXT, "xp")
	assert_true(bool(claim["ok"]))
	assert_eq(claim["reward"], {"xp": 400}, "the pick maps to a KNOWN reward — never a roll")
	assert_eq(
		int(CharacterManager.get_character("alice")["xp"]) > 0, true, "chosen XP actually lands"
	)
	var again := WeeklyStore.claim("alice", MON_NEXT, "xp")
	assert_false(bool(again["ok"]), "one vault, one claim per week")
	assert_eq(str(again["reason"]), "already_claimed")
	assert_eq(ServicesStore.get_coins(1), coins_before, "the rejected retry grants nothing")
	var vault: Dictionary = WeeklyStore.status("alice", MON_NEXT)["vault"]
	assert_true(bool(vault["claimed"]))
	assert_eq(str(vault["choice"]), "xp")


func test_unearned_or_unknown_choice_is_rejected_without_stamping_the_week() -> void:
	_fill_track("quests", WED)  # one track -> only the first offer is on the board
	var over_reach := WeeklyStore.claim("alice", MON_NEXT, "mixed")
	assert_false(bool(over_reach["ok"]), "an offer not yet unlocked cannot be claimed")
	assert_eq(str(over_reach["reason"]), "invalid_choice")
	var empty_week := WeeklyStore.claim("alice", "2026-08-31", "xp")
	assert_false(bool(empty_week["ok"]), "an empty vault has nothing to claim")
	var honest := WeeklyStore.claim("alice", MON_NEXT, "xp")
	assert_true(bool(honest["ok"]), "a failed pick never burns the once-per-week gate")


func test_rewards_are_power_neutral_allow_list_only() -> void:
	for offer: Dictionary in Weekly.offers_for(4):
		var reward: Dictionary = offer["reward"]
		assert_true(
			Daily.reward_is_power_neutral(reward), "every offer passes the T-450 allow-list"
		)
		for key in reward:
			assert_has(["xp", "coins", "cosmetic_currency"], str(key))
	assert_eq(
		Weekly.resolve_choice([{"id": "hack", "reward": {"gear": 1}}], "hack"),
		{},
		"a non-neutral offer can never resolve, even if one leaked onto a board"
	)


func test_skipped_week_is_additive_only_no_banked_loss_and_no_daily_subgate() -> void:
	_fill_track("dungeons", WED)
	WeeklyStore.claim("alice", MON_NEXT, "xp")
	var coins := ServicesStore.get_coins(1)
	var xp := int(CharacterManager.get_character("alice")["xp"])
	var after_gap := WeeklyStore.status("alice", "2026-08-12")  # weeks later, nothing played
	assert_true(bool(after_gap["ok"]))
	assert_eq(ServicesStore.get_coins(1), coins, "a skipped week removes no banked coin")
	assert_eq(
		int(CharacterManager.get_character("alice")["xp"]), xp, "a skipped week removes no XP"
	)
	# Catch-up guarantee: the whole set fills in ONE sitting (single date key, no per-day gate).
	for track: String in Weekly.TRACKS:
		_fill_track(track, "2026-08-12")
	assert_eq(int(WeeklyStore.status("alice", "2026-08-12")["completed"]), Weekly.TRACKS.size())


# T-549: inject an alt on an existing account (2nd+ character; same username, distinct id/name).
func _add_alt(account: String, name: String, slot: int) -> int:
	var rows: Dictionary = CharacterManager.test_characters_ref()
	var cid := 1000 + rows.size()
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


func _goal(track: String) -> int:
	return int((Weekly.TRACKS[track] as Dictionary)["goal"])


# T-549: an account's alts build toward ONE shared weekly set and share ONE vault claim — not 3x.
func test_weekly_vault_is_account_scoped_across_alts() -> void:
	_add_alt("alice", "alice_alt2", 1)
	_add_alt("alice", "alice_alt3", 2)
	# The alts do the work; the shared account progress reflects it.
	for _i in range(_goal("quests")):
		WeeklyStore.credit("alice_alt2", "quests", WED)
	var seen_by_main := WeeklyStore.status("alice", WED)
	var quests_row: Dictionary = {}
	for row: Dictionary in seen_by_main["tracks"]:
		if str(row["track"]) == "quests":
			quests_row = row
	assert_eq(int(quests_row["progress"]), _goal("quests"), "an alt's progress is the account's")
	assert_true(bool(quests_row["complete"]), "the shared track is complete for the whole account")

	# One vault claim per account: first character claims, the others are locked out.
	var first := WeeklyStore.claim("alice", MON_NEXT, "xp")
	assert_true(bool(first["ok"]), "the first character to claim spends the account's vault")
	var second := WeeklyStore.claim("alice_alt2", MON_NEXT, "xp")
	var third := WeeklyStore.claim("alice_alt3", MON_NEXT, "xp")
	assert_false(bool(second["ok"]), "a second alt cannot re-claim the account's vault")
	assert_eq(str(second["reason"]), "already_claimed")
	assert_false(bool(third["ok"]), "a third alt cannot re-claim the account's vault")


# T-549: characters on DIFFERENT accounts each earn and claim their own vault.
func test_weekly_vault_is_independent_across_accounts() -> void:
	CharacterManager.ensure_character("bob")
	_fill_track("quests", WED)  # alice's account earns its vault
	for _i in range(_goal("quests")):
		WeeklyStore.credit("bob", "quests", WED)  # bob's account earns its own
	var a := WeeklyStore.claim("alice", MON_NEXT, "xp")
	var b := WeeklyStore.claim("bob", MON_NEXT, "xp")
	assert_true(bool(a["ok"]), "alice's account claims its vault")
	assert_true(bool(b["ok"]), "bob's account claims its own vault, independently")


func test_turn_in_dispatch_ticks_the_quests_track_and_telemetry_taxonomy_emits() -> void:
	var main := Main.new()
	var quest := {
		"id": "q_weekly",
		"title": "Weekly probe",
		"min_level": 1,
		"prerequisite_quest": "",
		"giver_npc": "npc_board",
		"turnin_npc": "npc_board",
		"objectives": [{"type": "kill", "target": "mob_wolf", "count": 1}],
		"rewards": {"xp": 0, "coins": 10, "items": []},
		"provided_items": [],
		"repeatable": true,
	}
	var cid := int(CharacterManager.get_character("alice")["id"])
	assert_true(main._dispatch("accept_quest", {"username": "alice", "quest": quest})["ok"])
	CharacterManager.credit_objective(cid, quest, "kill", "mob_wolf")
	var result: Dictionary = (
		main
		. _dispatch(
			"turn_in",
			{
				"username": "alice",
				"quest": quest,
				"quest_defs": {"q_weekly": quest},
				"at_turnin_npc": true,
				"item_registry": {},
				"date_key": WED,
			}
		)
	)
	assert_true(bool(result["ok"]))
	var status: Dictionary = main._dispatch("weekly_op", {"username": "alice", "date_key": WED})
	var quests_row: Dictionary = {}
	for row: Dictionary in status["tracks"]:
		if str(row["track"]) == "quests":
			quests_row = row
	assert_eq(int(quests_row["progress"]), 1, "a real turn-in dispatch ticks the weekly track")
	_fill_track("quests", WED)
	WeeklyStore.claim("alice", MON_NEXT, "xp")
	var types: Array = TelemetryStore.test_events().map(func(e): return e["event_type"])
	for expected in ["weekly_open", "weekly_progress", "weekly_claim", "weekly_reward_chosen"]:
		assert_has(types, expected, "T-186 snake_case taxonomy: %s" % expected)
	main.free()
