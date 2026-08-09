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


# T-729: sticky mode added a third honest state — armed but with nothing legal to hit.
func test_armed_but_idle_reads_differently_from_swinging() -> void:
	assert_eq(State.label_text(true, false), "Auto-Attack: ON (idle)")
	assert_eq(State.color(true, false), State.IDLE_COLOR)
	assert_ne(State.label_text(true, false), State.label_text(true, true))
	assert_ne(State.color(true, false), State.color(true, true))


func test_idle_still_reads_as_armed_not_as_off() -> void:
	assert_true(State.label_text(true, false).begins_with(State.ON_TEXT), "the mode reads ON")
	assert_ne(State.color(true, false), State.OFF_COLOR)
	assert_eq(State.label_text(true), State.ON_TEXT, "engaged defaults true for pre-T-729 callers")
