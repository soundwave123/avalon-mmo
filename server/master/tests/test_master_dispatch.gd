extends "res://addons/gut/test.gd"
# T-041: master RPC dispatch arms for quest transport (get_quest_log, accept_quest).
# Instantiates main.gd and calls _dispatch directly (no _ready → no TCP/DB), with
# CharacterManager in test-mode. Exercises the real dispatch + persistence path.

const Main = preload("res://scripts/main.gd")
const CharacterManager = preload("res://scripts/character_manager.gd")
const DiscoveryStore = preload("res://scripts/discovery_store.gd")
const TelemetryStore = preload("res://scripts/telemetry_store.gd")  # T-426: tutorial funnel emits

var _main: Node


func before_each() -> void:
	CharacterManager.reset_for_test()
	DiscoveryStore.reset_for_test()
	TelemetryStore.reset_for_test()  # T-426: keep skill-acquisition emits off the DB in dispatch tests
	_main = Main.new()


func after_each() -> void:
	if _main != null:
		_main.free()
		_main = null


func _quest() -> Dictionary:
	return {
		"id": "q001",
		"min_level": 1,
		"prerequisite_quest": "",
		"giver_npc": "npc_geld",
		"turnin_npc": "npc_geld",
		"objectives": [{"type": "kill", "target": "mob_wolf", "count": 1}],
		"rewards": {"xp": 100, "items": []},
	}


func test_dispatch_accept_quest_persists_and_is_idempotent() -> void:
	CharacterManager.ensure_character("alice")
	var cid := int(CharacterManager.get_character("alice")["id"])
	var resp: Dictionary = _main._dispatch("accept_quest", {"username": "alice", "quest": _quest()})
	assert_true(resp["ok"])
	assert_eq(CharacterManager.get_quests(cid)[0]["state"], "active")
	# Re-accept is guarded by try_accept (already_active).
	var resp2: Dictionary = _main._dispatch(
		"accept_quest", {"username": "alice", "quest": _quest()}
	)
	assert_false(resp2["ok"])
	assert_eq(CharacterManager.get_quests(cid).size(), 1)


func test_dispatch_accept_quest_unknown_character() -> void:
	var resp: Dictionary = _main._dispatch("accept_quest", {"username": "ghost", "quest": _quest()})
	assert_false(resp["ok"])
	assert_eq(resp["reason"], "unknown_character")


func test_dispatch_accept_quest_respects_prerequisite() -> void:
	CharacterManager.ensure_character("alice")
	var quest := _quest()
	quest["prerequisite_quest"] = "q000"  # never completed
	var resp: Dictionary = _main._dispatch("accept_quest", {"username": "alice", "quest": quest})
	assert_false(resp["ok"])
	assert_eq(resp["reason"], "prerequisite_incomplete")


func test_dispatch_get_quest_log_returns_state_and_progress() -> void:
	CharacterManager.ensure_character("alice")
	var cid := int(CharacterManager.get_character("alice")["id"])
	CharacterManager.try_accept(cid, _quest(), 5, true)
	var resp: Dictionary = _main._dispatch("get_quest_log", {"username": "alice"})
	assert_eq(int(resp.get("level", 0)), 1, "small quest-state response carries player level")
	assert_eq(resp["quests"].size(), 1)
	assert_eq(resp["quests"][0]["quest_id"], "q001")
	assert_eq(resp["quests"][0]["state"], "active")
	assert_eq(resp["quests"][0]["progress"], [0])  # one kill objective, zeroed on accept


func test_dispatch_get_quest_log_unknown_character_empty() -> void:
	var resp: Dictionary = _main._dispatch("get_quest_log", {"username": "ghost"})
	assert_eq(resp["quests"], [])


func test_dispatch_unknown_method_unchanged() -> void:
	assert_eq(_main._dispatch("nope", {}), {"error": "unknown_method"})


func _kill_quest() -> Dictionary:
	return {
		"id": "q050",
		"min_level": 1,
		"prerequisite_quest": "",
		"objectives": [{"type": "kill", "target": "mob_wolf", "count": 2}],
		"rewards": {"xp": 10, "items": []},
	}


func test_dispatch_credit_kill_credits_and_persists() -> void:
	CharacterManager.ensure_character("alice")
	var cid := int(CharacterManager.get_character("alice")["id"])
	CharacterManager.try_accept(cid, _kill_quest(), 5, true)
	var resp: Dictionary = _main._dispatch(
		"credit_kill",
		{"username": "alice", "mob_id": "mob_wolf", "quest_defs": {"q050": _kill_quest()}}
	)
	assert_eq(resp["credited"], ["q050"])
	var log: Dictionary = _main._dispatch("get_quest_log", {"username": "alice"})
	assert_eq(log["quests"][0]["progress"][0], 1)


func test_dispatch_credit_kill_unknown_character() -> void:
	var resp: Dictionary = _main._dispatch(
		"credit_kill", {"username": "ghost", "mob_id": "mob_wolf", "quest_defs": {}}
	)
	assert_eq(resp["credited"], [])


# T-452 consumer half: only the world-internal mentor_level changes the gray comparison. A forged
# player_level field is ignored; persisted true level remains the progression authority.
func test_dispatch_credit_kill_synced_mentor_earns_without_wire_level_trust() -> void:
	CharacterManager.ensure_character("mentor")
	var character: Dictionary = CharacterManager.get_character("mentor")
	character["level"] = 40
	character["xp"] = 78000  # leveling.total_xp_for_level(40)
	var forged: Dictionary = (
		_main
		. _dispatch(
			"credit_kill",
			{
				"username": "mentor",
				"mob_id": "mob_low",
				"quest_defs": {},
				"mob_xp": 40,
				"mob_level": 5,
				"player_level": 5,
			}
		)
	)
	assert_false(forged.has("mob_xp"), "client-shaped player_level cannot defeat gray cutoff")
	var synced: Dictionary = (
		_main
		. _dispatch(
			"credit_kill",
			{
				"username": "mentor",
				"mob_id": "mob_low",
				"quest_defs": {},
				"mob_xp": 40,
				"mob_level": 5,
				"mentor_level": 5,
			}
		)
	)
	assert_eq(int(synced["mob_xp"]), 40, "synced mentor receives the ordinary authored reward")
	assert_eq(int(CharacterManager.get_character("mentor")["level"]), 40, "true level is unchanged")


# T-620: the level-weighted party split, end-to-end through real dispatch + CharacterManager (not
# the pure mob_xp.gd unit tests). An L8 and an L2 credited on the SAME kill must NOT earn an equal
# absolute share — the session-22 boost-abuse surface this ticket closes.
func test_dispatch_credit_kill_level_weighted_split_favors_the_higher_level_member() -> void:
	# xp must match the forced level (leveling.total_xp_for_level) — alice's OWN kill grant below
	# calls award_xp_to_character, which recomputes level from total xp; leaving xp at the ensure_
	# character default (0) would silently reset her back to L1 before bob's call re-reads her level.
	CharacterManager.ensure_character("alice8")
	var alice: Dictionary = CharacterManager.get_character("alice8")
	alice["level"] = 8
	alice["xp"] = 2800  # leveling.total_xp_for_level(8) = 50*7*8
	CharacterManager.ensure_character("bob2")
	var bob: Dictionary = CharacterManager.get_character("bob2")
	bob["level"] = 2
	bob["xp"] = 100  # leveling.total_xp_for_level(2) = 50*1*2
	var usernames := ["alice8", "bob2"]
	var alice_resp: Dictionary = (
		_main
		. _dispatch(
			"credit_kill",
			{
				"username": "alice8",
				"mob_id": "mob_low",
				"quest_defs": {},
				"mob_xp": 100,
				"mob_level": 4,  # gray to neither (grey_level(8)=3, grey_level(2)=0)
				"party_size": 2,
				"party_usernames": usernames,
			}
		)
	)
	var bob_resp: Dictionary = (
		_main
		. _dispatch(
			"credit_kill",
			{
				"username": "bob2",
				"mob_id": "mob_low",
				"quest_defs": {},
				"mob_xp": 100,
				"mob_level": 4,
				"party_size": 2,
				"party_usernames": usernames,
			}
		)
	)
	assert_eq(int(alice_resp["mob_xp"]), 92, "L8's share of a 10-total-level party")
	assert_eq(int(bob_resp["mob_xp"]), 23, "L2's share is much smaller, not an equal 1/N cut")
	assert_gt(int(alice_resp["mob_xp"]), int(bob_resp["mob_xp"]))


# T-426: the world forwards an accepted ability use; master credits matching use_ability objectives.
func _ability_quest() -> Dictionary:
	return {
		"id": "q426a",
		"min_level": 1,
		"prerequisite_quest": "",
		"giver_npc": "npc_x",
		"turnin_npc": "npc_x",
		"objectives": [{"type": "use_ability", "target": "heroic_strike", "count": 1}],
		"rewards": {"xp": 10, "items": []},
	}


func test_dispatch_credit_ability_credits_and_persists() -> void:
	CharacterManager.ensure_character("alice")
	var cid := int(CharacterManager.get_character("alice")["id"])
	CharacterManager.try_accept(cid, _ability_quest(), 5, true)
	var resp: Dictionary = _main._dispatch(
		"credit_ability",
		{
			"username": "alice",
			"ability_slug": "heroic_strike",
			"quest_defs": {"q426a": _ability_quest()}
		}
	)
	assert_eq(resp["credited"], ["q426a"])
	var log: Dictionary = _main._dispatch("get_quest_log", {"username": "alice"})
	assert_eq(log["quests"][0]["progress"][0], 1)


# T-426 slice 4: an interrupt objective credits through the master credit_interrupt dispatch.
func _interrupt_quest() -> Dictionary:
	return {
		"id": "q_tut_03",
		"min_level": 1,
		"prerequisite_quest": "",
		"giver_npc": "npc_drillmaster",
		"turnin_npc": "npc_drillmaster",
		"objectives": [{"type": "interrupt", "target": "mob_training_effigy", "count": 1}],
		"rewards": {"xp": 80, "coins": 40, "items": []},
	}


func test_dispatch_credit_interrupt_credits_and_persists() -> void:
	CharacterManager.ensure_character("alice")
	var cid := int(CharacterManager.get_character("alice")["id"])
	CharacterManager.try_accept(cid, _interrupt_quest(), 5, true)
	var resp: Dictionary = (
		_main
		. _dispatch(
			"credit_interrupt",
			{
				"username": "alice",
				"mob_alias": "mob_training_effigy",
				"quest_defs": {"q_tut_03": _interrupt_quest()},
			}
		)
	)
	assert_eq(resp["credited"], ["q_tut_03"])
	var log: Dictionary = _main._dispatch("get_quest_log", {"username": "alice"})
	assert_eq(log["quests"][0]["progress"][0], 1)


# T-426: equipping an item credits an active `equip` objective through the master equip dispatch.
func _equip_quest() -> Dictionary:
	return {
		"id": "q426e",
		"min_level": 1,
		"prerequisite_quest": "",
		"giver_npc": "npc_x",
		"turnin_npc": "npc_x",
		"objectives": [{"type": "equip", "target": "itm_leather_cap", "count": 1}],
		"rewards": {"xp": 10, "items": []},
	}


func test_dispatch_equip_credits_equip_objective() -> void:
	CharacterManager.ensure_character("alice")
	var cid := int(CharacterManager.get_character("alice")["id"])
	CharacterManager.add_item_to_bag(cid, "itm_leather_cap", 1, 0)
	CharacterManager.try_accept(cid, _equip_quest(), 5, true)
	var reg := {"itm_leather_cap": {"slot": "head"}}
	var resp: Dictionary = (
		_main
		. _dispatch(
			"equip",
			{
				"username": "alice",
				"bag_slot": 0,
				"item_registry": reg,
				"quest_defs": {"q426e": _equip_quest()},
			}
		)
	)
	assert_true(resp.get("ok", false), "equip succeeded")
	assert_eq(resp.get("equip_credited", []), ["q426e"], "the equip objective was credited")
	assert_eq(CharacterManager.get_objective_progress(cid, "q426e")[0], 1)


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


func _reg() -> Dictionary:
	return {"itm_leather_cap": {"slot": "head", "stackable": false, "max_stack": 1}}


func test_dispatch_turn_in_grants_when_objectives_complete() -> void:
	CharacterManager.ensure_character("alice")
	var cid := int(CharacterManager.get_character("alice")["id"])
	CharacterManager.try_accept(cid, _reward_quest(), 5, true)
	CharacterManager.credit_objective(cid, _reward_quest(), "kill", "mob_wolf")  # complete the kill
	var resp: Dictionary = _main._dispatch(
		"turn_in",
		{
			"username": "alice",
			"quest": _reward_quest(),
			"at_turnin_npc": true,
			"item_registry": _reg()
		}
	)
	assert_true(resp["ok"])
	var log: Dictionary = _main._dispatch("get_quest_log", {"username": "alice"})
	assert_eq(log["quests"][0]["state"], "complete")


func test_dispatch_turn_in_grants_coin_reward_once() -> void:
	CharacterManager.ensure_character("alice")
	var cid := int(CharacterManager.get_character("alice")["id"])
	var quest := _reward_quest()
	quest["rewards"]["coins"] = 250
	CharacterManager.try_accept(cid, quest, 5, true)
	CharacterManager.credit_objective(cid, quest, "kill", "mob_wolf")
	var resp: Dictionary = _main._dispatch(
		"turn_in",
		{"username": "alice", "quest": quest, "at_turnin_npc": true, "item_registry": _reg()}
	)
	assert_true(resp["ok"])
	assert_eq(resp["coins"], 250)
	assert_eq(ServicesStore.get_coins(cid), 350)
	var duplicate: Dictionary = _main._dispatch(
		"turn_in",
		{"username": "alice", "quest": quest, "at_turnin_npc": true, "item_registry": _reg()}
	)
	assert_false(duplicate["ok"])
	assert_eq(ServicesStore.get_coins(cid), 350, "duplicate turn-in grants no extra coins")


func test_dispatch_turn_in_rejects_incomplete_objectives() -> void:
	CharacterManager.ensure_character("alice")
	var cid := int(CharacterManager.get_character("alice")["id"])
	CharacterManager.try_accept(cid, _reward_quest(), 5, true)
	# Objectives not credited → master computes objectives_complete = false → reject.
	var resp: Dictionary = _main._dispatch(
		"turn_in",
		{
			"username": "alice",
			"quest": _reward_quest(),
			"at_turnin_npc": true,
			"item_registry": _reg()
		}
	)
	assert_false(resp["ok"])
	assert_eq(CharacterManager.get_quests(cid)[0]["state"], "active")


func test_dispatch_turn_in_unknown_character() -> void:
	var resp: Dictionary = _main._dispatch(
		"turn_in",
		{
			"username": "ghost",
			"quest": _reward_quest(),
			"at_turnin_npc": true,
			"item_registry": _reg()
		}
	)
	assert_false(resp["ok"])
	assert_eq(resp["reason"], "unknown_character")


func _talk_quest() -> Dictionary:
	return {
		"id": "q070",
		"min_level": 1,
		"prerequisite_quest": "",
		"giver_npc": "npc_geld",
		"turnin_npc": "npc_geld",
		"objectives": [{"type": "talk", "target": "npc_mira", "count": 1}],
		"rewards": {"xp": 10, "items": []},
	}


func test_dispatch_talk_credits_talk_objective() -> void:
	CharacterManager.ensure_character("alice")
	var cid := int(CharacterManager.get_character("alice")["id"])
	CharacterManager.try_accept(cid, _talk_quest(), 5, true)
	var npc := {"id": "npc_mira", "gives_quests": [], "talk_text": "north treeline"}
	var resp: Dictionary = _main._dispatch(
		"talk", {"username": "alice", "npc": npc, "quest_defs": {"q070": _talk_quest()}}
	)
	assert_eq(resp["talk_text"], "north treeline")
	assert_eq(resp["credited"], ["q070"])
	assert_eq(CharacterManager.get_objective_progress(cid, "q070")[0], 1)


func test_dispatch_abandon_quest_removes_it() -> void:  # T-056: abandon removes the quest
	CharacterManager.ensure_character("alice")
	var cid := int(CharacterManager.get_character("alice")["id"])
	CharacterManager.try_accept(cid, _talk_quest(), 5, true)
	var resp: Dictionary = _main._dispatch(
		"abandon_quest", {"username": "alice", "quest_id": "q070"}
	)
	assert_true(resp["ok"])
	assert_eq(CharacterManager.get_quests(cid).size(), 0, "abandon removes the quest from the log")
	# Abandoning a non-active quest is guarded by try_abandon.
	var resp2: Dictionary = _main._dispatch(
		"abandon_quest", {"username": "alice", "quest_id": "q070"}
	)
	assert_false(resp2["ok"])


func test_dispatch_abandon_unknown_character() -> void:
	var resp: Dictionary = _main._dispatch(
		"abandon_quest", {"username": "ghost", "quest_id": "q070"}
	)
	assert_false(resp["ok"])
	assert_eq(resp["reason"], "unknown_character")


func _inv_reg() -> Dictionary:
	return {
		"itm_wolf_pelt": {"slot": "none", "stackable": true, "max_stack": 20},
		"itm_iron_sword": {"slot": "weapon", "stackable": false, "max_stack": 1},
	}


func _seed_with_sword() -> int:
	CharacterManager.ensure_character("alice")
	var cid := int(CharacterManager.get_character("alice")["id"])
	CharacterManager.try_add_items(cid, [{"item": "itm_iron_sword", "count": 1}], _inv_reg())
	return cid


func test_dispatch_get_inventory() -> void:
	_seed_with_sword()
	var resp: Dictionary = _main._dispatch("get_inventory", {"username": "alice"})
	assert_eq(resp["slots"].size(), 1)
	assert_eq(resp["slots"][0]["item_id"], "itm_iron_sword")


func test_dispatch_get_inventory_unknown_character() -> void:
	assert_eq(_main._dispatch("get_inventory", {"username": "ghost"})["slots"], [])


func test_dispatch_equip_then_unequip() -> void:
	_seed_with_sword()
	var eq: Dictionary = _main._dispatch(
		"equip", {"username": "alice", "bag_slot": 0, "item_registry": _inv_reg(), "quest_defs": {}}
	)
	assert_true(eq["ok"])
	var has_weapon := false
	for s: Dictionary in _main._dispatch("get_inventory", {"username": "alice"})["slots"]:
		if s["slot_type"] == "weapon":
			has_weapon = true
	assert_true(has_weapon)
	var un: Dictionary = _main._dispatch(
		"unequip", {"username": "alice", "equip_slot": "weapon", "quest_defs": {}}
	)
	assert_true(un["ok"])


func test_dispatch_equip_empty_slot_fails() -> void:
	CharacterManager.ensure_character("alice")
	var resp: Dictionary = _main._dispatch(
		"equip", {"username": "alice", "bag_slot": 5, "item_registry": _inv_reg(), "quest_defs": {}}
	)
	assert_false(resp["ok"])
	assert_eq(resp["reason"], "empty_slot")


func test_dispatch_drop_decrements_stack() -> void:
	CharacterManager.ensure_character("alice")
	var cid := int(CharacterManager.get_character("alice")["id"])
	CharacterManager.try_add_items(cid, [{"item": "itm_wolf_pelt", "count": 5}], _inv_reg())
	var resp: Dictionary = _main._dispatch(
		"drop",
		{"username": "alice", "slot_type": "bag", "slot_index": 0, "count": 2, "quest_defs": {}}
	)
	assert_true(resp["ok"])
	assert_eq(_main._dispatch("get_inventory", {"username": "alice"})["slots"][0]["item_count"], 3)


func test_dispatch_credit_reach_credits_and_persists() -> void:
	CharacterManager.ensure_character("alice")
	var cid := int(CharacterManager.get_character("alice")["id"])
	var q := {
		"id": "q090",
		"min_level": 1,
		"prerequisite_quest": "",
		"objectives":
		[{"type": "reach", "target": "loc_well", "count": 1, "x": 10.0, "y": 10.0, "radius": 3.0}],
		"rewards": {"xp": 5, "items": []},
	}
	CharacterManager.try_accept(cid, q, 5, true)
	var resp: Dictionary = _main._dispatch(
		"credit_reach", {"username": "alice", "target": "loc_well", "quest_defs": {"q090": q}}
	)
	assert_eq(resp["credited"], ["q090"])
	assert_eq(
		_main._dispatch("get_quest_log", {"username": "alice"})["quests"][0]["progress"][0], 1
	)


func test_dispatch_discover_resolves_character_and_completes_achievement_once() -> void:
	CharacterManager.ensure_character("alice")
	var node := {
		"id": "hamlet_churchyard",
		"name": "The Hamlet Churchyard",
		"zone": "era_1_hamlet",
		"level": 1,
		"xp": 40,
	}
	var first: Dictionary = _main._dispatch("discover", {"username": "alice", "node": node})
	assert_true(first["discovered"])
	assert_eq(str(first["achievements"][0]["id"]), "first_footfall")
	var duplicate: Dictionary = _main._dispatch("discover", {"username": "alice", "node": node})
	assert_false(duplicate["discovered"], "the dispatch reaches the same persisted once-only gate")


func test_dispatch_npc_indicators() -> void:
	CharacterManager.ensure_character("alice")
	var npc := {"id": "npc_g", "gives_quests": ["qi"], "talk_text": ""}
	var q := {
		"id": "qi",
		"min_level": 1,
		"prerequisite_quest": "",
		"giver_npc": "npc_g",
		"turnin_npc": "npc_g",
		"objectives": [{"type": "kill", "target": "mob_w", "count": 1}],
		"rewards": {"xp": 1, "items": []},
	}
	var resp: Dictionary = _main._dispatch(
		"npc_indicators", {"username": "alice", "npcs": [npc], "quest_defs": {"qi": q}}
	)
	assert_eq(resp["indicators"]["npc_g"], "!")


func test_dispatch_npc_indicators_unknown_character() -> void:
	var resp: Dictionary = _main._dispatch(
		"npc_indicators", {"username": "ghost", "npcs": [], "quest_defs": {}}
	)
	assert_eq(resp["indicators"], {})


func test_dispatch_accept_refreshes_collect_for_held_items() -> void:
	# T-049: accepting a collect quest while already holding the items must credit immediately,
	# not stay at 0/N until some later inventory change (the gap the wire harness surfaced).
	CharacterManager.ensure_character("alice")
	var cid := int(CharacterManager.get_character("alice")["id"])
	CharacterManager.try_add_items(cid, [{"item": "itm_wolf_pelt", "count": 5}], _inv_reg())
	var q := {
		"id": "qc",
		"min_level": 1,
		"prerequisite_quest": "",
		"objectives": [{"type": "collect", "target": "itm_wolf_pelt", "count": 5}],
		"rewards": {"xp": 1, "items": []},
	}
	_main._dispatch("accept_quest", {"username": "alice", "quest": q})
	var credited := -1
	for entry: Dictionary in _main._dispatch("get_quest_log", {"username": "alice"})["quests"]:
		if str(entry["quest_id"]) == "qc":
			credited = int(entry["progress"][0])
	assert_eq(credited, 5, "collect credited on accept for already-held items")


# T-650: session-23 live-verify proved T-601 "DONE" incomplete — gather_op minted the exact quest
# item but never routed through refresh_collect_for_character the way equip/unequip/drop do, so
# the tracker stayed at 0/N despite the bag holding the target. Mirrors
# test_dispatch_equip_credits_equip_objective's shape, one level down (gather_op instead of equip).
func test_dispatch_gather_credits_collect_objective() -> void:
	CharacterManager.ensure_character("alice")
	var cid := int(CharacterManager.get_character("alice")["id"])
	var q := {
		"id": "qg",
		"min_level": 1,
		"prerequisite_quest": "",
		"objectives": [{"type": "collect", "target": "itm_wolf_pelt", "count": 3}],
		"rewards": {"xp": 1, "items": []},
	}
	CharacterManager.try_accept(cid, q, 1, true)
	assert_eq(CharacterManager.get_objective_progress(cid, "qg")[0], 0, "0/3 before gathering")
	var resp: Dictionary = (
		_main
		. _dispatch(
			"gather_op",
			{
				"username": "alice",
				"item_id": "itm_wolf_pelt",
				"count": 3,
				"item_registry": _inv_reg(),
				"quest_defs": {"qg": q},
			}
		)
	)
	assert_true(resp.get("ok", false), "gather succeeded")
	assert_eq(resp.get("collect_refreshed", []), ["qg"], "collect refresh ran on gather")
	assert_eq(
		CharacterManager.get_objective_progress(cid, "qg")[0], 3, "3/3 credited by the gather"
	)


# T-650 sweep: craft_op shares the gather_op gap's family (a CraftOps path that mints/changes
# inventory without the shared collect-refresh hook) — audited and fixed alongside gather so the
# same live-verify class of bug can't ship again for crafted quest targets.
func test_dispatch_craft_credits_collect_objective() -> void:
	CharacterManager.ensure_character("bob")
	var cid := int(CharacterManager.get_character("bob")["id"])
	var reg := _inv_reg()
	ServicesStore.grant_recipe(cid, "rec_test_sword")
	CharacterManager.try_add_items(cid, [{"item": "itm_wolf_pelt", "count": 2}], reg)
	var recipe := {
		"id": "rec_test_sword",
		"profession": "test",
		"trainer_id": "npc_x",
		"coin_cost": 0,
		"inputs": [{"item": "itm_wolf_pelt", "count": 2}],
		"output": {"item": "itm_iron_sword", "count": 1},
	}
	var q := {
		"id": "qcraft",
		"min_level": 1,
		"prerequisite_quest": "",
		"objectives": [{"type": "collect", "target": "itm_iron_sword", "count": 1}],
		"rewards": {"xp": 1, "items": []},
	}
	CharacterManager.try_accept(cid, q, 1, true)
	var resp: Dictionary = _main._dispatch(
		"craft_op",
		{"username": "bob", "recipe": recipe, "item_registry": reg, "quest_defs": {"qcraft": q}}
	)
	assert_true(resp.get("ok", false), "craft succeeded")
	assert_eq(resp.get("collect_refreshed", []), ["qcraft"], "collect refresh ran on craft")
	assert_eq(
		CharacterManager.get_objective_progress(cid, "qcraft")[0], 1, "1/1 credited by the craft"
	)
