extends "res://addons/gut/test.gd"

# T-713: the graduation beat. Nothing in the first 15 minutes revealed a long-term goal — the era
# ladder was unmentioned and the Hollowing was first named at L15 — so Hale's q_tut_03 TURN-IN
# dialog now carries the stakes, and the q010 Highkeep breadcrumb has to be findable from the
# training yard the moment he points at it.

const ContentRegistry = preload("res://scripts/content/content_registry.gd")
const _CQ = preload("res://scripts/content/content_query.gd")

const GRADUATION := "q_tut_03"
const HALE := [12.5, 9.0]  # npcs.json anchor (the training yard)
const MARKER_HORIZON_M := 55.0  # client NameplateLod.MARKER_FADE_END — past this, no marker at all

var _quests: Dictionary = {}
var _npcs: Dictionary = {}


func before_all() -> void:
	var loaded: Dictionary = ContentRegistry.load_all("res://data")
	_quests = loaded.get("quests", {})
	_npcs = loaded.get("npcs", {})


# ---- 1. the stakes lines --------------------------------------------------------------------


func test_graduation_turn_in_points_south_to_highkeep() -> void:
	var text: String = str(_quests[GRADUATION].turnin_text)
	assert_ne(text, "", "the graduation turn-in must say something beyond 'well done'")
	assert_true(text.to_lower().contains("south"), "it points a direction")
	assert_true(text.contains("Highkeep"), "and names the capital as the next destination")


# The Hollowing tease has to match shipped canon (Father Osric, the churchyard/crypt, the dead
# not staying down) — an invented detail would contradict q_hollowing_creep / q_crypt_restless_dead.
func test_graduation_turn_in_teases_the_hollowing_within_canon() -> void:
	var text: String = str(_quests[GRADUATION].turnin_text)
	assert_true(text.contains("Hollowing"), "the era-1 antagonist is named for the first time")
	assert_true(text.contains("Osric"), "attributed to the parson who actually owns that thread")
	assert_true(_quests.has("q_hollowing_creep"), "and that thread really ships")


# The line rides the TURN-IN card only; the offer card keeps the quest description it always had.
func test_turnin_text_reaches_the_turn_in_card_and_not_the_offer_card() -> void:
	var turn_in: Array = _CQ.talk_previews([], [GRADUATION], _quests)
	assert_eq(turn_in.size(), 1)
	assert_string_contains(str(turn_in[0]["turnin_text"]), "Highkeep")
	var offer: Array = _CQ.talk_previews([GRADUATION], [], _quests)
	assert_eq(str(offer[0]["turnin_text"]), "", "an offer card is untouched")


func test_quests_without_a_turnin_line_stay_empty_not_broken() -> void:
	var previews: Array = _CQ.talk_previews([], ["q010"], _quests)
	assert_eq(str(previews[0]["turnin_text"]), "", "opt-in field; every other quest is unchanged")


# ---- 2. the q010 breadcrumb is findable from the yard ---------------------------------------


# Hale points at "the Regent's courier by the well" — if Edric's ! isn't visible from where the
# player is standing when he says it, the beat dead-ends.
func test_edric_carries_q010_and_stands_inside_the_marker_horizon_of_hale() -> void:
	var edric = _npcs["npc_regents_courier"]
	assert_true("q010" in edric.gives_quests, "the Highkeep breadcrumb giver")
	var distance := Vector2(HALE[0], HALE[1]).distance_to(Vector2(edric.x, edric.y))
	assert_lt(
		distance,
		MARKER_HORIZON_M,
		"Edric must be inside the client marker horizon from the training yard (%.1fm)" % distance
	)


# ...and the marker must actually be a gold "!" for a fresh graduate: q010 has no prerequisite and
# min_level 1, so nothing gates it behind the tutorial.
func test_q010_shows_a_gold_marker_for_a_fresh_graduate() -> void:
	var index: Dictionary = {"npc_regents_courier": {"q010": _CQ.quest_to_dict(_quests["q010"])}}
	var states: Array = [{"quest_id": GRADUATION, "state": "complete", "progress": [1]}]
	var indicators: Dictionary = _CQ.npc_indicators_from_state(_npcs, index, states, 2)
	assert_eq(str(indicators["npc_regents_courier"]), "!", "available the moment training ends")


func test_q010_needs_no_tutorial_prerequisite_or_level() -> void:
	assert_eq(str(_quests["q010"].prerequisite_quest), "", "no chain gate")
	assert_eq(int(_quests["q010"].min_level), 1, "no level gate")
