extends GutTest
# T-558: on first spawn the Adventurer's Handbook auto-showed BEHIND the permanent gender/class
# creation modals — three competing panels at the single most important onboarding moment. The
# handbook must stay suppressed while either creation modal is visible.

const OnboardingController = preload("res://scripts/ui/onboarding_controller.gd")


func _panel(visible: bool) -> Control:
	var p := Control.new()
	add_child_autofree(p)
	p.visible = visible
	return p


func test_gate_blocks_while_the_gender_modal_is_up() -> void:
	assert_true(
		OnboardingController.creation_modal_open(_panel(true), _panel(false)),
		"the gender modal alone suppresses the handbook"
	)


func test_gate_blocks_while_the_class_modal_is_up() -> void:
	assert_true(
		OnboardingController.creation_modal_open(_panel(false), _panel(true)),
		"the class modal alone suppresses the handbook"
	)


func test_gate_opens_once_both_modals_are_dismissed() -> void:
	assert_false(
		OnboardingController.creation_modal_open(_panel(false), _panel(false)),
		"with both creation modals closed the handbook may auto-show"
	)


func test_gate_is_null_safe_for_a_returning_locked_character() -> void:
	# A returning, locked character never instantiates the creation modals (null panels).
	assert_false(
		OnboardingController.creation_modal_open(null, null),
		"no creation modals => nothing to suppress the handbook"
	)


# The controller's auto-show respects the gate: while a creation modal is visible the handbook stays
# closed (the reported stacked-panels bug). maybe_show is idempotent, so this holds on every re-run.
func test_maybe_show_holds_the_handbook_behind_a_visible_creation_modal() -> void:
	var hud := Control.new()
	add_child_autofree(hud)
	var gender := _panel(true)
	var oc := OnboardingController.new()
	oc.setup(hud, null, gender)
	oc.maybe_show()
	assert_false(oc.card.visible, "the handbook stays closed while the gender modal is up")


# ---- T-714 (portal #105): the gate covers the WHOLE creation sequence, not this frame's pixels ---


func _controller_with_flow(flow: CreationFlow) -> OnboardingController:
	var hud := Control.new()
	add_child_autofree(hud)
	var oc := OnboardingController.new()
	oc.setup(hud, null, null, flow)
	oc._username = "t714_%d_%d" % [Time.get_ticks_usec(), randi() % 100000]
	return oc


# The live repro: after the gender pick, BOTH panels are momentarily hidden (gender just closed,
# class ack pending) — visibility alone said "clear" and the handbook fired over the incoming class
# panel. The flow's latches must keep the gate shut through that instant.
func test_handbook_holds_through_the_gender_to_class_transition() -> void:
	var flow := CreationFlow.new()
	flow.setup(null, null)  # latch truth only — no panels, mirroring the both-hidden instant
	var oc := _controller_with_flow(flow)
	flow.on_gender_chosen()  # the transition instant: gender latched, class NOT locked yet
	oc.maybe_show()
	assert_false(oc.card.visible, "mid-transition is STILL in-creation — no auto-show")
	flow.on_class_locked()
	oc.maybe_show()
	assert_true(oc.card.visible, "once the whole sequence resolves the handbook may show")


func test_returning_locked_character_still_gets_the_handbook() -> void:
	var flow := CreationFlow.new()
	flow.setup(null, null)
	flow.on_class_kit({"gender": "male", "class_locked": true})  # returning char: both latch at once
	var oc := _controller_with_flow(flow)
	oc.maybe_show()
	assert_true(oc.card.visible, "a resolved flow never suppresses the returning-player auto-show")


# ---- T-714 defense: Esc closes the topmost surface during an illegal overlap --------------------


func test_escape_closes_topmost_decision() -> void:
	assert_eq(
		OnboardingController.escape_closes(true, true, false), "card", "handbook over a modal"
	)
	assert_eq(
		OnboardingController.escape_closes(true, true, true),
		"card",
		"handbook draws last -> it is topmost even over the offer prompt"
	)
	assert_eq(OnboardingController.escape_closes(true, false, true), "offer", "offer over a modal")
	assert_eq(
		OnboardingController.escape_closes(true, false, false), "", "no overlap, nothing to do"
	)
	assert_eq(
		OnboardingController.escape_closes(false, true, true),
		"",
		"no creation modal -> Esc keeps its normal main.gd precedence"
	)
