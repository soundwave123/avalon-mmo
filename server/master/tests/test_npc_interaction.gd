extends "res://addons/gut/test.gd"
# T-037: Pure NPC indicator + talk-plan logic.

const NI = preload("res://scripts/npc_interaction.gd")

const NPC_GELD := {
	"id": "npc_farmer_geld",
	"gives_quests": ["q001"],
	"talk_text": "Those wolves will be the end of me, friend.",
}


func _q001(turnin: String = "npc_farmer_geld") -> Dictionary:
	return {
		"id": "q001",
		"min_level": 1,
		"prerequisite_quest": "",
		"giver_npc": "npc_farmer_geld",
		"turnin_npc": turnin,
		"objectives": [{"type": "kill", "target": "mob_wolf", "count": 1}],
		"rewards": {"xp": 100, "items": []},
	}


func _facts(state: String, level: int, prereq: bool, objs_done: bool) -> Dictionary:
	return {
		"state": state,
		"player_level": level,
		"prereq_complete": prereq,
		"objectives_complete": objs_done,
	}


func test_available_quest_shows_bang() -> void:
	var defs := {"q001": _q001()}
	var facts := {"q001": _facts("", 5, true, false)}
	var r := NI.evaluate(NPC_GELD, defs, facts)
	assert_eq(r["indicator"], "!")
	assert_true(r["available"].has("q001"))


func test_complete_quest_shows_gold_question() -> void:  # T-056
	var defs := {"q001": _q001()}
	var facts := {"q001": _facts("active", 5, true, true)}  # objectives done
	var r := NI.evaluate(NPC_GELD, defs, facts)
	assert_eq(r["indicator"], "?", "objectives done → gold ? (ready to turn in)")
	assert_true(r["turn_in_ready"].has("q001"))


func test_level_too_low_not_available() -> void:
	var defs := {"q001": _q001()}
	defs["q001"]["min_level"] = 5
	var facts := {"q001": _facts("", 1, true, false)}
	var r := NI.evaluate(NPC_GELD, defs, facts)
	assert_false(r["available"].has("q001"))
	assert_eq(r["indicator"], "")


func test_tutorial_stays_offerable_regardless_of_account_graduation() -> void:
	# T-550: the tutorial auto-skip for alts is an ACCOUNT-level graduation flag; it never touches
	# Hale's OFFER. Indicator/availability depend only on the per-character quest state, so an alt on
	# a graduated account can always still pick the chain up by choice (it is offered, not forced).
	var hale := {"id": "npc_drillmaster", "gives_quests": ["q_tut_01"], "talk_text": ""}
	var q_tut := _q001("npc_drillmaster")
	q_tut["id"] = "q_tut_01"
	q_tut["giver_npc"] = "npc_drillmaster"
	var defs := {"q_tut_01": q_tut}
	var facts := {"q_tut_01": _facts("", 1, true, false)}  # fresh alt: never started this quest
	var r := NI.evaluate(hale, defs, facts)
	assert_true(r["available"].has("q_tut_01"), "the tutorial is still OFFERED to a fresh alt")
	assert_eq(r["indicator"], "!", "Hale still shows the gold ! — offer, not force")


func test_turn_in_ready_shows_question() -> void:
	var defs := {"q001": _q001()}
	var facts := {"q001": _facts("active", 5, true, true)}
	var r := NI.evaluate(NPC_GELD, defs, facts)
	assert_eq(r["indicator"], "?")
	assert_true(r["turn_in_ready"].has("q001"))


func test_question_outranks_bang() -> void:
	# Geld gives q002 (acceptable) and is the turn-in point of q001 (active + complete).
	var npc := {"id": "npc_farmer_geld", "gives_quests": ["q002"], "talk_text": ""}
	var q002 := _q001()
	q002["id"] = "q002"
	var defs := {"q001": _q001(), "q002": q002}
	var facts := {
		"q001": _facts("active", 5, true, true),  # turn-in ready
		"q002": _facts("", 5, true, false),  # acceptable
	}
	var r := NI.evaluate(npc, defs, facts)
	assert_eq(r["indicator"], "?")
	assert_true(r["available"].has("q002"))
	assert_true(r["turn_in_ready"].has("q001"))


func test_active_incomplete_shows_grey_question() -> void:  # T-056: was "nothing", now grey ?
	var defs := {"q001": _q001()}
	var facts := {"q001": _facts("active", 5, true, false)}
	var r := NI.evaluate(NPC_GELD, defs, facts)
	assert_eq(r["indicator"], "?grey", "have it, not ready → grey ? (find where to hand in)")
	assert_false(r["available"].has("q001"))
	assert_false(r["turn_in_ready"].has("q001"))
	assert_true(r["turn_in_active"].has("q001"))


func test_talk_targets_lists_active_talk_objectives() -> void:
	var mira := {"id": "npc_scout_mira", "gives_quests": [], "talk_text": "north treeline"}
	var q003 := {
		"id": "q003",
		"min_level": 1,
		"prerequisite_quest": "",
		"giver_npc": "npc_farmer_geld",
		"turnin_npc": "npc_farmer_geld",
		"objectives": [{"type": "talk", "target": "npc_scout_mira", "count": 1}],
		"rewards": {"xp": 10, "items": []},
	}
	var defs := {"q003": q003}
	var active := {"q003": _facts("active", 5, true, false)}
	assert_true(NI.evaluate(mira, defs, active)["talk_targets"].has("q003"))
	# not active → no talk target
	var inactive := {"q003": _facts("", 5, true, false)}
	assert_false(NI.evaluate(mira, defs, inactive)["talk_targets"].has("q003"))


func test_inputs_not_mutated() -> void:
	var defs := {"q001": _q001()}
	var facts := {"q001": _facts("", 5, true, false)}
	NI.evaluate(NPC_GELD, defs, facts)
	assert_eq(NPC_GELD["gives_quests"].size(), 1)
	assert_eq(defs["q001"]["objectives"].size(), 1)
	assert_eq(facts["q001"]["state"], "")


# T-621: silver "!future" — a quest gated ONLY by level, and within SILVER_MARKER_RANGE levels, is a
# visible promise (the player can see where their next quests come from before they can take them).
func test_silver_future_marker_within_range() -> void:
	var q := _q001()
	q["min_level"] = 8
	var defs := {"q001": q}
	# Player L6, quest L8 -> gap 2 (<= 3), prereq clear, only the level gate stands: silver !.
	var soon := {"q001": _facts("", 6, true, false)}
	var r := NI.evaluate(NPC_GELD, defs, soon)
	assert_eq(r["indicator"], "!future", "level-gated but within reach = silver !")
	assert_true(r["available_soon"].has("q001"))


func test_no_silver_marker_when_too_far_out() -> void:
	var q := _q001()
	q["min_level"] = 20
	var defs := {"q001": q}
	var faraway := {"q001": _facts("", 6, true, false)}  # gap 14 -> no promise yet
	assert_eq(NI.evaluate(NPC_GELD, defs, faraway)["indicator"], "")


func test_silver_marker_needs_prereq_clear() -> void:
	var q := _q001()
	q["min_level"] = 8
	q["prerequisite_quest"] = "q000"
	var defs := {"q001": q}
	var blocked := {"q001": _facts("", 6, false, false)}  # prereq wall, not just a level gap
	assert_eq(NI.evaluate(NPC_GELD, defs, blocked)["indicator"], "")


func test_gold_bang_outranks_silver() -> void:
	# A takeable quest AND a soon-available one on the same NPC: gold ! wins.
	var q_now := _q001()
	var q_soon := _q001()
	q_soon["id"] = "q001b"
	q_soon["min_level"] = 8
	var npc := {"id": "npc_farmer_geld", "gives_quests": ["q001", "q001b"], "talk_text": ""}
	var defs := {"q001": q_now, "q001b": q_soon}
	var facts := {"q001": _facts("", 6, true, false), "q001b": _facts("", 6, true, false)}
	assert_eq(NI.evaluate(npc, defs, facts)["indicator"], "!", "gold ! outranks silver !future")
