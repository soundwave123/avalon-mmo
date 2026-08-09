extends GutTest
# T-521: the dev-only force-death intent. OFF unless AVALON_DEBUG_INTENTS is set, self-only, and it
# drives the real _check_death_player path. These tests pin the gate + the self-kill wiring.

const DebugIntents = preload("res://scripts/debug_intents.gd")


class FakeRes:
	var hp: int = 100

	func apply_damage(amount: int) -> FakeRes:
		var r := FakeRes.new()
		r.hp = hp - amount
		return r


class FakeWorld:
	extends RefCounted
	var _combat_resources: Dictionary = {}
	var death_calls: Array = []

	func _check_death_player(pid: int, _now: int) -> void:
		death_calls.append(pid)


func after_each() -> void:
	OS.set_environment("AVALON_DEBUG_INTENTS", "")


func test_non_debug_message_is_not_claimed() -> void:
	var w := FakeWorld.new()
	assert_false(
		DebugIntents.handle(w, "use_ability", 1), "genuinely unknown messages fall through"
	)


func test_debug_kill_is_gated_off_by_default() -> void:
	OS.set_environment("AVALON_DEBUG_INTENTS", "")
	var w := FakeWorld.new()
	w._combat_resources = {1: FakeRes.new()}
	# Recognized (so main.gd won't warn) but does NOTHING when the env flag is unset.
	assert_true(DebugIntents.handle(w, "debug_kill", 1), "debug_kill is a recognized intent")
	assert_eq(w.death_calls.size(), 0, "gated off — no death applied")
	assert_eq((w._combat_resources[1] as FakeRes).hp, 100, "no damage while disabled")


func test_debug_kill_when_enabled_applies_lethal_self_damage_and_checks_death() -> void:
	OS.set_environment("AVALON_DEBUG_INTENTS", "1")
	var w := FakeWorld.new()
	w._combat_resources = {7: FakeRes.new()}
	assert_true(DebugIntents.handle(w, "debug_kill", 7))
	assert_lt((w._combat_resources[7] as FakeRes).hp, 0, "HP driven well past zero (lethal)")
	assert_eq(w.death_calls, [7], "the normal server death check runs for the calling peer only")


func test_debug_kill_on_a_peer_with_no_resources_is_a_safe_noop() -> void:
	OS.set_environment("AVALON_DEBUG_INTENTS", "1")
	var w := FakeWorld.new()
	assert_true(DebugIntents.handle(w, "debug_kill", 99), "handled")
	assert_eq(w.death_calls.size(), 0, "no resources → nothing to kill, no crash")
