extends GutTest

# T-376: the controls handbook Control — builds a row per control, opens/closes, and F1-style
# toggle. Headless-instantiated (it is pure code UI on the shared theme, no .tscn).

const ControlsCard = preload("res://scripts/ui/controls_card.gd")
const ControlsReference = preload("res://scripts/ui/controls_reference.gd")


func _make() -> ControlsCard:
	var card := ControlsCard.new()
	add_child_autofree(card)
	return card


func test_builds_one_row_per_control_and_hidden_by_default() -> void:
	var card := _make()
	assert_false(card.visible, "the card starts hidden — main.gd decides when to show it")
	assert_eq(
		card.row_count(),
		ControlsReference.rows().size(),
		"one rendered row per control-reference entry"
	)


func test_open_and_close_toggle_visibility() -> void:
	var card := _make()
	card.open()
	assert_true(card.visible, "open() shows the card")
	card.close_card()
	assert_false(card.visible, "close_card() hides it")
	card.toggle()
	assert_true(card.visible, "toggle() re-opens a closed card (the F1 path)")
	card.toggle()
	assert_false(card.visible, "toggle() closes an open card")


func test_close_emits_dismissed() -> void:
	var card := _make()
	watch_signals(card)
	card.open()
	card.close_card()
	assert_signal_emitted(card, "dismissed", "closing the card signals dismissal")


func test_text_carries_the_real_key_labels() -> void:
	var card := _make()
	var text := card.get_text()
	assert_true(OS.get_keycode_string(KEY_W) in text, "the rendered card shows the live move key")
	assert_true("Auto-attack" in text, "the rendered card names the auto-attack action")


func test_renders_the_full_glossary() -> void:
	# T-426: the handbook is the in-game manual — one rendered row per glossary concept, and the
	# tactical-layer terms (GCD/threat/interrupt) must actually be present in the rendered text.
	var card := _make()
	assert_eq(
		card.glossary_count(),
		ControlsReference.glossary_rows().size(),
		"one rendered row per glossary entry"
	)
	var text := card.glossary_text()
	for term in ["GCD", "Threat", "Interrupt", "Loot", "Discovery"]:
		assert_true(term in text, "the rendered glossary must explain '%s'" % term)


func test_renders_the_hint_lines_for_review() -> void:
	# T-426: hints fire once live, but stay reviewable here forever.
	var card := _make()
	var hint_ref = load("res://scripts/ui/hint_reference.gd")
	assert_eq(card.hint_count(), hint_ref.ids().size(), "one row per contextual hint")


func test_hints_switch_emits_and_syncs_without_reemitting() -> void:
	# T-426: the "Show hints" switch — toggling emits for the controller to persist; a programmatic
	# sync (set_hints_checked) reflects the saved setting WITHOUT re-emitting (no feedback loop).
	var card := _make()
	watch_signals(card)
	assert_true(card.hints_checked(), "hints default ON")
	card.set_hints_checked(false)
	assert_false(card.hints_checked(), "programmatic sync updates the switch")
	assert_signal_not_emitted(card, "hints_toggled", "sync must not loop back into persistence")


func test_handbook_keeps_screen_edge_margin() -> void:
	var card := _make()
	await get_tree().process_frame
	assert_gt(card.offset_left, 0.0, "handbook overlay has a left screen margin")
	assert_gt(card.offset_top, 0.0, "handbook overlay has a top screen margin")
