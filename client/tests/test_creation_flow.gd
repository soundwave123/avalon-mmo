extends "res://addons/gut/test.gd"
# T-597 (portal report #47): the gender panel spontaneously reopened mid-session on an
# already-created character — a kit-refresh resend (party/trade/duel accept, training, mentor
# sync) carried gender:"" and CreationFlow.on_class_kit re-evaluated visibility off that blank
# value. This exercises CreationFlow (the real wiring, not just the pure gate) against real
# GenderPanel/ClassPanel nodes so a regression here fails loudly.

const CreationFlow = preload("res://scripts/ui/creation_flow.gd")

var _gender_panel: GenderPanel = null
var _class_panel: ClassPanel = null
var _name_panel: NamePanel = null
var _flow: CreationFlow = null


func before_each() -> void:
	_gender_panel = GenderPanel.new()
	_class_panel = ClassPanel.new()
	_name_panel = NamePanel.new()
	add_child(_gender_panel)
	add_child(_class_panel)
	add_child(_name_panel)
	_flow = CreationFlow.new()
	_flow.setup(_gender_panel, _class_panel, _name_panel)
	await get_tree().process_frame


func after_each() -> void:
	_gender_panel.queue_free()
	_class_panel.queue_free()
	_name_panel.queue_free()


# The T-597 repro: a class_kit resend on an ALREADY-gendered character must never reopen the
# panel, even though the resend itself carries an empty gender (the server-side bug this ticket
# also fixes at the source — this is the client's independent second line of defense).
func test_blank_gender_resend_does_not_reopen_panel_on_gendered_character() -> void:
	_flow.on_class_kit({"gender": "male", "class_locked": true})
	assert_false(_gender_panel.visible, "the real gender panel hides once gender is known")

	# Simulate the party/trade/duel-accept kit-resend hole: gender comes back blank.
	_flow.on_class_kit({"gender": "", "class_locked": true})
	assert_false(
		_gender_panel.visible, "a blank-gender resend must NOT reopen the panel mid-session"
	)


# A genuinely fresh character (gender never chosen) must still see the panel — the latch only
# ever protects an ALREADY-chosen gender, it doesn't hide the panel from new characters.
func test_fresh_character_still_sees_panel() -> void:
	_flow.on_class_kit({"gender": "", "class_locked": false})
	assert_true(_gender_panel.visible, "a truly fresh character must still get the modal")


# The counter-case that proves the latch isn't just "always false": a genuine gender arriving
# after a blank first frame must still hide the panel (and set_gender_result's own ack path
# latches immediately, without waiting on the next class_kit at all).
func test_gender_chosen_ack_latches_even_before_next_class_kit() -> void:
	_flow.on_class_kit({"gender": "", "class_locked": false})
	assert_true(_gender_panel.visible)
	_flow.on_gender_chosen()
	assert_false(_gender_panel.visible, "the ack alone hides the panel for good")
	_flow.on_class_kit({"gender": "", "class_locked": false})
	assert_false(
		_gender_panel.visible, "a follow-up class_kit resend must not undo the ack's latch"
	)


# ---- T-714 (portal #105): creation_pending covers the WHOLE gender→class sequence -------------


func test_creation_pending_holds_through_the_gender_to_class_transition() -> void:
	assert_true(_flow.creation_pending(), "a fresh flow is in-creation before any kit")
	_flow.on_class_kit({"gender": "", "class_locked": false})
	assert_true(_flow.creation_pending(), "gender modal up = still in-creation")
	# The regression instant: gender just chosen, class ack not yet in — BOTH panels can be
	# momentarily hidden here, but the sequence is still owed.
	_flow.on_gender_chosen()
	assert_true(_flow.creation_pending(), "the gender→class hand-off is STILL in-creation")
	_flow.on_class_locked()
	assert_false(_flow.creation_pending(), "both latches flipped = creation resolved")


func test_creation_pending_is_immediately_false_for_a_returning_character() -> void:
	_flow.on_class_kit({"gender": "female", "class_locked": true})
	assert_false(
		_flow.creation_pending(), "a returning locked character never counts as in-creation"
	)


# ---- T-716: the NAME step is third in the order (gender -> class -> name) ----------------------


# The whole point of the ordering latches: naming must not appear until the two permanent choices
# are settled, and it must appear the moment they are.
func test_name_panel_waits_for_gender_and_class_then_shows() -> void:
	_flow.on_player_stats({"name": "steamfresh", "name_chosen": false})
	_flow.on_class_kit({"gender": "", "class_locked": false})
	assert_false(_name_panel.visible, "gender still owed => no name step yet")
	_flow.on_gender_chosen()
	assert_false(_name_panel.visible, "class still owed => still no name step")
	_flow.on_class_locked()
	assert_true(_name_panel.visible, "class locked => the name step is due")
	assert_eq(_name_panel.get_field().text, "steamfresh", "prefilled with the account name")


func test_creation_pending_covers_the_name_step() -> void:
	_flow.on_player_stats({"name": "steamfresh", "name_chosen": false})
	_flow.on_gender_chosen()
	_flow.on_class_locked()
	assert_true(_flow.creation_pending(), "the Handbook must still wait — naming is owed")
	_flow.on_name_result({"ok": true, "name": "aldric"})
	assert_false(_flow.creation_pending(), "every latch flipped => creation resolved")
	assert_false(_name_panel.visible, "the ack alone closes the last modal")


# A rejected name keeps the step open and hands back a sentence (the retry loop the ticket asks
# for); only the SERVER can know a name is taken.
func test_rejected_name_keeps_the_step_open_with_plain_english() -> void:
	_flow.on_player_stats({"name": "steamfresh", "name_chosen": false})
	_flow.on_gender_chosen()
	_flow.on_class_locked()
	_flow.on_name_result({"ok": false, "reason": "name_taken"})
	assert_true(_name_panel.visible, "still owed")
	assert_true(_flow.creation_pending(), "and still in-creation, so nothing auto-shows over it")
	assert_string_contains(_name_panel.get_error_text(), "already goes by that name")


# "Existing characters keep their names": name_chosen is TRUE for every character that is not a
# fresh bootstrap, and the latch is monotonic so a stale resend can never reopen a resolved step.
func test_existing_character_never_sees_the_name_step() -> void:
	_flow.on_class_kit({"gender": "female", "class_locked": true})
	_flow.on_player_stats({"name": "aldric", "name_chosen": true})
	assert_false(_name_panel.visible)
	assert_false(_flow.creation_pending(), "a returning character is never in-creation")


func test_a_stale_resend_cannot_reopen_a_finished_name_step() -> void:
	_flow.on_player_stats({"name": "steamfresh", "name_chosen": false})
	_flow.on_gender_chosen()
	_flow.on_class_locked()
	_flow.on_name_result({"ok": true, "name": "aldric"})
	_flow.on_player_stats({"name": "aldric", "name_chosen": false})  # a stale/in-flight frame
	assert_false(_name_panel.visible, "the latch only ever flips false -> true")


# A payload that says nothing about naming (older server / harness / unit test) must never strand
# a player behind a modal — "no step owed" is the safe default.
func test_a_payload_without_naming_fields_owes_no_name_step() -> void:
	_flow.on_class_kit({"gender": "male", "class_locked": true})
	_flow.on_player_stats({"level": 3})
	assert_false(_name_panel.visible)
	assert_false(_flow.creation_pending())


# The queue-drain wiring: the NAME modal closes LAST on a fresh account, so it is what must re-run
# the onboarding gate — without that connection the handbook and the held tutorial offer would wait
# on a modal that already closed and never appear at all.
func test_the_name_modal_closing_re_runs_the_onboarding_gate() -> void:
	var hud := Control.new()
	add_child_autofree(hud)
	var flow := CreationFlow.mount(hud)
	var oc = preload("res://scripts/ui/onboarding_controller.gd").new()
	oc.setup(hud, flow.class_panel, flow.gender_panel, flow)
	oc._username = "t716_%d" % Time.get_ticks_usec()
	flow.on_player_stats({"name": "steamfresh", "name_chosen": false})
	flow.on_gender_chosen()
	flow.on_class_locked()
	assert_true(flow.name_panel.visible, "precondition: the name step is up")
	assert_false(oc.card.visible, "and the handbook is held behind it")
	flow.on_name_result({"ok": true, "name": "aldric"})
	assert_false(flow.name_panel.visible)
	assert_true(oc.card.visible, "creation resolved => the handbook finally gets its turn")
