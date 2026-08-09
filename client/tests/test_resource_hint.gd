extends GutTest

# T-666 (portal #85): a fresh warrior with 0 rage presses ability 1 and gets a deliberate silent
# no-op (T-027/T-402: the log records outcomes, not denials) — correct for veterans, but a
# NEWCOMER's first-ever resource-starved press reads as "the game is broken" (session-21's
# would-quit moment). The FIRST insufficient_resource rejection fires a one-time helper hint via
# the standard fire-once toast path; it never repeats, and no other rejection reason ever hints.

const OnboardingController = preload("res://scripts/ui/onboarding_controller.gd")
const HintReference = preload("res://scripts/ui/hint_reference.gd")


func _controller() -> OnboardingController:
	var hud := Control.new()
	add_child_autofree(hud)
	var oc := OnboardingController.new()
	oc.setup(hud, null)
	# Unique per-run user so OnboardingPrefs' persisted fire-once memory never bleeds across runs.
	oc._username = "t666_%d" % Time.get_ticks_usec()
	return oc


func test_resource_hint_text_is_kind_keyed() -> void:
	var rage := HintReference.resource_hint("rage")
	assert_string_contains(rage, "rage")
	assert_string_contains(rage, "auto-attack", "rage names its generator")
	assert_string_contains(rage, "`", "the generator hint names the auto-attack key")
	var mana := HintReference.resource_hint("mana")
	assert_string_contains(mana, "mana")
	assert_string_contains(mana, "refills", "mana explains regen/wait")
	assert_eq(HintReference.resource_hint("none"), "", "no class resource -> generic HINTS copy")


func test_resource_is_a_known_handbook_hint_id() -> void:
	assert_true(HintReference.ids().has("resource"), "the handbook lists the resource hint")
	assert_true(HintReference.text_for("resource") != "", "the generic fallback copy exists")


func test_first_insufficient_resource_rejection_fires_the_hint_once() -> void:
	var oc := _controller()
	oc.on_ability_rejected({"reason": "insufficient_resource"}, "rage")
	assert_true(oc.toast.is_showing(), "the first starved press fires the helper")
	assert_string_contains(oc.toast.current_text(), "rage", "the class resource text renders")
	oc.toast.dismiss()
	oc.on_ability_rejected({"reason": "insufficient_resource"}, "rage")
	assert_false(oc.toast.is_showing(), "the second starved press never re-fires")
	assert_eq(oc.toast.queued_count(), 0, "nothing queued either")


func test_other_rejection_reasons_never_hint() -> void:
	var oc := _controller()
	for reason in ["out_of_range", "cooldown", "invalid_target", "unknown_ability", ""]:
		oc.on_ability_rejected({"reason": reason}, "rage")
	assert_false(oc.toast.is_showing(), "only insufficient_resource may ever hint")


func test_account_that_already_saw_it_stays_silent() -> void:
	# T-550 scope: the fire-once memory is ACCOUNT-authoritative — a veteran's alt never sees it.
	var oc := _controller()
	oc.begin_account({"hints_seen": ["resource"]})
	oc.on_ability_rejected({"reason": "insufficient_resource"}, "mana")
	assert_false(oc.toast.is_showing(), "an account-seen hint never re-fires on an alt")
