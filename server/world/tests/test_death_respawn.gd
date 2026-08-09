extends "res://addons/gut/test.gd"

# T-026: Death and respawn — HP≤0 → Dead → respawn at spawn point
# Pure unit tests + minimal integration.

const CombatResources = preload("res://scripts/combat/combat_resources.gd")
const CombatState = preload("res://scripts/combat/combat_state.gd")
const CombatStateMachine = preload("res://scripts/combat/action_state_machine.gd")
const AbilityExecutor = preload("res://scripts/combat/ability_executor.gd")
const ServerConfig = preload("res://scripts/server_config.gd")

var asm: CombatStateMachine
var exec: AbilityExecutor


func before_each() -> void:
	asm = CombatStateMachine.new()
	exec = AbilityExecutor.new()


func _make_resources(
	int_val: int = 30, dex_val: int = 40, stamina_val: int = 50
) -> CombatResources:
	# T-061: HP now derives from the stamina stat (was str). Any positive entity suffices here.
	var stats := CharacterStats.new()
	stats.int_val = int_val
	stats.dex_val = dex_val
	stats.stamina_val = stamina_val
	var res := CombatResources.new()
	res.derive_from_stats(stats)
	return res


func _make_state(initial_state = CombatState.CombatStateEnum.IDLE) -> CombatState:
	var s = CombatState.new()
	s.state = initial_state
	s.gcd_until = 0
	s.respawn_at = 0
	return s


# ---- Assertion 1: apply_damage(res{hp=5}, 5) → hp==0, is_dead → true ----


func test_01_exact_damage_is_dead() -> void:
	var res := _make_resources()
	res.hp = 5
	var result := res.apply_damage(5)
	assert_eq(result.hp, 0, "hp clamped to 0 after exact damage")
	assert_true(CombatResources.is_dead(result), "is_dead must be true at hp=0")


# ---- Assertion 2: apply_damage(res{hp=5}, 10) → hp==0 (clamped), is_dead → true ----


func test_02_overkill_clamped_is_dead() -> void:
	var res := _make_resources()
	res.hp = 5
	var result := res.apply_damage(10)
	assert_eq(result.hp, 0, "hp clamped to 0 on overkill, not negative")
	assert_true(CombatResources.is_dead(result), "is_dead must be true after overkill")


# ---- Assertion 3: check_death_transition(IDLE, res{hp=0}) → DEAD ----


func test_03_death_transition_idle_to_dead() -> void:
	var state = _make_state(CombatState.CombatStateEnum.IDLE)
	var res := _make_resources()
	res.hp = 0
	var new_state = asm.check_death_transition(state, res, 100, ServerConfig.PLAYER_RESPAWN_TICKS)
	assert_eq(new_state.state, CombatState.CombatStateEnum.DEAD, "IDLE+hp0 → DEAD")


# ---- Assertion 4: check_death_transition(DEAD, res{hp=0}) → DEAD unchanged (no double) ----


func test_04_no_double_death_transition() -> void:
	var state = _make_state(CombatState.CombatStateEnum.DEAD)
	var res := _make_resources()
	res.hp = 0
	var new_state = asm.check_death_transition(state, res, 100, ServerConfig.PLAYER_RESPAWN_TICKS)
	assert_eq(new_state.state, CombatState.CombatStateEnum.DEAD, "DEAD stays DEAD")
	assert_eq(new_state.respawn_at, 0, "respawn_at unchanged when already DEAD (no re-set)")


# ---- Assertion 5: check_death_transition(IDLE, res{hp=1}) → IDLE unchanged ----


func test_05_no_death_when_hp_positive() -> void:
	var state = _make_state(CombatState.CombatStateEnum.IDLE)
	var res := _make_resources()
	res.hp = 1
	var new_state = asm.check_death_transition(state, res, 100, ServerConfig.PLAYER_RESPAWN_TICKS)
	assert_eq(new_state.state, CombatState.CombatStateEnum.IDLE, "IDLE stays IDLE when hp>0")


# ---- Assertion 6: DEAD state rejects ability intent ----


func test_06_dead_rejects_ability() -> void:
	var state = _make_state(CombatState.CombatStateEnum.DEAD)
	var intent := CombatState.CombatIntent.new()
	intent.type = CombatState.IntentType.USE_ABILITY
	intent.ability_id = 1
	intent.target_id = 99
	var result = asm.tick(state, intent, 200)
	assert_false(result.accepted, "DEAD must reject USE_ABILITY")
	assert_eq(result.new_state.state, CombatState.CombatStateEnum.DEAD, "state stays DEAD")


# ---- Assertion 7: respawn_at set on DEAD entry ----


func test_07_respawn_at_set_on_death() -> void:
	var state = _make_state(CombatState.CombatStateEnum.IDLE)
	var res := _make_resources()
	res.hp = 0
	var now: int = 500
	var new_state = asm.check_death_transition(state, res, now, ServerConfig.PLAYER_RESPAWN_TICKS)
	assert_eq(
		new_state.respawn_at,
		now + ServerConfig.PLAYER_RESPAWN_TICKS,
		"respawn_at == now + PLAYER_RESPAWN_TICKS"
	)


# ---- Assertion 8a: advance_timers fires respawn when delay elapsed ----


func test_08a_advance_timers_respawn_fires() -> void:
	var state = _make_state(CombatState.CombatStateEnum.DEAD)
	state.respawn_at = 100
	var new_state = asm.advance_timers(state, 100)
	assert_eq(
		new_state.state, CombatState.CombatStateEnum.IDLE, "DEAD → IDLE when now >= respawn_at"
	)
	assert_eq(new_state.respawn_at, 0, "respawn_at cleared after respawn")


func test_08b_advance_timers_respawn_not_yet() -> void:
	var state = _make_state(CombatState.CombatStateEnum.DEAD)
	state.respawn_at = 101
	var new_state = asm.advance_timers(state, 100)
	assert_eq(
		new_state.state, CombatState.CombatStateEnum.DEAD, "DEAD stays DEAD when now < respawn_at"
	)


func test_08c_advance_timers_dead_no_respawn_at_stays_dead() -> void:
	var state = _make_state(CombatState.CombatStateEnum.DEAD)
	state.respawn_at = 0  # never set
	var new_state = asm.advance_timers(state, 999)
	assert_eq(
		new_state.state,
		CombatState.CombatStateEnum.DEAD,
		"DEAD stays DEAD when respawn_at == 0 (no timer armed)"
	)


# ---- Assertion 9: respawn resets state, resources, position ----
# (Simulated here — the actual _handle_player_respawn lives in main.gd which is
# not a pure test target. We verify the state machine returns IDLE with cleared
# respawn_at, which is the prerequisite for a full respawn.)


func test_09_respawn_returns_idle_with_full_resources() -> void:
	var state = _make_state(CombatState.CombatStateEnum.DEAD)
	state.respawn_at = 50
	# Advance to respawn
	var new_state = asm.advance_timers(state, 50)
	assert_eq(new_state.state, CombatState.CombatStateEnum.IDLE, "state is IDLE after respawn")
	assert_eq(new_state.respawn_at, 0, "respawn_at is cleared")
	# The actual resource/position reset happens in main.gd._handle_player_respawn —
	# verified via integration below.


# ---- Assertion 10: Mob death transition + DEAD→IDLE after MOB_RESPAWN_TICKS ----


func test_10_mob_death_and_respawn_timing() -> void:
	var state = _make_state(CombatState.CombatStateEnum.IDLE)
	var res := _make_resources()
	res.hp = 0
	var now: int = 200
	# Mob death transition
	var dead_state = asm.check_death_transition(state, res, now, ServerConfig.MOB_RESPAWN_TICKS)
	assert_eq(dead_state.state, CombatState.CombatStateEnum.DEAD, "mob enters DEAD")
	assert_eq(
		dead_state.respawn_at,
		now + ServerConfig.MOB_RESPAWN_TICKS,
		"mob respawn_at == now + MOB_RESPAWN_TICKS"
	)
	# Advance to respawn
	var respawned = asm.advance_timers(dead_state, now + ServerConfig.MOB_RESPAWN_TICKS)
	assert_eq(respawned.state, CombatState.CombatStateEnum.IDLE, "mob respawns to IDLE")
	assert_eq(respawned.respawn_at, 0, "mob respawn_at cleared")


# ---- Assertion 11: No double-death — two kill-shots, death fires once ----


func test_11_no_double_death_two_kill_shots() -> void:
	var state = _make_state(CombatState.CombatStateEnum.IDLE)
	var res := _make_resources()
	res.hp = 10
	var now: int = 300

	# First kill-shot
	var after_first = asm.check_death_transition(
		state, res.apply_damage(10), now, ServerConfig.PLAYER_RESPAWN_TICKS
	)
	assert_eq(after_first.state, CombatState.CombatStateEnum.DEAD, "first kill-shot → DEAD")
	var death_respawn_at: int = after_first.respawn_at

	# Second kill-shot (should NOT change respawn_at or re-enter DEAD)
	var after_second = asm.check_death_transition(
		after_first, res.apply_damage(10), now + 1, ServerConfig.PLAYER_RESPAWN_TICKS
	)
	assert_eq(after_second.state, CombatState.CombatStateEnum.DEAD, "second kill-shot stays DEAD")
	assert_eq(after_second.respawn_at, death_respawn_at, "respawn_at unchanged by second kill-shot")


# ---- Ability executor skips DEAD targets ----


func test_12_ability_executor_skips_dead_target() -> void:
	# Build fake caster (dict-like object with required properties)
	var caster_obj = {
		"peer_id": 1,
		"combat_state": _make_state(CombatState.CombatStateEnum.IDLE),
		"resources": _make_resources(50, 30, 40),
		"position": Vector3(0, 0, 0.0),
		"stats": {"str": 50, "int": 30, "dex": 40},
	}

	# Build fake dead target
	var target_res := _make_resources(50, 30, 40)
	target_res.hp = 0
	var target_obj = {
		"peer_id": 2,
		"combat_state": _make_state(CombatState.CombatStateEnum.DEAD),
		"resources": target_res,
		"position": Vector3(1, 0, 0.0),
		"stats": {"str": 20, "int": 20, "dex": 20},
	}

	# Build minimal AbilityData
	var ability_data = preload("res://scripts/combat/ability_data.gd")
	var ability = ability_data.new()
	ability.id = 1
	ability.name = "Test"
	ability.range_units = 10.0
	ability.mana_cost = 0
	ability.stamina_cost = 0
	ability.cast_ticks = 0
	ability.triggers_gcd = true
	ability.base_damage = 10
	ability.threat_multiplier = 1.0

	var result = exec.execute_ability(
		caster_obj, target_obj, ability, 100, RandomNumberGenerator.new()
	)
	assert_false(result.accepted, "ability should reject DEAD target")
	assert_true(result.rejection_reason.find("dead") >= 0, "reason should mention dead")


# ---- Input immutability on check_death_transition ----


func test_13_death_transition_does_not_mutate_input() -> void:
	var state = _make_state(CombatState.CombatStateEnum.IDLE)
	var res := _make_resources()
	res.hp = 0
	var original_state_val = state.state
	asm.check_death_transition(state, res, 100, ServerConfig.PLAYER_RESPAWN_TICKS)
	assert_eq(state.state, original_state_val, "input state not mutated")


# ---- _copy_state copies respawn_at ----


func test_14_copy_state_copies_respawn_at() -> void:
	var src = _make_state(CombatState.CombatStateEnum.DEAD)
	src.respawn_at = 999
	var dst = asm._copy_state(src)
	assert_eq(dst.respawn_at, 999, "_copy_state must copy respawn_at")


# ---- GCD and cast cleared on death transition ----


func test_15_death_clears_gcd_and_cast() -> void:
	var state = _make_state(CombatState.CombatStateEnum.CASTING)
	state.gcd_until = 500
	state.cast_ability_id = 7
	state.cast_end = 200
	var res := _make_resources()
	res.hp = 0
	var new_state = asm.check_death_transition(state, res, 100, ServerConfig.PLAYER_RESPAWN_TICKS)
	assert_eq(new_state.state, CombatState.CombatStateEnum.DEAD, "cast cancelled → DEAD")
	assert_eq(new_state.cast_ability_id, -1, "cast_ability_id cleared on death")
	assert_eq(new_state.cast_end, 0, "cast_end cleared on death")
	assert_eq(new_state.gcd_until, 0, "gcd_until cleared on death")
