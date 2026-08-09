extends "res://addons/gut/test.gd"

var _parser: CombatEventParser = null


func before_all() -> void:
	_parser = CombatEventParser.new()


func after_all() -> void:
	_parser = null  # RefCounted, just drop reference


func before_each() -> void:
	if _parser:
		watch_signals(_parser)


func test_valid_ability_hit_emits_event() -> void:
	var payload := {
		"type": "ability_result",
		"ability_id": 42,
		"caster_id": "peer_1",
		"target_id": "peer_2",
		"damage": 15,
		"outcome": "hit",
		"caster_name": "Hero",
		"target_name": "Goblin",
		"target_hp": 85,
		"target_max_hp": 100,
	}
	_parser.parse(payload)
	assert_signal_emitted(_parser, "ability_result_event")


func test_valid_ability_hit_has_correct_fields() -> void:
	var payload := {
		"type": "ability_result",
		"ability_id": 42,
		"caster_id": 1,
		"target_id": 2,
		"damage": 15,
		"outcome": "hit",
		"caster_name": "Hero",
		"target_name": "Goblin",
		"target_hp": 85,
		"target_max_hp": 100,
	}
	_parser.parse(payload)
	assert_signal_emitted(_parser, "ability_result_event")


func test_heal_result_emits_heal_signal() -> void:
	var payload := {
		"type": "heal_result",
		"caster_id": 1,
		"caster_name": "Healer",
		"target_id": 2,
		"target_name": "Warrior",
		"amount": 20,
		"target_hp": 80,
		"target_max_hp": 100,
	}
	_parser.parse(payload)
	assert_signal_emitted(_parser, "heal_event")


func test_player_death_emits_signal() -> void:
	var payload := {
		"type": "player_death",
		"peer_id": "peer_dead",
		"player_id": 5,
		"player_name": "Player",
	}
	_parser.parse(payload)
	assert_signal_emitted(_parser, "player_death_event")


func test_player_respawn_emits_signal() -> void:
	var payload := {
		"type": "player_respawn",
		"peer_id": "peer_risen",
		"player_id": 5,
		"player_name": "Player",
	}
	_parser.parse(payload)
	assert_signal_emitted(_parser, "player_respawn_event")


func test_mob_death_emits_signal() -> void:
	var payload := {
		"type": "mob_death",
		"mob_id": 1001,
		"mob_name": "Goblin",
	}
	_parser.parse(payload)
	assert_signal_emitted(_parser, "mob_death_event")


func test_mob_respawn_emits_signal() -> void:
	var payload := {
		"type": "mob_respawn",
		"mob_id": 1001,
		"mob_name": "Goblin",
	}
	_parser.parse(payload)
	assert_signal_emitted(_parser, "mob_respawn_event")


func test_unknown_type_emits_unknown_event() -> void:
	var payload := {
		"type": "unknown_event_type_xyz",
		"ability_id": 0,
	}
	_parser.parse(payload)
	assert_signal_emitted(_parser, "unknown_event")


func test_empty_dict_does_not_crash() -> void:
	var empty: Dictionary = {}
	_parser.parse(empty)
	assert_true(true, "empty dict should not crash")


func test_missing_keys_use_defaults() -> void:
	var payload := {
		"type": "ability_result",
	}
	_parser.parse(payload)
	assert_signal_emitted(_parser, "ability_result_event")


func test_events_parsed_counter_increments() -> void:
	# Parser persists across tests so total count keeps growing.
	# Just verify that after this call, count increased by 1.
	var before := _parser.get_events_parsed()
	var payload := {
		"type": "ability_result",
		"damage": 10,
	}
	_parser.parse(payload)
	assert_eq(_parser.get_events_parsed(), before + 1)


func test_death_system_message_format() -> void:
	var payload := {
		"type": "player_death",
		"player_id": 3,
		"player_name": "Reine",
	}
	_parser.parse(payload)
	assert_signal_emitted(_parser, "player_death_event")


func test_heal_damage_uses_amount_field() -> void:
	var payload := {
		"type": "heal_result",
		"amount": 25,
		"caster_name": "Cleric",
		"target_name": "Knight",
	}
	_parser.parse(payload)
	assert_signal_emitted(_parser, "heal_event")


# ---- T-027 §6: cast events ----------------------------------------------


func test_cast_started_emits_signal_with_ticks() -> void:
	_parser.parse({"type": "cast_started", "ability_id": 5, "cast_ticks": 40})
	assert_signal_emitted_with_parameters(_parser, "cast_started_event", [5, 40])


func test_cast_cancelled_emits_signal_with_reason() -> void:
	_parser.parse({"type": "cast_cancelled", "reason": "target_lost"})
	assert_signal_emitted_with_parameters(_parser, "cast_cancelled_event", ["target_lost"])


func test_ability_result_carries_tick() -> void:
	var captured: Array = []
	_parser.ability_result_event.connect(
		func(evt: CombatEventParser.CombatEvent) -> void: captured.append(evt)
	)
	(
		_parser
		. parse(
			{
				"type": "ability_result",
				"ability_id": 1,
				"caster_id": 1,
				"target_id": 2,
				"damage": 10,
				"outcome": "hit",
				"tick": 123,
			}
		)
	)
	assert_eq(captured.size(), 1)
	assert_eq(captured[0].tick, 123)


func test_ability_result_tick_defaults_to_minus_one() -> void:
	var captured: Array = []
	_parser.ability_result_event.connect(
		func(evt: CombatEventParser.CombatEvent) -> void: captured.append(evt)
	)
	_parser.parse(
		{"type": "ability_result", "ability_id": 1, "caster_id": 1, "target_id": 2, "damage": 10}
	)
	assert_eq(captured[0].tick, -1)


# ---- T-072: heals arrive as ability_result with outcome "heal" (heal_result is never sent) ----


func test_ability_result_heal_outcome_emits_heal_event() -> void:
	var p := CombatEventParser.new()
	watch_signals(p)
	(
		p
		. parse(
			{
				"type": "ability_result",
				"ability_id": 301,
				"outcome": "heal",
				"damage": 17,
				"caster_id": 3,
				"caster_name": "kit_priest",
				"target_id": 3,
				"target_name": "kit_priest",
				"target_hp": 90,
				"target_max_hp": 100,
			}
		)
	)
	assert_signal_emit_count(p, "heal_event", 1, "heal outcome must emit heal_event, not damage")
	assert_signal_emit_count(p, "ability_result_event", 0)
	var evt = get_signal_parameters(p, "heal_event", 0)[0]
	assert_eq(evt.damage, 17, "heal amount carried from the ability_result damage field")
	assert_eq(evt.event_type, "heal")
