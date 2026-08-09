extends GutTest

# T-051: CombatState.copy() is the single full copy (replaced three drifting hand-copies, one
# of which dropped the cast fields). It must carry every field and be independent.

const CombatState = preload("res://scripts/combat/combat_state.gd")


func test_copy_preserves_all_fields() -> void:
	var s = CombatState.new()
	s.state = CombatState.CombatStateEnum.CASTING
	s.gcd_until = 11
	s.cast_start = 22
	s.cast_end = 33
	s.position_snapshot = Vector3(4, 5, 0.0)
	s.cast_target_id = 6
	s.cast_ability_id = 7
	s.next_swing_tick = 8
	s.respawn_at = 9
	s.stunned_until = 44
	s.rooted_until = 55
	s.ability_cooldowns = {106: 300}
	s.school_locks = {"fire": 220}
	s.control_dr_stages = {"stun": 2}
	s.control_dr_reset_at = {"stun": 500}
	s.last_full_interrupt_at = 77
	var c = s.copy()
	assert_eq(c.state, CombatState.CombatStateEnum.CASTING)
	assert_eq(c.gcd_until, 11)
	assert_eq(c.cast_start, 22)
	assert_eq(c.cast_end, 33)
	assert_eq(c.position_snapshot, Vector3(4, 5, 0.0))
	assert_eq(c.cast_target_id, 6)
	assert_eq(c.cast_ability_id, 7)
	assert_eq(c.next_swing_tick, 8)
	assert_eq(c.respawn_at, 9)
	assert_eq(c.stunned_until, 44)
	assert_eq(c.rooted_until, 55)
	assert_eq(c.ability_cooldowns, {106: 300})
	assert_eq(c.school_locks, {"fire": 220})
	assert_eq(c.control_dr_stages, {"stun": 2})
	assert_eq(c.control_dr_reset_at, {"stun": 500})
	assert_eq(c.last_full_interrupt_at, 77)


func test_copy_is_independent_of_source() -> void:
	var s = CombatState.new()
	s.cast_start = 100
	var c = s.copy()
	c.cast_start = 999
	c.ability_cooldowns[106] = 999
	assert_eq(s.cast_start, 100, "mutating the copy must not touch the source")
	assert_false(s.ability_cooldowns.has(106), "nested cooldown dictionaries are independent")
