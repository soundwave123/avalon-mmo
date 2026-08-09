extends "res://addons/gut/test.gd"
# T-661 (#51): quest turn-in consumes COLLECT objective items. New file (not added to
# test_character_manager.gd) — that file already sits over the 1000-line cap before this ticket
# (a pre-existing debt, tracked separately); this keeps the new coverage from growing it further.

const CharacterManager = preload("res://scripts/character_manager.gd")
const _IL = preload("res://scripts/inventory_logic.gd")


func before_each() -> void:
	CharacterManager.reset_for_test()


func _ensure_alice() -> int:
	CharacterManager.ensure_character("alice")
	return int(CharacterManager.get_character("alice")["id"])


func _item_registry() -> Dictionary:
	return {
		"itm_wolf_pelt": {"slot": "none", "stackable": true, "max_stack": 20},
		"itm_iron_sword": {"slot": "weapon", "stackable": false, "max_stack": 1},
		"itm_leather_cap": {"slot": "head", "stackable": false, "max_stack": 1},
	}


func _collect_reward_quest() -> Dictionary:
	return {
		"id": "q065",
		"min_level": 1,
		"prerequisite_quest": "",
		"giver_npc": "npc_x",
		"turnin_npc": "npc_x",
		"objectives": [{"type": "collect", "target": "itm_wolf_pelt", "count": 3}],
		"rewards": {"xp": 10, "items": [{"item": "itm_leather_cap", "count": 1}]},
	}


func test_turn_in_with_rewards_consumes_collected_items() -> void:
	var cid := _ensure_alice()
	CharacterManager.try_accept(cid, _collect_reward_quest(), 5, true)
	CharacterManager.try_add_items(cid, [{"item": "itm_wolf_pelt", "count": 5}], _item_registry())
	var r := CharacterManager.try_turn_in_with_rewards(
		cid, _collect_reward_quest(), true, true, _item_registry()
	)
	assert_true(r["ok"])
	assert_eq(
		_IL.bag_item_counts(CharacterManager.get_inventory(cid)).get("itm_wolf_pelt", 0),
		2,
		"only the objective's own count (3 of 5) is consumed"
	)
	assert_eq(_IL.bag_item_counts(CharacterManager.get_inventory(cid))["itm_leather_cap"], 1)


func test_turn_in_with_rewards_no_consume_flag_keeps_the_items() -> void:
	var cid := _ensure_alice()
	var quest := _collect_reward_quest()
	quest["no_consume_items"] = true
	CharacterManager.try_accept(cid, quest, 5, true)
	CharacterManager.try_add_items(cid, [{"item": "itm_wolf_pelt", "count": 3}], _item_registry())
	var r := CharacterManager.try_turn_in_with_rewards(cid, quest, true, true, _item_registry())
	assert_true(r["ok"])
	assert_eq(
		_IL.bag_item_counts(CharacterManager.get_inventory(cid)).get("itm_wolf_pelt", 0),
		3,
		"no_consume_items opts the quest out of the default consume"
	)


func test_turn_in_with_rewards_consume_frees_room_for_the_reward() -> void:
	var cid := _ensure_alice()
	CharacterManager.try_accept(cid, _collect_reward_quest(), 5, true)
	# Fill every OTHER bag slot, leaving only the collect stack itself holding the last one.
	var fill: Array = []
	for i in range(_IL.BAG_SLOTS - 1):
		fill.append({"item": "itm_iron_sword", "count": 1})
	CharacterManager.try_add_items(cid, fill, _item_registry())
	CharacterManager.try_add_items(cid, [{"item": "itm_wolf_pelt", "count": 3}], _item_registry())
	# Bag is now full (15 sword slots + 1 pelt stack = 16/16); the reward needs a free slot that
	# only exists once the collect stack is consumed — proves consume runs BEFORE the fit check.
	var r := CharacterManager.try_turn_in_with_rewards(
		cid, _collect_reward_quest(), true, true, _item_registry()
	)
	assert_true(r["ok"], "consuming the collected stack must free room for the reward")
	assert_eq(_IL.bag_item_counts(CharacterManager.get_inventory(cid))["itm_leather_cap"], 1)


func test_turn_in_with_rewards_consume_is_atomic_with_reward_on_persist_failure() -> void:
	var cid := _ensure_alice()
	CharacterManager.try_accept(cid, _collect_reward_quest(), 5, true)
	CharacterManager.try_add_items(cid, [{"item": "itm_wolf_pelt", "count": 3}], _item_registry())
	CharacterManager._test_fail_persist = true
	var r := CharacterManager.try_turn_in_with_rewards(
		cid, _collect_reward_quest(), true, true, _item_registry()
	)
	assert_false(r["ok"])
	CharacterManager._test_fail_persist = false
	# Fail-closed: the collected item is STILL in the bag (consume rolled back with the reward).
	assert_eq(
		_IL.bag_item_counts(CharacterManager.get_inventory(cid)).get("itm_wolf_pelt", 0),
		3,
		"a rolled-back reward persist must not have consumed the collected items either"
	)
	# Retry succeeds and consumes + grants together.
	var r2 := CharacterManager.try_turn_in_with_rewards(
		cid, _collect_reward_quest(), true, true, _item_registry()
	)
	assert_true(r2["ok"])
	assert_eq(_IL.bag_item_counts(CharacterManager.get_inventory(cid)).get("itm_wolf_pelt", 0), 0)
