extends "res://addons/gut/test.gd"

# T-017: Action state machine skeleton — pure function tests, no network, no engine loop.
# All tests call tick() / advance_timers() with synthetic inputs and assert output fields.

const CombatState = preload("res://scripts/combat/combat_state.gd")
const CombatStateMachine = preload("res://scripts/combat/action_state_machine.gd")

# Singleton instance — pure functions, no internal state to reset between tests.
var sm


func before_each() -> void:
	sm = CombatStateMachine.new()


func _make_state(initial_state = CombatState.CombatStateEnum.IDLE):
	var s = CombatState.new()
	s.state = initial_state
	return s


func _make_ability_intent(ability_id: int = 1, target_id: int = 99) -> CombatState.CombatIntent:
	var i := CombatState.CombatIntent.new()
	i.type = CombatState.IntentType.USE_ABILITY
	i.ability_id = ability_id
	i.target_id = target_id
	i.triggers_gcd = true  # default: all abilities trigger GCD in M1
	return i


func _make_cancel_intent() -> CombatState.CombatIntent:
	var i := CombatState.CombatIntent.new()
	i.type = CombatState.IntentType.CANCEL_CAST
	i.ability_id = -1
	i.target_id = -1
	return i


# --- TICK TRANSITION TESTS (ticket assertions 1-5) ---


func test_01_idle_use_ability_instant_accepted_gcd() -> void:
	var state = _make_state(CombatState.CombatStateEnum.IDLE)
	var intent := _make_ability_intent()
	var result = sm.tick(state, intent, 100)
	assert_true(result.accepted, "idle use_ability should be accepted")
	assert_eq(
		result.new_state.state,
		CombatState.CombatStateEnum.GLOBAL_COOLDOWN,
		"new state should be GLOBAL_COOLDOWN for instant ability"
	)
	assert_eq(result.new_state.gcd_until, 130, "gcd_until = now + 30 ticks")
	assert_eq(result.rejection_reason, "", "rejection_reason should be empty on accept")
	# Input state must be unchanged (pure function, no mutation)
	assert_eq(state.state, CombatState.CombatStateEnum.IDLE, "input state must not be mutated")


func test_02_dead_use_ability_rejected() -> void:
	var state = _make_state(CombatState.CombatStateEnum.DEAD)
	var intent := _make_ability_intent()
	var result = sm.tick(state, intent, 200)
	assert_false(result.accepted, "dead entity must reject use_ability")
	assert_eq(result.new_state.state, CombatState.CombatStateEnum.DEAD, "state must remain DEAD")
	assert_ne(result.rejection_reason, "", "rejection reason must be set")


func test_03_casting_use_ability_rejected_already_casting() -> void:
	var state = _make_state(CombatState.CombatStateEnum.CASTING)
	var intent := _make_ability_intent()
	var result = sm.tick(state, intent, 300)
	assert_false(result.accepted, "casting entity must reject use_ability")
	assert_true(
		result.rejection_reason.to_lower().find("cast") >= 0,
		"rejection reason should mention casting"
	)
	assert_eq(
		result.new_state.state, CombatState.CombatStateEnum.CASTING, "state must remain CASTING"
	)


func test_04_gcd_use_ability_before_ready_rejected() -> void:
	var state = _make_state(CombatState.CombatStateEnum.GLOBAL_COOLDOWN)
	state.gcd_until = 150
	var intent := _make_ability_intent()
	var result = sm.tick(state, intent, 120)  # now < gcd_until
	assert_false(result.accepted, "gcd not elapsed must reject")
	assert_eq(
		result.new_state.state,
		CombatState.CombatStateEnum.GLOBAL_COOLDOWN,
		"state must remain GLOBAL_COOLDOWN"
	)


func test_05_gcd_use_ability_after_ready_accepted() -> void:
	var state = _make_state(CombatState.CombatStateEnum.GLOBAL_COOLDOWN)
	state.gcd_until = 150
	var intent := _make_ability_intent()
	var result = sm.tick(state, intent, 150)  # now >= gcd_until
	assert_true(result.accepted, "gcd elapsed should accept use_ability")
	assert_eq(
		result.new_state.state,
		CombatState.CombatStateEnum.GLOBAL_COOLDOWN,
		"new state should be GLOBAL_COOLDOWN"
	)
	assert_eq(result.new_state.gcd_until, 180, "gcd_until advances: now(150) + GCD(30) = 180")


# --- DETERMINISM TEST (ticket assertion 6) ---


func test_06_determinism_same_inputs_same_output() -> void:
	var base_state = _make_state(CombatState.CombatStateEnum.IDLE)
	var intent := _make_ability_intent(42, 77)
	var now: int = 999

	var r1 = sm.tick(base_state, intent, now)
	var r2 = sm.tick(base_state, intent, now)

	assert_eq(r1.accepted, r2.accepted, "accepted must be deterministic")
	assert_eq(r1.new_state.state, r2.new_state.state, "state must be deterministic")
	assert_eq(r1.new_state.gcd_until, r2.new_state.gcd_until, "gcd_until must be deterministic")
	assert_eq(r1.new_state.cast_start, r2.new_state.cast_start, "cast_start must be deterministic")
	assert_eq(r1.new_state.cast_end, r2.new_state.cast_end, "cast_end must be deterministic")
	assert_eq(
		r1.new_state.position_snapshot,
		r2.new_state.position_snapshot,
		"position_snapshot must be deterministic"
	)
	assert_eq(
		r1.new_state.cast_target_id,
		r2.new_state.cast_target_id,
		"cast_target_id must be deterministic"
	)
	assert_eq(
		r1.new_state.cast_ability_id,
		r2.new_state.cast_ability_id,
		"cast_ability_id must be deterministic"
	)
	assert_eq(r1.rejection_reason, r2.rejection_reason, "rejection_reason must be deterministic")
	assert_eq(r1.events.size(), r2.events.size(), "events count must be deterministic")


# --- ADVANCE_TIMERS TESTS (ticket assertions 7-8) ---


func test_07_advance_timers_gcd_expired_to_idle() -> void:
	var state = _make_state(CombatState.CombatStateEnum.GLOBAL_COOLDOWN)
	state.gcd_until = 10
	var new_state = sm.advance_timers(state, 10)  # now >= gcd_until
	assert_eq(
		new_state.state, CombatState.CombatStateEnum.IDLE, "expired GCD should transition to IDLE"
	)
	assert_eq(
		state.state, CombatState.CombatStateEnum.GLOBAL_COOLDOWN, "input state must not be mutated"
	)


func test_08_advance_timers_gcd_not_expired_stays() -> void:
	var state = _make_state(CombatState.CombatStateEnum.GLOBAL_COOLDOWN)
	state.gcd_until = 10
	var new_state = sm.advance_timers(state, 9)  # now < gcd_until
	assert_eq(
		new_state.state,
		CombatState.CombatStateEnum.GLOBAL_COOLDOWN,
		"unexpired GCD should stay GLOBAL_COOLDOWN"
	)
	assert_eq(
		state.state, CombatState.CombatStateEnum.GLOBAL_COOLDOWN, "input state must not be mutated"
	)


# --- CANCEL_CAST TRANSITION ---


func test_09_casting_cancel_returns_idle() -> void:
	var state = _make_state(CombatState.CombatStateEnum.CASTING)
	state.cast_start = 100
	state.cast_end = 140
	state.cast_target_id = 42
	state.cast_ability_id = 7
	state.position_snapshot = Vector3(1.0, 2.0, 0.0)
	var intent := _make_cancel_intent()
	var result = sm.tick(state, intent, 120)
	assert_true(result.accepted, "cancel_cast should be accepted while casting")
	assert_eq(result.new_state.state, CombatState.CombatStateEnum.IDLE, "new state should be IDLE")
	assert_eq(result.new_state.cast_start, 0, "cast_start cleared on cancel")
	assert_eq(result.new_state.cast_end, 0, "cast_end cleared on cancel")
	assert_eq(result.new_state.cast_target_id, -1, "cast_target_id cleared on cancel")
	assert_eq(result.new_state.cast_ability_id, -1, "cast_ability_id cleared on cancel")
	assert_eq(
		result.new_state.position_snapshot, Vector3.ZERO, "position_snapshot cleared on cancel"
	)


# --- CHANNELING REJECTION ---


func test_10_channeling_use_ability_rejected() -> void:
	var state = _make_state(CombatState.CombatStateEnum.CHANNELING)
	var intent := _make_ability_intent()
	var result = sm.tick(state, intent, 500)
	assert_false(result.accepted, "channeling must reject use_ability")
	assert_eq(
		result.new_state.state,
		CombatState.CombatStateEnum.CHANNELING,
		"state must remain CHANNELING"
	)


func test_11_channeling_cancel_accepted() -> void:
	var state = _make_state(CombatState.CombatStateEnum.CHANNELING)
	state.cast_target_id = 5
	state.cast_ability_id = 3
	var intent := _make_cancel_intent()
	var result = sm.tick(state, intent, 500)
	assert_true(result.accepted, "channeling should accept cancel")
	assert_eq(
		result.new_state.state,
		CombatState.CombatStateEnum.IDLE,
		"new state should be IDLE after channel cancel"
	)
	assert_eq(result.new_state.cast_target_id, -1, "cast_target_id cleared on channel cancel")
	assert_eq(result.new_state.cast_ability_id, -1, "cast_ability_id cleared on channel cancel")


# --- EXECUTING REJECTION ---


func test_12_executing_use_ability_rejected() -> void:
	var state = _make_state(CombatState.CombatStateEnum.EXECUTING)
	var intent := _make_ability_intent()
	var result = sm.tick(state, intent, 600)
	assert_false(result.accepted, "executing must reject use_ability")
	assert_eq(
		result.new_state.state, CombatState.CombatStateEnum.EXECUTING, "state must remain EXECUTING"
	)


# --- DEAD REJECTS EVERYTHING ---


func test_13_dead_cancel_rejected() -> void:
	var state = _make_state(CombatState.CombatStateEnum.DEAD)
	var intent := _make_cancel_intent()
	var result = sm.tick(state, intent, 700)
	assert_false(result.accepted, "dead entity must reject cancel_cast")
	assert_eq(result.new_state.state, CombatState.CombatStateEnum.DEAD, "state must remain DEAD")


# --- INPUT IMMUTABILITY CHECKS ---


func test_14_input_state_unchanged_after_tick() -> void:
	var original_state = _make_state(CombatState.CombatStateEnum.IDLE)
	original_state.gcd_until = 0
	var intent := _make_ability_intent()
	var result = sm.tick(original_state, intent, 100)
	# Verify input was not mutated
	assert_eq(
		original_state.state,
		CombatState.CombatStateEnum.IDLE,
		"input state must remain IDLE after tick"
	)
	assert_eq(original_state.gcd_until, 0, "input gcd_until must not change after tick")


# --- EDGE CASES ---


func test_15_gcd_use_ability_at_exact_boundary() -> void:
	var state = _make_state(CombatState.CombatStateEnum.GLOBAL_COOLDOWN)
	state.gcd_until = 200
	var intent := _make_ability_intent()
	var result = sm.tick(state, intent, 200)  # now == gcd_until (edge)
	assert_true(result.accepted, "now == gcd_until should accept (>= not >)")
	assert_eq(
		result.new_state.state,
		CombatState.CombatStateEnum.GLOBAL_COOLDOWN,
		"new GCD started after accepting at boundary"
	)
	assert_eq(result.new_state.gcd_until, 230, "gcd_until advances: now(200) + GCD(30) = 230")


func test_16_advance_timers_idle_no_transition() -> void:
	var state = _make_state(CombatState.CombatStateEnum.IDLE)
	var new_state = sm.advance_timers(state, 999)
	assert_eq(
		new_state.state,
		CombatState.CombatStateEnum.IDLE,
		"idle should stay idle under advance_timers"
	)


func test_17_advance_timers_dead_no_transition() -> void:
	var state = _make_state(CombatState.CombatStateEnum.DEAD)
	var new_state = sm.advance_timers(state, 999)
	assert_eq(
		new_state.state,
		CombatState.CombatStateEnum.DEAD,
		"dead should stay dead under advance_timers"
	)


# T-063: stun (CC) — a stunned entity can't use abilities.


func test_stunned_rejects_ability() -> void:
	var state = _make_state(CombatState.CombatStateEnum.IDLE)
	state.stunned_until = 100
	var result = sm.tick(state, _make_ability_intent(), 50)  # now 50 < stunned_until 100
	assert_false(result.accepted, "a stunned entity can't act")
	assert_eq(result.rejection_reason, "stunned")


func test_stun_expired_allows_ability() -> void:
	var state = _make_state(CombatState.CombatStateEnum.IDLE)
	state.stunned_until = 100
	var result = sm.tick(state, _make_ability_intent(), 100)  # now == stunned_until → expired
	assert_true(result.accepted, "stun expired at now → can act")
