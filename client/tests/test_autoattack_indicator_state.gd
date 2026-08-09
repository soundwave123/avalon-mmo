extends GutTest

# T-571 (report #26): the auto-attack ON/OFF presentation is a pure function, unit-tested without
# a live scene tree — PlayerHud only renders whatever this returns.

const State = preload("res://scripts/ui/autoattack_indicator_state.gd")


func test_on_state_reads_unmistakably_active() -> void:
	assert_eq(State.label_text(true), "Auto-Attack: ON")
	assert_eq(State.color(true), State.ON_COLOR)


func test_off_state_reads_unmistakably_inactive() -> void:
	assert_eq(State.label_text(false), "Auto-Attack: OFF")
	assert_eq(State.color(false), State.OFF_COLOR)


func test_on_and_off_colors_are_visually_distinct() -> void:
	assert_ne(State.color(true), State.color(false))


func test_on_and_off_labels_are_distinct() -> void:
	assert_ne(State.label_text(true), State.label_text(false))
