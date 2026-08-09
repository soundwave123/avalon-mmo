extends GutTest

# T-056/T-519: the talk→quest-prompt planner is pure, so it's unit-tested directly.

const TalkActions = preload("res://scripts/net/talk_actions.gd")


func test_offers_pass_through_as_prompt_model() -> void:
	var offers := [
		{"kind": "offer", "quest_id": "q007", "title": "A Wolf Problem", "objectives": [], "xp": 50}
	]
	var model = TalkActions.prompt_model({"ok": true, "offers": offers})
	assert_eq(model.size(), 1, "one offer → one prompt card")
	assert_eq(str(model[0]["quest_id"]), "q007", "quest id preserved")
	assert_eq(str(model[0]["kind"]), "offer", "kind preserved")


func test_legacy_ids_fall_back_to_stub_cards() -> void:
	# A reply predating the server `offers` enrichment still opens a prompt (id-only cards).
	var model = TalkActions.prompt_model(
		{"ok": true, "available": ["q007"], "turn_in_ready": ["q003"]}
	)
	assert_eq(model.size(), 2, "one available + one turn-in → two cards")
	assert_eq(str(model[0]["kind"]), "offer", "available → offer card")
	assert_eq(str(model[1]["kind"]), "turn_in", "ready → turn_in card")
	assert_eq(str(model[1]["quest_id"]), "q003", "turn-in id preserved")


func test_rejected_talk_yields_empty_model() -> void:
	var model = TalkActions.prompt_model({"ok": false, "reason": "too_far", "available": ["q007"]})
	assert_eq(model.size(), 0, "ok=false → nothing to prompt (server rejected on proximity)")


func test_nothing_offered_yields_empty_model() -> void:
	var model = TalkActions.prompt_model({"ok": true, "offers": [], "available": []})
	assert_eq(model.size(), 0, "no offers and no ids → no prompt")
