extends GutTest

# T-481: pure mentor recognition rules + master-owned persistence/reward landing.

const MentorCredit = preload("res://scripts/mentor_credit.gd")
const MentorCreditStore = preload("res://scripts/mentor_credit_store.gd")
const CharacterManager = preload("res://scripts/character_manager.gd")
const AchievementRegistry = preload("res://scripts/achievement_registry.gd")
const TelemetryStore = preload("res://scripts/telemetry_store.gd")
const WardrobeOps = preload("res://scripts/wardrobe_ops.gd")
const PvpHonor = preload("res://scripts/pvp_honor.gd")
const ServicesStore = preload("res://scripts/services_store.gd")
const Main = preload("res://scripts/main.gd")

const _MENTOR_ACHIEVEMENTS := [
	{
		"id": "guiding_hand",
		"name": "A Guiding Hand",
		"criteria": {"event": "mentor_credit", "key": "*", "count": 5},
		"reward": {},
	}
]


func before_each() -> void:
	CharacterManager.reset_for_test()
	MentorCreditStore.reset_for_test()
	TelemetryStore.reset_for_test()
	PvpHonor.reset_for_test()
	AchievementRegistry._override_for_test(_MENTOR_ACHIEVEMENTS)


func _observation(overrides: Dictionary = {}) -> Dictionary:
	var observed := {
		"opted_in": true,
		"true_level": 40,
		"effective_level": 5,
		"max_level": 40,
		"content_completed": true,
		"active_participation": true,
	}
	observed.merge(overrides, true)
	return observed


func _max_character(username: String = "mentor") -> Dictionary:
	CharacterManager.ensure_character(username)
	var character := CharacterManager.get_character(username)
	character["level"] = 40
	return character


func test_credit_requires_opt_in_real_sync_cap_and_completed_content() -> void:
	var empty: Dictionary = MentorCredit.new_state()
	for denied: Dictionary in [
		_observation({"opted_in": false}),
		_observation({"effective_level": 40}),
		_observation({"true_level": 39}),
		_observation({"content_completed": false}),
		_observation({"active_participation": false}),
	]:
		var result: Dictionary = MentorCredit.accrue(empty, denied)
		assert_eq(int(result["credit_delta"]), 0)
		assert_eq(int(result["state"]["credit"]), 0, "toggle-only/unsynced/AFK grants nothing")
	var earned: Dictionary = MentorCredit.accrue(empty, _observation())
	assert_eq(int(earned["credit_delta"]), 1)
	assert_eq(int(earned["state"]["credit"]), 1)


func test_thresholds_are_title_achievement_cosmetic_only() -> void:
	var state: Dictionary = MentorCredit.new_state()
	var grants: Array = []
	for _completion in 10:
		var result: Dictionary = MentorCredit.accrue(state, _observation())
		state = result["state"]
		grants.append_array(result["grants"])
	assert_eq(
		grants.map(func(grant: Dictionary): return str(grant["kind"])),
		["title", "achievement", "cosmetic"]
	)
	assert_true(MentorCredit.rewards_are_power_neutral(grants))
	for grant: Dictionary in grants:
		for forbidden in ["coins", "xp", "item", "gear", "stats", "damage", "currency"]:
			assert_false(grant.has(forbidden), "mentor prestige cannot carry %s" % forbidden)


func test_credit_is_additive_only_with_no_streak_decay_or_penalty_state() -> void:
	var state: Dictionary = MentorCredit.new_state()
	for _completion in 3:
		state = MentorCredit.accrue(state, _observation())["state"]
	var idle: Dictionary = MentorCredit.accrue(state, _observation({"content_completed": false}))
	assert_eq(int(idle["state"]["credit"]), 3, "idle time cannot subtract earned recognition")
	for forbidden in ["streak", "decay", "missed", "penalty", "expires_at"]:
		assert_false(idle["state"].has(forbidden), "no chore/absence state: %s" % forbidden)


func test_store_persists_credit_and_grants_existing_power_neutral_seams() -> void:
	var character := _max_character()
	var cid := int(character["id"])
	var stats_before: Dictionary = (
		CharacterManager.get_character_combat("mentor")["stats"].duplicate(true)
	)
	var inventory_before: Array = CharacterManager.get_inventory(cid).duplicate(true)
	var coins_before := ServicesStore.get_coins(cid)
	var achievements: Array = []
	for index in 10:
		var result: Dictionary = MentorCreditStore.observe_completion(
			"mentor",
			{"opted_in": true, "effective_level": 5, "active_participation": true},
			"mob_%d" % index
		)
		assert_eq(int(result["credit"]), index + 1)
		achievements.append_array(result["achievements"])
	assert_eq(MentorCreditStore.state_for(cid)["credit"], 10)
	assert_true(PvpHonor.unlocks_for(cid).has("title:Mentor"))
	assert_true(WardrobeOps.unlocks_for(cid).has("mentor_sigil_blade"))
	assert_eq(achievements.map(func(row): return str(row["id"])), ["guiding_hand"])
	assert_eq(CharacterManager.get_inventory(cid), inventory_before, "prestige grants no gear")
	assert_eq(CharacterManager.get_character_combat("mentor")["stats"], stats_before)
	assert_eq(ServicesStore.get_coins(cid), coins_before, "recognition is not a coin wage")


func test_store_emits_t186_credit_and_unlock_taxonomy_once() -> void:
	_max_character("guide")
	for index in 10:
		MentorCreditStore.observe_completion(
			"guide",
			{"opted_in": true, "effective_level": 5, "active_participation": true},
			"mob_%d" % index
		)
	var events := TelemetryStore.test_events()
	assert_eq(events.filter(func(event): return event["event_type"] == "mentor_credit").size(), 10)
	assert_eq(events.filter(func(event): return event["event_type"] == "mentor_unlock").size(), 3)
	for event: Dictionary in events:
		assert_eq(str(event["account"]), "guide")
		assert_eq(str(event["character"]), "guide")


func test_credit_kill_dispatch_consumes_only_explicit_world_mentor_truth() -> void:
	_max_character("roundtrip")
	var main := Main.new()
	var without_opt_in: Dictionary = (
		main
		. _dispatch(
			"credit_kill",
			{
				"username": "roundtrip",
				"mob_id": "mob_wolf",
				"mentor_level": 5,
				"mentor_active": true,
			}
		)
	)
	assert_false(without_opt_in.has("mentor_credit"), "effective level alone cannot mint prestige")
	var observed: Dictionary = (
		main
		. _dispatch(
			"credit_kill",
			{
				"username": "roundtrip",
				"mob_id": "mob_wolf",
				"mentor_level": 5,
				"mentor_opted_in": true,
				"mentor_active": true,
			}
		)
	)
	assert_eq(int(observed["mentor_credit"]["credit"]), 1)
	assert_eq(MentorCreditStore.state_for(1)["credit"], 1)
	main.free()


func test_serialized_credit_kill_roundtrip_returns_correlated_mentor_result() -> void:
	_max_character("wire_mentor")
	var main := Main.new()
	var request := (
		JSON
		. stringify(
			{
				"id": 481,
				"method": "credit_kill",
				"params":
				{
					"username": "wire_mentor",
					"mob_id": "mob_wolf",
					"quest_defs": {},
					"mentor_level": 5,
					"mentor_opted_in": true,
					"mentor_active": true,
				},
			}
		)
	)
	var response: Dictionary = JSON.parse_string(main._handle_message(request))
	assert_eq(str(response["id"]), "481", "request id survives the production JSON choke point")
	assert_eq(int(response["result"]["mentor_credit"]["credit"]), 1)
	assert_eq(str(response["result"]["mentor_credit"]["unlocks"][0]["id"]), "title:Mentor")
	main.free()
