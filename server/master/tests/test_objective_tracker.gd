extends "res://addons/gut/test.gd"
# T-034: Pure objective tracker — match / increment-cap / collect-snapshot / is_complete.

const OT = preload("res://scripts/objective_tracker.gd")


func _objs() -> Array:
	return [
		{"type": "kill", "target": "mob_wolf", "count": 3},
		{"type": "collect", "target": "itm_pelt", "count": 5},
		{"type": "talk", "target": "npc_mira", "count": 1},
	]


func test_zeros() -> void:
	assert_eq(OT.zeros(_objs()), [0, 0, 0])


func test_credit_event_matches() -> void:
	var p = OT.credit_event(_objs(), OT.zeros(_objs()), "kill", "mob_wolf")
	assert_eq(p[0], 1)
	assert_eq(p[1], 0)


func test_credit_event_non_matching_target_noop() -> void:
	var p = OT.credit_event(_objs(), OT.zeros(_objs()), "kill", "mob_bear")
	assert_eq(p, [0, 0, 0])


func test_credit_event_wrong_type_noop() -> void:
	var p = OT.credit_event(_objs(), OT.zeros(_objs()), "collect", "mob_wolf")
	assert_eq(p, [0, 0, 0])


# T-426: a "*" target matches any event target of the same kind (the "use any ability" tutorial verb).
func test_credit_event_wildcard_target_matches_any() -> void:
	var objs := [{"type": "use_ability", "target": "*", "count": 1}]
	assert_eq(OT.credit_event(objs, OT.zeros(objs), "use_ability", "fireball"), [1])
	assert_eq(OT.credit_event(objs, OT.zeros(objs), "use_ability", "heroic_strike"), [1])
	# wrong kind still no-ops
	assert_eq(OT.credit_event(objs, OT.zeros(objs), "kill", "fireball"), [0])


func test_target_matches_helper() -> void:
	assert_true(OT.target_matches("*", "anything"))
	assert_true(OT.target_matches("fireball", "fireball"))
	assert_false(OT.target_matches("fireball", "frostbolt"))


func test_credit_event_caps_at_count() -> void:
	var p = OT.zeros(_objs())
	for i in range(10):
		p = OT.credit_event(_objs(), p, "kill", "mob_wolf")
	assert_eq(p[0], 3)


func test_apply_collect_snapshot_and_cap() -> void:
	var p = OT.apply_collect(_objs(), OT.zeros(_objs()), {"itm_pelt": 2})
	assert_eq(p[1], 2)
	p = OT.apply_collect(_objs(), p, {"itm_pelt": 7})
	assert_eq(p[1], 5)


func test_apply_collect_can_decrease() -> void:
	var p = OT.apply_collect(_objs(), OT.zeros(_objs()), {"itm_pelt": 5})
	assert_eq(p[1], 5)
	p = OT.apply_collect(_objs(), p, {"itm_pelt": 2})
	assert_eq(p[1], 2)


func test_is_complete_false_when_short() -> void:
	assert_false(OT.is_complete(_objs(), [3, 5, 0]))


func test_is_complete_true_when_all_met() -> void:
	assert_true(OT.is_complete(_objs(), [3, 5, 1]))


func test_input_progress_not_mutated() -> void:
	var p = OT.zeros(_objs())
	var p2 = OT.credit_event(_objs(), p, "kill", "mob_wolf")
	assert_eq(p[0], 0)
	assert_eq(p2[0], 1)
