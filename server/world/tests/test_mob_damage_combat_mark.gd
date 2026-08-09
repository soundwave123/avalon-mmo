extends "res://addons/gut/test.gd"

# T-582: the QA sentinel (T-561) infers "in combat" from CombatResources.last_combat_tick
# (see qa_sentinel_probe.gd's `now_tick - cr.last_combat_tick < OOC_TICKS`). _apply_mob_events
# only called mark_combat() inside the rage branch, so mana/energy classes taking mob damage
# never got combat-marked -> the sentinel saw a stale last_combat_tick and misclassified real
# mob-kill deaths as idle_hp_drain / unattributed_death (portal report #40: 28 false
# [qa-anomaly] lines from one Mage-vs-Kobold death). These tests exercise the REAL
# _apply_mob_events (via a thin harness that only silences the network broadcast) to prove the
# combat-mark now fires for every resource kind, and that a rage class's gain logic is untouched.

const CombatResources = preload("res://scripts/combat/combat_resources.gd")
const QaSentinel = preload("res://scripts/qa_sentinel.gd")

# Mirrors qa_sentinel_probe.gd's OOC_TICKS (~5s @ 20 ticks/s): last-combat older than this =
# out of combat.
const OOC_TICKS := 100


# Harness: the real world script, minus the one side-effecting call these tests must never
# trigger (network broadcast). Matches the _HarnessMain pattern in test_build_gate_handshake.gd.
class _HarnessMain:
	extends "res://scripts/main.gd"
	var broadcasts: Array = []

	func _broadcast(data: Dictionary) -> void:
		broadcasts.append(data)


func _mana_resources(hp: int = 100) -> CombatResources:
	var res := CombatResources.new()
	res.set_class_resource("mage", 30)  # resource_kind = "mana"
	res.hp = hp
	res.max_hp = hp
	return res


func _rage_resources(hp: int = 100) -> CombatResources:
	var res := CombatResources.new()
	res.set_class_resource("warrior", 30)  # resource_kind = "rage"
	res.hp = hp
	res.max_hp = hp
	return res


func test_mana_player_taking_mob_damage_marks_combat() -> void:
	var m := _HarnessMain.new()
	var pid := 42
	m._combat_resources[pid] = _mana_resources()
	assert_eq(m._combat_resources[pid].last_combat_tick, 0, "starts unmarked")

	m._apply_mob_events(
		[{"type": "damage", "mob_id": 900, "target_id": pid, "amount": 10, "outcome": "hit"}]
	)

	var after: CombatResources = m._combat_resources[pid]
	assert_eq(after.resource_kind, "mana", "still a mana-kind pool")
	assert_gt(after.last_combat_tick, 0, "T-582: mana class must be combat-marked on mob damage")
	m.free()


func test_rage_player_still_gains_rage_and_marks_combat() -> void:
	# Regression guard: the rage-gain branch (T-062) must survive the restructure untouched.
	var m := _HarnessMain.new()
	var pid := 43
	m._combat_resources[pid] = _rage_resources()
	assert_eq(m._combat_resources[pid].class_resource(), 0, "warriors start with no rage")

	m._apply_mob_events(
		[{"type": "damage", "mob_id": 901, "target_id": pid, "amount": 10, "outcome": "hit"}]
	)

	var after: CombatResources = m._combat_resources[pid]
	assert_gt(after.class_resource(), 0, "rage is still generated on taking damage")
	assert_gt(after.last_combat_tick, 0, "rage class stays combat-marked (unchanged behavior)")
	m.free()


func test_mana_player_mob_kill_after_damage_is_not_flagged_idle_or_unattributed() -> void:
	# End-to-end: the real _apply_mob_events combat-mark feeds directly into the same "in_combat"
	# formula qa_sentinel_probe.gd uses, which is what the QA sentinel's idle_hp_drain /
	# unattributed_death detectors key on.
	var m := _HarnessMain.new()
	var pid := 44
	m._combat_resources[pid] = _mana_resources(10)  # low HP so the next hit kills

	m._apply_mob_events(
		[{"type": "damage", "mob_id": 902, "target_id": pid, "amount": 5, "outcome": "hit"}]
	)
	var marked_tick: int = m._combat_resources[pid].last_combat_tick
	assert_gt(marked_tick, 0, "first hit already combat-marks the mana player")

	m._apply_mob_events(
		[{"type": "damage", "mob_id": 902, "target_id": pid, "amount": 20, "outcome": "hit"}]
	)
	var died: CombatResources = m._combat_resources[pid]
	assert_eq(died.hp, 0, "the second hit kills the mana player")

	var death_tick := marked_tick + 5  # well inside OOC_TICKS
	var in_combat: bool = death_tick - int(died.last_combat_tick) < OOC_TICKS
	assert_true(in_combat, "T-582: mob-damage-taken keeps a mana player combat-marked at death")

	var sentinel := QaSentinel.new()
	var alive_obs := {
		"pid": pid,
		"hp": 10,
		"max_hp": died.max_hp,
		"pos": Vector3.ZERO,
		"in_combat": true,
		"attacked_by_mob": true,
		"damage_source_recorded": true,
	}
	var death_obs := {
		"pid": pid,
		"hp": 0,
		"max_hp": died.max_hp,
		"pos": Vector3.ZERO,
		"in_combat": in_combat,
		"attacked_by_mob": true,
		"damage_source_recorded": in_combat,
	}
	assert_eq(sentinel.observe(marked_tick, [alive_obs]).size(), 0, "baseline tick is silent")
	var anomalies := sentinel.observe(death_tick, [death_obs])
	assert_eq(
		anomalies.size(),
		0,
		"T-582: a mob-kill death must stay silent, not idle_hp_drain/unattributed_death"
	)
	m.free()
