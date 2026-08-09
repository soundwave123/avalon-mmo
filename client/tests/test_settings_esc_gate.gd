extends GutTest

# T-078: the Esc precedence is a pure function (SettingsEscGate), so WoW ordering is proved without
# a live tree — close the options menu, else close other open HUD panels, else deselect, else open.

const Gate = preload("res://scripts/ui/settings_esc_gate.gd")


func test_open_menu_takes_priority_to_close() -> void:
	# menu open beats everything else: Esc closes the menu first.
	assert_eq(Gate.next_action(true, true, true), Gate.CLOSE_MENU)


func test_other_panels_close_before_deselect() -> void:
	assert_eq(Gate.next_action(false, true, true), Gate.CLOSE_PANELS)


func test_deselect_when_only_a_target() -> void:
	assert_eq(Gate.next_action(false, false, true), Gate.CLEAR_TARGET)


func test_open_menu_when_nothing_is_up() -> void:
	assert_eq(Gate.next_action(false, false, false), Gate.OPEN_MENU)
