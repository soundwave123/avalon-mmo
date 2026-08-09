# T-023: Hit-based interrupt unit tests — pure function calls, no network.

extends GutTest

const _ASM = preload("res://scripts/combat/action_state_machine.gd")
const _AR = preload("res://scripts/combat/ability_registry.gd")
const _CS = preload("res://scripts/combat/combat_state.gd")
const _SC = preload("res://scripts/server_config.gd")


func _make_registry(cast_ticks: int = 40) -> Object:
	var registry = _AR.new()
	var cast_ability := AbilityData.new()
	cast_ability.id = 2
	cast_ability.name = "Emberstrike"
	cast_ability.cast_ticks = cast_ticks
	registry._abilities[2] = cast_ability
	return registry


func _make_state(state_enum: int, cast_start: int = 100, cast_end: int = 140) -> CombatState:
	var state := CombatState.new()
	state.state = state_enum
	state.cast_start = cast_start
	state.cast_end = cast_end
	state.cast_ability_id = 2
	state.cast_target_id = 99
	state.position_snapshot = Vector3(5.0, 5.0, 0.0)
	return state


func _make_strike(can_full_interrupt: bool = false) -> AbilityData:
	var strike := AbilityData.new()
	strike.id = 1
	strike.name = "Strike"
	strike.cast_ticks = 0
	strike.can_full_interrupt = can_full_interrupt
	return strike


func test_01_pushback_extends_cast_end_by_configured_ticks():
	var result = _ASM.apply_interrupt(
		_make_state(_CS.CombatStateEnum.CASTING, 100, 140), _make_strike(), _make_registry(), 120
	)
	assert_eq(result.cast_end, 150, "pushback must extend cast_end by PUSHBACK_TICKS")


func test_02_pushback_clamps_at_max_cast_end_on_sixth_hit():
	var registry = _make_registry()
	var max_cast_end: int = 100 + 40 + _SC.MAX_PUSHBACK_TICKS
	var state := _make_state(_CS.CombatStateEnum.CASTING, 100, max_cast_end - 59)
	for i in range(5):
		state = _ASM.apply_interrupt(state, _make_strike(), registry, 120 + i)
	assert_eq(state.cast_end, max_cast_end - 9, "first 5 hits extend by 50 ticks before cap")
	var after_clamp = _ASM.apply_interrupt(state, _make_strike(), registry, 130)
	assert_eq(after_clamp.cast_end, max_cast_end, "sixth pushback must clamp at max_cast_end")


func test_03_default_max_pushback_does_not_cap_five_realistic_hits():
	var registry = _make_registry()
	var state := _make_state(_CS.CombatStateEnum.CASTING, 100, 140)
	for i in range(5):
		state = _ASM.apply_interrupt(state, _make_strike(), registry, 120 + i)
	assert_eq(state.cast_end, 190, "five 10-tick pushbacks must extend cast_end by 50 ticks")


func test_04_idle_state_is_unchanged():
	var state := _make_state(_CS.CombatStateEnum.IDLE, 100, 140)
	var result = _ASM.apply_interrupt(state, _make_strike(), _make_registry(), 120)
	assert_eq(result.state, _CS.CombatStateEnum.IDLE, "IDLE state must remain IDLE")
	assert_eq(result.cast_end, 140, "non-casting cast_end must be unchanged")


func test_05_full_interrupt_cancels_cast():
	var result = _ASM.apply_interrupt(
		_make_state(_CS.CombatStateEnum.CASTING, 100, 140),
		_make_strike(true),
		_make_registry(),
		120
	)
	assert_eq(result.state, _CS.CombatStateEnum.IDLE, "full interrupt must return to IDLE")
	assert_eq(result.cast_ability_id, -1, "full interrupt must clear cast_ability_id")


func test_06_dead_state_is_unchanged():
	var state := _make_state(_CS.CombatStateEnum.DEAD, 100, 140)
	var result = _ASM.apply_interrupt(state, _make_strike(), _make_registry(), 120)
	assert_eq(result.state, _CS.CombatStateEnum.DEAD, "DEAD state must remain DEAD")
	assert_eq(result.cast_end, 140, "DEAD cast_end must be unchanged")
