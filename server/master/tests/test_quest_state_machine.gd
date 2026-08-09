extends "res://addons/gut/test.gd"
# T-033: Pure quest lifecycle state machine — accept / turn_in / abandon guards.

const QSM = preload("res://scripts/quest_state_machine.gd")


func _quest(overrides: Dictionary = {}) -> Dictionary:
	var q := {
		"id": "q001",
		"min_level": 1,
		"prerequisite_quest": "",
		"rewards": {"xp": 100, "items": [{"item": "itm_leather_cap", "count": 1}]},
	}
	q.merge(overrides, true)
	return q


# ---- accept --------------------------------------------------------------


func test_accept_fresh_quest_ok() -> void:
	var r = QSM.evaluate_accept(_quest(), "", 1, true)
	assert_true(r.ok)
	assert_eq(r.new_state, "active")


func test_accept_rejected_below_min_level() -> void:
	var r = QSM.evaluate_accept(_quest({"min_level": 5}), "", 3, true)
	assert_false(r.ok)
	assert_true(r.reason.contains("level"))


func test_accept_rejected_prereq_incomplete() -> void:
	var r = QSM.evaluate_accept(_quest({"prerequisite_quest": "q000"}), "", 10, false)
	assert_false(r.ok)
	assert_true(r.reason.contains("prereq"))


func test_accept_allowed_prereq_complete() -> void:
	var r = QSM.evaluate_accept(_quest({"prerequisite_quest": "q000"}), "", 10, true)
	assert_true(r.ok)


func test_accept_rejected_when_already_active() -> void:
	var r = QSM.evaluate_accept(_quest(), "active", 10, true)
	assert_false(r.ok)


func test_accept_rejected_when_already_complete() -> void:
	var r = QSM.evaluate_accept(_quest(), "complete", 10, true)
	assert_false(r.ok)


func test_accept_allowed_again_from_abandoned() -> void:
	var r = QSM.evaluate_accept(_quest(), "abandoned", 10, true)
	assert_true(r.ok)
	assert_eq(r.new_state, "active")


# T-293: a repeatable bounty can be re-accepted after completion; a non-repeatable one still can't.
func test_accept_repeatable_allowed_from_complete() -> void:
	var r = QSM.evaluate_accept(_quest({"repeatable": true}), "complete", 10, true)
	assert_true(r.ok, "a completed repeatable quest re-accepts")
	assert_eq(r.new_state, "active")


func test_accept_repeatable_still_blocked_while_active() -> void:
	var r = QSM.evaluate_accept(_quest({"repeatable": true}), "active", 10, true)
	assert_false(r.ok, "can't re-accept a repeatable that's still active")
	assert_eq(r.reason, "already_active")


func test_accept_repeatable_still_gated_by_level() -> void:
	var r = QSM.evaluate_accept(_quest({"repeatable": true, "min_level": 5}), "complete", 3, true)
	assert_false(r.ok, "re-accept still honors min_level")
	assert_true(r.reason.contains("level"))


# ---- turn_in -------------------------------------------------------------


func test_turn_in_rejected_objectives_incomplete() -> void:
	var r = QSM.evaluate_turn_in(_quest(), "active", false, true)
	assert_false(r.ok)
	assert_true(r.reason.contains("objective"))


func test_turn_in_rejected_not_at_npc() -> void:
	var r = QSM.evaluate_turn_in(_quest(), "active", true, false)
	assert_false(r.ok)
	assert_true(r.reason.contains("npc"))


func test_turn_in_rejected_when_not_active() -> void:
	var r = QSM.evaluate_turn_in(_quest(), "complete", true, true)
	assert_false(r.ok)


func test_turn_in_ok_returns_complete_and_rewards() -> void:
	var q := _quest()
	var r = QSM.evaluate_turn_in(q, "active", true, true)
	assert_true(r.ok)
	assert_eq(r.new_state, "complete")
	assert_eq(r.rewards, q["rewards"])


# ---- abandon -------------------------------------------------------------


func test_abandon_ok_from_active() -> void:
	var r = QSM.evaluate_abandon("active")
	assert_true(r.ok)
	assert_eq(r.new_state, "abandoned")


func test_abandon_rejected_from_complete() -> void:
	var r = QSM.evaluate_abandon("complete")
	assert_false(r.ok)


# ---- determinism ---------------------------------------------------------


func test_deterministic() -> void:
	var a = QSM.evaluate_accept(_quest(), "", 1, true)
	var b = QSM.evaluate_accept(_quest(), "", 1, true)
	assert_eq(a.ok, b.ok)
	assert_eq(a.new_state, b.new_state)
	assert_eq(a.reason, b.reason)


# T-621: quest-log cap predicate — the accept gate refuses once the ACTIVE count hits the cap.
func test_would_exceed_log_cap_boundary() -> void:
	assert_false(QSM.would_exceed_log_cap(QSM.MAX_ACTIVE_QUESTS - 1), "room for one more")
	assert_true(
		QSM.would_exceed_log_cap(QSM.MAX_ACTIVE_QUESTS), "at the cap, the next accept is refused"
	)
	assert_true(QSM.would_exceed_log_cap(QSM.MAX_ACTIVE_QUESTS + 1), "over the cap stays refused")
