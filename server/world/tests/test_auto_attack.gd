# T-019: Auto-attack swing timer — unit tests.
# All tests are pure function calls with injected `now` — no engine loop, no network.

extends GutTest

const _AA = preload("res://scripts/combat/auto_attack.gd")
const _CS = preload("res://scripts/combat/combat_state.gd")
const _CR = preload("res://scripts/combat/combat_resources.gd")
const _CS2 = preload("res://scripts/combat/character_stats.gd")
const _SC = preload("res://scripts/server_config.gd")
const _ADAT = preload("res://scripts/combat/ability_data.gd")


func _setup_state(state_enum: int) -> CombatState:
	var s = _CS.new()
	s.state = state_enum
	s.next_swing_tick = 0
	return s


func _setup_resources(stamina_val: int) -> CombatResources:
	var r = _CR.new()
	r.hp = 100
	r.max_hp = 100
	r.mana = 50
	r.max_mana = 50
	r.stamina = stamina_val
	r.max_stamina = stamina_val
	return r


func _setup_stats(weapon_speed_val: float = 1.0) -> CharacterStats:
	var s = _CS2.new()
	s.weapon_speed = weapon_speed_val
	return s


# --- compute_swing_ticks tests ---


func test_compute_swing_ticks_normal_stamina():
	"""compute_swing_ticks(100, 1.0) == floor(15000 / (200 * 1.0)) == 75"""
	var ticks = _AA.compute_swing_ticks(100, 1.0)
	assert_eq(75, ticks, "Normal stamina 100, ws 1.0 should yield 75 ticks")


func test_compute_swing_ticks_zero_stamina():
	"""compute_swing_ticks(0, 1.0) == floor(15000 / (100 * 1.0)) == 150"""
	var ticks = _AA.compute_swing_ticks(0, 1.0)
	assert_eq(150, ticks, "Zero stamina, ws 1.0 should yield 150 ticks")


func test_compute_swing_ticks_high_stamina_fast_weapon():
	"""compute_swing_ticks(400, 4.0) == max(5, floor(15000/(500*4))) == max(5, 7) == 7"""
	var ticks = _AA.compute_swing_ticks(400, 4.0)
	assert_eq(7, ticks, "Stamina 400, ws 4.0 should yield 7 ticks")


func test_compute_swing_ticks_minimum_floor():
	"""compute_swing_ticks(9999, 99.0) >= SWING_TICKS_MIN (5)"""
	var ticks = _AA.compute_swing_ticks(9999, 99.0)
	assert_true(ticks >= _SC.SWING_TICKS_MIN, "Swing ticks should never be below minimum floor")
	# floor(15000 / (10099 * 99)) = floor(0.015) = 0, so floor clamps to 5
	assert_eq(_SC.SWING_TICKS_MIN, ticks, "Extreme values should clamp to SWING_TICKS_MIN")


# --- process_auto_attack integration tests ---


func test_swing_interval_slows_as_stamina_drops():
	"""Entity starts at stamina 100, fires 3 swings draining STAMINA_DRAIN_PER_SWING each.
	4th interval is longer than 1st because stamina decreased."""
	var state = _setup_state(_CS.CombatStateEnum.IDLE)
	var stats = _setup_stats(1.0)
	var res = _setup_resources(100)

	var now: int = 0
	state.next_swing_tick = 0

	var first_interval = 0
	var fourth_interval = 0

	for i in range(4):
		var result = _AA.process_auto_attack(state, res, stats, 42, now)
		assert_false(result.is_noop, "Swing %d should fire" % (i + 1))

		if i == 0:
			first_interval = result.new_next_swing_tick - now
		if i == 3:
			fourth_interval = result.new_next_swing_tick - now

		# Advance state for next iteration
		now = result.new_next_swing_tick
		state.next_swing_tick = result.new_next_swing_tick
		# Drain stamina from resources (pure — returns new instance)
		res = res.apply_stamina_drain(_SC.STAMINA_DRAIN_PER_SWING)

	# Stamina decreased → swing interval should be longer
	assert_true(
		fourth_interval > first_interval,
		(
			"4th swing interval (%d) should be longer than 1st (%d) as stamina drops"
			% [fourth_interval, first_interval]
		)
	)


func test_dead_entity_noop():
	"""process_auto_attack on DEAD entity returns noop (no swing, no drain)."""
	var state = _setup_state(_CS.CombatStateEnum.DEAD)
	var res = _setup_resources(100)
	var stats = _setup_stats(1.0)
	var result = _AA.process_auto_attack(state, res, stats, 42, 100)
	assert_true(result.is_noop, "Dead entity should return noop")


func test_no_target_noop():
	"""Entity with target_id == -1 returns noop."""
	var state = _setup_state(_CS.CombatStateEnum.IDLE)
	var res = _setup_resources(100)
	var stats = _setup_stats(1.0)
	var result = _AA.process_auto_attack(state, res, stats, -1, 100)
	assert_true(result.is_noop, "No target should return noop")


func test_real_swing_carries_server_computed_mitigation() -> void:
	var attacker := _setup_stats(1.0)
	var defender := _setup_stats(1.0)
	defender.armor_val = 100
	var ability := _ADAT.new()
	ability.base_damage = 100
	ability.variance_min = 1.0
	ability.variance_max = 1.0
	var rng := RandomNumberGenerator.new()
	rng.seed = 1
	var result = _AA.process_auto_attack(
		_setup_state(_CS.CombatStateEnum.IDLE),
		_setup_resources(100),
		attacker,
		42,
		100,
		defender,
		ability,
		rng
	)
	assert_eq(result.damage_amount, 50, "armor 100 halves raw 100 at K=100")
	assert_eq(result.mitigated_amount, 50, "the prevented half reaches the recap event seam")
