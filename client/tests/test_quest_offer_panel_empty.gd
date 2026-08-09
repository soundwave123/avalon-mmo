extends "res://addons/gut/test.gd"
# T-647: Quest offer panel must close when a new talk_result with empty offers is received.
# This prevents the stale panel from occluding a new NPC's real offers.

var _panel: QuestOfferPanel = null
var _mock_net: Node = null


func before_each() -> void:
	_panel = QuestOfferPanel.new()
	add_child(_panel)

	# Mock net provider
	_mock_net = Node.new()
	_panel._net_provider = func(): return _mock_net
	await get_tree().process_frame


func after_each() -> void:
	_panel.queue_free()
	_mock_net.queue_free()


# ---- Assertion 1: Empty offers close the panel --------


func test_empty_offers_close_panel() -> void:
	# T-647: If handle_talk_result receives a talk_result with no offers,
	# the panel should close (visible = false).

	# First, open the panel with some offers
	var talk_result_a := {
		"npc_id": "npc_quest_giver_a",
		"name": "Quest Giver A",
		"talk_text": "I have a quest for you.",
		"ok": true,
		"offers":
		[
			{
				"quest_id": "q001",
				"kind": "offer",
				"title": "Collect 5 mushrooms",
				"objectives": [],
				"xp": 100,
				"coins": 50,
			}
		],
	}
	_panel.handle_talk_result(talk_result_a)
	assert_true(_panel.visible, "Panel should be visible after receiving offers")

	# Now receive a talk_result with no offers (completed all quests with this NPC)
	var talk_result_b := {
		"npc_id": "npc_quest_giver_b",
		"name": "Quest Giver B",
		"talk_text": "You've already completed all my quests.",
		"ok": true,
		"offers": [],  # Empty!
	}
	_panel.handle_talk_result(talk_result_b)
	assert_false(_panel.visible, "Panel should be hidden when offers are empty")


# ---- Assertion 2: Non-empty offers reopen the panel --------


func test_non_empty_offers_reopen_panel() -> void:
	# T-647: After closing due to empty offers, non-empty offers should reopen the panel.

	# Close the panel with empty offers
	var talk_result_empty := {
		"npc_id": "npc_quest_giver_a",
		"name": "Quest Giver A",
		"talk_text": "You've completed my quests.",
		"ok": true,
		"offers": [],
	}
	_panel.handle_talk_result(talk_result_empty)
	assert_false(_panel.visible, "Panel should be closed")

	# Now receive offers from a different NPC
	var talk_result_with_offers := {
		"npc_id": "npc_quest_giver_b",
		"name": "Quest Giver B",
		"talk_text": "New quest for you!",
		"ok": true,
		"offers":
		[
			{
				"quest_id": "q002",
				"kind": "offer",
				"title": "Slay 3 wolves",
				"objectives": [],
				"xp": 200,
				"coins": 100,
			}
		],
	}
	_panel.handle_talk_result(talk_result_with_offers)
	assert_true(_panel.visible, "Panel should reopen with new offers")
	# Verify it's the new NPC's content, not a stale previous one
	assert_true(
		_panel._title.text.contains("Quest Giver B"),
		"Panel should show the new NPC's name, not a stale one"
	)


# ---- Assertion 3: Trainer/service NPCs don't affect the panel --------


func test_trainer_talk_result_ignored() -> void:
	# T-647: Non-quest-giver talk_results (trainer=true, service != "") should return false
	# and not affect the panel's visibility.

	# Open with a regular quest offer
	var quest_talk := {
		"npc_id": "npc_quest_a",
		"name": "Quest Giver",
		"talk_text": "Quest for you.",
		"ok": true,
		"offers":
		[
			{
				"quest_id": "q001",
				"kind": "offer",
				"title": "Collect 5 mushrooms",
				"objectives": [],
				"xp": 100,
				"coins": 50,
			}
		],
	}
	_panel.handle_talk_result(quest_talk)
	assert_true(_panel.visible, "Panel should be open with quest offers")

	# Now receive a trainer talk_result (should not affect the panel)
	var trainer_talk := {
		"npc_id": "npc_trainer",
		"name": "Trainer",
		"talk_text": "Learn skills here.",
		"ok": true,
		"trainer": true,
		"offers": [],
	}
	_panel.handle_talk_result(trainer_talk)
	assert_true(_panel.visible, "Panel should still be open (trainer talk ignored)")

	# And a service talk_result (should not affect the panel)
	var service_talk := {
		"npc_id": "npc_vendor",
		"name": "Vendor",
		"talk_text": "Browse my wares.",
		"ok": true,
		"service": "vendor",
		"offers": [],
	}
	_panel.handle_talk_result(service_talk)
	assert_true(_panel.visible, "Panel should still be open (service talk ignored)")
