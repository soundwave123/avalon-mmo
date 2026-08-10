extends GutTest

# T-376: the controls handbook must show the REAL keys, not hand-typed strings that rot when a
# binding moves. ControlsReference derives every label from the same KEY_* constants the live
# handlers use (main.gd._input, local_player.gd._unhandled_input), so these tests assert the
# labels track those keycodes via OS.get_keycode_string — the no-drift guarantee from the ticket.

const ControlsReference = preload("res://scripts/ui/controls_reference.gd")


func test_rows_cover_the_core_verbs() -> void:
	var actions: Array = []
	for r: Dictionary in ControlsReference.rows():
		actions.append(str(r["action"]))
	# The new player needs move / look / fight / interact at minimum.
	for needed in ["Move", "Look around", "Auto-attack", "Abilities", "Target / talk"]:
		assert_true(needed in actions, "controls card must teach '%s'" % needed)


func test_movement_label_is_derived_from_the_wasd_keycodes() -> void:
	var label := _label_for("Move")
	# Derived from KEY_W/A/S/D through the engine's own keycode names — never a literal "W A S D".
	for kc in [KEY_W, KEY_A, KEY_S, KEY_D]:
		assert_true(
			OS.get_keycode_string(kc) in label,
			"movement label must contain the live keycode name for %d" % kc
		)


func test_ability_row_collapses_the_whole_keyed_run() -> void:
	# T-723: the run is sourced from AbilityKeybinds (the live slot->key map), not KEY_1/KEY_4
	# literals, and a contiguous run renders as a range — so the row ends at the LAST keyed slot.
	var label := _label_for("Abilities")
	var last := AbilityKeybinds.slot_label(AbilityKeybinds.SLOT_COUNT - 1)
	assert_true(AbilityKeybinds.slot_label(0) in label, "ability label must include the first key")
	assert_true(last in label, "ability label must run to the last keyed slot (%s)" % last)


func test_help_keycode_matches_the_help_row() -> void:
	# main.gd re-opens the card on HELP_KEYCODE; the card advertises the same key, from one source.
	assert_eq(ControlsReference.help_keycode(), KEY_F1)
	assert_true(
		OS.get_keycode_string(KEY_F1) in _label_for("This help card"),
		"the help row must advertise the same key main.gd listens for"
	)


func test_wardrobe_uses_a_non_movement_key() -> void:
	assert_true(OS.get_keycode_string(KEY_V) in _label_for("Wardrobe"))
	assert_false(OS.get_keycode_string(KEY_W) == _label_for("Wardrobe"), "W remains movement")


func test_glossary_covers_the_load_bearing_concepts() -> void:
	# T-426: the "no manual needed" bar — every core verb/concept a new player will meet in the
	# first session must be look-up-able in the in-game glossary.
	var terms: Array = []
	for g: Dictionary in ControlsReference.glossary_rows():
		terms.append(str(g["term"]))
	var needed := [
		"Move",
		"Target",
		"Abilities",
		"GCD",
		"Casting",
		"Interrupt",
		"Threat",
		"Loot",
		"Equip",
		"Quests",
		"Party",
		"Guild & Help",
		"Discovery",
	]
	for term in needed:
		assert_true(term in terms, "glossary must explain '%s'" % term)


func test_glossary_tips_are_one_liners() -> void:
	# T-426: never a wall of text — every explanation is a single line with real content.
	for g: Dictionary in ControlsReference.glossary_rows():
		var tip := str(g["tip"])
		assert_true(tip.length() > 10, "'%s' needs a real explanation" % g["term"])
		assert_false("\n" in tip, "'%s' must be one line" % g["term"])


func _label_for(action: String) -> String:
	for r: Dictionary in ControlsReference.rows():
		if str(r["action"]) == action:
			return str(r["keys_label"])
	return ""


# T-717: the auto-shown card teaches only minute-one verbs; the full table stays behind F1.
func test_essential_rows_are_the_three_minute_one_verbs() -> void:
	var essential := ControlsReference.essential_rows()
	assert_eq(essential.size(), 3, "a first-show card holds ~3 items, not the full table")
	var actions: Array = []
	for r: Dictionary in essential:
		actions.append(str(r["action"]))
	assert_eq(actions, ["Move", "Look around", "Target / talk"], "move, look, talk — in that order")


func test_essential_rows_derive_the_same_labels_as_the_full_table() -> void:
	# Both paths run _label_for, so a binding change can never desync the two views.
	var full := {}
	for r: Dictionary in ControlsReference.rows():
		full[str(r["action"])] = str(r["keys_label"])
	for r: Dictionary in ControlsReference.essential_rows():
		assert_eq(str(r["keys_label"]), str(full[str(r["action"])]), "labels must match the table")


func test_every_essential_action_exists_in_the_full_table() -> void:
	var known: Array = []
	for r: Dictionary in ControlsReference.rows():
		known.append(str(r["action"]))
	for r: Dictionary in ControlsReference.essential_rows():
		assert_true(known.has(str(r["action"])), "essential row must name a real control row")
