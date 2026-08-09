extends "res://addons/gut/test.gd"
# T-461: ObjectiveTracker — the always-on, non-interactive HUD quest tracker. It renders the active
# quest view-model QuestLogPanel.active_tracker_model() produces (incomplete objectives with x/y
# counters), condenses to nothing with no active quest, caps the visible quest count, and never eats
# a world click (every node MOUSE_FILTER_IGNORE). Headless.

var _tracker: ObjectiveTracker = null


func before_each() -> void:
	_tracker = ObjectiveTracker.new()
	add_child(_tracker)
	await get_tree().process_frame


func after_each() -> void:
	_tracker.queue_free()


func _model(quests: int = 1) -> Array:
	var out: Array = []
	for i in range(quests):
		(
			out
			. append(
				{
					"title": "Quest %d" % i,
					"objectives": [{"desc": "Slay dummies", "current": 2, "required": 8}],
				}
			)
		)
	return out


func test_starts_condensed_when_no_active_quest() -> void:
	_tracker.render([])
	assert_false(_tracker.visible, "no active quest -> tracker condenses to nothing")
	assert_eq(_tracker.get_visible_quest_count(), 0)


func test_renders_active_quest_incomplete_objectives_with_counters() -> void:
	_tracker.render(_model(1))
	assert_true(_tracker.visible, "an active quest makes the tracker visible")
	var t: String = _tracker.get_text()
	assert_true(t.contains("Quest 0"), "shows the quest title")
	assert_true(t.contains("Slay dummies"), "shows the objective")
	assert_true(t.contains("2/8"), "shows the live x/y counter")


func test_counter_advances_live_on_credit() -> void:
	_tracker.render(_model(1))
	assert_true(_tracker.get_text().contains("2/8"))
	# A kill credit re-renders with the new count (main re-emits objectives_changed on quest_delta).
	_tracker.render(
		[
			{
				"title": "Quest 0",
				"objectives": [{"desc": "Slay dummies", "current": 3, "required": 8}]
			}
		]
	)
	assert_true(_tracker.get_text().contains("3/8"), "counter updates live")
	assert_false(_tracker.get_text().contains("2/8"))


func test_met_objectives_are_absent_ready_to_turn_in() -> void:
	# A quest whose objectives are all met arrives with an empty incomplete list.
	_tracker.render([{"title": "First Steps", "objectives": []}])
	assert_true(_tracker.visible)
	assert_true(_tracker.get_text().contains("First Steps"))
	assert_true(_tracker.get_text().contains("Ready to turn in"), "guides the player to hand in")


func test_caps_visible_quests() -> void:
	_tracker.render(_model(9))
	assert_eq(
		_tracker.get_visible_quest_count(),
		ObjectiveTracker.MAX_QUESTS,
		"never shows more than the cap"
	)


func test_is_non_interactive_mouse_filter_ignore() -> void:
	_tracker.render(_model(2))
	assert_eq(
		_tracker.mouse_filter, Control.MOUSE_FILTER_IGNORE, "root passes world clicks through"
	)
	_assert_all_ignore(_tracker)


func _assert_all_ignore(node: Node) -> void:
	for child in node.get_children():
		if child is Control:
			assert_eq(
				(child as Control).mouse_filter,
				Control.MOUSE_FILTER_IGNORE,
				"%s must not eat a world click" % child.name
			)
		_assert_all_ignore(child)
