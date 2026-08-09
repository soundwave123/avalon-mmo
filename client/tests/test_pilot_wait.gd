extends GutTest

# T-623: pure path-resolve/comparator grammar for the `wait_until` pilot op — the poll-don't-sleep
# idiom every QA session hand-rolled. See client/scripts/dev/pilot_wait.gd for the live per-frame
# poll loop (proven in test_pilot.gd via a real Pilot node).

const PilotWait = preload("res://scripts/dev/pilot_wait.gd")


func _snap() -> Dictionary:
	return {
		"class_panel_visible": false,
		"gender_panel_visible": true,
		"kit_size": 3,
		"player_pos": [12.0, 1.0, -8.0],
		"player": {"hp": 42, "max_hp": 100, "class": "mage"},
	}


func test_resolve_path_top_level_key() -> void:
	assert_eq(PilotWait.resolve_path(_snap(), "kit_size"), 3, "flat key")


func test_resolve_path_nested_dot_path() -> void:
	assert_eq(PilotWait.resolve_path(_snap(), "player.hp"), 42, "one level of nesting")


func test_resolve_path_missing_segment_is_null_not_an_error() -> void:
	assert_null(PilotWait.resolve_path(_snap(), "player.mana"), "missing key -> null")
	assert_null(PilotWait.resolve_path(_snap(), "player.hp.deep"), "indexing past a scalar -> null")
	assert_null(PilotWait.resolve_path(_snap(), "nope"), "missing top-level key -> null")


func test_matches_bool_equality() -> void:
	assert_true(PilotWait.matches(false, "false"), "bool false matches 'false'")
	assert_false(PilotWait.matches(true, "false"), "bool true does not match 'false'")
	assert_true(PilotWait.matches(true, "true"), "class_panel_visible=false idiom, inverse case")


func test_matches_numeric_equality() -> void:
	assert_true(PilotWait.matches(42, "42"), "int equals numeric string")
	assert_true(PilotWait.matches(42.0, "42"), "float equals numeric string")
	assert_false(PilotWait.matches(41, "42"), "a different number doesn't match")


func test_matches_numeric_comparators() -> void:
	assert_true(PilotWait.matches(75, ">50"), "hp-above: 75 > 50")
	assert_false(PilotWait.matches(30, ">50"), "hp-above: 30 not > 50")
	assert_true(PilotWait.matches(30, "<50"), "below")
	assert_true(PilotWait.matches(50, ">=50"), "at-or-above includes the boundary")
	assert_true(PilotWait.matches(50, "<=50"), "at-or-below includes the boundary")
	assert_true(PilotWait.matches(30, "!=50"), "not-equal")
	assert_false(PilotWait.matches(50, "!=50"), "not-equal excludes the exact value")


func test_matches_comparator_against_non_numeric_current_is_false() -> void:
	assert_false(PilotWait.matches("mage", ">50"), "a string can't satisfy a numeric comparator")
	assert_false(PilotWait.matches(null, ">50"), "null can't satisfy a numeric comparator")


func test_matches_position_near() -> void:
	assert_true(PilotWait.matches([12.0, 1.0, -8.0], "12,-8"), "exact position, default tol 1.0")
	assert_true(PilotWait.matches([12.4, 1.0, -8.0], "12,-8,1"), "within an explicit tolerance")
	assert_false(PilotWait.matches([20.0, 1.0, -8.0], "12,-8,1"), "8u away exceeds tol 1")


func test_matches_position_near_accepts_xz_dict_shape() -> void:
	assert_true(PilotWait.matches({"x": 12.0, "z": -8.0}, "12,-8"), "dict {x,z} shape also works")


func test_matches_position_near_malformed_target_is_false() -> void:
	assert_false(PilotWait.matches([12.0, 1.0, -8.0], "not,numbers"), "unparseable target -> false")


func test_matches_string_fallback() -> void:
	assert_true(PilotWait.matches("mage", "mage"), "plain string equality")
	assert_false(PilotWait.matches("mage", "warrior"), "a different string")
