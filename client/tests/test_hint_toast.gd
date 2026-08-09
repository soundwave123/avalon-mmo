extends GutTest

# T-426: the contextual-hint strip — a pure queue/expiry state machine (show -> tick -> expire,
# click dismiss, later hints wait their turn) plus the rendered one-line label. Non-modal by
# construction; these tests pin the fire/expire/dismiss behavior headless.

const HintToast = preload("res://scripts/ui/hint_toast.gd")
const HintReference = preload("res://scripts/ui/hint_reference.gd")
const OnboardingController = preload("res://scripts/ui/onboarding_controller.gd")
const SettingsPanel = preload("res://scripts/ui/settings_panel.gd")


func _make() -> HintToast:
	var toast := HintToast.new()
	add_child_autofree(toast)
	return toast


func test_starts_hidden_and_idle() -> void:
	var toast := _make()
	assert_false(toast.is_showing(), "no hint until one fires")
	assert_false(toast.visible, "the strip is invisible while idle")


func test_show_hint_displays_one_line() -> void:
	var toast := _make()
	toast.show_hint("Press I to open your bag.")
	assert_true(toast.is_showing())
	assert_true(toast.visible, "a live hint renders the strip")
	assert_eq(toast.current_text(), "Press I to open your bag.")


func test_second_hint_queues_behind_the_first() -> void:
	var toast := _make()
	toast.show_hint("first")
	toast.show_hint("second")
	assert_eq(toast.current_text(), "first", "one hint at a time — never a wall of text")
	assert_eq(toast.queued_count(), 1)


func test_hint_expires_after_show_secs_then_next_queued_shows() -> void:
	var toast := _make()
	toast.show_hint("first")
	toast.show_hint("second")
	toast.tick(HintToast.SHOW_SECS + 0.1)
	assert_eq(toast.current_text(), "second", "expiry advances to the queued hint")
	toast.tick(HintToast.SHOW_SECS + 0.1)
	assert_false(toast.is_showing(), "the queue drains to idle")
	assert_false(toast.visible)


func test_dismiss_drops_the_current_hint_early() -> void:
	var toast := _make()
	watch_signals(toast)
	toast.show_hint("first")
	toast.dismiss()
	assert_false(toast.is_showing(), "a click dismisses without waiting for expiry")
	assert_signal_emitted(toast, "hint_dismissed")


func test_blank_hint_is_ignored() -> void:
	var toast := _make()
	toast.show_hint("   ")
	assert_false(toast.is_showing(), "blank text never opens the strip")


func test_reference_hints_are_single_line_and_known() -> void:
	# The reference table drives the toast: every hint is one line (no walls of text), every id
	# resolves, and an unknown id resolves to "" (which show_hint ignores).
	assert_gt(HintReference.ids().size(), 3, "the core teaching moments are covered")
	for id in HintReference.ids():
		var text: String = HintReference.text_for(str(id))
		assert_true(text.length() > 0, "hint '%s' has text" % id)
		assert_false("\n" in text, "hint '%s' must be a single line" % id)
	assert_eq(HintReference.text_for("no_such_hint"), "", "unknown ids resolve to empty")


# ---- T-580 (portal #37): the toast must never draw over an open modal (e.g. Options) ------------


func test_toast_z_index_stays_behind_default_hud_panels() -> void:
	var toast := _make()
	# Every ordinary HUD panel (SettingsPanel/Options, quest log, bags, ...) uses the Control default
	# z_index of 0; a negative toast z_index is what keeps it behind them regardless of add_child
	# order (unlike sibling/tree-order, z_index comparisons are order-independent).
	assert_lt(toast.z_index, 0, "the toast must sit at a negative z_index to stay behind modals")


func test_toast_z_index_is_behind_the_options_panel() -> void:
	var toast := _make()
	var settings := SettingsPanel.new()
	add_child_autofree(settings)  # _ready() builds the panel; default z_index (0), no setup() needed
	assert_lt(
		toast.z_index,
		settings.z_index,
		"T-580: the daily-reward toast must render behind the Options panel, not over its header"
	)


# ---- T-483: session-one return reason ---------------------------------------------------------


func _return_state() -> Dictionary:
	return {
		"ok": true,
		"streak": 1,
		"objectives": [{"quest_id": "qb01", "title": "Bounty: Greymaw the Alpha"}],
		"weekly": {"progress": 2, "goal": 5},
	}


func test_return_reason_mirrors_authoritative_appointment_view_without_mutating_it() -> void:
	var state := _return_state()
	var before := state.duplicate(true)
	var text: String = HintReference.return_reason_text(state)
	assert_true(text.contains("Day 1"), "endowed streak comes from the authoritative view")
	assert_true(
		text.contains("Greymaw"), "the daily preview comes from the authoritative objective"
	)
	assert_true(text.contains("2/5"), "weekly progress is surfaced when T-480 supplies it")
	assert_eq(state, before, "formatting is read-only and grants or changes nothing")


func test_return_reason_is_a_warm_invitation_without_fomo_copy() -> void:
	var text := HintReference.return_reason_text(_return_state()).to_lower()
	assert_true(text.contains("waits tomorrow"), "the return cue is gift-framed")
	for threat in ["countdown", "expires", "lose", "lost", "break your streak", "left"]:
		assert_false(text.contains(threat), "return cue must not carry loss pressure: %s" % threat)
	assert_false("\n" in text, "the light toast stays one line")


func test_return_reason_uses_existing_fire_once_suppressible_hint_chassis() -> void:
	var controller := OnboardingController.new()
	controller._username = "gut_return_reason_%d" % Time.get_ticks_usec()
	controller.toast = HintToast.new()
	controller.set_return_reason_state(_return_state())
	controller.show_return_reason()
	assert_true(controller.toast.is_showing(), "the first end-session cue uses HintToast")
	assert_true(controller.toast.current_text().contains("Day 1"))
	controller.show_return_reason()
	assert_eq(controller.toast.queued_count(), 0, "the cue fires once, never queues a nag")


func test_return_reason_respects_the_existing_hide_hints_preference() -> void:
	var controller := OnboardingController.new()
	controller._username = "gut_return_reason_off_%d" % Time.get_ticks_usec()
	controller.toast = HintToast.new()
	controller.set_hints_enabled(false)
	controller.set_return_reason_state(_return_state())
	controller.show_return_reason()
	assert_false(controller.toast.is_showing(), "hide hints suppresses the return cue too")
