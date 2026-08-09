extends "res://addons/gut/test.gd"

const CharacterManager = preload("res://scripts/character_manager.gd")
const _IL = preload("res://scripts/inventory_logic.gd")


func before_each() -> void:
	CharacterManager.reset_for_test()


func _ensure_alice() -> int:
	CharacterManager.ensure_character("alice")
	return int(CharacterManager.get_character("alice")["id"])


func test_ensure_character_creates_entry() -> void:
	assert_true(CharacterManager.ensure_character("alice"))
	var character: Dictionary = CharacterManager.get_character("alice")
	assert_eq(character["username"], "alice")
	assert_eq(character["level"], 1)
	assert_eq(character["xp"], 0)


func test_ensure_character_idempotent() -> void:
	CharacterManager.ensure_character("alice")
	CharacterManager.ensure_character("alice")
	assert_eq(CharacterManager.get_character("alice")["xp"], 0)


func test_award_xp() -> void:
	CharacterManager.ensure_character("alice")
	CharacterManager.award_xp("alice", 100)
	assert_eq(CharacterManager.get_character("alice")["xp"], 100)


func test_award_xp_accumulates() -> void:
	CharacterManager.ensure_character("alice")
	CharacterManager.award_xp("alice", 50)
	CharacterManager.award_xp("alice", 75)
	assert_eq(CharacterManager.get_character("alice")["xp"], 125)


func test_get_inventory_empty() -> void:
	var character_id := _ensure_alice()
	assert_eq(CharacterManager.get_inventory(character_id), [])


func test_add_item_to_bag() -> void:
	var character_id := _ensure_alice()
	CharacterManager.add_item_to_bag(character_id, "itm_wolf_pelt", 3, 0)
	var inventory: Array = CharacterManager.get_inventory(character_id)
	assert_eq(inventory.size(), 1)
	assert_eq(inventory[0]["item_id"], "itm_wolf_pelt")
	assert_eq(inventory[0]["item_count"], 3)


func test_add_item_to_bag_multiple_slots() -> void:
	var character_id := _ensure_alice()
	CharacterManager.add_item_to_bag(character_id, "itm_wolf_pelt", 3, 0)
	CharacterManager.add_item_to_bag(character_id, "itm_leather_cap", 1, 1)
	assert_eq(CharacterManager.get_inventory(character_id).size(), 2)


func test_remove_item() -> void:
	var character_id := _ensure_alice()
	CharacterManager.add_item_to_bag(character_id, "itm_wolf_pelt", 3, 0)
	CharacterManager.remove_item(character_id, "bag", 0)
	assert_eq(CharacterManager.get_inventory(character_id), [])


func test_accept_quest() -> void:
	var character_id := _ensure_alice()
	CharacterManager.accept_quest(character_id, "q001")
	var quests: Array = CharacterManager.get_quests(character_id)
	assert_eq(quests.size(), 1)
	assert_eq(quests[0]["quest_id"], "q001")
	assert_eq(quests[0]["state"], "active")


func test_complete_quest() -> void:
	var character_id := _ensure_alice()
	CharacterManager.accept_quest(character_id, "q001")
	CharacterManager.complete_quest(character_id, "q001")
	var quest: Dictionary = CharacterManager.get_quests(character_id)[0]
	assert_eq(quest["state"], "complete")
	assert_not_null(quest["completed_at"])


func test_abandon_quest() -> void:  # T-056: abandon REMOVES the quest (gone from the log)
	var character_id := _ensure_alice()
	CharacterManager.accept_quest(character_id, "q001")
	CharacterManager.abandon_quest(character_id, "q001")
	assert_eq(CharacterManager.get_quests(character_id).size(), 0, "abandon removes the quest")


func test_accept_quest_idempotent() -> void:
	var character_id := _ensure_alice()
	CharacterManager.accept_quest(character_id, "q001")
	CharacterManager.accept_quest(character_id, "q001")
	assert_eq(CharacterManager.get_quests(character_id).size(), 1)


# ---- T-033: guarded transitions ------------------------------------------


func _quest_def() -> Dictionary:
	return {
		"id": "q001",
		"min_level": 1,
		"prerequisite_quest": "",
		"rewards": {"xp": 100, "items": []},
	}


func test_try_accept_persists_and_guards_duplicate() -> void:
	var character_id := _ensure_alice()
	var r1 = CharacterManager.try_accept(character_id, _quest_def(), 5, true)
	assert_true(r1.ok)
	assert_eq(CharacterManager.get_quests(character_id)[0]["state"], "active")
	var r2 = CharacterManager.try_accept(character_id, _quest_def(), 5, true)
	assert_false(r2.ok)
	assert_eq(CharacterManager.get_quests(character_id).size(), 1)


func test_try_turn_in_requires_objectives_and_npc() -> void:
	var character_id := _ensure_alice()
	CharacterManager.try_accept(character_id, _quest_def(), 5, true)
	var r_inc = CharacterManager.try_turn_in(character_id, _quest_def(), false, true)
	assert_false(r_inc.ok)
	assert_eq(CharacterManager.get_quests(character_id)[0]["state"], "active")
	var r_ok = CharacterManager.try_turn_in(character_id, _quest_def(), true, true)
	assert_true(r_ok.ok)
	assert_eq(CharacterManager.get_quests(character_id)[0]["state"], "complete")
	assert_eq(r_ok.rewards["xp"], 100)


func test_try_abandon_only_active() -> void:
	var character_id := _ensure_alice()
	CharacterManager.try_accept(character_id, _quest_def(), 5, true)
	var r_ok = CharacterManager.try_abandon(character_id, "q001")
	assert_true(r_ok.ok)
	assert_eq(CharacterManager.get_quests(character_id).size(), 0, "abandon removes the quest")
	var r_no = CharacterManager.try_abandon(character_id, "q001")
	assert_false(r_no.ok, "nothing active to abandon")


func test_reaccept_after_abandon() -> void:  # T-056: abandon → re-acceptable (the reported bug)
	var character_id := _ensure_alice()
	CharacterManager.try_accept(character_id, _quest_def(), 5, true)
	CharacterManager.try_abandon(character_id, "q001")
	var r = CharacterManager.try_accept(character_id, _quest_def(), 5, true)
	assert_true(r.ok, "can re-accept after abandoning")
	assert_eq(CharacterManager.get_quests(character_id)[0]["state"], "active")


# T-293: a completed REPEATABLE bounty re-accepts, flipping the persisted row back to active and
# re-zeroing its objectives (the accept → kill → turn-in → accept-again loop).
func test_repeatable_reaccept_resets_completed_quest() -> void:
	var character_id := _ensure_alice()
	var bounty := {
		"id": "qb01",
		"min_level": 1,
		"prerequisite_quest": "",
		"repeatable": true,
		"objectives": [{"type": "kill", "target": "mob_greymaw", "count": 1}],
		"rewards": {"xp": 600, "coins": 150, "items": []},
	}
	assert_true(CharacterManager.try_accept(character_id, bounty, 5, true).ok)
	CharacterManager.credit_objective(character_id, bounty, "kill", "mob_greymaw")
	assert_true(CharacterManager.objectives_complete(character_id, bounty), "kill completes it")
	assert_true(CharacterManager.complete_quest(character_id, "qb01"))
	assert_eq(CharacterManager.get_quests(character_id)[0]["state"], "complete")
	# Re-accept: the row must return to active AND the kill progress must be zeroed again.
	var r = CharacterManager.try_accept(character_id, bounty, 5, true)
	assert_true(r.ok, "completed repeatable re-accepts")
	assert_eq(CharacterManager.get_quests(character_id).size(), 1, "no duplicate row")
	assert_eq(CharacterManager.get_quests(character_id)[0]["state"], "active", "reset to active")
	assert_false(CharacterManager.objectives_complete(character_id, bounty), "objectives re-zeroed")


func test_non_repeatable_cannot_reaccept_after_complete() -> void:
	var character_id := _ensure_alice()
	CharacterManager.try_accept(character_id, _quest_def(), 5, true)
	assert_true(CharacterManager.complete_quest(character_id, "q001"))
	var r = CharacterManager.try_accept(character_id, _quest_def(), 5, true)
	assert_false(r.ok, "a one-and-done quest stays complete")
	assert_eq(r.reason, "already_complete")


# ---- T-034: objective progress -------------------------------------------


func _quest_obj() -> Dictionary:
	return {
		"id": "q001",
		"min_level": 1,
		"prerequisite_quest": "",
		"objectives":
		[
			{"type": "kill", "target": "mob_wolf", "count": 2},
			{"type": "collect", "target": "itm_pelt", "count": 3},
		],
		"rewards": {"xp": 50, "items": []},
	}


func test_init_quest_objectives_zeros() -> void:
	var character_id := _ensure_alice()
	CharacterManager.init_quest_objectives(character_id, _quest_obj())
	assert_eq(CharacterManager.get_objective_progress(character_id, "q001"), [0, 0])


func test_credit_objective_and_objectives_complete() -> void:
	var character_id := _ensure_alice()
	CharacterManager.init_quest_objectives(character_id, _quest_obj())
	CharacterManager.credit_objective(character_id, _quest_obj(), "kill", "mob_wolf")
	CharacterManager.credit_objective(character_id, _quest_obj(), "kill", "mob_wolf")
	assert_eq(CharacterManager.get_objective_progress(character_id, "q001")[0], 2)
	assert_false(CharacterManager.objectives_complete(character_id, _quest_obj()))
	CharacterManager.refresh_collect(character_id, _quest_obj(), {"itm_pelt": 3})
	assert_true(CharacterManager.objectives_complete(character_id, _quest_obj()))


func test_refresh_collect_can_decrease() -> void:
	var character_id := _ensure_alice()
	CharacterManager.init_quest_objectives(character_id, _quest_obj())
	CharacterManager.refresh_collect(character_id, _quest_obj(), {"itm_pelt": 3})
	assert_eq(CharacterManager.get_objective_progress(character_id, "q001")[1], 3)
	CharacterManager.refresh_collect(character_id, _quest_obj(), {"itm_pelt": 1})
	assert_eq(CharacterManager.get_objective_progress(character_id, "q001")[1], 1)


func test_turn_in_gated_by_objectives_end_to_end() -> void:
	var character_id := _ensure_alice()
	CharacterManager.try_accept(character_id, _quest_obj(), 5, true)
	assert_false(CharacterManager.objectives_complete(character_id, _quest_obj()))
	var r1 = CharacterManager.try_turn_in(
		character_id,
		_quest_obj(),
		CharacterManager.objectives_complete(character_id, _quest_obj()),
		true
	)
	assert_false(r1.ok)
	CharacterManager.credit_objective(character_id, _quest_obj(), "kill", "mob_wolf")
	CharacterManager.credit_objective(character_id, _quest_obj(), "kill", "mob_wolf")
	CharacterManager.refresh_collect(character_id, _quest_obj(), {"itm_pelt": 3})
	assert_true(CharacterManager.objectives_complete(character_id, _quest_obj()))
	var r2 = CharacterManager.try_turn_in(
		character_id,
		_quest_obj(),
		CharacterManager.objectives_complete(character_id, _quest_obj()),
		true
	)
	assert_true(r2.ok)
	assert_eq(CharacterManager.get_quests(character_id)[0]["state"], "complete")


# T-426: the tutorial verbs credit through the generic credit_event path (equip + use_ability).
func _equip_quest() -> Dictionary:
	return {
		"id": "q426e",
		"min_level": 1,
		"prerequisite_quest": "",
		"objectives": [{"type": "equip", "target": "itm_leather_cap", "count": 1}],
		"rewards": {"xp": 5, "items": []},
	}


func _ability_quest() -> Dictionary:
	return {
		"id": "q426a",
		"min_level": 1,
		"prerequisite_quest": "",
		"objectives": [{"type": "use_ability", "target": "heroic_strike", "count": 1}],
		"rewards": {"xp": 5, "items": []},
	}


func test_credit_event_equip_verb_bumps_active_quest() -> void:
	var cid := _ensure_alice()
	CharacterManager.try_accept(cid, _equip_quest(), 5, true)
	var r := CharacterManager.credit_event(
		cid, "equip", "itm_leather_cap", {"q426e": _equip_quest()}
	)
	assert_eq(r["credited"], ["q426e"])
	assert_eq(CharacterManager.get_objective_progress(cid, "q426e")[0], 1)


func test_credit_event_equip_wrong_item_noop() -> void:
	var cid := _ensure_alice()
	CharacterManager.try_accept(cid, _equip_quest(), 5, true)
	var r := CharacterManager.credit_event(cid, "equip", "itm_boots", {"q426e": _equip_quest()})
	assert_eq(r["credited"], [])
	assert_eq(CharacterManager.get_objective_progress(cid, "q426e")[0], 0)


func test_credit_event_use_ability_verb_bumps_active_quest() -> void:
	var cid := _ensure_alice()
	CharacterManager.try_accept(cid, _ability_quest(), 5, true)
	var r := CharacterManager.credit_event(
		cid, "use_ability", "heroic_strike", {"q426a": _ability_quest()}
	)
	assert_eq(r["credited"], ["q426a"])
	assert_eq(CharacterManager.get_objective_progress(cid, "q426a")[0], 1)


# ---- T-035: XP + leveling ------------------------------------------------


func test_award_xp_to_character_levels_up() -> void:
	var character_id := _ensure_alice()
	var r = CharacterManager.award_xp_to_character(character_id, 100)
	assert_eq(r["level"], 2)
	assert_true(r["leveled_up"])
	var c := CharacterManager.get_character_by_id(character_id)
	assert_eq(int(c["level"]), 2)
	assert_eq(int(c["xp"]), 100)


func test_award_xp_to_character_no_premature_levelup() -> void:
	var character_id := _ensure_alice()
	CharacterManager.award_xp_to_character(character_id, 100)
	var r = CharacterManager.award_xp_to_character(character_id, 50)
	assert_eq(r["level"], 2)
	assert_false(r["leveled_up"])


func test_turn_in_reward_xp_grants_level() -> void:
	var character_id := _ensure_alice()
	var quest := {
		"id": "q001",
		"min_level": 1,
		"prerequisite_quest": "",
		"rewards": {"xp": 300, "items": []},
	}
	CharacterManager.try_accept(character_id, quest, 1, true)
	var turn = CharacterManager.try_turn_in(character_id, quest, true, true)
	assert_true(turn.ok)
	CharacterManager.award_xp_to_character(character_id, int(turn.rewards["xp"]))
	assert_eq(int(CharacterManager.get_character_by_id(character_id)["level"]), 3)


# ---- T-360: rested XP (accrue on login, boost on award, surface in combat) ----

# Timestamps are realistic unix seconds — 0 is the "online / no window" sentinel, never a logout.
const _T0 := 1_700_000_000


func test_rested_accrues_over_logout_window() -> void:
	var cid := _ensure_alice()
	# Logged out, log back in 10h later. Default 50 XP/hr -> 500, over the L1 cap (1.5*100) -> 150.
	CharacterManager.mark_rested_logout(cid, _T0)
	var pool := CharacterManager.accrue_rested_on_login(cid, _T0 + 10 * 3600)
	assert_eq(pool, 150, "L1 cap is 1.5 * the 100-XP L1 span; 500 accrual clamps to it")
	assert_eq(CharacterManager.get_rested_remaining(cid), 150)


func test_rested_no_accrual_without_logout_stamp() -> void:
	var cid := _ensure_alice()
	# No logout stamp (logout_at = 0) -> a login banks nothing (never accrues during online play).
	assert_eq(CharacterManager.accrue_rested_on_login(cid, _T0), 0)


func test_rested_boosts_award_then_drains() -> void:
	var cid := _ensure_alice()
	CharacterManager.mark_rested_logout(cid, _T0)
	CharacterManager.accrue_rested_on_login(cid, _T0 + 10 * 3600)  # pool = 150
	# T-358: rested boosts MOB-KILL XP (the default use_rested=true path). 100 within the pool
	# doubles to 200; pool drains by the boosted base (100).
	var r := CharacterManager.award_xp_to_character(cid, 100)
	assert_eq(int(r["rested_bonus"]), 100)
	assert_eq(int(r["rested_remaining"]), 50)
	assert_eq(int(CharacterManager.get_character_by_id(cid)["xp"]), 200, "base 100 + rested 100")
	# Next award drains the rest, then a third gets no bonus.
	var r2 := CharacterManager.award_xp_to_character(cid, 100)
	assert_eq(int(r2["rested_remaining"]), 0)
	var r3 := CharacterManager.award_xp_to_character(cid, 100)
	assert_eq(int(r3["rested_bonus"]), 0, "empty pool -> plain award")


# T-358: the WoW rule — rested boosts kill XP but NOT quest XP. use_rested=false grants the base
# whole, adds no bonus, and leaves the banked pool untouched for the next grind.
func test_quest_xp_ignores_rested_pool() -> void:
	var cid := _ensure_alice()
	CharacterManager.mark_rested_logout(cid, _T0)
	CharacterManager.accrue_rested_on_login(cid, _T0 + 10 * 3600)  # pool = 150
	var r := CharacterManager.award_xp_to_character(cid, 100, false)
	assert_eq(int(r["rested_bonus"]), 0, "quest XP earns no rested bonus")
	assert_eq(int(r["rested_remaining"]), 150, "the pool is untouched by quest XP")
	assert_eq(int(CharacterManager.get_character_by_id(cid)["xp"]), 100, "base 100, no doubling")


# The quest turn-in path proves the wiring end to end: a banked pool survives a reward grant.
func test_turn_in_reward_does_not_consume_rested() -> void:
	var cid := _ensure_alice()
	CharacterManager.mark_rested_logout(cid, _T0)
	CharacterManager.accrue_rested_on_login(cid, _T0 + 10 * 3600)  # pool = 150
	var quest := {
		"id": "q001",
		"min_level": 1,
		"prerequisite_quest": "",
		"rewards": {"xp": 100, "items": []},
	}
	CharacterManager.try_accept(cid, quest, 1, true)
	var turn = CharacterManager.try_turn_in_with_rewards(cid, quest, true, true, {})
	assert_true(turn.ok, "turn-in succeeds")
	assert_eq(
		int(CharacterManager.get_rested_remaining(cid)), 150, "quest turn-in leaves rest intact"
	)
	assert_eq(
		int(CharacterManager.get_character_by_id(cid)["xp"]), 100, "base reward, no rested bonus"
	)


func test_rested_login_resets_window() -> void:
	var cid := _ensure_alice()
	CharacterManager.mark_rested_logout(cid, _T0)
	CharacterManager.accrue_rested_on_login(cid, _T0 + 3600)  # pool = 50, window reset to 0
	# A second login with no new logout must not accrue again (window was reset).
	assert_eq(CharacterManager.accrue_rested_on_login(cid, _T0 + 999999), 50)


func test_rested_remaining_in_combat_payload() -> void:
	var cid := _ensure_alice()
	CharacterManager.mark_rested_logout(cid, _T0)
	CharacterManager.accrue_rested_on_login(cid, _T0 + 3600)  # 50 banked
	var combat := CharacterManager.get_character_combat("alice")
	assert_eq(int(combat.get("rested_remaining", -1)), 50, "XP-bar payload carries the rested pool")


# ---- T-036: inventory model + reward delivery ----------------------------


func _item_registry() -> Dictionary:
	return {
		"itm_wolf_pelt": {"slot": "none", "stackable": true, "max_stack": 20},
		"itm_iron_sword": {"slot": "weapon", "stackable": false, "max_stack": 1},
		"itm_leather_cap": {"slot": "head", "stackable": false, "max_stack": 1},
	}


func test_try_add_items_delivers_reward_payload() -> void:
	var character_id := _ensure_alice()
	var reward_items := [
		{"item": "itm_wolf_pelt", "count": 5}, {"item": "itm_iron_sword", "count": 1}
	]
	var r := CharacterManager.try_add_items(character_id, reward_items, _item_registry())
	assert_true(r["ok"])
	var inventory: Array = CharacterManager.get_inventory(character_id)
	assert_eq(inventory.size(), 2)


func test_turn_in_reward_items_land_in_bag_end_to_end() -> void:
	var character_id := _ensure_alice()
	var quest := {
		"id": "q001",
		"min_level": 1,
		"prerequisite_quest": "",
		"rewards": {"xp": 100, "items": [{"item": "itm_leather_cap", "count": 1}]},
	}
	CharacterManager.try_accept(character_id, quest, 1, true)
	var turn = CharacterManager.try_turn_in(character_id, quest, true, true)
	assert_true(turn.ok)
	var r := CharacterManager.try_add_items(character_id, turn.rewards["items"], _item_registry())
	assert_true(r["ok"])
	assert_eq(
		_IL.bag_item_counts(CharacterManager.get_inventory(character_id))["itm_leather_cap"], 1
	)


func test_try_equip_unequip_round_trip_persists() -> void:
	var character_id := _ensure_alice()
	CharacterManager.try_add_items(
		character_id, [{"item": "itm_iron_sword", "count": 1}], _item_registry()
	)
	# the sword landed in bag slot 0
	var eq := CharacterManager.try_equip(character_id, 0, _item_registry())
	assert_true(eq["ok"])
	var has_weapon := false
	for entry: Dictionary in CharacterManager.get_inventory(character_id):
		if entry["slot_type"] == "weapon":
			has_weapon = true
	assert_true(has_weapon)
	var un := CharacterManager.try_unequip(character_id, "weapon")
	assert_true(un["ok"])
	assert_eq(
		_IL.bag_item_counts(CharacterManager.get_inventory(character_id))["itm_iron_sword"], 1
	)


# ---- T-399: gear folds into the get_character_combat stat vector -----------


func _combat_item_stats() -> Dictionary:
	# item_id -> authored {stat: amount}, the world-injected registry the master fold reads.
	return {"itm_iron_sword": {"attack": 8}, "itm_leather_cap": {"armor": 3}}


func test_get_character_combat_folds_equipped_gear_stats() -> void:
	var cid := _ensure_alice()
	var naked: Dictionary = CharacterManager.get_character_combat("alice", {}, _combat_item_stats())
	assert_false(naked["stats"].has("attack"), "naked character has no gear attack term")
	assert_false(naked["stats"].has("armor"), "naked character has no gear armor term")
	# equip a sword (attack 8) and a cap (armor 3)
	CharacterManager.try_add_items(
		cid,
		[{"item": "itm_iron_sword", "count": 1}, {"item": "itm_leather_cap", "count": 1}],
		_item_registry()
	)
	CharacterManager.try_equip(cid, 0, _item_registry())  # sword (bag slot 0)
	CharacterManager.try_equip(cid, 1, _item_registry())  # cap (bag slot 1)
	var geared: Dictionary = CharacterManager.get_character_combat(
		"alice", {}, _combat_item_stats()
	)
	assert_eq(int(geared["stats"]["attack"]), 8, "equipped sword folds attack into the stat vector")
	assert_eq(int(geared["stats"]["armor"]), 3, "equipped cap folds armor into the stat vector")
	# the primaries are untouched by attack/armor gear (same base as naked)
	assert_eq(
		int(geared["stats"]["str"]), int(naked["stats"]["str"]), "primaries unchanged by gear"
	)


func test_get_character_combat_broken_item_contributes_exactly_nothing() -> void:
	var cid := _ensure_alice()
	CharacterManager.try_add_items(cid, [{"item": "itm_iron_sword", "count": 1}], _item_registry())
	CharacterManager.try_equip(cid, 0, _item_registry())
	# break the equipped weapon (0 durability) — its attack must drop out entirely.
	ServicesStore.set_durability(cid, "weapon", 0, 0, 100)
	var broken: Dictionary = CharacterManager.get_character_combat(
		"alice", {}, _combat_item_stats()
	)
	assert_false(broken["stats"].has("attack"), "a 0-durability weapon contributes exactly nothing")
	# repair it (durability restored) — the attack comes back.
	ServicesStore.set_durability(cid, "weapon", 0, 100, 100)
	var repaired: Dictionary = CharacterManager.get_character_combat(
		"alice", {}, _combat_item_stats()
	)
	assert_eq(int(repaired["stats"]["attack"]), 8, "restored durability re-contributes the attack")


func test_get_character_combat_no_item_stats_registry_stays_naked() -> void:
	# Master-only callers (no world item registry) get the naked baseline, never a crash.
	var cid := _ensure_alice()
	CharacterManager.try_add_items(cid, [{"item": "itm_iron_sword", "count": 1}], _item_registry())
	CharacterManager.try_equip(cid, 0, _item_registry())
	var combat: Dictionary = CharacterManager.get_character_combat("alice")  # no item_stats
	assert_false(combat["stats"].has("attack"), "empty item registry -> no gear contribution")


func test_try_add_items_bag_full_no_partial_write() -> void:
	var character_id := _ensure_alice()
	var fill: Array = []
	for i in range(_IL.BAG_SLOTS):
		fill.append({"item": "itm_iron_sword", "count": 1})
	assert_true(CharacterManager.try_add_items(character_id, fill, _item_registry())["ok"])
	var before: int = CharacterManager.get_inventory(character_id).size()
	var r := CharacterManager.try_add_items(
		character_id, [{"item": "itm_leather_cap", "count": 1}], _item_registry()
	)
	assert_false(r["ok"])
	assert_eq(r["reason"], "bag_full")
	assert_eq(CharacterManager.get_inventory(character_id).size(), before)


# ---- T-037: NPC quest givers — indicators + talk -------------------------


func _npc_geld() -> Dictionary:
	return {"id": "npc_farmer_geld", "gives_quests": ["q001"], "talk_text": "Cull the wolves."}


func _quest_kill() -> Dictionary:
	return {
		"id": "q001",
		"min_level": 1,
		"prerequisite_quest": "",
		"giver_npc": "npc_farmer_geld",
		"turnin_npc": "npc_farmer_geld",
		"objectives": [{"type": "kill", "target": "mob_wolf", "count": 1}],
		"rewards": {"xp": 100, "items": []},
	}


func test_npc_state_reflects_persisted_quest_state() -> void:
	var character_id := _ensure_alice()
	var defs := {"q001": _quest_kill()}
	# Fresh: q001 is acceptable → bang.
	assert_eq(
		CharacterManager.npc_state_for_character(character_id, _npc_geld(), defs)["indicator"], "!"
	)
	# After accepting it (active, objectives incomplete) → grey ? at the turn-in NPC (T-056).
	CharacterManager.try_accept(character_id, _quest_kill(), 1, true)
	assert_eq(
		CharacterManager.npc_state_for_character(character_id, _npc_geld(), defs)["indicator"],
		"?grey"
	)


func test_npc_talk_credits_active_talk_objective() -> void:
	var character_id := _ensure_alice()
	# Quest given by Geld whose objective is to talk to Mira.
	var quest := {
		"id": "q010",
		"min_level": 1,
		"prerequisite_quest": "",
		"giver_npc": "npc_farmer_geld",
		"turnin_npc": "npc_farmer_geld",
		"objectives": [{"type": "talk", "target": "npc_scout_mira", "count": 1}],
		"rewards": {"xp": 10, "items": []},
	}
	CharacterManager.try_accept(character_id, quest, 1, true)
	var mira := {"id": "npc_scout_mira", "gives_quests": [], "talk_text": "Northern treeline."}
	var result := CharacterManager.npc_talk(character_id, mira, {"q010": quest})
	assert_eq(result["credited"], ["q010"])
	assert_eq(CharacterManager.get_objective_progress(character_id, "q010")[0], 1)
	assert_eq(result["talk_text"], "Northern treeline.")


func test_npc_talk_recompute_flips_indicator_to_question() -> void:
	var character_id := _ensure_alice()
	# A talk-only quest given AND turned in at Mira: talking completes it → turn-in ready (?).
	var quest := {
		"id": "q011",
		"min_level": 1,
		"prerequisite_quest": "",
		"giver_npc": "npc_scout_mira",
		"turnin_npc": "npc_scout_mira",
		"objectives": [{"type": "talk", "target": "npc_scout_mira", "count": 1}],
		"rewards": {"xp": 10, "items": []},
	}
	CharacterManager.try_accept(character_id, quest, 1, true)
	var mira := {"id": "npc_scout_mira", "gives_quests": ["q011"], "talk_text": "Reported."}
	var result := CharacterManager.npc_talk(character_id, mira, {"q011": quest})
	assert_eq(result["credited"], ["q011"])
	assert_eq(result["indicator"], "?")
	assert_true(result["turn_in_ready"].has("q011"))


func test_npc_talk_no_relevant_quests_is_noop() -> void:
	var character_id := _ensure_alice()
	var idle_npc := {"id": "npc_idle", "gives_quests": [], "talk_text": "Fine weather."}
	var result := CharacterManager.npc_talk(character_id, idle_npc, {})
	assert_eq(result["indicator"], "")
	assert_eq(result["credited"], [])
	assert_eq(result["talk_text"], "Fine weather.")


# ---- T-042: kill-credit --------------------------------------------------


func _kill_quest() -> Dictionary:
	return {
		"id": "q050",
		"min_level": 1,
		"prerequisite_quest": "",
		"objectives": [{"type": "kill", "target": "mob_wolf", "count": 2}],
		"rewards": {"xp": 10, "items": []},
	}


func test_credit_kill_bumps_active_matching_quest_and_caps() -> void:
	var cid := _ensure_alice()
	CharacterManager.try_accept(cid, _kill_quest(), 5, true)
	var r := CharacterManager.credit_kill(cid, "mob_wolf", {"q050": _kill_quest()})
	assert_eq(r["credited"], ["q050"])
	assert_eq(CharacterManager.get_objective_progress(cid, "q050")[0], 1)
	# Monotonic, capped at count=2.
	CharacterManager.credit_kill(cid, "mob_wolf", {"q050": _kill_quest()})
	CharacterManager.credit_kill(cid, "mob_wolf", {"q050": _kill_quest()})
	assert_eq(CharacterManager.get_objective_progress(cid, "q050")[0], 2)


func test_credit_kill_ignores_non_active_quest() -> void:
	var cid := _ensure_alice()
	CharacterManager.try_accept(cid, _kill_quest(), 5, true)
	CharacterManager.abandon_quest(cid, "q050")
	var r := CharacterManager.credit_kill(cid, "mob_wolf", {"q050": _kill_quest()})
	assert_eq(r["credited"], [])


func test_credit_kill_no_matching_objective() -> void:
	var cid := _ensure_alice()
	CharacterManager.try_accept(cid, _kill_quest(), 5, true)
	var r := CharacterManager.credit_kill(cid, "mob_unrelated", {"q050": _kill_quest()})
	assert_eq(r["credited"], [])
	assert_eq(CharacterManager.get_objective_progress(cid, "q050")[0], 0)


# ---- T-043: turn-in + reward grant ---------------------------------------


func _reward_quest() -> Dictionary:
	return {
		"id": "q060",
		"min_level": 1,
		"prerequisite_quest": "",
		"giver_npc": "npc_x",
		"turnin_npc": "npc_x",
		"objectives": [{"type": "kill", "target": "mob_wolf", "count": 1}],
		"rewards": {"xp": 100, "items": [{"item": "itm_leather_cap", "count": 1}]},
	}


func test_turn_in_with_rewards_grants_xp_and_item() -> void:
	var cid := _ensure_alice()
	CharacterManager.try_accept(cid, _reward_quest(), 5, true)
	var r := CharacterManager.try_turn_in_with_rewards(
		cid, _reward_quest(), true, true, _item_registry()
	)
	assert_true(r["ok"])
	assert_eq(r["xp"], 100)
	assert_eq(CharacterManager.get_quests(cid)[0]["state"], "complete")
	assert_eq(int(CharacterManager.get_character_by_id(cid)["xp"]), 100)
	assert_eq(_IL.bag_item_counts(CharacterManager.get_inventory(cid))["itm_leather_cap"], 1)


func test_turn_in_with_rewards_bag_full_is_atomic_reject() -> void:
	var cid := _ensure_alice()
	CharacterManager.try_accept(cid, _reward_quest(), 5, true)
	# Fill all 16 bag slots so the reward item cannot be delivered.
	var fill: Array = []
	for i in range(_IL.BAG_SLOTS):
		fill.append({"item": "itm_iron_sword", "count": 1})
	CharacterManager.try_add_items(cid, fill, _item_registry())
	var r := CharacterManager.try_turn_in_with_rewards(
		cid, _reward_quest(), true, true, _item_registry()
	)
	assert_false(r["ok"])
	assert_eq(r["reason"], "bag_full")
	# Atomic: quest still active, no XP gained, no partial delivery.
	assert_eq(CharacterManager.get_quests(cid)[0]["state"], "active")
	assert_eq(int(CharacterManager.get_character_by_id(cid)["xp"]), 0)


# T-567 (portal report #20): a reward-item persist that ROLLS BACK must not leave the quest
# complete + XP paid but the item gone — the silent softlock that stranded q_tut_02 (equip the cap).
# The turn-in must fail-closed: quest reopened (retryable), NO xp, NO item; a retry then succeeds
# and actually leaves the reward item in the bag.
func test_turn_in_with_rewards_persist_failure_is_atomic_reject_and_retryable() -> void:
	var cid := _ensure_alice()
	CharacterManager.try_accept(cid, _reward_quest(), 5, true)
	CharacterManager._test_fail_persist = true
	var r := CharacterManager.try_turn_in_with_rewards(
		cid, _reward_quest(), true, true, _item_registry()
	)
	assert_false(r["ok"], "a rolled-back reward persist must reject the whole turn-in")
	assert_eq(r["reason"], "reward_grant_failed")
	# Fail-closed: no XP-without-item, quest active again (not stranded complete), bag has no cap.
	assert_eq(CharacterManager.get_quests(cid)[0]["state"], "active")
	assert_eq(int(CharacterManager.get_character_by_id(cid)["xp"]), 0)
	assert_false(_IL.bag_item_counts(CharacterManager.get_inventory(cid)).has("itm_leather_cap"))
	# Retry once the write recovers: the item actually lands (the coverage gap that shipped the bug).
	CharacterManager._test_fail_persist = false
	var r2 := CharacterManager.try_turn_in_with_rewards(
		cid, _reward_quest(), true, true, _item_registry()
	)
	assert_true(r2["ok"])
	assert_eq(r2["xp"], 100)
	assert_eq(CharacterManager.get_quests(cid)[0]["state"], "complete")
	assert_eq(_IL.bag_item_counts(CharacterManager.get_inventory(cid))["itm_leather_cap"], 1)


func test_turn_in_with_rewards_rejects_incomplete_objectives() -> void:
	var cid := _ensure_alice()
	CharacterManager.try_accept(cid, _reward_quest(), 5, true)
	var r := CharacterManager.try_turn_in_with_rewards(
		cid, _reward_quest(), false, true, _item_registry()
	)
	assert_false(r["ok"])
	assert_eq(CharacterManager.get_quests(cid)[0]["state"], "active")


# ---- T-045: collect-objective refresh from inventory ---------------------


func _collect_quest() -> Dictionary:
	return {
		"id": "q080",
		"min_level": 1,
		"prerequisite_quest": "",
		"objectives": [{"type": "collect", "target": "itm_wolf_pelt", "count": 5}],
		"rewards": {"xp": 10, "items": []},
	}


func test_refresh_collect_for_character_from_bag() -> void:
	var cid := _ensure_alice()
	CharacterManager.try_accept(cid, _collect_quest(), 5, true)
	CharacterManager.try_add_items(cid, [{"item": "itm_wolf_pelt", "count": 3}], _item_registry())
	var refreshed := CharacterManager.refresh_collect_for_character(cid, {"q080": _collect_quest()})
	assert_eq(refreshed, ["q080"])
	assert_eq(CharacterManager.get_objective_progress(cid, "q080")[0], 3)


func test_refresh_collect_decreases_when_bag_loses_item() -> void:
	var cid := _ensure_alice()
	CharacterManager.try_accept(cid, _collect_quest(), 5, true)
	CharacterManager.try_add_items(cid, [{"item": "itm_wolf_pelt", "count": 5}], _item_registry())
	CharacterManager.refresh_collect_for_character(cid, {"q080": _collect_quest()})
	assert_eq(CharacterManager.get_objective_progress(cid, "q080")[0], 5)
	# Drop 2 from the stack (slot 0) → re-refresh snapshots the lower count.
	CharacterManager.try_remove_item(cid, "bag", 0, 2)
	CharacterManager.refresh_collect_for_character(cid, {"q080": _collect_quest()})
	assert_eq(CharacterManager.get_objective_progress(cid, "q080")[0], 3)


func test_refresh_collect_ignores_non_collect_quest() -> void:
	var cid := _ensure_alice()
	CharacterManager.try_accept(cid, _kill_quest(), 5, true)  # kill objective, no collect
	var refreshed := CharacterManager.refresh_collect_for_character(cid, {"q050": _kill_quest()})
	assert_eq(refreshed, [])


# ---- T-046: reach credit + NPC indicators -------------------------------


func _reach_quest() -> Dictionary:
	return {
		"id": "q090",
		"min_level": 1,
		"prerequisite_quest": "",
		"objectives":
		[{"type": "reach", "target": "loc_well", "count": 1, "x": 10.0, "y": 10.0, "radius": 3.0}],
		"rewards": {"xp": 5, "items": []},
	}


func test_credit_reach_bumps_active_quest() -> void:
	var cid := _ensure_alice()
	CharacterManager.try_accept(cid, _reach_quest(), 5, true)
	var r := CharacterManager.credit_reach(cid, "loc_well", {"q090": _reach_quest()})
	assert_eq(r["credited"], ["q090"])
	assert_eq(CharacterManager.get_objective_progress(cid, "q090")[0], 1)


func test_credit_kill_still_works_after_generalize() -> void:
	var cid := _ensure_alice()
	CharacterManager.try_accept(cid, _kill_quest(), 5, true)
	var r := CharacterManager.credit_kill(cid, "mob_wolf", {"q050": _kill_quest()})
	assert_eq(r["credited"], ["q050"])


func _ind_npc() -> Dictionary:
	return {"id": "npc_g", "gives_quests": ["qi"], "talk_text": ""}


func _ind_quest() -> Dictionary:
	return {
		"id": "qi",
		"min_level": 1,
		"prerequisite_quest": "",
		"giver_npc": "npc_g",
		"turnin_npc": "npc_g",
		"objectives": [{"type": "kill", "target": "mob_w", "count": 1}],
		"rewards": {"xp": 1, "items": []},
	}


func test_npc_indicators_bang_then_question() -> void:
	var cid := _ensure_alice()
	# Acceptable quest at this NPC → "!".
	assert_eq(
		CharacterManager.npc_indicators(cid, [_ind_npc()], {"qi": _ind_quest()})["npc_g"], "!"
	)
	# Accept + complete its objectives → turn-in ready at this NPC → "?".
	CharacterManager.try_accept(cid, _ind_quest(), 1, true)
	CharacterManager.credit_objective(cid, _ind_quest(), "kill", "mob_w")
	assert_eq(
		CharacterManager.npc_indicators(cid, [_ind_npc()], {"qi": _ind_quest()})["npc_g"], "?"
	)


# T-061: combat-facing character view (class + level + per-class stat vector for the world).


func test_get_character_combat_returns_class_level_and_stats() -> void:
	CharacterManager.ensure_character("alice")
	var combat: Dictionary = CharacterManager.get_character_combat("alice")
	assert_eq(combat["class"], "warrior", "default class")
	assert_eq(int(combat["level"]), 1)
	assert_true(combat["stats"].has("stamina"), "stat vector includes stamina (HP driver)")
	assert_eq(int(combat["stats"]["str"]), 10, "L1 base str")


func test_get_character_combat_unknown_is_empty() -> void:
	assert_true(CharacterManager.get_character_combat("nobody").is_empty())


func test_get_character_combat_stats_grow_with_level() -> void:
	var cid := _ensure_alice()
	var l1: Dictionary = CharacterManager.get_character_combat("alice")["stats"]
	CharacterManager.award_xp_to_character(cid, 100000)  # vault to max level
	var capped: Dictionary = CharacterManager.get_character_combat("alice")["stats"]
	assert_gt(
		int(capped["stamina"]), int(l1["stamina"]), "leveling raises stamina -> more HP in combat"
	)


# ---- T-064: talent persistence (in-memory mode) ----


func test_spend_talent_upserts_and_reroll_clears() -> void:
	CharacterManager.ensure_character("talent_tester")
	var cid: int = int(CharacterManager.get_character("talent_tester").get("id", -1))
	# In-memory characters are L1 warriors — level them so points exist.
	CharacterManager.award_xp_to_character(cid, 1000)
	var talent := {
		"id": "tal_x",
		"class": "warrior",
		"tree": "arms",
		"tier": 1,
		"max_ranks": 2,
		"prereq": null,
		"effect": {"kind": "stat_add", "stat": "str", "per_rank": 2},
	}
	var defs := {"tal_x": talent}
	var first: Dictionary = CharacterManager.spend_talent(cid, talent, defs)
	assert_true(first["ok"], str(first))
	assert_eq(int(first["ranks"]), 1)
	var second: Dictionary = CharacterManager.spend_talent(cid, talent, defs)
	assert_eq(int(second["ranks"]), 2, "upsert increments ranks")
	assert_eq(int(CharacterManager.get_talents(cid).get("tal_x", 0)), 2)
	var third: Dictionary = CharacterManager.spend_talent(cid, talent, defs)
	assert_false(third["ok"], "max_ranks enforced through the persistence path")
	assert_true(CharacterManager.clear_talents(cid), "reroll clear succeeds")
	assert_eq(CharacterManager.get_talents(cid).size(), 0, "reroll wipes the sheet")


# ---- T-065: one-shot class selection ----


func test_set_class_once_then_locked() -> void:
	CharacterManager.ensure_character("class_tester")
	var cid: int = int(CharacterManager.get_character("class_tester").get("id", -1))
	var bad: Dictionary = CharacterManager.set_class(cid, "necromancer")
	assert_false(bad["ok"], "unknown class rejected")
	var first: Dictionary = CharacterManager.set_class(cid, "mage")
	assert_true(first["ok"], str(first))
	assert_eq(str(CharacterManager.get_character("class_tester").get("class", "")), "mage")
	var second: Dictionary = CharacterManager.set_class(cid, "warrior")
	assert_false(second["ok"], "class is locked after the first set")
	assert_eq(second["reason"], "class_locked")


# ---- T-520: one-shot gender selection (at creation, before class) ----


func test_set_gender_once_then_locked() -> void:
	CharacterManager.ensure_character("gender_tester")
	var cid: int = int(CharacterManager.get_character("gender_tester").get("id", -1))
	# A brand-new character has no gender yet (empty -> the client shows the gender panel).
	assert_eq(str(CharacterManager.get_character("gender_tester").get("gender", "x")), "")
	var bad: Dictionary = CharacterManager.set_gender(cid, "wizard")
	assert_false(bad["ok"], "unknown gender rejected")
	assert_eq(bad["reason"], "unknown_gender")
	var first: Dictionary = CharacterManager.set_gender(cid, "female")
	assert_true(first["ok"], str(first))
	assert_eq(str(first.get("gender", "")), "female")
	# Persisted + returned on the combat payload so the world/client can skip the panel next time.
	assert_eq(str(CharacterManager.get_character("gender_tester").get("gender", "")), "female")
	assert_eq(
		str(CharacterManager.get_character_combat("gender_tester").get("gender", "")), "female"
	)
	# One-shot: a second set is rejected (reroll — row deletion — is the only way out).
	var second: Dictionary = CharacterManager.set_gender(cid, "male")
	assert_false(second["ok"], "gender is locked after the first set")
	assert_eq(second["reason"], "gender_set")


func test_set_gender_unknown_character() -> void:
	var result: Dictionary = CharacterManager.set_gender(999999, "male")
	assert_false(result["ok"])
	assert_eq(result["reason"], "unknown_character")


# ---- T-060: XP-bar fields on the combat payload ----


func test_get_character_combat_includes_xp_progress() -> void:
	CharacterManager.ensure_character("xp_tester")
	var cid: int = int(CharacterManager.get_character("xp_tester").get("id", -1))
	CharacterManager.award_xp_to_character(cid, 150)  # L2 at 100 total; 50 into L2 (span 200)
	var combat: Dictionary = CharacterManager.get_character_combat("xp_tester")
	assert_eq(int(combat.get("level", 0)), 2)
	assert_eq(int(combat.get("xp_into_level", -1)), 50)
	assert_eq(int(combat.get("xp_for_next_level", -1)), 200)


# ---- T-058: provided items lifecycle (in-memory) ----


func test_provided_items_granted_and_removed_with_the_quest() -> void:
	CharacterManager.ensure_character("courier")
	var cid: int = int(CharacterManager.get_character("courier").get("id", -1))
	var quest := {
		"id": "q_deliver",
		"objectives": [],
		"provided_items": [{"item": "itm_parcel", "count": 1}],
	}
	var registry := {"itm_parcel": {"slot": "none", "stackable": false, "max_stack": 1}}
	CharacterManager.accept_quest(cid, "q_deliver")
	var grant: Dictionary = CharacterManager.grant_provided_items(cid, quest, registry)
	assert_true(bool(grant.get("ok", false)), str(grant))
	var counts: Dictionary = _IL.bag_item_counts(CharacterManager.get_inventory(cid))
	assert_eq(int(counts.get("itm_parcel", 0)), 1, "provided item in the bag after accept")
	CharacterManager.remove_provided_items(cid, quest)
	counts = _IL.bag_item_counts(CharacterManager.get_inventory(cid))
	assert_eq(int(counts.get("itm_parcel", 0)), 0, "provided item gone after abandon/turn-in")


func test_quest_entry_returns_single_row_with_progress() -> void:
	CharacterManager.ensure_character("entry_tester")
	var cid: int = int(CharacterManager.get_character("entry_tester").get("id", -1))
	var quest := {
		"id": "q_one",
		"objectives": [{"type": "kill", "target": "mob_wolf", "count": 3}],
	}
	CharacterManager.try_accept(cid, quest, 1, true)
	var entry: Dictionary = CharacterManager.quest_entry(cid, "q_one")
	assert_eq(str(entry.get("quest_id", "")), "q_one")
	assert_eq(str(entry.get("state", "")), "active")
	assert_true(entry.has("progress"))
	assert_eq(CharacterManager.quest_entry(cid, "q_missing"), {}, "unknown quest -> {}")


# ---- TD-003: turn-in claim is atomic (no double grant under interleaving) ----


func test_complete_quest_claims_exactly_once() -> void:
	CharacterManager.ensure_character("racer")
	var cid: int = int(CharacterManager.get_character("racer").get("id", -1))
	var quest := {"id": "q_race", "objectives": [], "rewards": {"xp": 50, "items": []}}
	CharacterManager.try_accept(cid, quest, 1, true)
	# Two interleaved turn-ins both pass the evaluate guard before either writes — the
	# CLAIM is the real gate: the second complete_quest must lose.
	assert_true(CharacterManager.complete_quest(cid, "q_race"), "first claim wins")
	assert_false(CharacterManager.complete_quest(cid, "q_race"), "second claim must LOSE")


func test_turn_in_rejects_when_claim_lost() -> void:
	CharacterManager.ensure_character("racer2")
	var cid: int = int(CharacterManager.get_character("racer2").get("id", -1))
	var quest := {"id": "q_race2", "objectives": [], "rewards": {"xp": 50, "items": []}}
	CharacterManager.try_accept(cid, quest, 1, true)
	CharacterManager.complete_quest(cid, "q_race2")  # a racer already claimed it
	var xp_before: int = int(CharacterManager.get_character("racer2").get("xp", 0))
	var result: Dictionary = CharacterManager.try_turn_in_with_rewards(cid, quest, true, true, {})
	assert_false(bool(result.get("ok", true)), "a completed quest must reject turn-in")
	assert_eq(
		int(CharacterManager.get_character("racer2").get("xp", 0)), xp_before, "no double XP grant"
	)


# ---- T-353: the rift gear-carry orchestration (reads inventory, re-scales, persists) ------------


func _carry_registry() -> Dictionary:
	return {
		"itm_wolf_pelt": {"slot": "none", "stackable": true, "max_stack": 20},
		"itm_epic_crown": {"slot": "head", "stackable": false, "max_stack": 1},
		"itm_legendary_edge": {"slot": "weapon", "stackable": false, "max_stack": 1},
	}


func _carry_rarities() -> Dictionary:
	return {
		"itm_wolf_pelt": "common",
		"itm_epic_crown": "epic",
		"itm_legendary_edge": "legendary",
	}


func _seed_crossing_bag(character_id: int) -> void:
	(
		CharacterManager
		. try_add_items(
			character_id,
			[
				{"item": "itm_wolf_pelt", "count": 3},
				{"item": "itm_epic_crown", "count": 1},
				{"item": "itm_legendary_edge", "count": 1},
			],
			_carry_registry()
		)
	)


func test_carry_gear_persists_the_rescale_and_retire() -> void:
	var cid := _ensure_alice()
	_seed_crossing_bag(cid)
	var summary := CharacterManager.carry_gear_across_era(cid, 2, _carry_rarities())
	assert_true("itm_epic_crown" in summary["carried"])
	assert_true("itm_legendary_edge" in summary["carried"])
	assert_true("itm_wolf_pelt" in summary["retired"])
	# Persisted marks survive a fresh read.
	for row: Dictionary in CharacterManager.get_inventory(cid):
		match str(row["item_id"]):
			"itm_epic_crown":
				assert_eq(row["era_scaled_to"], 2)
				assert_eq(row["era_index"], 660)
			"itm_legendary_edge":
				assert_eq(row["era_index"], 750)
			"itm_wolf_pelt":
				assert_true(row["retired"])
				assert_false(row.has("era_scaled_to"))


func test_carry_gear_second_crossing_does_not_double_scale() -> void:
	var cid := _ensure_alice()
	_seed_crossing_bag(cid)
	CharacterManager.carry_gear_across_era(cid, 2, _carry_rarities())  # Era 1 -> 2
	CharacterManager.carry_gear_across_era(cid, 3, _carry_rarities())  # Era 2 -> 3, one hop spent
	for row: Dictionary in CharacterManager.get_inventory(cid):
		if str(row["item_id"]) == "itm_epic_crown":
			assert_eq(row["era_scaled_to"], 2, "stamp stays at the first-carry era")
			assert_eq(row["era_index"], 660, "power is not re-scaled a second time")
			assert_true(row["retired"], "the spent relic retires at the next rift")


func test_carry_gear_leaves_an_all_sub_epic_bag_with_no_relics() -> void:
	var cid := _ensure_alice()
	CharacterManager.try_add_items(cid, [{"item": "itm_wolf_pelt", "count": 2}], _carry_registry())
	var summary := CharacterManager.carry_gear_across_era(cid, 2, _carry_rarities())
	assert_eq(summary["carried"], [])
	assert_eq(summary["retired"], ["itm_wolf_pelt"])


# ---- T-610: the starting grant is ledgered — coins column reconciles against the ledger ----


func test_ensure_character_ledgers_the_starting_grant() -> void:
	var cid := _ensure_alice()
	var coins: int = int(CharacterManager.get_character("alice").get("coins", -1))
	assert_eq(coins, 100, "test-mode character mirrors the schema-default starting balance")
	var grants: Array = CoinLedger.test_rows().filter(
		func(row: Dictionary) -> bool: return row["reason"] == CoinLedger.REASON_STARTING_GRANT
	)
	assert_eq(grants.size(), 1, "exactly one starting_grant row per character")
	assert_eq(int(grants[0]["character_id"]), cid)
	assert_eq(int(grants[0]["delta"]), coins, "ledger sum reconciles with the coins column")
	# Idempotent bootstrap must not double-grant.
	CharacterManager.ensure_character("alice")
	var after: Array = CoinLedger.test_rows().filter(
		func(row: Dictionary) -> bool: return row["reason"] == CoinLedger.REASON_STARTING_GRANT
	)
	assert_eq(after.size(), 1, "re-ensure of an existing character grants nothing")
