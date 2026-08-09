extends "res://addons/gut/test.gd"
# T-621: the quest reward model wired through CharacterManager — over-level XP decay at turn-in, the
# full-reward-in-group rule (no per-head split for quests, ever), and the quest-log accept cap.

const CharacterManager = preload("res://scripts/character_manager.gd")
const QSM = preload("res://scripts/quest_state_machine.gd")


func before_each() -> void:
	CharacterManager.reset_for_test()


func _char(name: String, level: int) -> int:
	CharacterManager.ensure_character(name)
	var cid := int(CharacterManager.get_character(name)["id"])
	CharacterManager.test_characters_ref()[name]["level"] = level
	return cid


func _quest(id: String, min_level: int, xp: int) -> Dictionary:
	return {
		"id": id,
		"min_level": min_level,
		"prerequisite_quest": "",
		"giver_npc": "npc_x",
		"turnin_npc": "npc_x",
		"objectives": [],  # no objectives -> objectives_complete trivially true
		"rewards": {"xp": xp, "items": []},
	}


func _turn_in(cid: int, quest: Dictionary) -> Dictionary:
	CharacterManager.try_accept(cid, quest, 99, true)
	return CharacterManager.try_turn_in_with_rewards(cid, quest, true, true, {})


func _active(cid: int) -> int:
	var n := 0
	for e: Dictionary in CharacterManager.get_quests(cid):
		if str(e.get("state", "")) == "active":
			n += 1
	return n


# ---- over-level decay ----


func test_turn_in_at_level_grants_full_xp() -> void:
	var cid := _char("atlevel", 10)
	var r := _turn_in(cid, _quest("q_full", 10, 250))
	assert_true(r["ok"])
	assert_eq(r["xp"], 250, "at quest level = full authored XP")


func test_turn_in_over_level_grants_decayed_xp() -> void:
	# charLevel 16 vs questLevel 10 = +6 over -> 80% of 250 = 200.
	var cid := _char("high", 16)
	var r := _turn_in(cid, _quest("q_over", 10, 250))
	assert_true(r["ok"])
	assert_eq(r["xp"], 200, "+6 over the quest decays to 80%")


func test_grey_quest_still_pays_the_floor() -> void:
	# A wildly out-levelled quest pays the 10% grey floor, never zero.
	var cid := _char("veteran", 40)
	var r := _turn_in(cid, _quest("q_grey", 1, 300))
	assert_true(r["ok"])
	assert_eq(r["xp"], 30, "grey quest = 10% floor, not zero")


# ---- full-reward-in-group (T-621 item 1): quest XP is never split per head ----


func test_two_characters_each_get_full_reward_no_group_split() -> void:
	# Turn-in is per-character; there is deliberately no party term. Two characters at the SAME level
	# turning in the same quest each get the identical full value — grouping never reduces quest XP.
	var a := _char("ally_a", 10)
	var b := _char("ally_b", 10)
	var ra := _turn_in(a, _quest("q_shared", 10, 250))
	var rb := _turn_in(b, _quest("q_shared", 10, 250))
	assert_eq(ra["xp"], 250, "member A gets full quest XP")
	assert_eq(rb["xp"], 250, "member B gets the same full quest XP — no per-head split")


# ---- quest-log cap ----


func test_log_cap_refuses_the_twenty_first_accept() -> void:
	var cid := _char("busy", 50)
	for i in range(QSM.MAX_ACTIVE_QUESTS):
		var r := CharacterManager.try_accept(cid, _quest("qcap_%d" % i, 1, 10), 99, true)
		assert_true(r.ok, "accept #%d fits under the cap" % (i + 1))
	assert_eq(_active(cid), QSM.MAX_ACTIVE_QUESTS)
	var overflow := CharacterManager.try_accept(cid, _quest("qcap_over", 1, 10), 99, true)
	assert_false(overflow.ok, "the 21st accept is refused")
	assert_eq(overflow.reason, "log_full")


func test_abandoning_frees_a_log_slot() -> void:
	var cid := _char("busy2", 50)
	for i in range(QSM.MAX_ACTIVE_QUESTS):
		CharacterManager.try_accept(cid, _quest("qc_%d" % i, 1, 10), 99, true)
	CharacterManager.try_abandon(cid, "qc_0")
	assert_eq(_active(cid), QSM.MAX_ACTIVE_QUESTS - 1)
	var r := CharacterManager.try_accept(cid, _quest("qc_new", 1, 10), 99, true)
	assert_true(r.ok, "a freed slot admits a new accept")


func test_completed_quests_do_not_occupy_a_log_slot() -> void:
	# Fill to cap, complete one (turn it in) — its slot frees for a new accept even though the row
	# still exists as 'complete'. Only ACTIVE quests count against the cap.
	var cid := _char("busy3", 50)
	for i in range(QSM.MAX_ACTIVE_QUESTS):
		CharacterManager.try_accept(cid, _quest("qd_%d" % i, 1, 10), 99, true)
	CharacterManager.try_turn_in_with_rewards(cid, _quest("qd_0", 1, 10), true, true, {})
	assert_eq(_active(cid), QSM.MAX_ACTIVE_QUESTS - 1)
	var r := CharacterManager.try_accept(cid, _quest("qd_new", 1, 10), 99, true)
	assert_true(r.ok, "a turned-in quest frees its active slot")
