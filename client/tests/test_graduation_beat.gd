extends GutTest

# T-713: the client half of the graduation beat — Hale's stakes line reaching the turn-in card, and
# the once-per-account LFG toast that finally surfaces the board (T-625) nobody could find.

const OnboardingController = preload("res://scripts/ui/onboarding_controller.gd")
const QuestOfferPanel = preload("res://scripts/ui/quest_offer_panel.gd")
const HintReference = preload("res://scripts/ui/hint_reference.gd")


func _controller() -> OnboardingController:
	var hud := Control.new()
	add_child_autofree(hud)
	var oc := OnboardingController.new()
	oc.setup(hud, null)
	# Unique per-run user so OnboardingPrefs' persisted fire-once memory never bleeds across runs
	# (the test_resource_hint.gd idiom).
	oc._username = "t713_%d" % Time.get_ticks_usec()
	return oc


# ---- the turn-in card carries Hale's spoken stakes line ---------------------------------------


func test_turn_in_card_renders_the_giver_spoken_line() -> void:
	var p = QuestOfferPanel.new()
	add_child_autofree(p)
	(
		p
		. open(
			"npc_drillmaster",
			"Drillmaster Hale",
			"Well met, recruit.",
			[
				{
					"kind": "turn_in",
					"quest_id": "q_tut_03",
					"title": "Read the Fight",
					"objectives": [],
					"turnin_text": "The road runs south — Highkeep has work.",
				}
			]
		)
	)
	assert_string_contains(p.get_text(), "The road runs south", "the stakes line is on the card")
	assert_string_contains(p.get_text(), "Read the Fight", "alongside the title, not instead of it")


func test_a_card_without_a_spoken_line_is_unchanged() -> void:
	var p = QuestOfferPanel.new()
	add_child_autofree(p)
	p.open("g", "Giver", "", [{"kind": "offer", "quest_id": "q010", "title": "Word", "xp": 5}])
	assert_string_contains(p.get_text(), "Word", "ordinary cards render exactly as before")


# ---- the LFG surface fires ONCE, on graduation only -------------------------------------------


func test_lfg_graduation_is_a_known_handbook_hint_id() -> void:
	assert_true(
		HintReference.ids().has("lfg_graduation"), "reviewable in the handbook like the rest"
	)


func test_graduation_turn_in_surfaces_the_lfg_board_with_its_keybind() -> void:
	var oc := _controller()
	oc.on_turn_in({"ok": true, "quest_id": "q_tut_03"})
	assert_true(oc.toast.is_showing(), "graduation surfaces the board — non-modally")
	var text := oc.toast.current_text()
	assert_true(text.contains("U"), "and names the keybind rather than seizing the screen")
	assert_string_contains(text, "adventurers", "it says WHY you'd press it")


func test_the_lfg_surface_fires_only_once() -> void:
	var oc := _controller()
	oc.on_turn_in({"ok": true, "quest_id": "q_tut_03"})
	oc.toast.dismiss()
	oc.on_turn_in({"ok": true, "quest_id": "q_tut_03"})
	assert_false(oc.toast.is_showing(), "a second graduation ack must not re-nag")
	assert_eq(oc.toast.queued_count(), 0, "nothing queued either")


func test_other_turn_ins_and_failures_never_fire_it() -> void:
	var oc := _controller()
	oc.on_turn_in({"ok": true, "quest_id": "q_tut_02"})
	assert_false(oc.toast.is_showing(), "mid-chain turn-ins are not graduation")
	oc.on_turn_in({"ok": false, "quest_id": "q_tut_03"})
	assert_false(oc.toast.is_showing(), "a REJECTED turn-in is not a graduation either")
