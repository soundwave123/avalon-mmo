extends "res://addons/gut/test.gd"
# T-519: content_query.talk_previews builds the offer/turn-in cards the client's quest-prompt draws
# on a talk_result. Over the real seed content (same load idiom as test_world_content.gd).

const CQ = preload("res://scripts/content/content_query.gd")
const _CONTENT = preload("res://scripts/content/content_registry.gd")

var _q: Dictionary  # quests


func before_each() -> void:
	var loaded := _CONTENT.load_all("res://data")
	assert_eq(loaded["errors"], [], "real seed content loads with no errors")
	_q = loaded["quests"]


func test_talk_previews_builds_offer_and_turn_in_cards() -> void:
	var previews: Array = CQ.talk_previews(["q001"], ["q002"], _q)
	assert_eq(previews.size(), 2, "one available + one ready → two cards")
	assert_eq(str(previews[0]["kind"]), "offer", "available quest → offer card")
	assert_eq(str(previews[0]["quest_id"]), "q001")
	assert_eq(str(previews[0]["title"]), "Cull the Wolves", "title pulled from content")
	assert_true(previews[0]["objectives"].size() > 0, "objectives carried for the prompt")
	assert_true(previews[0]["objectives"][0].has("desc"), "objective desc present")
	assert_true(previews[0]["objectives"][0].has("required"), "objective required count present")
	assert_eq(str(previews[1]["kind"]), "turn_in", "ready quest → turn_in card")


func test_talk_previews_unknown_quest_falls_back_to_id() -> void:
	var previews: Array = CQ.talk_previews(["q999"], [], {})
	assert_eq(str(previews[0]["title"]), "q999", "unknown quest → id as title")
	assert_eq(previews[0]["objectives"], [], "unknown quest → no objectives")


func test_retired_quest_never_renders_an_offer_card_but_still_turns_in() -> void:
	# T-707: q007 is retired — even a stale gives_quests listing must not produce an offer card;
	# a mid-quest character's turn-in card is unaffected (the JSON stays loadable).
	assert_true(_q["q007"].retired, "q007 ships retired")
	var offers: Array = CQ.talk_previews(["q007", "q001"], [], _q)
	assert_eq(offers.size(), 1, "the retired quest is filtered from the offer list")
	assert_eq(str(offers[0]["quest_id"]), "q001")
	var turn_ins: Array = CQ.talk_previews([], ["q007"], _q)
	assert_eq(turn_ins.size(), 1, "a mid-quest character still gets the q007 turn-in card")
	assert_eq(str(turn_ins[0]["kind"]), "turn_in")
