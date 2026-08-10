extends "res://addons/gut/test.gd"

var _parser: CombatEventParser = null


# T-756: the parser used to be built ONCE in before_all and shared by every test in the file.
# Two tests below connect a capturing lambda to its signals and never disconnect, so from the
# moment they ran, every later test's parse() also appended into those closures' arrays — one
# test's payloads silently landing in another test's captures. It also made get_events_parsed()
# a running total across the whole file. CombatEventParser is a RefCounted with no setup cost;
# there is no reason to share one. Each test now gets its own.
func before_each() -> void:
	_parser = CombatEventParser.new()
	watch_signals(_parser)


func after_each() -> void:
	_parser = null  # RefCounted, just drop the reference


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


# T-756: named "has_correct_fields" but asserted only that the signal fired — byte-identical to
# the test above it, so every field could have been dropped, swapped or mistyped by the parser
# and this still passed. It is the ONLY test of the server→client field contract in the header,
# so read the event out of the signal and check every field it claims to carry.
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
	var evt = get_signal_parameters(_parser, "ability_result_event", 0)[0]
	assert_eq(evt.event_type, "ability_result", "tagged as an ability result")
	assert_eq(evt.caster_id, 1, "caster_id carried")
	assert_eq(evt.caster_name, "Hero", "caster_name carried")
	assert_eq(evt.target_id, 2, "target_id carried")
	assert_eq(evt.target_name, "Goblin", "target_name carried")
	assert_eq(evt.damage, 15, "damage carried")
	assert_eq(evt.outcome, "hit", "outcome carried")
	assert_eq(evt.target_hp, 85, "target_hp carried")
	assert_eq(evt.target_max_hp, 100, "target_max_hp carried")


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
	# T-756: this ended on `assert_true(true)`, which is green even if parse() were removed.
	# The real claim is that an empty payload is dropped SILENTLY — no signal, no counter bump,
	# and in particular not routed to unknown_event, which would spam the feedback layer.
	assert_signal_not_emitted(_parser, "unknown_event", "an empty dict is dropped, not 'unknown'")
	assert_signal_not_emitted(_parser, "ability_result_event")
	assert_eq(_parser.get_events_parsed(), 0, "an empty payload is not counted as an event")


# T-756: "use_defaults" asserted only that the signal fired — it never looked at a single
# default. The defaults are what stops a truncated packet rendering as "Unknown hits Unknown
# for 0", so assert them.
func test_missing_keys_use_defaults() -> void:
	var payload := {
		"type": "ability_result",
	}
	_parser.parse(payload)
	assert_signal_emitted(_parser, "ability_result_event")
	var evt = get_signal_parameters(_parser, "ability_result_event", 0)[0]
	assert_eq(evt.caster_id, -1, "absent caster_id defaults to the sentinel, not 0")
	assert_eq(evt.target_id, -1, "absent target_id defaults to the sentinel, not 0")
	assert_eq(evt.caster_name, "Unknown", "absent names default to Unknown")
	assert_eq(evt.target_name, "Unknown", "absent names default to Unknown")
	assert_eq(evt.damage, 0, "absent damage is zero")
	assert_eq(evt.outcome, "hit", "absent outcome defaults to hit")
	assert_eq(evt.target_hp, -1, "absent target_hp stays unknown, not zero (which reads as dead)")
	assert_eq(evt.tick, -1, "absent tick is the -1 sentinel")


func test_events_parsed_counter_increments() -> void:
	# T-756: the parser is per-test now (see before_each), so `before` is 0 — the delta form is
	# kept anyway because it is the honest way to state the claim.
	var before := _parser.get_events_parsed()
	var payload := {
		"type": "ability_result",
		"damage": 10,
	}
	_parser.parse(payload)
	assert_eq(_parser.get_events_parsed(), before + 1)


# T-756: named for the message FORMAT, asserted only that a signal fired — the very field it
# exists to pin (system_message) was never read, so the death line could have rendered empty.
func test_death_system_message_format() -> void:
	var payload := {
		"type": "player_death",
		"player_id": 3,
		"player_name": "Reine",
	}
	_parser.parse(payload)
	assert_signal_emitted(_parser, "player_death_event")
	var evt = get_signal_parameters(_parser, "player_death_event", 0)[0]
	assert_eq(evt.system_message, "Reine has died.", "the death line names the player")
	assert_eq(evt.target_id, 3, "player_id lands on target_id")
	assert_eq(evt.target_name, "Reine", "player_name lands on target_name")
	assert_eq(evt.event_type, "player_death")


# T-756: the whole point of this test is that a heal's size comes off the "amount" key rather
# than "damage" — and it never read the amount. Swapping the two keys in the parser left it
# green. Assert the number.
func test_heal_damage_uses_amount_field() -> void:
	var payload := {
		"type": "heal_result",
		"amount": 25,
		"caster_name": "Cleric",
		"target_name": "Knight",
	}
	_parser.parse(payload)
	assert_signal_emitted(_parser, "heal_event")
	var evt = get_signal_parameters(_parser, "heal_event", 0)[0]
	assert_eq(evt.damage, 25, "the heal size is read from the 'amount' key")
	assert_eq(evt.event_type, "heal", "and it is tagged as a heal, never as damage")
	assert_eq(evt.caster_name, "Cleric")
	assert_eq(evt.target_name, "Knight")


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
