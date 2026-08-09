extends "res://addons/gut/test.gd"
# T-027 §5/§6: CombatFeedback integration for cast bar, screen flash, and [tick=NNN] log.
# Fresh feedback per test — these subsystems are stateful (a flash/cast persists across
# synchronous calls), so a shared instance would leak state between tests.

var _feedback: CombatFeedback = null


func before_each() -> void:
	_feedback = CombatFeedback.new()
	add_child(_feedback)
	await get_tree().process_frame


func after_each() -> void:
	_feedback.queue_free()


func _ability_result(
	caster_id: int, target_id: int, damage: int, extra: Dictionary = {}
) -> Dictionary:
	var ev := {
		"type": "ability_result",
		"ability_id": 1,
		"caster_id": caster_id,
		"target_id": target_id,
		"damage": damage,
		"outcome": "hit",
		"caster_name": "Src",
		"target_name": "Tgt",
		"target_hp": 100 - damage,
		"target_max_hp": 100,
	}
	ev.merge(extra, true)
	return ev


# ---- Cast bar -----------------------------------------------------------


func test_cast_started_shows_cast_bar() -> void:
	_feedback.process_event({"type": "cast_started", "ability_id": 5, "cast_ticks": 40})
	assert_true(_feedback.get_cast_bar().is_casting())
	assert_eq(_feedback.get_cast_bar().get_ability_id(), 5)


func test_cast_cancelled_hides_cast_bar() -> void:
	_feedback.process_event({"type": "cast_started", "ability_id": 5, "cast_ticks": 40})
	_feedback.process_event({"type": "cast_cancelled", "reason": "target_lost"})
	assert_false(_feedback.get_cast_bar().is_casting())


func test_local_ability_result_clears_cast_bar() -> void:
	_feedback.set_local_player(1)
	_feedback.process_event({"type": "cast_started", "ability_id": 5, "cast_ticks": 40})
	_feedback.process_event(_ability_result(1, 2, 10))
	assert_false(_feedback.get_cast_bar().is_casting())


func test_other_players_ability_result_does_not_clear_cast_bar() -> void:
	_feedback.set_local_player(1)
	_feedback.process_event({"type": "cast_started", "ability_id": 5, "cast_ticks": 40})
	# A different caster's result must not cancel our cast bar.
	_feedback.process_event(_ability_result(99, 2, 10))
	assert_true(_feedback.get_cast_bar().is_casting())


# ---- Screen flash -------------------------------------------------------


func test_flash_on_damage_to_local_player() -> void:
	_feedback.set_local_player(42)
	_feedback.process_event(_ability_result(9, 42, 15))
	assert_true(_feedback.get_screen_flash().is_flashing())


func test_no_flash_on_damage_to_other_entity() -> void:
	_feedback.set_local_player(42)
	_feedback.process_event(_ability_result(42, 7, 15))
	assert_false(_feedback.get_screen_flash().is_flashing())


func test_no_flash_when_local_player_unset() -> void:
	_feedback.process_event(_ability_result(9, 2, 15))
	assert_false(_feedback.get_screen_flash().is_flashing())


func test_no_flash_on_zero_damage_to_local_player() -> void:
	_feedback.set_local_player(42)
	_feedback.process_event(_ability_result(9, 42, 0, {"outcome": "miss"}))
	assert_false(_feedback.get_screen_flash().is_flashing())


# ---- Tick prefix + log panel --------------------------------------------


func test_tick_prefix_in_log_line() -> void:
	# T-308: the raw [tick=NNN] id is now a DEBUG-only prefix (AVALON_DEBUG_TICKS / show_tick),
	# hidden in the normal feed. With the flag on it still appears for ordering diagnostics.
	_feedback.show_tick = true
	_feedback.process_event(_ability_result(1, 2, 5, {"tick": 777}))
	var lines: Array = _feedback.get_combat_log().get_lines()
	assert_true(lines[lines.size() - 1].contains("[tick=777]"))


func test_no_tick_prefix_when_absent() -> void:
	_feedback.process_event(_ability_result(1, 2, 5))
	var lines: Array = _feedback.get_combat_log().get_lines()
	assert_false(lines[lines.size() - 1].contains("[tick="))


func test_processed_events_reach_the_combat_log() -> void:
	# T-607: CombatFeedback no longer owns a visual CombatLogPanel (retired — see
	# combat_log_panel.gd header); it only has to get events into the CombatLog data model. The
	# live client renders those entries by binding ChatPanel to this same CombatLog (main.gd).
	var before: int = _feedback.get_combat_log().get_count()
	_feedback.process_event(_ability_result(1, 2, 5))
	assert_eq(_feedback.get_combat_log().get_count(), before + 1)


func test_no_standalone_combat_log_panel_child() -> void:
	# T-607: closes the T-027 risk note — CombatFeedback must not mount a second on-screen surface
	# that overlaps ChatPanel's rect anymore.
	assert_null(_feedback.get_node_or_null("CombatLogPanel"))
