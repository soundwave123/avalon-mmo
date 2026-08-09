# T-024: Threat table unit tests — pure data structure, no network, no engine loop.
# Tests ThreatTable directly with preload + .new() (parse-gate compat).
# GUT 9.6.0 — int != float, store threat as int consistently.

extends GutTest

const _TT = preload("res://scripts/combat/threat_table.gd")


func _make_table():
	return _TT.new()


# --- Helper: simulate ability_executor threat generation ---


func _simulate_threat_gen(
	table, target_id: int, caster_id: int, damage_amount: int, threat_multiplier: float
) -> int:
	var raw = float(damage_amount) * threat_multiplier
	var threat: int = int(raw)
	table.add_threat(target_id, caster_id, threat)
	return threat


# --- Tests ---


func test_01_add_and_get_threat():
	var table = _make_table()
	table.add_threat(1, 10, 50)
	assert_eq(table.get_threat(1, 10), 50)


func test_02_cumulative_threat():
	var table = _make_table()
	table.add_threat(1, 10, 50)
	table.add_threat(1, 10, 30)
	assert_eq(table.get_threat(1, 10), 80)


func test_get_attackers_returns_all_damagers():
	# T-034: kill credit = everyone with threat on the mob.
	var table = _make_table()
	table.add_threat(1, 10, 50)
	table.add_threat(1, 20, 30)
	var attackers = table.get_attackers(1)
	assert_eq(attackers.size(), 2)
	assert_true(attackers.has(10) and attackers.has(20))


func test_get_attackers_empty_for_unknown_mob():
	var table = _make_table()
	assert_eq(table.get_attackers(999), [])


func test_03_top_threat_two_attackers():
	var table = _make_table()
	table.add_threat(1, 10, 100)
	table.add_threat(1, 11, 200)
	assert_eq(table.get_top_threat_target(1), 11)


func test_04_clear_mob_returns_empty():
	var table = _make_table()
	table.add_threat(1, 10, 100)
	table.add_threat(1, 11, 200)
	table.clear_mob(1)
	assert_eq(table.get_top_threat_target(1), -1)


func test_05_remove_attacker_promotes_next():
	var table = _make_table()
	table.add_threat(1, 10, 50)
	table.add_threat(1, 11, 200)
	table.remove_attacker(1, 10)
	assert_eq(table.get_top_threat_target(1), 11)


func test_06_empty_table_returns_minus_one():
	var table = _make_table()
	assert_eq(table.get_top_threat_target(99), -1)


func test_07_threat_multiplier_doubles_threat():
	var table = _make_table()
	var generated = _simulate_threat_gen(table, 1, 10, 50, 2.0)
	assert_eq(generated, 100, "damage 50 * multiplier 2.0 = 100 threat")
	assert_eq(table.get_threat(1, 10), 100)


func test_08_separate_mob_tables():
	var table = _make_table()
	table.add_threat(1, 10, 300)
	table.add_threat(1, 11, 50)
	table.add_threat(2, 10, 100)
	table.add_threat(2, 11, 250)
	assert_eq(table.get_top_threat_target(1), 10, "mob 1 top = attacker 10 (300 > 50)")
	assert_eq(table.get_top_threat_target(2), 11, "mob 2 top = attacker 11 (250 > 100)")


func test_09_remove_attacker_mob_a_does_not_affect_mob_b():
	var table = _make_table()
	table.add_threat(1, 10, 300)
	table.add_threat(2, 10, 100)
	table.remove_attacker(1, 10)
	assert_eq(table.get_top_threat_target(1), -1, "mob 1 empty after removal")
	assert_eq(table.get_threat(2, 10), 100, "mob 2 unaffected")


func test_10_clear_mob_a_does_not_affect_mob_b():
	var table = _make_table()
	table.add_threat(1, 10, 300)
	table.add_threat(2, 10, 100)
	table.clear_mob(1)
	assert_eq(table.get_top_threat_target(1), -1, "mob 1 cleared")
	assert_eq(table.get_threat(2, 10), 100, "mob 2 unaffected")


func test_11_remove_attacker_everywhere_on_disconnect():
	# T-051: a disconnected peer must be dropped from EVERY mob's threat (no ghost kill-credit/aggro).
	var table = _make_table()
	table.add_threat(1001, 5, 100)
	table.add_threat(1002, 5, 50)
	table.add_threat(1001, 6, 20)
	table.remove_attacker_everywhere(5)
	assert_false(table.get_attackers(1001).has(5), "attacker 5 gone from mob 1001")
	assert_false(table.get_attackers(1002).has(5), "attacker 5 gone from mob 1002")
	assert_true(table.get_attackers(1001).has(6), "other attacker untouched")


# T-063: taunt — force the taunter to the top of a mob's threat.


func test_taunt_forces_top_threat() -> void:
	var tt := ThreatTable.new()
	tt.add_threat(1, 10, 500)  # player 10 holds 500 threat (top)
	tt.add_threat(1, 20, 100)  # player 20 holds 100
	tt.taunt(1, 20)  # player 20 taunts
	assert_eq(tt.get_top_threat_target(1), 20, "taunter becomes top threat")
	assert_gt(tt.get_threat(1, 20), tt.get_threat(1, 10), "taunter now exceeds the old top")


func test_taunt_noop_when_already_top() -> void:
	var tt := ThreatTable.new()
	tt.add_threat(1, 10, 500)
	tt.taunt(1, 10)
	assert_eq(tt.get_threat(1, 10), 500, "no extra threat when already top")
