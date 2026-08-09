# T-722: the boss wind-up telegraph — proof that `dirge_start` / `dirge_end` reach the client.
#
# Before this ticket the channel was invisible: boss_mechanics emitted dirge_start/dirge_end,
# instance_service._apply_boss_action had no case for either, and mobs_array shipped no cast field,
# so nothing about the 3 s wind-up ever crossed the wire. The q_tut_03 interrupt lesson paid off on
# a telegraph the player could not see (T-719 finding 2).
#
# The fix carries NO new message type: the dirge already parks the mob in CombatState.CHANNELING
# with cast_start/cast_end stamped, so the wind-up rides the positions broadcast as the very same
# `cast` dict a player's cast bar uses (T-264/T-266). These tests drive the REAL Sexton Marrow and
# the REAL training effigy through boss_mechanics tick by tick and assert what a client would
# actually receive at each phase — dirge_start makes a cast appear, dirge_end (interrupted OR
# completed) makes it vanish, and the T-699 delta explicitly CLEARS it rather than dropping the key.
#
# The client half (the bar rendering from this payload) is client/tests/test_remote_entities.gd.

extends GutTest

const _BB = preload("res://scripts/broadcast_builder.gd")
const _BM = preload("res://scripts/combat/boss_mechanics.gd")
const _MAI = preload("res://scripts/combat/mob_ai.gd")
const _ML = preload("res://scripts/combat/mob_loader.gd")
const _CS = preload("res://scripts/combat/combat_state.gd")

const _MOBS_DIR := "res://data/mobs"
const _HZ := 20


func _rng() -> RandomNumberGenerator:
	var r := RandomNumberGenerator.new()
	r.seed = 7
	return r


# A real boss in the "actively fighting" state, so is_active() is true and the mechanic runs.
func _engaged_boss(file: String) -> Object:
	var mob = _ML.load_from_file(_MOBS_DIR + "/" + file, 5000)
	assert_not_null(mob, "%s must load" % file)
	mob.ai_state = _MAI.MobAIState.MELEE
	mob.combat_state.state = _CS.CombatStateEnum.IDLE
	return mob


func _has_action(res, type_name: String) -> bool:
	for a in res.actions:
		if str(a.get("type", "")) == type_name:
			return true
	return false


# The single mob's row exactly as a client receives it.
func _row(mob, now_tick: int) -> Dictionary:
	return _BB.mobs_array({int(mob.entity_id): mob}, now_tick, _HZ)[0]


# ---- dirge_start -> the client learns a wind-up is running ----


func test_dirge_start_puts_a_cast_on_the_wire() -> void:
	var boss = _engaged_boss("sexton_marrow.json")
	assert_false(
		_row(boss, 0).has("cast"), "an idle boss ships no cast (costs nothing on the wire)"
	)
	var res = _BM.tick(boss, 0, _rng())
	assert_true(_has_action(res, "dirge_start"), "the wind-up begins")
	var row := _row(res.new_mob, 0)
	assert_true(row.has("cast"), "dirge_start is now VISIBLE to the client — the T-722 fix")
	assert_almost_eq(float(row["cast"]["remaining_s"]), 3.0, 0.001, "full window remains at start")


func test_the_window_is_derived_from_mob_data_not_hardcoded() -> void:
	# The 3 s the ticket quotes is dirge_channel_ticks (60) / TICK_RATE_HZ (20) — authored in
	# sexton_marrow.json. Nothing client-side or wire-side may hardcode a literal 3.
	var boss = _engaged_boss("sexton_marrow.json")
	var started = _BM.tick(boss, 0, _rng()).new_mob
	var expected: float = float(boss.dirge_channel_ticks) / float(_HZ)
	assert_almost_eq(
		float(_row(started, 0)["cast"]["total_s"]), expected, 0.001, "window from data"
	)
	assert_almost_eq(expected, 3.0, 0.001, "and that authored window is in fact the 3 s lesson")


func test_the_bar_drains_across_the_window() -> void:
	var boss = _engaged_boss("sexton_marrow.json")
	var started = _BM.tick(boss, 0, _rng()).new_mob
	assert_almost_eq(float(_row(started, 30)["cast"]["remaining_s"]), 1.5, 0.001, "half-way")
	assert_almost_eq(float(_row(started, 50)["cast"]["remaining_s"]), 0.5, 0.001, "nearly done")


# ---- dirge_end -> the telegraph clears, both ways out of the channel ----


func test_dirge_end_interrupted_clears_the_cast() -> void:
	# The lesson's win condition: 24 damage inside the window (the role-free damage path a priest,
	# who has no kick, uses). The bar must vanish the instant the wind-up breaks.
	var boss = _engaged_boss("sexton_marrow.json")
	boss = _BM.tick(boss, 0, _rng()).new_mob
	assert_true(_row(boss, 10).has("cast"), "channelling mid-window")
	boss.resources.hp = boss.resources.hp - boss.dirge_interrupt_damage
	var res = _BM.tick(boss, 10, _rng())
	assert_true(_has_action(res, "dirge_end"), "the wind-up breaks")
	assert_false(_row(res.new_mob, 10).has("cast"), "dirge_end interrupted -> telegraph gone")


func test_dirge_end_completed_clears_the_cast() -> void:
	var boss = _engaged_boss("sexton_marrow.json")
	boss = _BM.tick(boss, 0, _rng()).new_mob
	var res = _BM.tick(boss, boss.dirge_channel_ticks, _rng())
	assert_true(_has_action(res, "dirge_end"), "the channel completes at cast_end")
	assert_false(_row(res.new_mob, 60).has("cast"), "dirge_end completed -> telegraph gone")


func test_dedicated_interrupt_also_clears_the_telegraph() -> void:
	# Pummel / Counterspell cancel CHANNELING at ability-commit time; boss_mechanics consumes the
	# stamped tick. Either interrupt route must leave the player with no lingering bar.
	var boss = _engaged_boss("sexton_marrow.json")
	boss = _BM.tick(boss, 0, _rng()).new_mob
	boss.combat_state.state = _CS.CombatStateEnum.IDLE  # the executor already cancelled the channel
	boss.combat_state.last_full_interrupt_at = 10
	var res = _BM.tick(boss, 10, _rng())
	assert_true(_has_action(res, "dirge_end"), "a dedicated kick is a real dirge_end")
	assert_false(_row(res.new_mob, 10).has("cast"), "no orphaned bar after a kick")


# ---- the delta must CLEAR the finished cast, not merely omit it ----


func test_delta_clears_a_finished_windup() -> void:
	# The client merge is a field overwrite, not a key drop (T-699): if the ended cast were simply
	# omitted from the delta row the bar would hang on screen forever. _empty_like must send {}.
	var boss = _engaged_boss("sexton_marrow.json")
	var channelling := _row(_BM.tick(boss, 0, _rng()).new_mob, 0)
	var idle := _row(boss, 0)
	var delta: Dictionary = _BB._row_delta(channelling, idle, "mob_id")
	assert_true(delta.has("cast"), "the ended wind-up is explicitly transmitted")
	assert_true((delta["cast"] as Dictionary).is_empty(), "...as {} so the client clears the bar")


# ---- the training effigy teaches the same lesson through the same payload ----


func test_training_effigy_windup_is_also_visible() -> void:
	var effigy = _engaged_boss("training_effigy.json")
	var res = _BM.tick(effigy, 0, _rng())
	assert_true(_has_action(res, "dirge_start"), "q_tut_03's practice wind-up begins")
	assert_almost_eq(
		float(_row(res.new_mob, 0)["cast"]["total_s"]), 3.0, 0.001, "same readable 3 s window"
	)


func test_the_telegraph_survives_the_retaliate_only_disposition() -> void:
	# The trap this ticket had to clear: every mob whose wind-up matters is retaliate_only, which
	# broadcasts hostile:false. The payload must still carry the cast — the client's T-266 gate is
	# what had to widen to NEUTRAL mobs (see _shows_cast_bar in remote_entities_layer.gd).
	var boss = _engaged_boss("sexton_marrow.json")
	assert_true(boss.retaliate_only, "Marrow is retaliate_only (anchored off the spine corridor)")
	var row := _row(_BM.tick(boss, 0, _rng()).new_mob, 0)
	assert_false(bool(row["hostile"]), "...so the wire says NOT hostile")
	assert_true(row.has("cast"), "and the wind-up rides along anyway")
