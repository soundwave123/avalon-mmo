extends "res://addons/gut/test.gd"

# T-018: Global cooldown — pure function tests, no network, no engine loop.
# Tests GCD wire-up: triggers_gcd flag, ServerConfig.GCD_TICKS source of truth,
# advance_timers GCD→IDLE transition, and client-spam rejection.
# All tests use injected clock (now parameter) — no real waiting.

const CombatState = preload("res://scripts/combat/combat_state.gd")
const CombatStateMachine = preload("res://scripts/combat/action_state_machine.gd")
const ServerConfig = preload("res://scripts/server_config.gd")

var sm


func before_each() -> void:
	sm = CombatStateMachine.new()


func _make_state(initial_state = CombatState.CombatStateEnum.IDLE):
	var s = CombatState.new()
	s.state = initial_state
	return s


func _make_gcd_intent(target_id: int = 99) -> CombatState.CombatIntent:
	var i = CombatState.CombatIntent.new()
	i.type = CombatState.IntentType.USE_ABILITY
	i.ability_id = 1
	i.target_id = target_id
	i.triggers_gcd = true
	return i


func _make_off_gcd_intent(target_id: int = 99) -> CombatState.CombatIntent:
	var i = CombatState.CombatIntent.new()
	i.type = CombatState.IntentType.USE_ABILITY
	i.ability_id = 2
	i.target_id = target_id
	i.triggers_gcd = false
	return i


# --- T-018 assertion 1: GCD ability commits with correct gcd_until ---


func test_01_gcd_commit_sets_gcd_until_from_server_config() -> void:
	var state = _make_state(CombatState.CombatStateEnum.IDLE)
	var intent = _make_gcd_intent()
	var result = sm.tick(state, intent, 100)
	assert_true(result.accepted, "GCD ability from IDLE should be accepted")
	assert_eq(
		result.new_state.gcd_until,
		100 + ServerConfig.GCD_TICKS,
		"guild_until should be now + ServerConfig.GCD_TICKS"
	)
	assert_eq(
		result.new_state.state,
		CombatState.CombatStateEnum.GLOBAL_COOLDOWN,
		"state should be GLOBAL_COOLDOWN"
	)


# --- T-018 assertion 2: GCD ability rejected before gcd_until ---


func test_02_gcd_ability_rejected_before_gcd_until() -> void:
	var state = _make_state(CombatState.CombatStateEnum.GLOBAL_COOLDOWN)
	state.gcd_until = 130
	var intent = _make_gcd_intent()
	var result = sm.tick(state, intent, 129)
	assert_false(result.accepted, "GCD ability before gcd_until should be rejected")
	assert_eq(result.rejection_reason, "on_gcd", "rejection reason should be on_gcd")
	assert_eq(result.new_state.gcd_until, 130, "gcd_until should be unchanged on rejection")
	assert_eq(
		result.new_state.state,
		CombatState.CombatStateEnum.GLOBAL_COOLDOWN,
		"state should remain GLOBAL_COOLDOWN"
	)


# --- T-018 assertion 3: GCD ability accepted at gcd_until boundary ---


func test_03_gcd_ability_accepted_at_gcd_until() -> void:
	var state = _make_state(CombatState.CombatStateEnum.GLOBAL_COOLDOWN)
	state.gcd_until = 130
	var intent = _make_gcd_intent()
	var result = sm.tick(state, intent, 130)
	assert_true(result.accepted, "GCD ability at gcd_until should be accepted (>=)")
	assert_eq(result.new_state.gcd_until, 130 + ServerConfig.GCD_TICKS, "new gcd_until advances")


# --- T-018 assertion 4: off-GCD ability bypasses GCD check ---


func test_04_off_gcd_ability_bypasses_gcd() -> void:
	var state = _make_state(CombatState.CombatStateEnum.GLOBAL_COOLDOWN)
	state.gcd_until = 130
	var intent = _make_off_gcd_intent()
	var result = sm.tick(state, intent, 129)
	assert_true(result.accepted, "off-GCD ability should be accepted even while on GCD")


# --- T-018 assertion 5: advance_timers GCD→IDLE at boundary ---


func test_05_advance_timers_gcd_to_idle_at_boundary() -> void:
	var state = _make_state(CombatState.CombatStateEnum.GLOBAL_COOLDOWN)
	state.gcd_until = 130
	var new_state = sm.advance_timers(state, 130)
	assert_eq(
		new_state.state,
		CombatState.CombatStateEnum.IDLE,
		"advance_timers at now>=gcd_until should transition to IDLE"
	)
	assert_eq(
		state.state, CombatState.CombatStateEnum.GLOBAL_COOLDOWN, "input state must not be mutated"
	)


# --- T-018 assertion 6: advance_timers stays GLOBAL_COOLDOWN before boundary ---


func test_06_advance_timers_gcd_not_elapsed() -> void:
	var state = _make_state(CombatState.CombatStateEnum.GLOBAL_COOLDOWN)
	state.gcd_until = 130
	var new_state = sm.advance_timers(state, 129)
	assert_eq(
		new_state.state,
		CombatState.CombatStateEnum.GLOBAL_COOLDOWN,
		"advance_timers before gcd_until should stay GLOBAL_COOLDOWN"
	)


# --- T-018 assertion 7: client spam simulation ---


func test_07_client_spam_two_rapid_ticks() -> void:
	var state = _make_state(CombatState.CombatStateEnum.IDLE)
	var intent = _make_gcd_intent()

	var r1 = sm.tick(state, intent, 100)
	assert_true(r1.accepted, "first tick should be accepted")

	var r2 = sm.tick(r1.new_state, intent, 101)
	assert_false(r2.accepted, "second tick should be rejected (on_gcd)")
	assert_eq(r2.rejection_reason, "on_gcd", "rejection reason should be on_gcd")
	assert_eq(r2.new_state.gcd_until, 130, "gcd_until unchanged by second rejection")


# --- off-GCD from IDLE should NOT set gcd_until ---


func test_08_off_gcd_from_idle_no_gcd() -> void:
	var state = _make_state(CombatState.CombatStateEnum.IDLE)
	var intent = _make_off_gcd_intent()
	var result = sm.tick(state, intent, 200)
	assert_true(result.accepted, "off-GCD from IDLE should be accepted")
	assert_eq(
		result.new_state.state,
		CombatState.CombatStateEnum.IDLE,
		"off-GCD should stay in IDLE, not enter GLOBAL_COOLDOWN"
	)
	assert_eq(result.new_state.gcd_until, 0, "gcd_until should remain 0")
