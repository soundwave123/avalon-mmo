extends "res://addons/gut/test.gd"
# T-621: content_query wiring for the difficulty band (enrich_quest_log) + the silver "!future"
# marker (npc_indicators_from_state). The band MATH itself lives in test_quest_difficulty.gd; this
# proves the view-model + marker paths attach it. Loads the real seed content for the enrich case.

const CQ = preload("res://scripts/content/content_query.gd")
const _CONTENT = preload("res://scripts/content/content_registry.gd")

var _q: Dictionary


func before_each() -> void:
	var loaded := _CONTENT.load_all("res://data")
	assert_eq(loaded["errors"], [], "real seed content loads with no errors")
	_q = loaded["quests"]


# T-621: enrich attaches the difficulty band + quest_level so the client log/tracker paint the band.
func test_enrich_quest_log_attaches_difficulty_band() -> void:
	var raw := [{"quest_id": "q001", "state": "active", "progress": [0, 0, 0, 0]}]
	var at_level: Array = CQ.enrich_quest_log(raw, _q, 1)
	assert_eq(
		int(at_level[0]["quest_level"]), int(_q["q001"].min_level), "quest_level == min_level"
	)
	assert_eq(at_level[0]["difficulty"], "yellow", "an at-level quest is yellow")
	var out_levelled: Array = CQ.enrich_quest_log(raw, _q, 40)
	assert_eq(out_levelled[0]["difficulty"], "grey", "a wildly out-levelled quest reads grey")


func test_enrich_quest_log_defaults_to_level_one() -> void:
	# Back-compat: the char_level arg defaults to 1 (a q001 min_level-1 quest reads yellow at L1).
	var raw := [{"quest_id": "q001", "state": "active", "progress": []}]
	var enriched: Array = CQ.enrich_quest_log(raw, _q)
	assert_true(enriched[0].has("difficulty"), "difficulty always present in the view-model")


# T-621: silver "!future" — a level-gated quest within reach shows as a visible promise.
func test_npc_indicators_silver_future_marker() -> void:
	var npcs := {"giver": {"id": "giver", "gives_quests": ["q"]}}
	var quest := {
		"id": "q",
		"min_level": 8,
		"prerequisite_quest": "",
		"giver_npc": "giver",
		"turnin_npc": "giver",
		"objectives": [{"type": "kill", "target": "wolf", "count": 1}],
	}
	var index := {"giver": {"q": quest}}
	var soon: Dictionary = CQ.npc_indicators_from_state(npcs, index, [], 6)  # gap 2
	assert_eq(soon["giver"], "!future", "level-gated but within reach = silver !")
	var takeable: Dictionary = CQ.npc_indicators_from_state(npcs, index, [], 8)  # now eligible
	assert_eq(takeable["giver"], "!", "at the level gate it becomes a gold !")
	var faraway: Dictionary = CQ.npc_indicators_from_state(npcs, index, [], 2)  # gap 6
	assert_eq(faraway["giver"], "", "too far below the gate = no promise yet")
