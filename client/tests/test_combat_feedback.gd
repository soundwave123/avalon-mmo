extends "res://addons/gut/test.gd"
# T-027: Integration tests for CombatFeedback orchestrator.
# Tests event routing, floating text, health bar updates, and combat log formatting.

var _feedback: CombatFeedback = null


func before_all() -> void:
	_feedback = CombatFeedback.new()
	add_child(_feedback)
	# Wait one frame so _ready() fires and subsystems initialize
	await get_tree().process_frame


func after_all() -> void:
	_feedback.queue_free()


# ---- Assertion 1: Damage event shows exact amount string ----------------


func test_1_damage_event_shows_amount() -> void:
	# A damage event with damage=42 must cause floating text "42" (not "0", not "amount=42")
	var pool: FloatingTextPool = _feedback.get_floating_pool()
	var initial_spawned: int = pool.get_spawned_count()

	var event := {
		"type": "ability_result",
		"ability_id": 1,
		"caster_id": 1,
		"target_id": 2,
		"damage": 42,
		"outcome": "hit",
		"caster_name": "PlayerA",
		"target_name": "Mob",
		"target_hp": 58,
		"target_max_hp": 100,
	}
	_feedback.process_event(event)

	# Verify spawn count increased by 1
	assert_eq(pool.get_spawned_count(), initial_spawned + 1)
	# Verify the floating text was spawned with "42"
	# (signal parameters: target_id, text) — captured via signal watch
	# Since we can't easily catch the exact text from pool, verify via signal
	# The pool already emits text_spawned with (entity_id, text)
	# We check indirectly: combat log should show 42 damage
	var log_lines: Array = _feedback.get_combat_log().get_lines()
	assert_true(log_lines.size() >= 1)
	var last_line: String = log_lines[log_lines.size() - 1]
	assert_true(last_line.contains("42"))
	assert_true(last_line.contains("PlayerA"))
	assert_true(last_line.contains("Mob"))


# ---- Assertion 2: Miss event shows "MISS" not "0" -----------------------


func test_2_miss_event_shows_miss_text() -> void:
	var event := {
		"type": "ability_result",
		"ability_id": 1,
		"caster_id": 1,
		"target_id": 2,
		"damage": 0,
		"outcome": "miss",
		"caster_name": "PlayerA",
		"target_name": "Mob",
		"target_hp": 58,
		"target_max_hp": 100,
	}
	_feedback.process_event(event)

	var log_lines: Array = _feedback.get_combat_log().get_lines()
	var last_line: String = log_lines[log_lines.size() - 1]
	# Log should contain the miss outcome, not "0"
	assert_true(last_line.contains("miss") or last_line.contains("MISS"))


# ---- Assertion 3: Combat log contains source, target, amount ------------


func test_3_log_contains_all_fields() -> void:
	# Feed: {caster_id: 1, target_id: 2, damage: 34, ability_id: 1}
	var event := {
		"type": "ability_result",
		"ability_id": 1,
		"caster_id": 1,
		"target_id": 2,
		"damage": 34,
		"outcome": "hit",
		"caster_name": "SourceName",
		"target_name": "TargetName",
		"target_hp": 66,
		"target_max_hp": 100,
	}
	_feedback.process_event(event)

	var log_lines: Array = _feedback.get_combat_log().get_lines()
	var last_line: String = log_lines[log_lines.size() - 1]
	assert_true(last_line.contains("SourceName"), "log should contain source name")
	assert_true(last_line.contains("TargetName"), "log should contain target name")
	assert_true(last_line.contains("34"), "log should contain damage amount")


# ---- Assertion 4: Log ordering (tick 100 before tick 101) ---------------


func test_4_log_ordering_preserved() -> void:
	# Feed two events in order; log should reflect insertion order (FIFO)
	var event_a := {
		"type": "ability_result",
		"ability_id": 1,
		"caster_id": 1,
		"target_id": 2,
		"damage": 10,
		"outcome": "hit",
		"caster_name": "First",
		"target_name": "Target",
		"target_hp": 90,
		"target_max_hp": 100,
	}
	var event_b := {
		"type": "ability_result",
		"ability_id": 1,
		"caster_id": 1,
		"target_id": 2,
		"damage": 20,
		"outcome": "hit",
		"caster_name": "Second",
		"target_name": "Target",
		"target_hp": 70,
		"target_max_hp": 100,
	}

	_feedback.process_event(event_a)
	_feedback.process_event(event_b)

	var log_lines: Array = _feedback.get_combat_log().get_lines()
	# Find lines containing "First" and "Second"
	var first_idx: int = -1
	var second_idx: int = -1
	for i in log_lines.size():
		if log_lines[i].contains("First") and first_idx == -1:
			first_idx = i
		if log_lines[i].contains("Second") and second_idx == -1:
			second_idx = i

	assert_true(first_idx >= 0, "First event log entry should exist")
	assert_true(second_idx >= 0, "Second event log entry should exist")
	assert_true(first_idx < second_idx, "First event should appear before second in log")


# ---- Assertion 5: Health bar ratio after damage -------------------------


func test_5_health_bar_ratio_after_damage() -> void:
	# Initialize health bar with event at full HP, then damage it
	var full_hp_event := {
		"type": "ability_result",
		"ability_id": 1,
		"caster_id": 1,
		"target_id": 99,
		"damage": 0,
		"outcome": "hit",
		"caster_name": "Test",
		"target_name": "TestTarget",
		"target_hp": 100,
		"target_max_hp": 100,
	}
	_feedback.process_event(full_hp_event)

	var bar: HealthBar = _feedback.get_health_bar(99)
	assert_true(bar != null, "health bar should exist for entity 99")
	assert_eq(bar.get_ratio(), 1.0, "initial ratio should be 1.0")

	# Now apply 30 damage → ratio = 70/100 = 0.7
	var damage_event := {
		"type": "ability_result",
		"ability_id": 1,
		"caster_id": 1,
		"target_id": 99,
		"damage": 30,
		"outcome": "hit",
		"caster_name": "Test",
		"target_name": "TestTarget",
		"target_hp": 70,
		"target_max_hp": 100,
	}
	_feedback.process_event(damage_event)

	# is_equal_approx only takes 2 args; check within tolerance manually
	assert_true(
		abs(bar.get_ratio() - 0.7) < 0.01, "ratio should be ~0.7 after 30 damage from 100 HP"
	)


# ---- Assertion 6: Health bar hidden on death ----------------------------


func test_6_health_bar_hidden_on_death() -> void:
	# Create health bar for entity 77
	var init_event := {
		"type": "ability_result",
		"ability_id": 1,
		"caster_id": 1,
		"target_id": 77,
		"damage": 0,
		"outcome": "hit",
		"caster_name": "Killer",
		"target_name": "Victim",
		"target_hp": 50,
		"target_max_hp": 100,
	}
	_feedback.process_event(init_event)

	var bar: HealthBar = _feedback.get_health_bar(77)
	assert_true(bar != null, "health bar should exist for entity 77")
	assert_true(bar.is_visible_in_tree() or bar.visible, "health bar should be visible")

	# Death event
	var death_event := {
		"type": "player_death",
		"peer_id": 77,
		"player_id": 77,
		"player_name": "Victim",
	}
	_feedback.process_event(death_event)

	# Note: death event uses target_id from the CombatEvent struct
	# The parser creates CombatEvent with target_id from peer_id
	assert_false(bar.visible, "health bar should be hidden on death")


# ---- Assertion 7: rejection feedback (T-402 item 3) ----------------------
# out_of_range IS surfaced (throttled, with server-computed dist/reach); every other
# rejection reason stays silent per the T-027 spec.


func test_7_out_of_range_rejection_logs_once_then_throttles() -> void:
	var log_before: int = _feedback.get_combat_log().get_count()
	var rejected_event := {
		"type": "ability_rejected",
		"ability_id": 99,
		"reason": "out_of_range",
		"detail": {"dist_m": 12.4, "range_m": 2.5},
	}
	_feedback.process_event(rejected_event)

	var lines: Array[String] = _feedback.get_combat_log().get_lines()
	assert_eq(
		_feedback.get_combat_log().get_count(), log_before + 1, "out_of_range must log one line"
	)
	var last: String = lines[lines.size() - 1]
	assert_string_contains(last, "Out of range", "line names the problem")
	assert_string_contains(last, "12.4", "line carries the server-computed distance")
	assert_string_contains(last, "2.5", "line carries the ability reach")

	# Immediate repeat (same mashed key) is throttled — no second line inside the window.
	_feedback.process_event(rejected_event)
	assert_eq(
		_feedback.get_combat_log().get_count(),
		log_before + 1,
		"repeat rejection inside the throttle window must not log again"
	)


func test_7b_other_rejection_reasons_stay_silent() -> void:
	var log_before: int = _feedback.get_combat_log().get_count()
	for reason in ["on_gcd", "insufficient_resource", "los_blocked", "not_trained"]:
		_feedback.process_event({"type": "ability_rejected", "ability_id": 99, "reason": reason})
	assert_eq(
		_feedback.get_combat_log().get_count(),
		log_before,
		"non-range rejections must not create combat log entries"
	)


# ---- Assertion 7c: floating text throttle (T-644 / T-750) -----------------
# The out_of_range log line and the floating text share ONE throttle verdict: a rejection that
# passes the throttle must produce BOTH, and an immediate repeat must produce NEITHER.
#
# The old 7c only asserted has_method() + a first call returning true, which is why T-750 shipped:
# CombatFeedback carried two byte-identical throttles that both re-armed _last_reject_log_ms, so
# once process_event() spent the budget on the log line, main.gd's follow-up call ALWAYS returned
# false and the floating text at main.gd's ability_rejected branch could never render. These tests
# drive the exact call ORDER main.gd._on_combat() uses — process_event() first, then the query —
# because that ordering is the whole bug.


func _reject_event() -> Dictionary:
	return {
		"type": "ability_rejected",
		"ability_id": 99,
		"reason": "out_of_range",
		"detail": {"dist_m": 12.4, "range_m": 2.5},
	}


func test_7c_one_rejection_yields_both_the_log_line_and_the_floating_text() -> void:
	var fb := CombatFeedback.new()
	add_child(fb)
	await get_tree().process_frame

	var log_before: int = fb.get_combat_log().get_count()
	fb.process_event(_reject_event())  # main.gd:_on_combat step 1

	assert_eq(fb.get_combat_log().get_count(), log_before + 1, "the log line renders")
	assert_true(
		fb.should_show_reject_feedback(),  # main.gd:_on_combat step 2 — gates the floating text
		"the floating text must ALSO be allowed for the same rejection the log line reported"
	)
	# The verdict is a READ, not a second consume: asking twice cannot flip it.
	assert_true(
		fb.should_show_reject_feedback(), "querying the verdict must not spend the throttle budget"
	)

	fb.queue_free()


func test_7c_immediate_repeat_suppresses_both_surfaces_together() -> void:
	var fb := CombatFeedback.new()
	add_child(fb)
	await get_tree().process_frame

	fb.process_event(_reject_event())
	var log_after_first: int = fb.get_combat_log().get_count()
	assert_true(fb.should_show_reject_feedback(), "first rejection always shows")

	fb.process_event(_reject_event())  # mashed key, well inside REJECT_LOG_THROTTLE_MS
	assert_eq(
		fb.get_combat_log().get_count(), log_after_first, "no second log line inside the window"
	)
	assert_false(
		fb.should_show_reject_feedback(),
		"the floating text must be throttled in lockstep with the log line (no text blob)"
	)

	fb.queue_free()


func test_7c_a_non_range_rejection_does_not_authorize_floating_text() -> void:
	var fb := CombatFeedback.new()
	add_child(fb)
	await get_tree().process_frame

	fb.process_event(_reject_event())
	assert_true(fb.should_show_reject_feedback(), "the out_of_range verdict stands")
	# T-402: only out_of_range surfaces. A later silent rejection must clear the stale verdict, or
	# main.gd would spawn "out of range" text for an on_gcd/insufficient_resource press.
	fb.process_event({"type": "ability_rejected", "ability_id": 99, "reason": "on_gcd"})
	assert_false(
		fb.should_show_reject_feedback(), "a silent rejection must not inherit the previous verdict"
	)

	fb.queue_free()
