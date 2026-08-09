extends "res://addons/gut/test.gd"
# T-621: QuestLogPanel difficulty-band title colour + active-log occupancy count. The band NAME is
# server-computed (content_query.quest_difficulty); the panel only paints it and mirrors it into the
# tracker model.

var _panel: QuestLogPanel = null


func before_each() -> void:
	_panel = QuestLogPanel.new()
	add_child(_panel)
	await get_tree().process_frame


func after_each() -> void:
	_panel.queue_free()


func test_active_title_paints_the_difficulty_band() -> void:
	(
		_panel
		. render(
			[
				{
					"quest_id": "q1",
					"title": "Red One",
					"state": "active",
					"objectives": [],
					"difficulty": "red",
				}
			]
		)
	)
	var reds := 0
	for lbl in _panel.find_children("*", "Label", true, false):
		if (lbl as Label).text == "Red One":
			assert_eq(
				(lbl as Label).get_theme_color("font_color"),
				Color.html("#" + str(QuestLogPanel._DIFFICULTY_HEX["red"])),
				"a red-band active quest title is painted red",
			)
			reds += 1
	assert_eq(reds, 1, "the active quest title rendered exactly once")


func test_title_shows_active_log_occupancy() -> void:
	(
		_panel
		. render(
			[
				{"quest_id": "a", "title": "A", "state": "active", "objectives": []},
				{"quest_id": "b", "title": "B", "state": "active", "objectives": []},
				{"quest_id": "c", "title": "C", "state": "complete", "objectives": []},
			]
		)
	)
	assert_true(
		_panel.get_text().contains("(2/%d)" % QuestLogPanel.LOG_CAP),
		"the title counts only ACTIVE quests against the cap",
	)


func test_tracker_model_carries_difficulty_band() -> void:
	(
		_panel
		. render(
			[
				{
					"quest_id": "q1",
					"title": "Hard",
					"state": "active",
					"objectives": [],
					"difficulty": "orange",
				}
			]
		)
	)
	var model: Array = _panel.active_tracker_model()
	assert_eq(
		str(model[0]["difficulty"]), "orange", "the tracker model forwards the difficulty band"
	)
