extends GutTest

const DailyLockout = preload("res://scripts/dungeon_daily_lockout.gd")
const Main = preload("res://scripts/main.gd")
const CharacterManager = preload("res://scripts/character_manager.gd")
const DailyAppointmentStore = preload("res://scripts/daily_appointment_store.gd")


func before_each() -> void:
	CharacterManager.reset_for_test()
	DailyLockout.reset_for_test()
	DailyAppointmentStore.reset_for_test()
	CharacterManager.ensure_character("alice")


func test_daily_gate_is_clock_injected_and_resets_next_date() -> void:
	var stamps := {"mob_crypt_aldric": "2026-07-11"}
	assert_false(DailyLockout.can_claim(stamps, "mob_crypt_aldric", "2026-07-11"))
	assert_true(DailyLockout.can_claim(stamps, "mob_crypt_aldric", "2026-07-12"))
	assert_true(DailyLockout.can_claim(stamps, "mob_crypt_vharis", "2026-07-11"))


func test_second_same_day_grant_keeps_green_but_suppresses_blue() -> void:
	var main := Main.new()
	var params := {
		"username": "alice",
		"boss_id": "mob_crypt_aldric",
		"date_key": "2026-07-11",
		"guaranteed_items": [{"item": "itm_cryptkeeper_chain", "count": 1}],
		"blue_item": "itm_aldric_oathblade",
		"item_registry":
		{
			"itm_cryptkeeper_chain": {"slot": "chest", "stackable": false, "max_stack": 1},
			"itm_aldric_oathblade": {"slot": "weapon", "stackable": false, "max_stack": 1},
		},
		"quest_defs": {},
	}
	var first: Dictionary = main._dispatch("grant_dungeon_loot", params)
	var second: Dictionary = main._dispatch("grant_dungeon_loot", params)
	assert_true(first["blue_granted"])
	assert_false(second["blue_granted"])
	assert_true(first["daily"]["bonus_granted"], "first dungeon completion gets a daily gift")
	assert_false(second["daily"]["bonus_granted"], "same-day rerun keeps loot but not the gift")
	assert_eq(int(first["coins"]), 50)
	assert_eq(int(second["coins"]), 0)
	var cid := int(CharacterManager.get_character("alice")["id"])
	var inventory := CharacterManager.get_inventory(cid)
	assert_eq(
		inventory.filter(func(row): return row["item_id"] == "itm_cryptkeeper_chain").size(), 2
	)
	assert_eq(
		inventory.filter(func(row): return row["item_id"] == "itm_aldric_oathblade").size(), 1
	)
	params["date_key"] = "2026-07-12"
	var next_day: Dictionary = main._dispatch("grant_dungeon_loot", params)
	assert_true(next_day["blue_granted"], "injected next date resets the soft lockout")
	assert_true(next_day["daily"]["bonus_granted"], "new date restores the dungeon gift")
	main.free()


# ---- T-473: weekly cadence (pure window-key math + the raid re-lock behaviour) ----


func test_window_key_daily_passes_through_and_weekly_maps_to_iso_monday() -> void:
	assert_eq(DailyLockout.window_key("daily", "2026-07-16"), "2026-07-16")
	assert_eq(DailyLockout.window_key("", "2026-07-16"), "2026-07-16", "absent cadence is daily")
	assert_eq(DailyLockout.window_key("weekly", "2026-07-16"), "2026-07-13", "Thu -> its Monday")
	assert_eq(DailyLockout.window_key("weekly", "2026-07-19"), "2026-07-13", "Sun ends the week")
	assert_eq(DailyLockout.window_key("weekly", "2026-07-20"), "2026-07-20", "Mon maps to itself")
	assert_eq(DailyLockout.window_key("weekly", "2026-01-01"), "2025-12-29", "ISO week spans NY")
	assert_eq(DailyLockout.window_key("weekly", "2024-02-29"), "2024-02-26", "leap day")
	assert_eq(DailyLockout.window_key("weekly", "not-a-date"), "", "invalid date fails closed")


func test_weekly_boss_relocks_for_the_iso_week_and_daily_is_unaffected() -> void:
	var main := Main.new()
	var params := {
		"username": "alice",
		"boss_id": "mob_vault_hollow_king",
		"cadence": "weekly",
		"date_key": "2026-07-16",
		"guaranteed_items": [],
		"blue_item": "itm_maldrath_hollow_crown",
		"item_registry":
		{
			"itm_maldrath_hollow_crown": {"slot": "head", "stackable": false, "max_stack": 1},
			"itm_aldric_oathblade": {"slot": "weapon", "stackable": false, "max_stack": 1},
		},
		"quest_defs": {},
	}
	var first: Dictionary = main._dispatch("grant_dungeon_loot", params)
	assert_true(first["blue_granted"], "first weekly kill grants the relic")
	params["date_key"] = "2026-07-18"  # Saturday, SAME ISO week
	var rerun: Dictionary = main._dispatch("grant_dungeon_loot", params)
	assert_false(rerun["blue_granted"], "a new DAY inside the week stays locked (weekly cadence)")
	# Cadence isolation: a DAILY boss claimed on the 16th is already open again on the 18th.
	var daily_params: Dictionary = params.duplicate(true)
	daily_params["boss_id"] = "mob_crypt_aldric"
	daily_params["blue_item"] = "itm_aldric_oathblade"
	daily_params["cadence"] = "daily"
	daily_params["date_key"] = "2026-07-16"
	assert_true(main._dispatch("grant_dungeon_loot", daily_params)["blue_granted"])
	daily_params["date_key"] = "2026-07-18"
	assert_true(
		main._dispatch("grant_dungeon_loot", daily_params)["blue_granted"],
		"the daily cadence is untouched by the weekly machinery"
	)
	params["date_key"] = "2026-07-20"  # Monday — the next ISO week window
	var next_week: Dictionary = main._dispatch("grant_dungeon_loot", params)
	assert_true(next_week["blue_granted"], "the weekly lockout opens on the next ISO week")
	main.free()
