extends GutTest
# T-710/T-711: the guided first session, client half.
#   * OnboardingStall — the pure escalation ladder (60s no-quest, 90s untouched objective, the
#     resource wall) and its restate copy.
#   * guided_tracker_model — the persistent pre-accept "find Drillmaster Hale" tracker line.
#   * route_talk_result + maybe_show — the server-pushed tutorial offer is HELD through creation
#     and the whole first-entry queue drains strictly serially: gender -> class -> offer -> handbook
#     (the T-714 rule extended to the quest prompt).

const OnboardingController = preload("res://scripts/ui/onboarding_controller.gd")
const OnboardingStallRef = preload("res://scripts/ui/onboarding_stall.gd")
const CreationFlowRef = preload("res://scripts/ui/creation_flow.gd")
const QuestOfferPanelRef = preload("res://scripts/ui/quest_offer_panel.gd")

# ---- OnboardingStall: pure escalation decisions ------------------------------


func test_find_giver_due_only_pre_grad_idle_past_60s() -> void:
	assert_false(OnboardingStallRef.find_giver_due(true, false, 59.9), "not yet at 60s")
	assert_true(OnboardingStallRef.find_giver_due(true, false, 60.0), "due at 60s idle")
	assert_false(OnboardingStallRef.find_giver_due(true, true, 999.0), "acting disarms it forever")
	assert_false(OnboardingStallRef.find_giver_due(false, false, 999.0), "never for a grad alt")


func test_objective_restate_due_only_with_an_untouched_active_quest() -> void:
	assert_false(OnboardingStallRef.objective_restate_due(true, true, 89.9))
	assert_true(OnboardingStallRef.objective_restate_due(true, true, 90.0))
	assert_false(OnboardingStallRef.objective_restate_due(true, false, 999.0), "no active quest")
	assert_false(OnboardingStallRef.objective_restate_due(false, true, 999.0), "pre-grad only")


func test_resource_wall_needs_autoattack_off_target_and_two_fails() -> void:
	assert_true(OnboardingStallRef.resource_wall_hit(true, false, 12, 2), "the #85 wall pattern")
	assert_false(OnboardingStallRef.resource_wall_hit(true, false, 12, 1), "one fail is noise")
	assert_false(OnboardingStallRef.resource_wall_hit(true, true, 12, 5), "auto-attack ON = fine")
	assert_false(OnboardingStallRef.resource_wall_hit(true, false, -1, 5), "no target = no wall")
	assert_false(OnboardingStallRef.resource_wall_hit(false, false, 12, 5), "pre-grad only")


func test_restate_text_names_the_next_objective() -> void:
	var model := [
		{
			"title": "First Steps",
			"objectives": [{"desc": "Walk to the training ring", "current": 0, "required": 1}],
		}
	]
	var text := OnboardingStallRef.restate_text(model)
	assert_string_contains(text, "First Steps")
	assert_string_contains(text, "Walk to the training ring")
	assert_eq(OnboardingStallRef.restate_text([]), "", "nothing tracked -> nothing to say")
	assert_string_contains(
		OnboardingStallRef.restate_text([{"title": "First Steps", "objectives": []}]),
		"turn it in",
		"all objectives met -> point at the turn-in instead"
	)


# ---- guided tracker model: the persistent pre-accept line --------------------


func test_guided_tracker_model_injects_the_hale_line_then_retires() -> void:
	var injected: Array = OnboardingController.guided_tracker_model([], true)
	assert_eq(injected.size(), 1, "an empty active set still shows the tutorial line")
	assert_string_contains(str((injected[0]["objectives"] as Array)[0]["desc"]), "Drillmaster Hale")
	var quest := {"title": "First Steps", "objectives": []}
	assert_eq(
		OnboardingController.guided_tracker_model([quest], false),
		[quest],
		"once retired the model passes through untouched"
	)


# ---- T-710/T-714: the offer is deferred through creation, then strictly serial ----------------


func _serial_fixture() -> Dictionary:
	var hud := Control.new()
	add_child_autofree(hud)
	var flow := CreationFlowRef.new()
	flow.setup(null, null)  # latch truth only — the both-panels-hidden transition instant
	var oc := OnboardingController.new()
	oc.setup(hud, null, null, flow)
	oc._username = "t710_%d_%d" % [Time.get_ticks_usec(), randi() % 100000]
	var panel := QuestOfferPanelRef.new()
	panel.name = "QuestOfferPanel"
	hud.add_child(panel)
	return {"oc": oc, "flow": flow, "panel": panel}


func _tut_offer() -> Dictionary:
	return {
		"ok": true,
		"npc_id": "npc_drillmaster",
		"name": "Drillmaster Hale",
		"talk_text": "New blood?",
		"offers":
		[
			{
				"kind": "offer",
				"quest_id": "q_tut_01",
				"title": "First Steps",
				"objectives": [],
				"xp": 40,
				"coins": 0,
			}
		],
	}


func test_offer_defers_through_creation_then_opens_before_the_handbook() -> void:
	var f := _serial_fixture()
	var oc: OnboardingController = f["oc"]
	var flow: CreationFlowRef = f["flow"]
	var panel: QuestOfferPanelRef = f["panel"]

	oc.route_talk_result(panel, _tut_offer())  # the server's first-entry push, mid-creation
	assert_false(panel.is_open(), "the offer is HELD while creation is unresolved")
	assert_false(oc.card.visible, "and the handbook stays down too")

	flow.on_gender_chosen()
	oc.maybe_show()  # the pulse a real modal's visibility_changed sends
	assert_false(panel.is_open(), "still held through the gender->class transition (portal #105)")

	flow.on_class_locked()
	oc.maybe_show()
	assert_true(panel.is_open(), "creation resolved -> the tutorial offer opens FIRST")
	assert_false(oc.card.visible, "the handbook waits its turn behind the offer")
	assert_eq(panel.get_action_metas(), ["accept|q_tut_01"], "an ACCEPT choice, never silent")

	panel.close_panel()  # the player resolves the prompt
	await get_tree().process_frame
	assert_true(oc.card.visible, "the handbook shows only after the offer resolves — serial")


func test_offer_routes_straight_through_when_creation_is_already_resolved() -> void:
	var f := _serial_fixture()
	var oc: OnboardingController = f["oc"]
	var flow: CreationFlowRef = f["flow"]
	var panel: QuestOfferPanelRef = f["panel"]
	flow.on_class_kit({"gender": "male", "class_locked": true})  # a returning character
	oc.route_talk_result(panel, _tut_offer())
	assert_true(panel.is_open(), "no creation pending -> the prompt opens immediately")
