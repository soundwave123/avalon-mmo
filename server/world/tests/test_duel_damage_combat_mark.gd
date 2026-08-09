extends "res://addons/gut/test.gd"

# T-600 (Suggestion #50): T-582 made MOB damage universally mark_combat() the damaged player, but
# PvP/duel damage never got the same treatment. ability_executor.gd's _resolve_damage() only
# mark_combat()s the CASTER (line ~307, on every ability use) — the defender's new_target_resources
# is built with apply_damage() alone. main.gd::_commit_ability_result() then wrote that resource
# object straight into _combat_resources[target_id] with no combat-mark, so a duel opponent taking
# damage looked "idle" to qa_sentinel_probe.gd's in_combat formula (session-7: 6 false
# idle_hp_drain anomalies from one duel). These tests exercise the REAL _commit_ability_result
# (T-582's harness pattern) to prove the DEFENDER is now combat-marked exactly when damage lands.

const CombatResources = preload("res://scripts/combat/combat_resources.gd")
const AbilityExecutor = preload("res://scripts/combat/ability_executor.gd")
const QaSentinel = preload("res://scripts/qa_sentinel.gd")

# Mirrors qa_sentinel_probe.gd's OOC_TICKS (~5s @ 20 ticks/s): last-combat older than this =
# out of combat. Same constant test_mob_damage_combat_mark.gd (T-582) uses.
const OOC_TICKS := 100


# Harness: the real world script, minus the one side-effecting call these tests must never
# trigger (network broadcast). Matches the _HarnessMain pattern in test_build_gate_handshake.gd /
# test_mob_damage_combat_mark.gd.
class _HarnessMain:
	extends "res://scripts/main.gd"
	var broadcasts: Array = []

	func _broadcast(data: Dictionary) -> void:
		broadcasts.append(data)


# _commit_ability_result() statically types the registry's return as AbilityData and reads
# .id/.name (for the recap event) — a minimal REAL AbilityData avoids needing the full
# content-loaded AbilityRegistry for this unit-level test.
class _FakeRegistry:
	func get_ability(_id: int) -> AbilityData:
		var a := AbilityData.new()
		a.id = 1
		a.name = "Test Strike"
		return a


func _mana_resources(hp: int = 100) -> CombatResources:
	var res := CombatResources.new()
	res.set_class_resource("mage", 30)  # resource_kind = "mana"
	res.hp = hp
	res.max_hp = hp
	return res


# A player-vs-player "hit" AbilityResult, shaped like _resolve_damage()'s real return: the
# defender's resources already carry the damage (apply_damage), same as production.
func _hit_result(damage: int, defender_res: CombatResources) -> AbilityExecutor.AbilityResult:
	return AbilityExecutor.AbilityResult.accept(
		CombatState.new(), CombatResources.new(), damage, "hit", CombatState.new(), defender_res
	)


func _harness() -> _HarnessMain:
	var m := _HarnessMain.new()
	m._ability_registry = _FakeRegistry.new()
	return m


func test_duel_damage_marks_the_defender_combat() -> void:
	var m := _harness()
	var defender_id := 52
	m._combat_resources[defender_id] = _mana_resources()
	assert_eq(m._combat_resources[defender_id].last_combat_tick, 0, "starts unmarked")

	m._commit_ability_result(
		51, defender_id, null, 1, _hit_result(15, _mana_resources(85)), 12345, "t"
	)

	var after: CombatResources = m._combat_resources[defender_id]
	assert_gt(after.last_combat_tick, 0, "T-600: duel/PvP damage must combat-mark the DEFENDER")
	m.free()


func test_zero_damage_result_does_not_falsely_mark_combat() -> void:
	# A heal (or any zero-damage ability) targeting a player must NOT combat-mark them — only actual
	# damage should (mirrors the dismount-on-damage-only gate right above the fix in main.gd).
	var m := _harness()
	var target_id := 53
	m._combat_resources[target_id] = _mana_resources()

	m._commit_ability_result(51, target_id, null, 1, _hit_result(0, _mana_resources()), 999, "t")

	assert_eq(
		m._combat_resources[target_id].last_combat_tick,
		0,
		"a zero-damage result (e.g. a heal) leaves the target's combat mark untouched"
	)
	m.free()


func test_duel_damage_defender_not_flagged_idle_by_qa_sentinel() -> void:
	# End to end: the real _commit_ability_result combat-mark feeds directly into the same
	# "in_combat" formula qa_sentinel_probe.gd uses, mirroring T-582's sentinel-level test.
	var m := _harness()
	var defender_id := 54
	m._combat_resources[defender_id] = _mana_resources()

	var now := 5000
	m._commit_ability_result(
		51, defender_id, null, 1, _hit_result(20, _mana_resources(80)), now, "t"
	)
	var marked_tick: int = m._combat_resources[defender_id].last_combat_tick
	assert_gt(marked_tick, 0, "duel damage combat-marks the defender")

	var probe_tick := marked_tick + 5  # well inside OOC_TICKS
	var in_combat: bool = probe_tick - marked_tick < OOC_TICKS
	assert_true(in_combat, "T-600: a duel-damaged defender reads as in_combat, not idle")

	var sentinel := QaSentinel.new()
	var death_obs := {
		"pid": defender_id,
		"hp": 80,
		"max_hp": 100,
		"pos": Vector3.ZERO,
		"in_combat": in_combat,
		"attacked_by_mob": false,
		"damage_source_recorded": true,
	}
	var anomalies := sentinel.observe(probe_tick, [death_obs])
	assert_eq(
		anomalies.size(), 0, "T-600: a combat-marked duel defender must not read as idle_hp_drain"
	)
	m.free()
