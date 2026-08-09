extends "res://addons/gut/test.gd"
# T-429: pure personal-recap aggregation over server-truth combat events.

const Recap = preload("res://scripts/combat/performance_recap.gd")


func _hit(caster: int, target: int, amount: int = 30) -> Dictionary:
	return {
		"type": "ability_result",
		"ability_id": 101,
		"ability_name": "Heroic Strike",
		"caster_id": caster,
		"target_id": target,
		"damage": amount,
		"outcome": "hit",
		"mitigated": 8,
		"interrupt_landed": true,
		"tick": 110,
	}


func _heal(caster: int, target: int, amount: int = 18) -> Dictionary:
	return {
		"type": "ability_result",
		"ability_id": 301,
		"ability_name": "Mend",
		"caster_id": caster,
		"target_id": target,
		"damage": amount,
		"outcome": "heal",
		"mitigated": 0,
		"interrupt_landed": false,
		"tick": 115,
	}


func _damage_event(
	caster: int, target: int, amount: int, event_type: String = "damage"
) -> Dictionary:
	return {
		"type": event_type,
		"caster_id": caster,
		"target_id": target,
		"damage": amount,
		"outcome": "hit",
		"mitigated": 3,
		"tick": 118,
	}


func test_aggregates_private_done_taken_and_ability_breakdown() -> void:
	var own: Dictionary = Recap.blank(100)
	own = Recap.apply_event(own, _hit(7, 9001), 7)
	own = Recap.apply_event(own, _heal(7, 7), 7)
	own = Recap.apply_event(own, {"type": "player_death", "target_id": 7, "tick": 130}, 7)
	var recap: Dictionary = Recap.finalize(own, "wolf", "Wolf", 140, 20, [])

	assert_eq(recap["damage_done"], 30)
	assert_eq(recap["damage_taken"], 0)
	assert_eq(recap["healing_done"], 18)
	assert_eq(recap["healing_taken"], 18)
	assert_eq(recap["mitigation"], 0, "mitigation belongs to the defender, never the attacker")
	assert_eq(recap["interrupts"], 1)
	assert_eq(recap["deaths"], 1)
	assert_eq(recap["duration_s"], 2.0)
	assert_eq(recap["dps"], 15.0)
	assert_eq(recap["hps"], 9.0)
	assert_eq(recap["abilities"].size(), 2)
	assert_eq(recap["abilities"][0]["name"], "Heroic Strike")
	assert_eq(recap["abilities"][0]["uses"], 1)
	assert_eq(recap["abilities"][0]["damage"], 30)
	assert_eq(recap["abilities"][0]["interrupts"], 1)


func test_defender_gets_damage_taken_and_server_computed_mitigation() -> void:
	var own: Dictionary = Recap.apply_event(Recap.blank(100), _hit(8, 7, 30), 7)
	var recap: Dictionary = Recap.finalize(own, "duel", "Duel", 120, 20, [])
	assert_eq(recap["damage_done"], 0)
	assert_eq(recap["damage_taken"], 30)
	assert_eq(recap["mitigation"], 8)
	assert_eq(recap["interrupts"], 0, "the attacker, not the target, landed the interrupt")
	assert_true(8 in recap["participant_ids"], "encounter tracks its server-observed opponent")


func test_incoming_damage_events_count_even_when_not_ability_result() -> void:
	var own: Dictionary = Recap.blank(100)
	own = Recap.apply_event(own, _damage_event(9001, 7, 25), 7)
	own = Recap.apply_event(own, _damage_event(9002, 7, 10, "dot_tick"), 7)
	own = Recap.apply_event(own, {"type": "player_death", "target_id": 7, "tick": 130}, 7)
	var recap: Dictionary = Recap.finalize(own, "wolf", "Wolf", 140, 20, [])
	assert_eq(recap["damage_taken"], 35, "all authoritative incoming damage feeds the death recap")
	assert_eq(recap["mitigation"], 6, "mitigation column follows non-ability incoming damage too")
	assert_eq(recap["deaths"], 1, "death count still comes from the death event")


func test_comparison_uses_only_same_content_personal_history() -> void:
	var prior_state: Dictionary = Recap.apply_event(Recap.blank(0), _hit(7, 9001, 40), 7)
	var prior: Dictionary = Recap.finalize(prior_state, "wolf", "Wolf", 20, 20, [])
	var unrelated_state: Dictionary = Recap.apply_event(Recap.blank(0), _hit(7, 9002, 500), 7)
	var unrelated: Dictionary = Recap.finalize(unrelated_state, "kobold", "Kobold", 20, 20, [])
	var current_state: Dictionary = Recap.apply_event(Recap.blank(40), _hit(7, 9003, 50), 7)
	var current: Dictionary = Recap.finalize(current_state, "wolf", "Wolf", 60, 20, [prior])

	assert_eq(current["comparison"]["runs"], 1)
	assert_eq(current["comparison"]["damage_pct"], 25.0, "50 is +25% vs own wolf average 40")
	assert_false(current["comparison"].has("rank"), "self mirror contains no public rank")
	assert_ne(unrelated["damage_done"], current["damage_done"], "control: other content differs")


func test_history_is_bounded_and_inputs_are_not_mutated() -> void:
	var history: Array = []
	for i in range(7):
		var state: Dictionary = Recap.apply_event(Recap.blank(i), _hit(7, 9001, 10 + i), 7)
		var recap: Dictionary = Recap.finalize(state, "wolf", "Wolf", i + 20, 20, history)
		var before: Array = history.duplicate(true)
		var next: Array = Recap.append_history(history, recap, 5)
		assert_eq(history, before, "pure helper must not mutate caller history")
		history = next
	assert_eq(history.size(), 5)
	assert_eq(history[0]["damage_done"], 12, "oldest two of seven were evicted")
	assert_eq(history[4]["damage_done"], 16)
