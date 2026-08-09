extends GutTest

const Daily = preload("res://scripts/daily_appointment.gd")
const DailyStore = preload("res://scripts/daily_appointment_store.gd")
const CharacterManager = preload("res://scripts/character_manager.gd")
const ServicesStore = preload("res://scripts/services_store.gd")
const TelemetryStore = preload("res://scripts/telemetry_store.gd")
const Main = preload("res://scripts/main.gd")


func before_each() -> void:
	CharacterManager.reset_for_test()
	DailyStore.reset_for_test()
	TelemetryStore.reset_for_test()
	CharacterManager.ensure_character("alice")


func _quest(quest_id: String, min_level: int = 1) -> Dictionary:
	return {
		"id": quest_id,
		"title": "Daily %s" % quest_id,
		"min_level": min_level,
		"prerequisite_quest": "",
		"giver_npc": "npc_board",
		"turnin_npc": "npc_board",
		"objectives": [{"type": "kill", "target": "mob_wolf", "count": 1}],
		"rewards": {"xp": 0, "coins": 100, "items": []},
		"provided_items": [],
		"repeatable": true,
		"bounty": true,
	}


func _defs(count: int = 4) -> Dictionary:
	var out: Dictionary = {}
	for i in range(count):
		var quest_id := "qb%02d" % i
		out[quest_id] = _quest(quest_id)
	return out


func test_new_date_rotates_available_objectives_and_resets_first_bonus() -> void:
	var defs := _defs()
	var first := DailyStore.status("alice", "2026-07-15", defs)
	assert_eq((first["objectives"] as Array).size(), 2, "small daily set selected")
	assert_true(first["first_bonus_available"], "new date exposes the additive bonus")
	var selected_id := str(first["objectives"][0]["quest_id"])
	var cid := int(CharacterManager.get_character("alice")["id"])
	var claim := DailyStore.complete_quest(cid, "alice", "2026-07-15", defs[selected_id], defs)
	assert_true(claim["bonus_granted"])
	assert_true(claim["objective_claimed"])
	var same_day := DailyStore.status("alice", "2026-07-15", defs)
	assert_false(same_day["first_bonus_available"])
	var next_day := DailyStore.status("alice", "2026-07-16", defs)
	assert_true(next_day["first_bonus_available"], "new date makes the gift available again")
	assert_ne(first["objectives"], next_day["objectives"], "the deterministic set rotates")


func test_repeatable_turn_in_keeps_normal_reward_after_daily_bonus_is_spent() -> void:
	var main := Main.new()
	var quest := _quest("qb01")
	var cid := int(CharacterManager.get_character("alice")["id"])
	for run in range(2):
		assert_true(main._dispatch("accept_quest", {"username": "alice", "quest": quest})["ok"])
		CharacterManager.credit_objective(cid, quest, "kill", "mob_wolf")
		var result: Dictionary = (
			main
			. _dispatch(
				"turn_in",
				{
					"username": "alice",
					"quest": quest,
					"quest_defs": {"qb01": quest},
					"at_turnin_npc": true,
					"item_registry": {},
					"date_key": "2026-07-15",
				}
			)
		)
		assert_true(result["ok"])
		if run == 0:
			assert_true(result["daily"]["bonus_granted"], "first completion gets the gift")
			assert_gt(int(result["coins"]), 100, "first reward is base plus daily bonus")
		else:
			assert_false(result["daily"]["bonus_granted"], "bonus is once per day")
			assert_eq(int(result["coins"]), 100, "repeat still pays the full normal reward")
	main.free()


func test_streak_is_endowed_and_missed_day_decays_without_reset_or_power_loss() -> void:
	var first := DailyStore.login("alice", "2026-07-13")
	var second := DailyStore.login("alice", "2026-07-14")
	var third := DailyStore.login("alice", "2026-07-15")
	var before_miss := ServicesStore.get_coins(1)
	var after_miss := DailyStore.login("alice", "2026-07-17")
	assert_eq(int(first["streak"]), 1, "day one starts endowed, never at zero")
	assert_eq(int(second["streak"]), 2)
	assert_eq(int(third["streak"]), 3)
	assert_eq(int(after_miss["streak"]), 2, "one missed day decays one step instead of resetting")
	assert_gt(
		ServicesStore.get_coins(1), before_miss, "a lapse never removes banked power/currency"
	)


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


# T-549: three characters on ONE account share ONE daily gift per day — not 3x the T-475 faucet.
func test_daily_gift_is_account_scoped_across_alts() -> void:
	var cid_a := int(CharacterManager.get_character("alice")["id"])
	var cid_b := _add_alt("alice", "alice_alt2", 1)
	var cid_c := _add_alt("alice", "alice_alt3", 2)
	var coins_b_before := ServicesStore.get_coins(cid_b)
	var coins_c_before := ServicesStore.get_coins(cid_c)
	var coins_a_before := ServicesStore.get_coins(cid_a)

	var first := DailyStore.login("alice", "2026-07-15")
	assert_true(bool(first["claimed"]), "the first character to log in spends the account's gift")
	assert_gt(
		ServicesStore.get_coins(cid_a), coins_a_before, "the claiming character gets the coin"
	)

	var second := DailyStore.login("alice_alt2", "2026-07-15")
	var third := DailyStore.login("alice_alt3", "2026-07-15")
	assert_false(
		bool(second["claimed"]), "a second alt the same day mints no gift (account capped)"
	)
	assert_false(bool(third["claimed"]), "a third alt the same day mints no gift (account capped)")
	assert_eq(ServicesStore.get_coins(cid_b), coins_b_before, "no coin minted to the second alt")
	assert_eq(ServicesStore.get_coins(cid_c), coins_c_before, "no coin minted to the third alt")


# T-549: the streak is one continuous per-ACCOUNT chain; any character advances it.
func test_streak_continuity_is_preserved_at_account_level() -> void:
	_add_alt("alice", "alice_alt2", 1)
	var day1 := DailyStore.login("alice", "2026-07-13")
	assert_eq(int(day1["streak"]), 1, "day one endows the account streak")
	# The next day a DIFFERENT character logs in and advances the SAME account streak.
	var day2 := DailyStore.login("alice_alt2", "2026-07-14")
	assert_true(bool(day2["claimed"]), "next day the alt claims the account's fresh gift")
	assert_eq(int(day2["streak"]), 2, "the streak continues at account level across characters")
	# Original character on day 3 keeps the SAME chain going.
	var day3 := DailyStore.login("alice", "2026-07-15")
	assert_eq(int(day3["streak"]), 3, "the account streak is one chain, not per-character")


# T-549: characters on DIFFERENT accounts each earn their own daily gift.
func test_different_accounts_each_get_their_own_daily_gift() -> void:
	CharacterManager.ensure_character("bob")
	var cid_alice := int(CharacterManager.get_character("alice")["id"])
	var cid_bob := int(CharacterManager.get_character("bob")["id"])
	var a_before := ServicesStore.get_coins(cid_alice)
	var b_before := ServicesStore.get_coins(cid_bob)
	assert_true(bool(DailyStore.login("alice", "2026-07-15")["claimed"]))
	assert_true(
		bool(DailyStore.login("bob", "2026-07-15")["claimed"]),
		"a separate account claims its own daily gift"
	)
	assert_gt(ServicesStore.get_coins(cid_alice), a_before)
	assert_gt(ServicesStore.get_coins(cid_bob), b_before)


func test_daily_rewards_are_power_neutral_and_emit_t186_taxonomy() -> void:
	var login := DailyStore.login("alice", "2026-07-15")
	var allowed := ["xp", "coins", "cosmetic_currency"]
	for key in login["reward"]:
		assert_has(allowed, str(key), "daily reward cannot contain gear or combat stats")
	assert_true(Daily.reward_is_power_neutral(login["reward"]))
	var defs := _defs(1)
	DailyStore.complete_quest(1, "alice", "2026-07-15", defs["qb00"], defs)
	var types: Array = TelemetryStore.test_events().map(func(e): return e["event_type"])
	assert_has(types, "daily_streak", "streak event uses the T-186 snake_case taxonomy")
	assert_has(types, "daily_claim", "claim event uses the T-186 snake_case taxonomy")
	for event in TelemetryStore.test_events():
		if event["event_type"] in ["daily_streak", "daily_claim"]:
			assert_eq(event["character"], "alice")
			assert_eq(event["payload"]["date_key"], "2026-07-15")
