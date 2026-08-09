extends GutTest

# T-519: the quest-giver prompt renders the server offers and its buttons emit the accept/turn_in
# metas (main.gd turns those into the server-authoritative intents).

const QuestOfferPanel = preload("res://scripts/ui/quest_offer_panel.gd")


func _panel() -> QuestOfferPanel:
	var p = QuestOfferPanel.new()
	add_child_autofree(p)
	return p


func test_open_renders_offer_and_turn_in_cards() -> void:
	var p := _panel()
	var offers := [
		{
			"kind": "offer",
			"quest_id": "q007",
			"title": "A Wolf Problem",
			"objectives": [{"desc": "Slay 5 wolves", "required": 5}],
			"xp": 50,
			"coins": 10,
		},
		{"kind": "turn_in", "quest_id": "q003", "title": "Report Back", "objectives": [], "xp": 0},
	]
	p.open("hale", "Drillmaster Hale", "Well met, recruit.", offers)
	assert_true(p.is_open(), "prompt opens on a quest-giver talk")
	assert_eq(p.get_offer_count(), 2, "one offer + one turn-in → two action buttons")
	assert_eq(
		p.get_action_metas(), ["accept|q007", "turn_in|q003"], "metas carry the intent + quest id"
	)
	assert_string_contains(p.get_text(), "A Wolf Problem", "offer title rendered")
	assert_string_contains(p.get_text(), "Slay 5 wolves", "objective rendered")


func test_button_emits_accept_meta_and_closes() -> void:
	var p := _panel()
	watch_signals(p)
	p.open(
		"hale",
		"Drillmaster Hale",
		"",
		[{"kind": "offer", "quest_id": "q007", "title": "A Wolf Problem", "objectives": []}]
	)
	# Drive the Accept button by locating it in the tree and pressing it.
	var btn := _find_button(p, "Accept")
	assert_not_null(btn, "an Accept button exists")
	btn.emit_signal("pressed")
	assert_signal_emitted_with_parameters(p, "action_selected", ["accept|q007"])
	assert_false(p.is_open(), "choosing an action closes the prompt")


func _find_button(node: Node, label: String) -> Button:
	if node is Button and (node as Button).text == label:
		return node
	for child in node.get_children():
		var found := _find_button(child, label)
		if found != null:
			return found
	return null
