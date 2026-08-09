# T-071: once-per-server-tick resource dynamics — tick-edge guard + per-player pass.
# Pure/clock-injected: no OS time, no network, no engine loop.

extends GutTest

const _RT = preload("res://scripts/combat/resource_ticker.gd")
const _RM = preload("res://scripts/combat/resource_model.gd")
const _CS = preload("res://scripts/combat/combat_state.gd")
const _SC = preload("res://scripts/server_config.gd")


func _make_cr(kind: String = "none") -> CombatResources:
	var cr := CombatResources.new()
	cr.hp = 50
	cr.max_hp = 100
	cr.mana = 10
	cr.max_mana = 50
	cr.stamina = 50
	cr.max_stamina = 100
	cr.resource_kind = kind
	if kind == "rage":
		cr.rage = 50
		cr.max_rage = 100
	return cr


func _idle_state() -> CombatState:
	return CombatState.new()


func _dead_state() -> CombatState:
	var cs := CombatState.new()
	cs.state = _CS.CombatStateEnum.DEAD
	return cs


# ---- tick-edge guard ----


func test_is_new_tick_true_once_per_tick() -> void:
	var ticker = _RT.new()
	assert_true(ticker.is_new_tick(5), "first frame of tick 5 processes")
	assert_false(ticker.is_new_tick(5), "second frame inside tick 5 must NOT process")
	assert_false(ticker.is_new_tick(5), "nor the third")
	assert_true(ticker.is_new_tick(6), "next tick processes again")


func test_two_frames_inside_one_tick_apply_decay_once() -> void:
	# Composition: guard + pass. Rage decays exactly once even when two frames share a tick.
	var ticker = _RT.new()
	var cr := _make_cr("rage")
	cr.last_combat_tick = 0
	var now: int = 200  # out of combat (>=100) and on the decay interval (%10 == 0)
	var cs := _idle_state()
	for _frame in range(2):
		if ticker.is_new_tick(now):
			cr = _RT.tick_player(cr, 10, cs, now)
	assert_eq(cr.rage, 50 - _RM.RAGE_DECAY_PER_INTERVAL, "decay applied exactly once")


# ---- vitals regen (T-071) ----


func test_vitals_regen_out_of_combat_at_interval() -> void:
	var cr := _make_cr()
	cr.last_combat_tick = 0
	var now: int = 200  # out of combat; 200 % 20 == 0 (hp) and 200 % 10 == 0 (stamina)
	var out = _RT.tick_player(cr, 10, _idle_state(), now)
	assert_eq(out.hp, 50 + _SC.HP_REGEN_PER_INTERVAL, "hp regenerates out of combat")
	assert_eq(
		out.stamina, 50 + _SC.STAMINA_REGEN_PER_INTERVAL, "swing pool regenerates out of combat"
	)


func test_no_vitals_regen_in_combat() -> void:
	var cr := _make_cr()
	cr.last_combat_tick = 150  # 200 - 150 = 50 < OUT_OF_COMBAT_TICKS (100)
	var out = _RT.tick_player(cr, 10, _idle_state(), 200)
	assert_eq(out.hp, 50, "no hp regen while in combat")
	assert_eq(out.stamina, 50, "no swing-pool regen while in combat")


func test_dead_player_regenerates_nothing() -> void:
	var cr := _make_cr("mana")
	cr.hp = 0
	cr.last_combat_tick = 0
	cr.last_spend_tick = 0
	var out = _RT.tick_player(cr, 10, _dead_state(), 300)  # every interval aligns at 300
	assert_eq(out.hp, 0, "no hp regen while DEAD")
	assert_eq(out.stamina, 50, "no swing-pool regen while DEAD")
	assert_eq(out.mana, 10, "no mana regen while DEAD")


# ---- class-resource dynamics still flow through the ticker ----


func test_mana_regen_flows_through_tick_player() -> void:
	var cr := _make_cr("mana")
	cr.last_spend_tick = 0
	cr.last_combat_tick = 150  # in combat — mana regen is NOT gated by the combat window
	var out = _RT.tick_player(cr, 10, _idle_state(), 300)  # 300 % 30 == 0; 5s rule elapsed
	assert_gt(out.mana, 10, "spirit mana regen applies on the interval")


func test_rage_holds_in_combat() -> void:
	var cr := _make_cr("rage")
	cr.last_combat_tick = 150
	var out = _RT.tick_player(cr, 10, _idle_state(), 200)
	assert_eq(out.rage, 50, "rage does not decay in combat")
