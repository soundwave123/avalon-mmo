# T-426 slice 4: the tactical teaching encounter. Proves (1) the straw effigy content loads as a
# training_dirge telegraph mob (NOT a passive dummy) with easy-to-break, gentle numbers; (2) the
# boss_mechanics dirge channel drives + interrupts under the training_dirge alias exactly like the
# crypt dirge; and (3) training_interrupt.telegraph_broken detects the breaking hit — both the
# dedicated-interrupt path and the class-agnostic damage-threshold path — and nothing else.

extends GutTest

const _ML = preload("res://scripts/combat/mob_loader.gd")
const _MD = preload("res://scripts/combat/mob_data.gd")
const _CR = preload("res://scripts/combat/combat_resources.gd")
const _BM = preload("res://scripts/combat/boss_mechanics.gd")
const _CS = preload("res://scripts/combat/combat_state.gd")
const _MAI = preload("res://scripts/combat/mob_ai.gd")
const _TI = preload("res://scripts/combat/training_interrupt.gd")
const _AE = preload("res://scripts/combat/ability_executor.gd")
const _CQ = preload("res://scripts/content/content_query.gd")
const _STC = preload("res://scripts/combat/stat_converter.gd")
const _TT = preload("res://scripts/combat/threat_table.gd")

const _EFFIGY := "res://data/mobs/training_effigy.json"
const _QUEST := "res://data/quests/q_tut_03_read_the_fight.json"
# T-564 / report #18: Drillmaster Hale's spot — a fresh trainee stands here to accept q_tut_01,
# ~3.64m from the effigy's spawn (16,10). Well inside the old aggro_radius (5.0) and inside the
# mob_aggro AGGRO_FLOOR (5.0m) that always applies to a same-level, non-gray mob regardless of the
# authored radius — which is why shrinking aggro_radius alone could never have fixed this.
const _HALE_POS := Vector3(12.5, 9.0, 0.0)


func _effigy():
	var mob = _ML.load_from_file(_EFFIGY, 1051)
	assert_not_null(mob, "the effigy mob file loads")
	return mob


func _rng() -> RandomNumberGenerator:
	var r := RandomNumberGenerator.new()
	r.seed = 7
	return r


# ---- Content shape ----


func test_effigy_is_a_training_telegraph_not_a_dummy():
	var mob = _effigy()
	assert_eq(mob.mob_id, "mob_training_effigy")
	assert_eq(mob.boss_mechanic, _TI.MECHANIC, "runs the training_dirge telegraph")
	assert_false(mob.is_dummy, "must aggro to channel — a passive dummy never would")
	assert_true(mob.dirge_interrupt_damage > 0, "breakable by damage (class-agnostic)")
	assert_true(mob.dirge_channel_ticks > 0, "has a telegraph window")
	assert_true(mob.loot.is_empty(), "a training tool drops nothing")


# ---- T-564: retaliate-only — passive until attacked (report #18 fix) ----
# The effigy is NOT a dummy (must still aggro/channel to teach the interrupt), but it must never
# jump an idle new player who merely walks up to Drillmaster Hale to accept q_tut_01.


func test_effigy_is_flagged_retaliate_only():
	assert_true(
		_effigy().retaliate_only, "the sparring effigy must not proximity-aggro an idle trainee"
	)


func _make_idle_player(pos: Vector3, hp: int = 100) -> Dictionary:
	return {
		"position": pos,
		"combat_state": CombatState.new(),
		"resources": _hp_resources(hp),
		"stats": CharacterStats.new(),
		"level": 1,
	}


func _hp_resources(hp: int) -> CombatResources:
	var cr := CombatResources.new()
	cr.hp = hp
	cr.max_hp = hp
	cr.mana = 50
	cr.max_mana = 50
	cr.stamina = 100
	cr.max_stamina = 100
	return cr


func test_idle_trainee_at_hale_is_never_aggroed_or_hit():
	# Report #18 repro: a fresh player at Hale's exact spot (12.5,9.0), ~3.64m from the effigy's
	# spawn (16,10) — well inside the old aggro_radius (5.0) and the AGGRO_FLOOR (5.0m). Simulate
	# many seconds of idling (accepting/reading the quest) with no attack ever thrown.
	var mob = _effigy()
	var players := {1: _make_idle_player(_HALE_POS)}
	var tt := _TT.new()
	var current_mob = mob
	for i in range(400):  # 20 simulated seconds @ 20 Hz
		var r = _MAI.ai_tick(current_mob, players, tt, i, _rng())
		assert_eq(r.events.size(), 0, "no aggro/damage event while merely standing near Hale")
		current_mob = r.new_mob
	assert_eq(
		current_mob.ai_state,
		_MAI.MobAIState.IDLE,
		"the effigy must stay IDLE for an idle trainee at Hale's spot"
	)
	assert_eq(current_mob.resources.hp, current_mob.resources.max_hp, "the trainee took no damage")


func test_attacking_the_effigy_still_pulls_it_into_combat_and_channels():
	# The other half of the fix: retaliate-only must not neuter q_tut_03. A trainee who actually
	# attacks the effigy (threat added, same as ability_executor.gd does on every landed hit) pulls
	# it into combat exactly like before, and it still winds up + channels the dirge telegraph.
	var mob = _effigy()
	var players := {1: _make_idle_player(_HALE_POS)}
	var tt := _TT.new()
	tt.add_threat(mob.entity_id, 1, 10)  # the trainee's opening swing landed
	var aggroed = _MAI.ai_tick(mob, players, tt, 0, _rng())
	assert_eq(
		aggroed.new_mob.ai_state,
		_MAI.MobAIState.AGGROED,
		"an attack must still pull a retaliate_only mob into combat"
	)
	assert_eq(aggroed.new_mob.current_target_id, 1, "the attacker becomes the target")
	# Drive the channel exactly as test_engaged_effigy_winds_up_a_channel does, now reached via the
	# real retaliation path instead of a hand-set ai_state.
	var res = _BM.tick(aggroed.new_mob, 1000, _rng())
	assert_eq(
		res.new_mob.combat_state.state,
		_CS.CombatStateEnum.CHANNELING,
		"the wind-up still begins once retaliation engages it"
	)
	var kinds: Array = []
	for a in res.actions:
		kinds.append(str(a.get("type", "")))
	assert_true(kinds.has("dirge_start"), "the telegraph is still announced — q_tut_03 unaffected")


# ---- T-560: the effigy is non-lethal — a confused trainee who eats hits forever never dies ----


func test_effigy_is_flagged_non_lethal():
	assert_true(_effigy().non_lethal, "the tutorial sparring effigy can bruise but never kill")


func test_repeated_effigy_hits_never_kill_a_l1_trainee():
	# The real killer behind the T-559 misdiagnosis: the effigy aggros an idle trainee at the ring and
	# drains 100->0 over ~30s. non_lethal_damage caps EVERY hit so the trainee bottoms out at the 15%
	# floor and can never be reduced below it — no matter how long they stand in range.
	var mob = _effigy()
	assert_true(mob.non_lethal)
	var res := _CR.new()
	res.max_hp = 100
	res.hp = 100
	var floor_hp: int = int(ceil(100.0 * _MD.NON_LETHAL_FLOOR_PCT))
	# 60 rounds of the effigy's worst plausible output each tick: a melee swing AND the token dirge.
	for _i in range(60):
		res = res.apply_damage(_MD.non_lethal_cap(mob, 3, res))  # melee (~base_damage 2)
		res = res.apply_damage(_MD.non_lethal_cap(mob, mob.dirge_damage, res))  # dirge 15
		assert_gt(res.hp, 0, "the trainee is never dropped to 0 by the practice target")
	assert_eq(res.hp, floor_hp, "damage stabilises at the 15% HP floor, never a kill")
	# Even an absurd single hit cannot punch a floored target below the floor.
	assert_eq(_MD.non_lethal_cap(mob, 9999, res), 0, "a floored target takes no more")
	# From full HP the effigy still bruises down to — but not past — the floor.
	var full := _CR.new()
	full.max_hp = 100
	full.hp = 100
	assert_eq(_MD.non_lethal_cap(mob, 9999, full), 85, "a full-HP trainee is bruised to the floor")
	# A normal (lethal) mob is unaffected — the cap is opt-in via the non_lethal flag.
	assert_eq(_MD.non_lethal_cap(_MD.new(), 9999, full), 9999, "a lethal mob is not capped")


# ---- The channel drives + breaks via boss_mechanics (reused verbatim under the new alias) ----


func test_engaged_effigy_winds_up_a_channel():
	var mob = _effigy()
	mob.ai_state = _MAI.MobAIState.AGGROED  # is_active requires an actively-fighting mob
	var res = _BM.tick(mob, 1000, _rng())
	assert_eq(
		res.new_mob.combat_state.state,
		_CS.CombatStateEnum.CHANNELING,
		"the wind-up begins on engage"
	)
	assert_eq(res.new_mob.dirge_hp_at_start, mob.resources.hp, "snapshots HP at channel start")
	var kinds: Array = []
	for a in res.actions:
		kinds.append(str(a.get("type", "")))
	assert_true(kinds.has("dirge_start"), "announces the telegraph")


func test_damage_over_threshold_breaks_the_channel():
	var mob = _effigy()
	mob.ai_state = _MAI.MobAIState.AGGROED
	mob = _BM.tick(mob, 1000, _rng()).new_mob  # now CHANNELING, dirge_hp_at_start set
	# Trainee lands enough damage during the window to cross the interrupt threshold.
	mob.resources = mob.resources.apply_damage(mob.dirge_interrupt_damage)
	var res = _BM.tick(mob, 1010, _rng())
	assert_eq(res.new_mob.combat_state.state, _CS.CombatStateEnum.IDLE, "the wind-up is cancelled")
	var interrupted := false
	for a in res.actions:
		if str(a.get("type", "")) == "dirge_end" and bool(a.get("interrupted", false)):
			interrupted = true
	assert_true(interrupted, "the break is reported as an interrupt")


# ---- T-540: a WIN, not a wipe — the uninterrupted channel is survivable for the squishiest L1 ----


func test_uninterrupted_channel_lands_one_survivable_hit_for_a_l1_mage():
	# The squishiest L1: every primary stat is 10 (class_growth base), so max HP is grounded on the
	# real derivation (CombatResources.derive_from_stats -> stat_converter.max_hp).
	var l1_hp := _STC.max_hp(10)
	assert_eq(l1_hp, 100, "L1 mage HP = HP_BASE(50) + Stamina 10 * HP_PER_STAMINA(5)")
	var mob = _effigy()
	mob.ai_state = _MAI.MobAIState.AGGROED
	mob = _BM.tick(mob, 1000, _rng()).new_mob  # CHANNELING; cast_end = 1000 + dirge_channel_ticks
	# Mid-wind-up ticks are a PURE telegraph — no per-tick pulse (the old bug stacked ~60 hits).
	var mid = _BM.tick(mob, 1000 + int(mob.dirge_channel_ticks / 2), _rng())
	for a in mid.actions:
		assert_ne(str(a.get("type", "")), "dirge_pulse", "no damage lands mid-wind-up")
	mob = mid.new_mob
	# At channel end the move lands as exactly ONE token hit, then the effigy re-arms.
	var done = _BM.tick(mob, 1000 + mob.dirge_channel_ticks, _rng())
	var pulses := 0
	var total := 0
	for a in done.actions:
		if str(a.get("type", "")) == "dirge_pulse":
			pulses += 1
			total += int(a.get("amount", 0))
	assert_eq(pulses, 1, "the uninterrupted wind-up lands exactly one hit, not a per-tick pulse")
	assert_lte(total, int(l1_hp * 0.20), "one hit is <= 20% of a L1 mage's HP — never a one-shot")
	assert_gte(total, int(l1_hp * 0.05), "but a real sting worth reading + interrupting")
	assert_eq(done.new_mob.combat_state.state, _CS.CombatStateEnum.IDLE, "re-arms after the hit")


func test_q_tut_03_completes_by_interrupt_without_a_kill():
	var f := FileAccess.open(_QUEST, FileAccess.READ)
	assert_not_null(f, "the tutorial quest file loads")
	var q = JSON.parse_string(f.get_as_text())
	f.close()
	assert_eq(str(q.get("id", "")), "q_tut_03")
	var objs: Array = q.get("objectives", [])
	assert_eq(objs.size(), 1, "a single objective")
	var o: Dictionary = objs[0]
	assert_eq(str(o.get("type", "")), "interrupt", "completes by INTERRUPTING, never by killing")
	assert_eq(str(o.get("target", "")), "mob_training_effigy", "targets the effigy")
	# And the effigy's telegraph is actually breakable, so the objective is satisfiable.
	var mob = _channeling_effigy()
	var post = mob.resources.apply_damage(mob.dirge_interrupt_damage)
	assert_true(
		_TI.telegraph_broken(mob, _hit(post, false)), "a threshold hit credits the interrupt"
	)


# ---- training_interrupt.telegraph_broken: the crediting predicate ----


func _channeling_effigy():
	var mob = _effigy()
	mob.combat_state.state = _CS.CombatStateEnum.CHANNELING
	mob.dirge_hp_at_start = mob.resources.hp
	return mob


func _hit(target_res, interrupted: bool):
	# A minimal accepted ability result carrying the post-hit target resources + interrupt flag.
	return _AE.AbilityResult.accept(null, null, 1, "hit", null, target_res, 0, interrupted)


func test_damage_break_is_credited():
	var mob = _channeling_effigy()
	var post = mob.resources.apply_damage(mob.dirge_interrupt_damage)
	assert_true(_TI.telegraph_broken(mob, _hit(post, false)), "threshold damage during the channel")


func test_below_threshold_damage_is_not_credited():
	var mob = _channeling_effigy()
	var post = mob.resources.apply_damage(mob.dirge_interrupt_damage - 1)
	assert_false(
		_TI.telegraph_broken(mob, _hit(post, false)), "a nibble does not break the wind-up"
	)


func test_dedicated_interrupt_is_credited_regardless_of_damage():
	var mob = _channeling_effigy()
	var post = mob.resources.apply_damage(0)  # pummel/counterspell hit for ~nothing
	assert_true(_TI.telegraph_broken(mob, _hit(post, true)), "a landed interrupt breaks it")


func test_not_channeling_is_never_credited():
	var mob = _effigy()  # IDLE, not winding up
	var post = mob.resources.apply_damage(mob.dirge_interrupt_damage)
	assert_false(_TI.telegraph_broken(mob, _hit(post, true)), "no telegraph to break")


func test_a_real_dirge_boss_never_credits_a_tutorial_interrupt():
	var mob = _channeling_effigy()
	mob.boss_mechanic = "dirge"  # a crypt boss, not the training effigy
	var post = mob.resources.apply_damage(mob.dirge_interrupt_damage)
	assert_false(_TI.telegraph_broken(mob, _hit(post, true)), "gated to training_dirge only")


# ---- content_query.interrupt_quest_defs: the quest filter world_rpc uses ----


func test_interrupt_quest_defs_matches_alias_and_wildcard():
	var quests := {
		"q_named": _quest("mob_training_effigy"),
		"q_star": _quest("*"),
		"q_other": _quest("mob_wolf"),
	}
	var got := _CQ.interrupt_quest_defs(quests, "mob_training_effigy")
	assert_true(got.has("q_named"), "the exact alias matches")
	assert_true(got.has("q_star"), "the wildcard matches any channel")
	assert_false(got.has("q_other"), "a different alias does not match")
	assert_true(_CQ.interrupt_quest_defs(quests, "").is_empty(), "empty alias matches nothing")


# The registry loads quests as its own object type; a duck-typed stand-in carrying every field
# content_query.quest_to_dict reads is enough for the pure filter under test.
func _quest(target: String):
	return _DuckQuest.new(target)


class _DuckQuest:
	extends RefCounted
	var id: String = "q"
	var title: String = "t"
	var min_level: int = 1
	var prerequisite_quest: String = ""
	var giver_npc: String = "npc_drillmaster"
	var turnin_npc: String = "npc_drillmaster"
	var objectives: Array = []
	var rewards: Dictionary = {}
	var provided_items: Array = []
	var repeatable: bool = false
	var bounty: bool = false

	func _init(target: String) -> void:
		objectives = [{"type": "interrupt", "target": target, "count": 1, "desc": "d"}]
