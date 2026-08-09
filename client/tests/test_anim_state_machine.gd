extends GutTest

# T-123: pure AnimStateMachine tick/trigger math — no engine, no AnimationPlayer needed. The
# runtime hookup (entity_visuals.play_state actually getting called) is covered by
# test_local_player.gd / test_remote_entities_layer.gd's existing anim-state assertions.

const ASM = preload("res://scripts/world/anim_state_machine.gd")


func test_new_state_is_idle_and_alive() -> void:
	var s := ASM.new_state()
	assert_eq(ASM.display_state(s, 0.0), "idle")
	assert_false(bool(s["dead"]))


# ---- locomotion thresholds ----


func test_speed_below_threshold_reads_as_walk() -> void:
	var s := ASM.tick(ASM.new_state(), 1.2, false)  # NPC amble speed
	assert_eq(ASM.display_state(s, 0.0), "walk")


func test_mob_chase_speed_reads_as_walk_not_run() -> void:
	var s := ASM.tick(ASM.new_state(), 3.0, false)  # MOB_MOVE_SPEED (server_config.gd)
	assert_eq(ASM.display_state(s, 0.0), "walk", "3.0 m/s chase is a prowl, not a sprint")


func test_player_move_speed_reads_as_run() -> void:
	var s := ASM.tick(ASM.new_state(), 6.0, false)  # LocalPlayer.MOVE_SPEED
	assert_eq(ASM.display_state(s, 0.0), "run")


func test_zero_speed_reads_as_idle() -> void:
	var s := ASM.tick(ASM.new_state(), 0.0, false)
	assert_eq(ASM.display_state(s, 0.0), "idle")


func test_airborne_overrides_speed_to_jump() -> void:
	var s := ASM.tick(ASM.new_state(), 0.0, true)
	assert_eq(ASM.display_state(s, 0.0), "jump")
	var s2 := ASM.tick(ASM.new_state(), 6.0, true)
	assert_eq(ASM.display_state(s2, 0.0), "jump", "airborne wins over run speed too")


# ---- one-shot actions ----


func test_attack_plays_then_returns_to_locomotion() -> void:
	var s := ASM.new_state()
	s = ASM.trigger(s, "attack", 0.0)
	assert_eq(ASM.display_state(s, 0.0), "attack")
	assert_eq(ASM.display_state(s, 0.1), "attack", "still mid-swing")
	assert_eq(ASM.display_state(s, 10.0), "idle", "swing finished, released to locomotion")


func test_action_return_lands_on_current_locomotion_not_stale_idle() -> void:
	var s := ASM.new_state()
	s = ASM.tick(s, 6.0, false)  # running
	s = ASM.trigger(s, "attack", 0.0)
	s = ASM.tick(s, 6.0, false)  # still running while the swing plays
	assert_eq(ASM.display_state(s, 0.0), "attack", "one-shot still showing")
	assert_eq(ASM.display_state(s, 10.0), "run", "released into the CURRENT locomotion, not idle")


func test_hit_is_a_one_shot() -> void:
	var s := ASM.trigger(ASM.new_state(), "hit", 0.0)
	assert_eq(ASM.display_state(s, 0.0), "hit")
	assert_eq(ASM.display_state(s, 1.0), "idle")


func test_cast_is_a_one_shot() -> void:
	var s := ASM.trigger(ASM.new_state(), "cast", 0.0)
	assert_eq(ASM.display_state(s, 0.0), "cast")
	assert_eq(ASM.display_state(s, 1.0), "idle")


# ---- death stickiness ----


func test_death_sticks_forever() -> void:
	var s := ASM.trigger(ASM.new_state(), "death", 0.0)
	assert_eq(ASM.display_state(s, 0.0), "death")
	assert_eq(ASM.display_state(s, 999999.0), "death", "death never releases on its own")


func test_death_ignores_further_triggers() -> void:
	var s := ASM.trigger(ASM.new_state(), "death", 0.0)
	s = ASM.trigger(s, "hit", 1.0)
	assert_eq(ASM.display_state(s, 1.0), "death", "nothing outranks a dead state")


func test_tick_does_not_resurrect_a_dead_state() -> void:
	var s := ASM.trigger(ASM.new_state(), "death", 0.0)
	s = ASM.tick(s, 6.0, false)
	assert_eq(ASM.display_state(s, 0.0), "death", "locomotion ticks must not override death")


func test_reset_state_clears_death_for_respawn() -> void:
	var s := ASM.trigger(ASM.new_state(), "death", 0.0)
	s = ASM.respawn_reset()
	assert_eq(ASM.display_state(s, 0.0), "idle")
	assert_false(bool(s["dead"]))


# ---- interrupt priority matrix: death(3) > hit(2) > attack/cast(1) > locomotion(0) ----


func test_hit_interrupts_an_in_flight_attack() -> void:
	var s := ASM.trigger(ASM.new_state(), "attack", 0.0)
	s = ASM.trigger(s, "hit", 0.1)
	assert_eq(ASM.display_state(s, 0.1), "hit", "damage taken interrupts the swing pose")


func test_attack_cannot_interrupt_an_in_flight_hit() -> void:
	var s := ASM.trigger(ASM.new_state(), "hit", 0.0)
	s = ASM.trigger(s, "attack", 0.1)
	assert_eq(ASM.display_state(s, 0.1), "hit", "flinch still playing — the swing is dropped")


func test_cast_cannot_interrupt_an_in_flight_attack_priority_tie_refreshes_instead() -> void:
	var s := ASM.trigger(ASM.new_state(), "attack", 0.0)
	s = ASM.trigger(s, "cast", 0.1)  # same priority tier (1) as attack — refreshes, doesn't drop
	assert_eq(ASM.display_state(s, 0.1), "cast", "equal-priority action refreshes to the new one")


func test_death_interrupts_everything() -> void:
	for blocker in ["attack", "cast", "hit"]:
		var s := ASM.trigger(ASM.new_state(), blocker, 0.0)
		s = ASM.trigger(s, "death", 0.05)
		assert_eq(ASM.display_state(s, 0.05), "death", "death always wins over %s" % blocker)


func test_new_action_after_previous_one_shot_expired_is_not_blocked() -> void:
	var s := ASM.trigger(ASM.new_state(), "hit", 0.0)
	s = ASM.trigger(s, "attack", 5.0)  # well past the hit's ~0.37s hold
	assert_eq(ASM.display_state(s, 5.0), "attack", "an expired one-shot no longer blocks anything")


# ---- T-697 fix 1: the allocation-free hot-loop variant ----


func test_tick_in_place_mutates_the_given_dict_and_matches_pure_tick() -> void:
	var pure := ASM.tick(ASM.new_state(), 5.0, false, true)
	var s := ASM.new_state()
	var out := ASM.tick_in_place(s, 5.0, false, true)
	assert_true(is_same(out, s), "tick_in_place returns the SAME dict (no per-frame duplicate)")
	assert_eq(s, pure, "in-place transition result is value-identical to the pure tick()")


func test_tick_in_place_keeps_the_dead_freeze_rule() -> void:
	var s := ASM.trigger(ASM.new_state(), "death", 0.0)
	ASM.tick_in_place(s, 9.0, false)
	assert_eq(ASM.display_state(s, 1.0), "death", "a corpse never flickers back to locomotion")
