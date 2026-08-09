extends GutTest

# T-367: the pure achievement-progress evaluator — completion is DERIVED from counters, fires
# exactly once, and definitions are data-only (these tests feed arbitrary def arrays, no code path
# is achievement-specific).

const _AP = preload("res://scripts/achievement_progress.gd")

const _DEFS := [
	{"id": "first_blood", "criteria": {"event": "kill", "key": "*", "count": 1}},
	{"id": "slayer", "criteria": {"event": "kill", "key": "*", "count": 3}},
	{"id": "wolfbane", "criteria": {"event": "kill", "key": "wolf", "count": 2}},
	{"id": "apprentice", "criteria": {"event": "level", "key": "*", "count": 5}},
	{"id": "delver", "criteria": {"event": "reach", "key": "crypt", "count": 1}},
	{"id": "wayfarer", "criteria": {"event": "discovery", "key": "*", "count": 2}},
	{"id": "quester", "criteria": {"event": "quest", "key": "*", "count": 1}},
]


func _empty() -> Dictionary:
	return {"counters": {}, "earned": []}


func test_kill_advances_and_earns_threshold() -> void:
	var s := _AP.apply(_DEFS, _empty(), "kill", "wolf")
	assert_eq(s["newly_earned"], ["first_blood"], "one kill clears first_blood only")
	assert_eq(int(s["counters"]["kill:*"]), 1)
	assert_eq(
		int(s["counters"]["kill:wolf"]), 1, "specific-mob counter tracked alongside the total"
	)
	s = _AP.apply(_DEFS, s, "kill", "wolf")
	assert_eq(s["newly_earned"], ["wolfbane"], "second wolf clears the wolf-specific def")


func test_inputs_are_not_mutated() -> void:
	var start := _empty()
	_AP.apply(_DEFS, start, "kill", "wolf")
	assert_eq(start["counters"].size(), 0, "apply must not mutate the caller's state")


func test_completion_fires_exactly_once() -> void:
	var s := _AP.apply(_DEFS, _empty(), "kill", "rat")
	assert_true(s["earned"].has("first_blood"))
	# Re-counting more kills advances the counter but never re-earns first_blood.
	s = _AP.apply(_DEFS, s, "kill", "rat")
	s = _AP.apply(_DEFS, s, "kill", "rat")
	assert_false(s["newly_earned"].has("first_blood"), "an earned achievement never fires again")
	assert_true(s["newly_earned"].has("slayer"), "3rd kill clears slayer once")
	assert_eq(int(s["counters"]["kill:*"]), 3)


func test_reach_and_quest_are_idempotent_flags() -> void:
	var s := _AP.apply(_DEFS, _empty(), "reach", "crypt")
	assert_eq(s["newly_earned"], ["delver"])
	s = _AP.apply(_DEFS, s, "reach", "crypt")
	assert_eq(
		int(s["counters"]["reach:*"]), 1, "re-entering a discovered target does not re-advance"
	)
	s = _AP.apply(_DEFS, s, "quest", "q1")
	assert_eq(s["newly_earned"], ["quester"])


func test_discovery_counts_unique_nodes_only() -> void:
	var s := _AP.apply(_DEFS, _empty(), "discovery", "churchyard")
	s = _AP.apply(_DEFS, s, "discovery", "churchyard")
	assert_eq(int(s["counters"]["discovery:*"]), 1, "re-entry never advances the collection")
	s = _AP.apply(_DEFS, s, "discovery", "ashmoor_plaza")
	assert_true(s["newly_earned"].has("wayfarer"), "a second unique landmark completes the def")


func test_level_is_monotonic_max() -> void:
	var s := _AP.apply(_DEFS, _empty(), "level", "*", 5)
	assert_eq(s["newly_earned"], ["apprentice"])
	s = _AP.apply(_DEFS, s, "level", "*", 3)  # a stale/lower level never lowers the counter
	assert_eq(int(s["counters"]["level"]), 5)


func test_fraction_reports_progress() -> void:
	var s := _AP.apply(_DEFS, _empty(), "kill", "rat")
	assert_almost_eq(_AP.fraction(_DEFS[1]["criteria"], s["counters"]), 1.0 / 3.0, 0.01)
	assert_eq(_AP.fraction(_DEFS[0]["criteria"], s["counters"]), 1.0, "capped at 1.0 once cleared")
