# T-332: Hollowed Crypt boss mechanics — pure, headless unit tests over boss_mechanics.gd.
# Each boss carries ONE mechanic beyond the T-294 enrage; these prove the summon CADENCE, the dirge
# INTERRUPT threshold + channel lifecycle, and the Maldrath PHASE flip (faster cadence). No OS time,
# no engine loop, no network — the boss JSONs are loaded through the real mob_loader and driven tick
# by tick. Inputs are never mutated (the pure-tick contract).

extends GutTest

const _BM = preload("res://scripts/combat/boss_mechanics.gd")
const _MAI = preload("res://scripts/combat/mob_ai.gd")
const _ML = preload("res://scripts/combat/mob_loader.gd")
const _CS = preload("res://scripts/combat/combat_state.gd")

const _MOBS_DIR := "res://data/mobs"


func _rng() -> RandomNumberGenerator:
	var r := RandomNumberGenerator.new()
	r.seed = 7
	return r


# Load a real boss into the "actively fighting" state (MELEE, alive) so is_active() is true.
func _engaged_boss(file: String) -> Object:
	var mob = _ML.load_from_file(_MOBS_DIR + "/" + file, 5000)
	assert_not_null(mob, "%s must load" % file)
	mob.ai_state = _MAI.MobAIState.MELEE
	mob.combat_state.state = _CS.CombatStateEnum.IDLE  # combat_state IDLE = alive/not-channeling
	return mob


func _first_action(res, type_name: String) -> Dictionary:
	for a in res.actions:
		if str(a.get("type", "")) == type_name:
			return a
	return {}


# ---- is_active / out-of-combat reset ----


func test_idle_boss_is_inactive_and_resets():
	var boss = _engaged_boss("crypt_aldric.json")
	boss.ai_state = _MAI.MobAIState.IDLE
	boss.last_mechanic_tick = 500
	var res = _BM.tick(boss, 999, _rng())
	assert_true(res.actions.is_empty(), "an idle boss fires no mechanic")
	assert_eq(res.new_mob.last_mechanic_tick, -100000, "idle boss re-arms its cadence")


func test_evading_boss_drops_dirge_channel():
	var boss = _engaged_boss("crypt_vharis.json")
	boss.combat_state.state = _CS.CombatStateEnum.CHANNELING
	boss.combat_state.cast_end = 2000
	boss.ai_state = _MAI.MobAIState.EVADING
	var res = _BM.tick(boss, 100, _rng())
	assert_eq(
		res.new_mob.combat_state.state, _CS.CombatStateEnum.IDLE, "leaving combat cancels the dirge"
	)


func test_input_mob_never_mutated():
	var boss = _engaged_boss("crypt_aldric.json")
	boss.last_mechanic_tick = -100000
	var before: int = boss.last_mechanic_tick
	_BM.tick(boss, 10000, _rng())
	assert_eq(boss.last_mechanic_tick, before, "tick() must not mutate its input MobData")


# ---- Warden Aldric: summon cadence + cap intent ----


func test_summon_fires_on_first_engaged_tick():
	# armed (last_mechanic_tick == -100000): the first engaged tick raises adds.
	var boss = _engaged_boss("crypt_aldric.json")
	var res = _BM.tick(boss, 0, _rng())
	var act := _first_action(res, "summon")
	assert_false(act.is_empty(), "Warden summons on the opening tick")
	assert_eq(str(act.get("mob_file", "")), "skeletal_warrior.json", "summons skeletal warriors")
	assert_eq(int(act.get("max_adds", 0)), 2, "cap of 2 adds passed to the live layer")
	assert_eq(res.new_mob.last_mechanic_tick, 0, "cadence clock stamped")


func test_summon_respects_cadence():
	var boss = _engaged_boss("crypt_aldric.json")
	boss.last_mechanic_tick = 100
	# cadence is 300 ticks; at +299 nothing, at +300 it fires again.
	assert_true(_first_action(_BM.tick(boss, 399, _rng()), "summon").is_empty(), "no summon early")
	assert_false(
		_first_action(_BM.tick(boss, 400, _rng()), "summon").is_empty(), "summon at cadence"
	)


# ---- Vharis: dirge channel lifecycle + damage interrupt ----


func test_dirge_starts_and_snapshots_hp():
	var boss = _engaged_boss("crypt_vharis.json")
	var res = _BM.tick(boss, 0, _rng())
	assert_false(_first_action(res, "dirge_start").is_empty(), "the dirge begins")
	assert_eq(
		res.new_mob.combat_state.state,
		_CS.CombatStateEnum.CHANNELING,
		"reuses the CHANNELING state"
	)
	assert_eq(res.new_mob.combat_state.cast_end, boss.dirge_channel_ticks, "cast window set")
	assert_eq(
		res.new_mob.dirge_hp_at_start, boss.resources.hp, "HP snapshot for the interrupt check"
	)


func test_dirge_pulses_mid_channel():
	var boss = _engaged_boss("crypt_vharis.json")
	boss.combat_state.state = _CS.CombatStateEnum.CHANNELING
	boss.combat_state.cast_end = 120
	boss.dirge_hp_at_start = boss.resources.hp
	var act := _first_action(_BM.tick(boss, 60, _rng()), "dirge_pulse")
	assert_false(act.is_empty(), "the dirge pulses AoE each channel tick")
	assert_eq(int(act.get("amount", 0)), boss.dirge_damage, "pulse deals dirge_damage")


func test_dirge_interrupted_by_damage_threshold():
	var boss = _engaged_boss("crypt_vharis.json")
	boss.combat_state.state = _CS.CombatStateEnum.CHANNELING
	boss.combat_state.cast_end = 120
	boss.dirge_hp_at_start = boss.resources.hp
	# The party out-damages the interrupt threshold during the channel.
	boss.resources.hp = boss.resources.hp - boss.dirge_interrupt_damage
	var res = _BM.tick(boss, 60, _rng())
	var end := _first_action(res, "dirge_end")
	assert_false(end.is_empty(), "the dirge ends")
	assert_true(bool(end.get("interrupted", false)), "it was interrupted")
	assert_eq(res.new_mob.combat_state.state, _CS.CombatStateEnum.IDLE, "channel cleared")
	assert_true(_first_action(res, "dirge_pulse").is_empty(), "no pulse on the interrupt tick")


func test_dirge_not_interrupted_below_threshold():
	var boss = _engaged_boss("crypt_vharis.json")
	boss.combat_state.state = _CS.CombatStateEnum.CHANNELING
	boss.combat_state.cast_end = 120
	boss.dirge_hp_at_start = boss.resources.hp
	boss.resources.hp = boss.resources.hp - (boss.dirge_interrupt_damage - 1)  # one short
	var res = _BM.tick(boss, 60, _rng())
	assert_true(_first_action(res, "dirge_end").is_empty(), "not enough damage — dirge continues")
	assert_false(_first_action(res, "dirge_pulse").is_empty(), "still pulsing")


func test_dirge_completes_uninterrupted():
	var boss = _engaged_boss("crypt_vharis.json")
	boss.combat_state.state = _CS.CombatStateEnum.CHANNELING
	boss.combat_state.cast_end = 120
	boss.dirge_hp_at_start = boss.resources.hp
	var end := _first_action(_BM.tick(boss, 120, _rng()), "dirge_end")
	assert_false(end.is_empty(), "the channel completes at cast_end")
	assert_false(bool(end.get("interrupted", false)), "completed, not interrupted")


func test_dedicated_interrupt_ends_dirge_and_starts_full_cadence():
	var boss = _engaged_boss("crypt_vharis.json")
	boss.combat_state.state = _CS.CombatStateEnum.IDLE  # executor already cancelled CHANNELING
	boss.combat_state.last_full_interrupt_at = 60
	boss.dirge_hp_at_start = boss.resources.hp
	boss.last_mechanic_tick = -100000
	var ended = _BM.tick(boss, 60, _rng())
	var action := _first_action(ended, "dirge_end")
	assert_true(bool(action.get("interrupted", false)), "dedicated kick is a real dirge interrupt")
	assert_eq(ended.new_mob.last_mechanic_tick, 60, "cadence starts at the interrupt tick")
	var waiting = _BM.tick(ended.new_mob, 60 + boss.mechanic_cadence - 1, _rng())
	assert_true(_first_action(waiting, "dirge_start").is_empty(), "no immediate channel restart")


func test_final_boss_immunity_flags_load_from_data():
	for file in ["crypt_maldrath.json", "vault_hollow_king.json"]:
		var boss = _ML.load_from_file(_MOBS_DIR + "/" + file, 9900)
		assert_true(boss.control_immune, "%s resists hard CC" % file)
		assert_true(boss.interrupt_immune, "%s resists full interrupts" % file)


# ---- Maldrath: phase flip → enrage (T-294) + faster summons ----


func test_phase_flip_once_below_half_hp():
	var boss = _engaged_boss("crypt_maldrath.json")
	# above 50%: no flip.
	boss.resources.hp = int(boss.resources.max_hp * 0.6)
	assert_true(
		_first_action(_BM.tick(boss, 0, _rng()), "phase_flip").is_empty(), "no flip above 50%"
	)
	# at/below 50%: flip once.
	boss.resources.hp = int(boss.resources.max_hp * 0.5)
	var res = _BM.tick(boss, 0, _rng())
	assert_false(_first_action(res, "phase_flip").is_empty(), "phase 2 flips at 50%")
	assert_true(res.new_mob.in_phase2, "in_phase2 latched")
	# already in phase 2: no second flip.
	assert_true(
		_first_action(_BM.tick(res.new_mob, 1, _rng()), "phase_flip").is_empty(), "flips once"
	)


func test_phase2_uses_faster_summon_cadence():
	var boss = _engaged_boss("crypt_maldrath.json")
	boss.in_phase2 = true
	boss.last_mechanic_tick = 0
	# phase2_cadence 200 < mechanic_cadence 400: a summon that would NOT fire pre-phase fires now.
	assert_true(boss.phase2_cadence < boss.mechanic_cadence, "phase 2 cadence is faster")
	assert_false(
		_first_action(_BM.tick(boss, 200, _rng()), "summon").is_empty(),
		"phase-2 summons at the faster cadence"
	)


func test_enrage_threshold_aligned_with_phase():
	# The phase-2 enrage is the T-294 swing-path buff — its threshold must equal the phase threshold
	# so "phase 2" == "enrage" as designed (no separate enrage plumbing).
	var boss = _ML.load_from_file(_MOBS_DIR + "/crypt_maldrath.json", 5001)
	assert_eq(
		boss.enrage_threshold, boss.phase2_threshold, "enrage fires exactly at the phase flip"
	)
	assert_gt(boss.enrage_mult, 1.0, "phase 2 actually enrages the swings")
