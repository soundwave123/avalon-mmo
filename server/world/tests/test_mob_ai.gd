# T-025: Mob AI FSM — headless tick simulation tests.
# All tests use injected now — no OS time, no engine loop, no network.

extends GutTest

const _MAI = preload("res://scripts/combat/mob_ai.gd")
const _MD = preload("res://scripts/combat/mob_data.gd")
const _CS = preload("res://scripts/combat/combat_state.gd")
const _TT = preload("res://scripts/combat/threat_table.gd")
const _SC = preload("res://scripts/server_config.gd")


func _make_mob(pos: Vector3, ai_state: int) -> Object:
	var mob = _MD.new()
	mob.entity_id = 1001
	mob.mob_type_id = 1
	mob.position = pos
	mob.spawn_position = Vector3(10.0, 10.0, 0.0)
	mob.aggro_radius = 5.0
	mob.leash_radius = 15.0
	mob.melee_range = 2.0
	mob.ai_state = ai_state
	mob.current_target_id = -1
	mob.combat_state = CombatState.new()
	var cr := CombatResources.new()
	cr.hp = 50
	cr.max_hp = 50
	cr.mana = 10
	cr.max_mana = 10
	cr.stamina = 20
	cr.max_stamina = 20
	mob.resources = cr
	var stats := CharacterStats.new()
	stats.weapon_speed = 1.0
	stats.str_val = 30
	stats.int_val = 10
	stats.dex_val = 20
	stats.skills = {"Swordsmanship": 20, "Tactics": 10}
	mob.stats = stats
	var ab := AbilityData.new()
	ab.id = 0
	ab.name = "Mob Melee"
	ab.cast_ticks = 0
	ab.triggers_gcd = false
	ab.mana_cost = 0
	ab.stamina_cost = 0
	ab.range_units = 2.0
	ab.base_damage = 8
	ab.variance_min = 1.0
	ab.variance_max = 1.0
	ab.attacker_skill_coeffs = {}
	ab.mitigation_skill_coeffs = {}
	ab.miss_chance = 0.0
	ab.dodge_chance = 0.0
	ab.parry_chance = 0.0
	ab.crit_chance = 0.0
	ab.crit_multiplier = 2.0
	ab.threat_multiplier = 1.0
	mob.melee_ability = ab
	return mob


func _make_player(pos: Vector3, hp: int = 100, dead: bool = false) -> Dictionary:
	var cs := CombatState.new()
	if dead:
		cs.state = _CS.CombatStateEnum.DEAD
	var cr := CombatResources.new()
	cr.hp = hp
	cr.max_hp = 100
	cr.mana = 50
	cr.max_mana = 50
	cr.stamina = 100
	cr.max_stamina = 100
	return {
		"position": pos,
		"combat_state": cs,
		"resources": cr,
		"stats": CharacterStats.new(),
	}


func _make_rng() -> RandomNumberGenerator:
	var rng := RandomNumberGenerator.new()
	rng.seed = 42
	return rng


# --- Tests ---


func test_00_ai_tick_preserves_mob_id():
	# T-047 regression: the AI-tick mob copy must carry mob_id (the quest kill-credit alias). When it
	# didn't, every loaded mob's alias became "" after the first tick and on_mob_kill silently bailed —
	# kill objectives never credited in the real world. Caught only by the ENet quest-loop harness.
	var mob = _make_mob(Vector3(0.0, 0.0, 0.0), _MAI.MobAIState.IDLE)
	mob.mob_id = "mob_dummy"
	var result = _MAI.ai_tick(mob, {}, _TT.new(), 0, _make_rng())
	assert_eq(result.new_mob.mob_id, "mob_dummy", "mob_id must survive the AI-tick copy")


func test_00_ai_tick_preserves_combat_state_cast_fields() -> void:
	# T-051: _copy_mob dropped CombatState's cast fields (a mob_id-class bug — inert until M3 caster
	# mobs). Now it goes through CombatState.copy(), so every field must survive the tick.
	var mob = _make_mob(Vector3(0.0, 0.0, 0.0), _MAI.MobAIState.IDLE)
	mob.combat_state.cast_start = 42
	mob.combat_state.cast_ability_id = 7
	var result = _MAI.ai_tick(mob, {}, _TT.new(), 0, _make_rng())
	assert_eq(result.new_mob.combat_state.cast_start, 42, "cast_start survives _copy_mob")
	assert_eq(result.new_mob.combat_state.cast_ability_id, 7, "cast_ability_id survives _copy_mob")


func test_01_idle_no_players_in_range_stays_idle():
	var mob = _make_mob(Vector3(0.0, 0.0, 0.0), _MAI.MobAIState.IDLE)
	# Player well outside aggro_radius (5.0)
	var players := {1: _make_player(Vector3(10.0, 0.0, 0.0))}
	var tt := _TT.new()
	var rng := _make_rng()
	var current_mob = mob
	for i in range(100):
		var r = _MAI.ai_tick(current_mob, players, tt, i, rng)
		current_mob = r.new_mob
	assert_eq(
		current_mob.ai_state,
		_MAI.MobAIState.IDLE,
		"mob outside aggro range should stay IDLE after 100 ticks"
	)


func test_02_idle_player_enters_aggro_radius_transitions_to_aggroed():
	var mob = _make_mob(Vector3(0.0, 0.0, 0.0), _MAI.MobAIState.IDLE)
	# Player at 4.0 — within aggro_radius (5.0)
	var players := {1: _make_player(Vector3(4.0, 0.0, 0.0))}
	var tt := _TT.new()
	var result = _MAI.ai_tick(mob, players, tt, 0, _make_rng())
	assert_eq(
		result.new_mob.ai_state,
		_MAI.MobAIState.AGGROED,
		"player within aggro_radius should trigger AGGROED"
	)
	assert_eq(result.new_mob.current_target_id, 1, "target should be the nearby player")


func test_03_aggroed_approaches_and_enters_melee():
	# Mob at origin; spawn at (10,10); player at (0, 3.0).
	# Distance = 3.0; melee_range = 2.0. T-534: per-tick chase step = MOB_MOVE_SPEED(0.30) *
	# speed_mult(1.01) = 0.303. Ticks to close from 3.0 → ≤ 2.0: ceil(1.0/0.303) = 4 ticks.
	var mob = _make_mob(Vector3(0.0, 0.0, 0.0), _MAI.MobAIState.AGGROED)
	mob.current_target_id = 1
	var players := {1: _make_player(Vector3(0.0, 3.0, 0.0))}
	var tt := _TT.new()
	var rng := _make_rng()
	var current_mob = mob
	for i in range(20):
		var r = _MAI.ai_tick(current_mob, players, tt, i, rng)
		current_mob = r.new_mob
		if current_mob.ai_state == _MAI.MobAIState.MELEE:
			break
	assert_eq(
		current_mob.ai_state,
		_MAI.MobAIState.MELEE,
		"mob should transition to MELEE after closing distance"
	)


func test_04_melee_auto_attack_fires_and_generates_damage_event():
	# Mob in MELEE, next_swing_tick=0, now=0 → swing fires immediately.
	var mob = _make_mob(Vector3(0.0, 0.0, 0.0), _MAI.MobAIState.MELEE)
	mob.current_target_id = 1
	mob.combat_state.next_swing_tick = 0
	var players := {1: _make_player(Vector3(0.0, 1.0, 0.0))}
	var tt := _TT.new()
	var result = _MAI.ai_tick(mob, players, tt, 0, _make_rng())
	assert_eq(result.new_mob.ai_state, _MAI.MobAIState.MELEE, "should stay in MELEE")
	var has_damage_event: bool = false
	for ev in result.events:
		if ev.get("type", "") == "damage" and ev.get("amount", 0) > 0:
			has_damage_event = true
	assert_true(has_damage_event, "MELEE auto-attack should produce a damage event with amount > 0")


func test_05_melee_player_leaves_leash_radius_transitions_to_evading():
	var mob = _make_mob(Vector3(0.0, 0.0, 0.0), _MAI.MobAIState.MELEE)
	mob.current_target_id = 1
	mob.combat_state.next_swing_tick = 9999  # prevent swing this tick
	# Player at (30, 10) — distance from spawn (10,10) = 20 > leash_radius 15
	var players := {1: _make_player(Vector3(30.0, 10.0, 0.0))}
	var tt := _TT.new()
	var result = _MAI.ai_tick(mob, players, tt, 0, _make_rng())
	assert_eq(
		result.new_mob.ai_state,
		_MAI.MobAIState.EVADING,
		"player beyond leash_radius should trigger EVADING"
	)


func test_06_evading_restores_resources_and_resets_to_idle():
	# Mob in MELEE with depleted resources. Leash broken → EVADING.
	var mob = _make_mob(Vector3(0.0, 0.0, 0.0), _MAI.MobAIState.MELEE)
	mob.spawn_position = Vector3(0.0, 0.0, 0.0)  # spawn at current pos — reaches home in 1 tick
	mob.current_target_id = 1
	mob.resources.hp = 1
	mob.resources.mana = 0
	mob.resources.stamina = 0
	# Player beyond leash (distance from spawn (0,0) is 20 > 15)
	var players := {1: _make_player(Vector3(20.0, 0.0, 0.0))}
	var tt := _TT.new()
	tt.add_threat(mob.entity_id, 1, 50)
	var rng := _make_rng()

	# Tick 1: leash broken → EVADING with instant resource restore
	var r1 = _MAI.ai_tick(mob, players, tt, 0, rng)
	assert_eq(r1.new_mob.ai_state, _MAI.MobAIState.EVADING, "should enter EVADING")
	assert_eq(r1.new_mob.resources.hp, r1.new_mob.resources.max_hp, "HP restored on EVADING entry")
	assert_eq(
		r1.new_mob.resources.stamina,
		r1.new_mob.resources.max_stamina,
		"stamina restored on EVADING entry"
	)

	# Tick 2: mob at spawn (0,0) == spawn_position (0,0) → IDLE + clear_threat event
	var r2 = _MAI.ai_tick(r1.new_mob, {}, tt, 1, rng)
	assert_eq(r2.new_mob.ai_state, _MAI.MobAIState.IDLE, "should reach IDLE at spawn")
	var has_clear: bool = false
	for ev in r2.events:
		if ev.get("type", "") == "clear_threat":
			has_clear = true
	assert_true(has_clear, "clear_threat event must be emitted when mob resets to IDLE")


func test_07_melee_switches_target_to_top_threat():
	# Mob targeting player 1; player 2 has higher threat → mob switches.
	var mob = _make_mob(Vector3(0.0, 0.0, 0.0), _MAI.MobAIState.MELEE)
	mob.current_target_id = 1
	mob.combat_state.next_swing_tick = 9999  # no swing this tick — isolate target-switch logic
	var players := {
		1: _make_player(Vector3(0.0, 1.0, 0.0)),
		2: _make_player(Vector3(1.0, 0.0, 0.0)),
	}
	var tt := _TT.new()
	tt.add_threat(mob.entity_id, 1, 10)
	tt.add_threat(mob.entity_id, 2, 999)
	var result = _MAI.ai_tick(mob, players, tt, 0, _make_rng())
	assert_eq(result.new_mob.ai_state, _MAI.MobAIState.MELEE, "should remain in MELEE")
	assert_eq(result.new_mob.current_target_id, 2, "mob should switch to higher-threat player 2")


func test_08_cannot_attack_dead_player_transitions_to_evading():
	var mob = _make_mob(Vector3(0.0, 0.0, 0.0), _MAI.MobAIState.MELEE)
	mob.current_target_id = 1
	mob.combat_state.next_swing_tick = 0
	var players := {1: _make_player(Vector3(0.0, 0.0, 0.0), 100, true)}  # dead
	var tt := _TT.new()
	var result = _MAI.ai_tick(mob, players, tt, 0, _make_rng())
	assert_eq(
		result.new_mob.ai_state,
		_MAI.MobAIState.EVADING,
		"mob should enter EVADING when target is DEAD"
	)
	for ev in result.events:
		assert_ne(ev.get("type", ""), "damage", "no damage dealt to a dead player")


# T-063: CC — a rooted mob holds position; a stunned mob does nothing.


func test_rooted_mob_holds_position() -> void:
	var mob = _make_mob(Vector3(10.0, 10.0, 0.0), _MAI.MobAIState.AGGROED)
	mob.current_target_id = 1
	mob.combat_state.rooted_until = 100
	var players = {1: _make_player(Vector3(14.0, 10.0, 0.0))}  # 4 units away — would normally chase
	var result = _MAI.ai_tick(mob, players, _TT.new(), 50, _make_rng())  # now 50 < rooted_until
	assert_eq(result.new_mob.position, Vector3(10.0, 10.0, 0.0), "rooted mob doesn't chase")


func test_stunned_mob_no_op() -> void:
	var mob = _make_mob(Vector3(10.0, 10.0, 0.0), _MAI.MobAIState.AGGROED)
	mob.current_target_id = 1
	mob.combat_state.stunned_until = 100
	var players = {1: _make_player(Vector3(14.0, 10.0, 0.0))}
	var result = _MAI.ai_tick(mob, players, _TT.new(), 50, _make_rng())
	assert_eq(result.new_mob.position, Vector3(10.0, 10.0, 0.0), "stunned mob holds position")


# --- T-070: melee range re-check, threat pull, corpse skip ---


func test_20_melee_target_beyond_melee_range_returns_to_aggroed():
	# Live-proven defect: mob_attack landed on a player 14 units away (melee_range 2.0).
	var mob = _make_mob(Vector3(10.0, 10.0, 0.0), _MAI.MobAIState.MELEE)
	mob.current_target_id = 1
	var players := {1: _make_player(Vector3(10.0, 16.0, 0.0))}  # dist 6 > melee 2, inside leash
	var result = _MAI.ai_tick(mob, players, _TT.new(), 100, _make_rng())
	assert_eq(
		result.new_mob.ai_state,
		_MAI.MobAIState.AGGROED,
		"target beyond melee range must be chased (AGGROED), not hit"
	)
	for ev in result.events:
		assert_ne(ev.get("type", ""), "damage", "no swing may land beyond melee range")


func test_21_ranged_damage_on_idle_mob_aggros_it():
	# Threat pull: hitting an idle mob from range must aggro it even outside proximity.
	var mob = _make_mob(Vector3(10.0, 10.0, 0.0), _MAI.MobAIState.IDLE)
	var players := {1: _make_player(Vector3(18.0, 10.0, 0.0))}  # dist 8 > aggro 5, inside leash
	var tt := _TT.new()
	tt.add_threat(1001, 1, 30)
	var result = _MAI.ai_tick(mob, players, tt, 0, _make_rng())
	assert_eq(result.new_mob.ai_state, _MAI.MobAIState.AGGROED, "threat must pull an IDLE mob")
	assert_eq(result.new_mob.current_target_id, 1, "the attacker becomes the target")


func test_22_idle_ignores_dead_player_in_aggro_radius():
	var mob = _make_mob(Vector3(10.0, 10.0, 0.0), _MAI.MobAIState.IDLE)
	var players := {1: _make_player(Vector3(11.0, 10.0, 0.0), 0, true)}  # corpse at dist 1
	var result = _MAI.ai_tick(mob, players, _TT.new(), 0, _make_rng())
	assert_eq(result.new_mob.ai_state, _MAI.MobAIState.IDLE, "a corpse must not pull aggro")


func test_23_idle_threat_pull_ignores_dead_attacker():
	var mob = _make_mob(Vector3(10.0, 10.0, 0.0), _MAI.MobAIState.IDLE)
	var players := {1: _make_player(Vector3(18.0, 10.0, 0.0), 0, true)}  # dead attacker
	var tt := _TT.new()
	tt.add_threat(1001, 1, 30)
	var result = _MAI.ai_tick(mob, players, tt, 0, _make_rng())
	assert_eq(result.new_mob.ai_state, _MAI.MobAIState.IDLE, "dead attacker cannot threat-pull")


func test_24_aggroed_retargets_to_top_living_threat():
	var mob = _make_mob(Vector3(10.0, 10.0, 0.0), _MAI.MobAIState.AGGROED)
	mob.current_target_id = 1
	var players := {
		1: _make_player(Vector3(10.0, 13.0, 0.0)),
		2: _make_player(Vector3(10.0, 12.0, 0.0)),
	}
	var tt := _TT.new()
	tt.add_threat(1001, 2, 50)
	var result = _MAI.ai_tick(mob, players, tt, 0, _make_rng())
	assert_eq(
		result.new_mob.current_target_id, 2, "AGGROED must re-target via threat, not just MELEE"
	)


func test_25_aggroed_dead_target_no_other_threat_evades():
	var mob = _make_mob(Vector3(10.0, 10.0, 0.0), _MAI.MobAIState.AGGROED)
	mob.current_target_id = 1
	var players := {1: _make_player(Vector3(10.0, 12.0, 0.0), 0, true)}  # corpse
	var result = _MAI.ai_tick(mob, players, _TT.new(), 0, _make_rng())
	assert_eq(
		result.new_mob.ai_state,
		_MAI.MobAIState.EVADING,
		"AGGROED on a corpse with no living threat must evade, not chase it"
	)


func test_26_ai_tick_preserves_loot_table():
	# T-073: loot must survive the AI-tick copy (same trap that once dropped mob_id).
	var mob = _make_mob(Vector3(0.0, 0.0, 0.0), _MAI.MobAIState.IDLE)
	mob.loot = [{"item_id": "itm_wolf_pelt", "chance": 1.0}]
	var result = _MAI.ai_tick(mob, {}, _TT.new(), 0, _make_rng())
	assert_eq(result.new_mob.loot.size(), 1, "loot survives _copy_mob")


# ---- T-080: idle patrol ----


func test_30_patrol_mob_wanders_but_stays_in_radius() -> void:
	var mob = _make_mob(Vector3(10.0, 10.0, 0.0), _MAI.MobAIState.IDLE)
	mob.patrol_radius = 5.0
	var rng := _make_rng()
	var moved := false
	var current = mob
	for i in range(600):  # 30 simulated seconds
		var r = _MAI.ai_tick(current, {}, _TT.new(), i, rng)
		current = r.new_mob
		assert_eq(current.ai_state, _MAI.MobAIState.IDLE, "patrol never leaves IDLE")
		var dist: float = current.position.distance_to(mob.spawn_position)
		assert_lt(dist, 5.5, "never beyond patrol_radius (+slack)")
		if dist > 0.5:
			moved = true
	assert_true(moved, "a patrol mob must actually wander")


func test_31_zero_patrol_radius_never_moves() -> void:
	var mob = _make_mob(Vector3(10.0, 10.0, 0.0), _MAI.MobAIState.IDLE)
	var rng := _make_rng()
	var current = mob
	for i in range(200):
		current = _MAI.ai_tick(current, {}, _TT.new(), i, rng).new_mob
	assert_eq(current.position, Vector3(10.0, 10.0, 0.0), "stationary mobs stay put")


func test_32_aggro_preempts_patrol() -> void:
	var mob = _make_mob(Vector3(10.0, 10.0, 0.0), _MAI.MobAIState.IDLE)
	mob.patrol_radius = 5.0
	var players := {1: _make_player(Vector3(11.0, 10.0, 0.0))}  # inside aggro radius
	var r = _MAI.ai_tick(mob, players, _TT.new(), 0, _make_rng())
	assert_eq(r.new_mob.ai_state, _MAI.MobAIState.AGGROED, "a player in range beats the stroll")


func test_33_patrol_state_survives_copy() -> void:
	var mob = _make_mob(Vector3(10.0, 10.0, 0.0), _MAI.MobAIState.IDLE)
	mob.patrol_radius = 5.0
	mob.patrol_target = Vector3(12.0, 11.0, 0.0)
	var r = _MAI.ai_tick(mob, {}, _TT.new(), 1, _make_rng())
	assert_eq(r.new_mob.patrol_radius, 5.0)


# T-516: a training dummy is a static, passive target. A player standing right inside the aggro
# radius (which aggros a normal mob in test_02) must not make the dummy aggro, target, move, or
# attack — and the flag must survive the tick copy (else it reverts to a hostile mob on tick two).
func test_34_training_dummy_ignores_players_and_stays_static() -> void:
	var mob = _make_mob(Vector3(0.0, 0.0, 0.0), _MAI.MobAIState.IDLE)
	mob.is_dummy = true
	mob.patrol_radius = 5.0  # even with patrol configured, a dummy never wanders
	var players := {1: _make_player(Vector3(4.0, 0.0, 0.0))}
	var r = _MAI.ai_tick(mob, players, _TT.new(), 100, _make_rng())
	assert_eq(r.new_mob.ai_state, _MAI.MobAIState.IDLE, "dummy never leaves idle")
	assert_eq(r.new_mob.current_target_id, -1, "dummy never targets a player")
	assert_eq(r.new_mob.position, Vector3(0.0, 0.0, 0.0), "dummy never moves")
	assert_eq(r.events.size(), 0, "dummy emits no aggro/attack events")
	assert_true(r.new_mob.is_dummy, "the training-dummy flag survives the tick copy")


# T-534: a mob chasing a player who flees directly away closes the gap at ~1% of the player's run
# speed per SECOND (a slow gain), NOT multiples. Simulate one wall-clock second = TICK_RATE_HZ ticks:
# each tick the player runs one player-step away (PLAYER_RUN_SPEED / TICK_RATE_HZ) and then the mob
# takes one chase step. Net closing per second must be ~PLAYER_RUN_SPEED * (speed_mult - 1) = 6.0 *
# 0.01 = 0.06 units. Before T-534 (0.15/frame, uncapped fps) the mob out-closed the player by
# multiples per second — this test would have failed hard.
func test_35_chase_closes_at_one_percent_of_player_speed_per_second() -> void:
	var player_step: float = _SC.PLAYER_RUN_SPEED / float(_SC.TICK_RATE_HZ)  # 0.30 / tick
	var mob = _make_mob(Vector3(0.0, 0.0, 0.0), _MAI.MobAIState.AGGROED)
	mob.current_target_id = 1
	mob.spawn_position = Vector3(0.0, 0.0, 0.0)  # keep the fleeing chase inside the leash
	mob.leash_radius = 1000.0
	mob.melee_range = 0.0  # never flips to MELEE, so it keeps chasing the whole second
	var flee_x: float = 5.0
	var start_gap: float = flee_x - mob.position.x
	var current_mob = mob
	for i in range(_SC.TICK_RATE_HZ):
		flee_x += player_step  # the player runs one step directly away first
		var players := {1: _make_player(Vector3(flee_x, 0.0, 0.0))}
		current_mob = _MAI.ai_tick(current_mob, players, _TT.new(), i, _make_rng()).new_mob
	var end_gap: float = flee_x - current_mob.position.x
	var closed: float = start_gap - end_gap
	var expected: float = _SC.PLAYER_RUN_SPEED * (_SC.MOB_CHASE_SPEED_MULT - 1.0)  # 0.06 u/s
	assert_almost_eq(closed, expected, 0.005, "mob closes ~1% of player run speed per second")
	assert_lt(closed, 0.2, "the mob must NOT out-close a fleeing player by multiples (the old bug)")


# T-534: chase movement is FRAME-RATE INDEPENDENT. main.gd advances mob AI once per SERVER TICK via a
# ResourceTicker tick-edge guard, so the SAME wall-clock second yields the SAME displacement no matter
# how many frames render inside it. Drive the exact production gate (_RT.is_new_tick) at 60 fps and at
# 30 fps over one second against a stationary target; the mob must land in the identical spot.
func test_36_chase_is_frame_rate_independent() -> void:
	var _RT = load("res://scripts/combat/resource_ticker.gd")
	var players := {1: _make_player(Vector3(100.0, 0.0, 0.0))}  # far, stationary → pure chase

	var end_pos_for = func(fps: int) -> Vector3:
		var mob = _make_mob(Vector3(0.0, 0.0, 0.0), _MAI.MobAIState.AGGROED)
		mob.current_target_id = 1
		mob.spawn_position = Vector3(0.0, 0.0, 0.0)
		mob.leash_radius = 1000.0
		var ticker = _RT.new()
		var current_mob = mob
		for frame in range(fps):  # `fps` frames == one wall-clock second
			var now_tick: int = int(frame * _SC.TICK_RATE_HZ / float(fps))
			if ticker.is_new_tick(now_tick):
				current_mob = (
					_MAI.ai_tick(current_mob, players, _TT.new(), now_tick, _make_rng()).new_mob
				)
		return current_mob.position

	var at_60 = end_pos_for.call(60)
	var at_30 = end_pos_for.call(30)
	assert_almost_eq(
		at_60.x, at_30.x, 0.0001, "same second → same chase distance regardless of fps"
	)
	assert_gt(at_60.x, 0.0, "the mob actually chased")


# ---- T-564: retaliate-only (passive-until-attacked, e.g. the tutorial sparring effigy) ----
# Report #18: a fresh player walking up to the quest giver at (12.5,9.0) was already inside the
# effigy's proximity aggro_radius (spawn 16,10, radius 5.0 -> ~3.64m away) and got auto-meleed
# before the tutorial started. Shrinking aggro_radius alone doesn't fix it — mob_aggro.gd's
# AGGRO_FLOOR (5.0m) guarantees a same-level, non-gray mob always notices within 5m regardless of
# the authored radius. retaliate_only skips the proximity scan entirely; the existing T-070 threat
# check (which never consulted aggro_radius) still fires the instant the mob takes threat.


func test_37_retaliate_only_ignores_proximity_even_inside_aggro_radius():
	var mob = _make_mob(Vector3(0.0, 0.0, 0.0), _MAI.MobAIState.IDLE)
	mob.retaliate_only = true
	# Same setup as test_02 (player at dist 4.0, inside aggro_radius 5.0) — a normal mob aggros here.
	var players := {1: _make_player(Vector3(4.0, 0.0, 0.0))}
	var tt := _TT.new()
	var current_mob = mob
	for i in range(100):  # many ticks — an idle/confused trainee standing at the ring
		var r = _MAI.ai_tick(current_mob, players, tt, i, _make_rng())
		current_mob = r.new_mob
		assert_eq(r.events.size(), 0, "no aggro/attack events while merely standing nearby")
	assert_eq(
		current_mob.ai_state,
		_MAI.MobAIState.IDLE,
		"retaliate_only must NOT proximity-aggro even well inside aggro_radius"
	)
	assert_eq(current_mob.current_target_id, -1, "never targets a player it wasn't attacked by")


func test_38_retaliate_only_still_aggros_and_engages_on_threat():
	# The player attacks first (threat added, as ability_executor.gd does on every landed hit) —
	# the effigy must still fully engage, exactly like a normal mob, so q_tut_03's interrupt lesson
	# is untouched.
	var mob = _make_mob(Vector3(10.0, 10.0, 0.0), _MAI.MobAIState.IDLE)
	mob.spawn_position = Vector3(10.0, 10.0, 0.0)
	mob.retaliate_only = true
	var players := {1: _make_player(Vector3(18.0, 10.0, 0.0))}  # dist 8 > aggro 5, inside leash
	var tt := _TT.new()
	tt.add_threat(1001, 1, 30)  # the attack that pulled it
	var result = _MAI.ai_tick(mob, players, tt, 0, _make_rng())
	assert_eq(
		result.new_mob.ai_state,
		_MAI.MobAIState.AGGROED,
		"being attacked must still pull a retaliate_only mob into combat"
	)
	assert_eq(result.new_mob.current_target_id, 1, "the attacker becomes the target")


func test_39_retaliate_only_flag_survives_the_tick_copy():
	var mob = _make_mob(Vector3(0.0, 0.0, 0.0), _MAI.MobAIState.IDLE)
	mob.retaliate_only = true
	var result = _MAI.ai_tick(mob, {}, _TT.new(), 0, _make_rng())
	assert_true(result.new_mob.retaliate_only, "retaliate_only must survive _copy_mob")


# ---- T-585: leash coverage — portal report #40 (Kobold Miners "chased 35+m with no leash") ----
# Investigation confirmed the leash/evade mechanism already exists (this file's test_05/test_06
# cover it from MELEE) and is exercised on every AGGROED/MELEE/RANGED tick via
# `mob.spawn_position.distance_to(target_pos) > mob.leash_radius`. The gap this closes: no test
# drove the break from AGGROED (chasing, not yet in melee) — the exact state a fleeing player
# leaves a mob in — and there was no explicit "still pursues inside the leash" regression guard.
# The real report #40 cause was the spawn sitting on top of the trainer NPC (see FIX 2,
# test_trainer_spawn_safety.gd), not a missing/oversized leash.


func test_40_aggroed_drag_beyond_leash_evades_clears_threat_and_resets_hp_on_return():
	var mob = _make_mob(Vector3(0.0, 0.0, 0.0), _MAI.MobAIState.AGGROED)
	mob.spawn_position = Vector3(0.0, 0.0, 0.0)  # reaches home in 1 tick once evading
	mob.current_target_id = 1
	mob.resources.hp = 1  # damaged — must be instantly restored on the leash break, not the return
	var players := {1: _make_player(Vector3(20.0, 0.0, 0.0))}  # dist 20 > leash_radius 15, chasing
	var tt := _TT.new()
	tt.add_threat(mob.entity_id, 1, 50)

	# Tick 1: still AGGROED (chasing, never reached melee) — leash breaks, evade + instant HP restore.
	var r1 = _MAI.ai_tick(mob, players, tt, 0, _make_rng())
	assert_eq(
		r1.new_mob.ai_state,
		_MAI.MobAIState.EVADING,
		"a chasing (AGGROED, not yet MELEE) mob beyond leash_radius must evade"
	)
	assert_eq(r1.new_mob.resources.hp, r1.new_mob.resources.max_hp, "HP restored on EVADING entry")

	# Tick 2: at spawn → IDLE, threat cleared.
	var r2 = _MAI.ai_tick(r1.new_mob, {}, tt, 1, _make_rng())
	assert_eq(r2.new_mob.ai_state, _MAI.MobAIState.IDLE, "reaches home and resets to IDLE")
	assert_eq(r2.new_mob.current_target_id, -1, "target cleared on reset")
	var cleared_threat := false
	for ev in r2.events:
		if ev.get("type", "") == "clear_threat":
			cleared_threat = true
	assert_true(cleared_threat, "clear_threat must fire so the pack can't re-aggro on stale threat")


func test_41_aggroed_chase_within_leash_still_pursues():
	# Negative case for test_40 — don't over-fix: a target still inside the leash must keep being
	# chased, never evaded early.
	var mob = _make_mob(Vector3(0.0, 0.0, 0.0), _MAI.MobAIState.AGGROED)
	mob.spawn_position = Vector3(0.0, 0.0, 0.0)
	mob.current_target_id = 1
	mob.melee_range = 0.5  # keep it out of MELEE range for the whole run
	var tt := _TT.new()
	var current_mob = mob
	for i in range(30):
		# Player flees but stays inside leash_radius (15) the whole time.
		var players := {1: _make_player(Vector3(10.0, 0.0, 0.0))}
		var r = _MAI.ai_tick(current_mob, players, tt, i, _make_rng())
		current_mob = r.new_mob
		assert_ne(
			current_mob.ai_state,
			_MAI.MobAIState.EVADING,
			"a target inside leash_radius must never trigger evade"
		)
	assert_gt(current_mob.position.x, 0.0, "the mob actually chased toward the in-leash target")
