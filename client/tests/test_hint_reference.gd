extends GutTest
# T-557: the target-lock hint's ability-key range must match the number of filled action-bar slots
# for the class (the bar grew to 5 with T-464), never the stale hard-coded "1-4".

const HintReference = preload("res://scripts/ui/hint_reference.gd")


func test_default_target_hint_reflects_the_five_slot_bar() -> void:
	assert_string_contains(HintReference.text_for("target"), "1-5")
	assert_false(HintReference.text_for("target").contains("1-4"), "the stale 1-4 range is gone")


func test_target_hint_range_tracks_the_filled_slot_count() -> void:
	assert_string_contains(HintReference.target_hint(5), "press 1-5")
	assert_string_contains(HintReference.target_hint(4), "press 1-4")
	assert_string_contains(
		HintReference.target_hint(1), "press 1 ", "a single-slot kit reads 'press 1'"
	)
	assert_false(HintReference.target_hint(1).contains("1-1"), "no degenerate 1-1 range")


func test_target_hint_keeps_the_autoattack_clause() -> void:
	assert_string_contains(HintReference.target_hint(5), "auto-attack")


# ---- T-711: the stall-detector hints ride the same fire-once reference ------------------------


func test_stall_hints_exist_with_one_line_copy() -> void:
	assert_string_contains(
		HintReference.text_for("stall_find_hale"), "Drillmaster Hale", "rule 1 names the giver"
	)
	assert_string_contains(
		HintReference.text_for("stall_find_hale"), "northwest", "and gives a direction"
	)
	assert_true(HintReference.text_for("stall_objective") != "", "rule 2 has fallback copy")
	assert_true(
		HintReference.ids().has("stall_find_hale") and HintReference.ids().has("stall_objective"),
		"both ids are in the canonical fire-once registry (handbook + persistence)"
	)
