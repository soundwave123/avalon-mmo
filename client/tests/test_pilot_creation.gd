extends GutTest

# T-623: pure state-machine for the `create_character` boot dance (dismiss Handbook -> gender ->
# class as ONE op, replacing the eaten-keypress-prone key/poll/key/poll hand-dance). See
# client/scripts/dev/pilot_creation.gd's run() for the live click-and-poll driver — that half needs
# a real Main/HUD scene (gender/class panels + the onboarding Handbook) to fully verify live.

const PilotCreation = preload("res://scripts/dev/pilot_creation.gd")


func test_no_panels_visible_is_done() -> void:
	# T-623 (s24): an EXISTING account never shows the creation modals at all.
	assert_eq(PilotCreation.next_action({}), "done", "existing-account case: nothing to click")


func test_handbook_takes_priority_over_gender() -> void:
	var state := {"controls_card_visible": true, "gender_panel_visible": true}
	assert_eq(
		PilotCreation.next_action(state),
		"dismiss_handbook",
		"s25 ground truth: the Handbook can overlap + eat clicks — must close first"
	)


func test_handbook_takes_priority_over_class() -> void:
	var state := {"controls_card_visible": true, "class_panel_visible": true}
	assert_eq(PilotCreation.next_action(state), "dismiss_handbook")


func test_gender_panel_visible_alone() -> void:
	assert_eq(PilotCreation.next_action({"gender_panel_visible": true}), "click_gender")


func test_class_panel_visible_alone() -> void:
	assert_eq(PilotCreation.next_action({"class_panel_visible": true}), "click_class")


func test_gender_takes_priority_over_class() -> void:
	# Shouldn't happen live (T-520: gender is shown before class), but the state machine still
	# resolves deterministically rather than picking whichever dict key iterates first.
	var state := {"gender_panel_visible": true, "class_panel_visible": true}
	assert_eq(PilotCreation.next_action(state), "click_gender")
