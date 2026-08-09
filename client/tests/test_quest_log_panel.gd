extends "res://addons/gut/test.gd"
# T-038 / T-422d: QuestLogPanel — renders the enriched quest-log view-model as a modern card list
# (grouped by state, per-objective progress bars, action buttons). Headless.

var _panel: QuestLogPanel = null


func before_each() -> void:
	_panel = QuestLogPanel.new()
	add_child(_panel)
	await get_tree().process_frame


func after_each() -> void:
	_panel.queue_free()


func _quests() -> Array:
	return [
		{
			"quest_id": "q001",
			"title": "Cull the Wolves",
			"state": "active",
			"objectives":
			[
				{"desc": "Slay gray wolves", "current": 3, "required": 8},
				{"desc": "Recover pelts", "current": 5, "required": 5},
			],
		},
		{"quest_id": "q002", "title": "Lost Heirloom", "state": "complete", "objectives": []},
		{"quest_id": "q003", "title": "Old Debt", "state": "abandoned", "objectives": []},
	]


# Recursively collect all Buttons under the panel (the action buttons live inside cards).
func _buttons(node: Node = null) -> Array:
	var out: Array = []
	var root: Node = node if node != null else _panel
	for child in root.get_children():
		if child is Button:
			out.append(child)
		out.append_array(_buttons(child))
	return out


func test_starts_hidden() -> void:
	assert_false(_panel.visible)


func test_empty_render_shows_empty_state() -> void:
	_panel.render([])
	assert_eq(_panel.get_quest_count(), 0)
	assert_true(_panel.get_text().contains("No quests"))


func test_renders_titles_and_objective_progress() -> void:
	_panel.render(_quests())
	assert_eq(_panel.get_quest_count(), 3)
	var t: String = _panel.get_text()
	assert_true(t.contains("Cull the Wolves"), "shows quest title")
	assert_true(t.contains("3/8"), "shows objective progress")
	assert_true(t.contains("✓"), "marks the met 5/5 objective")


func test_objective_progress_bar_reflects_current_over_required() -> void:
	_panel.render(_quests())
	var bars: Array = []
	for node in _panel.find_children("*", "ProgressBar", true, false):
		bars.append(node)
	assert_gt(bars.size(), 0, "objective rows render real ProgressBars")
	var first: ProgressBar = bars[0]
	assert_eq(first.max_value, 8.0, "max = required")
	assert_eq(first.value, 3.0, "value = current")


func test_groups_by_state() -> void:
	_panel.render(_quests())
	var t: String = _panel.get_text()
	assert_true(t.contains("Active"))
	assert_true(t.contains("Completed"))
	# T-056: abandoned quests are deleted, never shown — no Abandoned section, ever.
	assert_false(t.contains("Abandoned"), "no Abandoned section")
	assert_false(t.contains("Old Debt"), "the abandoned quest is not rendered")


func test_set_open_toggles_visibility() -> void:
	_panel.set_open(true)
	assert_true(_panel.visible)
	_panel.set_open(false)
	assert_false(_panel.visible)


func test_completed_quest_renders_no_turn_in_action() -> void:  # T-569 (portal #24)
	# server "complete" is only ever reached via a SUCCESSFUL turn_in (quest_state_machine.gd) —
	# every card under Completed is already turned in, so it must carry no action button at all.
	_panel.render([{"quest_id": "q007", "title": "Done", "state": "complete", "objectives": []}])
	assert_false(_panel.get_action_metas().has("turn_in|q007"))
	assert_eq(
		_panel.get_action_metas().size(), 0, "an already-turned-in quest has no action button"
	)
	assert_eq(_buttons().size(), 0, "no Turn In button renders on a completed quest card")


func test_active_quest_renders_abandon_action() -> void:  # T-056
	_panel.render([{"quest_id": "q003", "title": "Doing", "state": "active", "objectives": []}])
	assert_true(_panel.get_action_metas().has("abandon|q003"))


func test_action_button_press_emits_action_selected() -> void:  # T-056
	_panel.render([{"quest_id": "q003", "title": "Doing", "state": "active", "objectives": []}])
	watch_signals(_panel)
	var btns := _buttons()
	assert_eq(btns.size(), 1, "one abandon button")
	btns[0].pressed.emit()
	assert_signal_emitted_with_parameters(_panel, "action_selected", ["abandon|q003"])


# ---- T-569 (portal #24): should_show_turn_in — pure predicate, no Control instantiation ----


func test_should_show_turn_in_false_for_complete_state() -> void:
	assert_false(QuestLogPanel.should_show_turn_in({"state": "complete"}))


func test_should_show_turn_in_true_for_active_state() -> void:
	assert_true(QuestLogPanel.should_show_turn_in({"state": "active"}))


func test_should_show_turn_in_true_for_unknown_or_missing_state() -> void:
	assert_true(QuestLogPanel.should_show_turn_in({}))


# ---- T-058: targeted delta application (no re-request) ----


func test_apply_delta_upserts_one_quest() -> void:
	_panel.render([{"quest_id": "q001", "title": "Wolves", "state": "active", "objectives": []}])
	(
		_panel
		. apply_delta(
			"q001",
			{
				"quest_id": "q001",
				"title": "Wolves",
				"state": "complete",
				"objectives": [],
			}
		)
	)
	assert_eq(_panel.get_quest_count(), 1, "upsert replaces, never duplicates")
	assert_string_contains(_panel.get_text(), "Completed")


func test_apply_delta_null_removes_the_quest() -> void:
	_panel.render([{"quest_id": "q001", "title": "Wolves", "state": "active", "objectives": []}])
	_panel.apply_delta("q001", null)
	assert_eq(_panel.get_quest_count(), 0, "abandon delta drops the entry")


func test_apply_delta_inserts_new_quest() -> void:
	_panel.render([])
	_panel.apply_delta(
		"q002", {"quest_id": "q002", "title": "Ore", "state": "active", "objectives": []}
	)
	assert_eq(_panel.get_quest_count(), 1, "accept delta inserts")


# T-400 / T-422d: the window roots on the theme's SolidWindow frame with an internal scroll.
func test_uses_solidwindow_frame_with_scroll() -> void:
	assert_not_null(_panel.theme, "carries the shared UiTheme so SolidWindow resolves")
	var frame := _panel.get_node_or_null("Frame") as PanelContainer
	assert_not_null(frame, "a PanelContainer frame roots the window")
	assert_eq(frame.theme_type_variation, &"SolidWindow", "opaque deliberate-window variation")
	assert_not_null(frame.get_node_or_null("Scroll"), "internal scroll caps the window to 720p")
	for child in _panel.get_children():
		assert_false(child is ColorRect, "the hand-rolled ColorRect box is gone")


# ---- T-461: active-objective model feeding the HUD tracker ----


func test_active_tracker_model_drops_met_objectives_and_inactive_quests() -> void:
	_panel.render(_quests())
	var model: Array = _panel.active_tracker_model()
	assert_eq(model.size(), 1, "only the active quest feeds the tracker (complete/abandoned drop)")
	var quest: Dictionary = model[0]
	assert_eq(str(quest["title"]), "Cull the Wolves")
	# Cull the Wolves has one incomplete (3/8) + one met (5/5) objective; only the incomplete stays.
	assert_eq(quest["objectives"].size(), 1, "the met 5/5 objective drops off the tracker")
	assert_eq(int(quest["objectives"][0]["current"]), 3)


func test_render_emits_objectives_changed_for_the_tracker() -> void:
	watch_signals(_panel)
	_panel.render(_quests())
	assert_signal_emitted(_panel, "objectives_changed", "render feeds the always-on tracker")


# ---- T-608: safe-zone at 1280x720 (shared HudSafeZone — never overlap Vitals or the hotbar) -----


func test_panel_rect_clears_vitals_at_720p() -> void:
	# The panel is statically anchored (left 0, bottom 1), so its 720p rect is pure offset math —
	# same pattern character_sheet_panel.gd's T-640 regression test uses.
	var top := _panel.offset_top
	var bottom := 720.0 + _panel.offset_bottom
	var rect := Rect2(
		_panel.offset_left, top, _panel.offset_right - _panel.offset_left, bottom - top
	)
	assert_eq(
		_panel.offset_top,
		HudSafeZone.PANEL_SAFE_TOP,
		"reads the shared safe-zone constant, not a re-derived local guess",
	)
	assert_false(
		HudSafeZone.intersects_vitals(rect),
		"was a hardcoded 56.0 (34px inside VitalsFrame's occupied band) before T-608",
	)
