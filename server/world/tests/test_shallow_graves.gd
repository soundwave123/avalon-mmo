# T-719: The Shallow Graves — the tutorial capstone mini-dungeon. Covers the ticket's acceptance
# criteria that live in content + the live seed path: the instance seeds the authored encounter set
# instance-scoped, the anchors cannot chain-pull or strand a respawn (the T-628 mistake inverted),
# the two bosses are winnable by every class with no tank and no healer, headcount scaling reaches
# the seeded mobs, a death here costs no gear, and the quest chains off graduation with enough XP
# to land the arrival.
extends GutTest

const _ISVC = preload("res://scripts/instance_service.gd")
const _ML = preload("res://scripts/combat/mob_loader.gd")
const _TS = preload("res://scripts/combat/trial_scaling.gd")
const _SC = preload("res://scripts/server_config.gd")
const _CR = preload("res://scripts/content/content_registry.gd")
const _ED = preload("res://scripts/event_dispatch.gd")
const _PL = preload("res://scripts/party_logic.gd")
const PlayerSessions = preload("res://scripts/player_sessions.gd")

const _SRESP = preload("res://scripts/spawn_respawn.gd")

const _MOBS_DIR := "res://data/mobs"
const _TRASH_ID := "mob_grave_husk"
const _BOSS_IDS := ["mob_pallbearer_ost", "mob_sexton_marrow"]

# T-725 (owner-decided 2026-08-09): the trial's trash dwell, in server ticks. 6000 / 20 Hz = 300 s.
const TRIAL_DWELL_TICKS := 6000
# mob_loader._RARE_CYCLE_CAP — the worst-case dormant cycles a variable-ratio source can draw.
const RARE_CYCLE_CAP := 12

# The modeled squishiest fresh L2 (mage/priest): stamina 11 -> stat_converter 50 + 11*5 = 105 HP,
# and a deliberately pessimistic sustained 10 damage/second with the starter weapon plus Kessa's
# level-2 ability. DESIGN targets, not measured client numbers — the live 3-class run is the
# orchestrator's, per the T-332 precedent.
const MODEL_HP := 105.0
const MODEL_DPS := 10.0

# leveling.gd (master-side, so it cannot be preloaded here) is total_xp_for_level(L) = 50*(L-1)*L.
const L4_TOTAL_XP := 600  # 50 * 3 * 4
const GRADUATE_XP := 180  # q_tut_01 40 + q_tut_02 60 + q_tut_03 80, the state at Hale's turn-in

var _moves: Dictionary = {}
var _mobs: Dictionary = {}
var _master_calls: Array = []


func before_each() -> void:
	_moves = {}
	_mobs = {}
	_master_calls = []
	PlayerSessions._reset_for_test()


func _noop1(_a) -> void:
	pass


func _noop2(_a, _b) -> void:
	pass


func _record_move(peer: int, pos: Vector3) -> void:
	_moves[peer] = pos


# A minimal MasterClient stand-in: records the ops instance_service fires at it.
class FakeMaster:
	extends RefCounted
	var calls: Array = []

	func call_master(action: String, params: Dictionary) -> Dictionary:
		calls.append({"action": action, "params": params})
		return {}


# A wired service whose mob table is this test's, with `levels` deciding the routing.
func _service(levels: Dictionary, party_store: Dictionary = {}) -> Object:
	var svc = _ISVC.new()
	var party_of: Dictionary = party_store.get("party_of", _PL.new_store()["party_of"])
	svc.setup(
		_mobs,
		party_of,
		Callable(self, "_noop2"),
		Callable(self, "_record_move"),
		Callable(self, "_noop1")
	)
	svc.setup_lfg({}, Callable(), null, levels)
	svc.setup_rift(party_store, Callable(), {})
	return svc


func _def(file: String):
	return _ML.load_from_file(_MOBS_DIR + "/" + file, 9000)


func _seeded_of(alias: String) -> Array:
	var out: Array = []
	for eid in _mobs:
		if _mobs[eid].mob_id == alias:
			out.append(_mobs[eid])
	return out


func _content() -> Dictionary:
	return _CR.load_all(ProjectSettings.globalize_path("res://data"))


# ---- The encounter set seeds instance-scoped, with the aliases the quest and loot key on ----


func test_the_trial_seeds_its_own_encounter_set_scoped_to_its_instance() -> void:
	var svc = _service({1: 2})
	var iid: int = svc.enter(1)
	assert_eq(_seeded_of(_TRASH_ID).size(), 2, "the gallery pack")
	for boss_id in _BOSS_IDS:
		assert_eq(_seeded_of(boss_id).size(), 1, "%s stands exactly once" % boss_id)
	for eid in _mobs:
		assert_eq(int(_mobs[eid].instance_id), iid, "every seeded mob is scoped to the trial")


func test_the_crypt_seed_is_untouched_by_the_trial() -> void:
	# One door, two dungeons: a level-12 descent must still get the T-341 undead, never the husks.
	var svc = _service({1: 12})
	svc.enter(1)
	assert_eq(_seeded_of(_TRASH_ID).size(), 0, "no capstone trash in the real crypt")
	assert_gt(_seeded_of("mob_skeletal_warrior").size(), 0, "the crypt's own packs seeded")


func test_boss_aliases_are_unique_and_match_the_loot_schedule() -> void:
	var raw: Variant = JSON.parse_string(
		FileAccess.get_file_as_string("res://data/loot/dungeon_schedule.json")
	)
	var bosses: Dictionary = (raw as Dictionary)["bosses"]
	for boss_id in _BOSS_IDS:
		assert_true(bosses.has(boss_id), "%s has a dungeon_loot schedule row" % boss_id)
		var row: Dictionary = bosses[boss_id]
		assert_gt(
			(row["guaranteed_green"] as Array).size(),
			0,
			"%s always pays — a first-timer's boss never ends in nothing" % boss_id
		)
	# The finale carries the one lottery in the run: the reason to come back.
	assert_gt(float(bosses["mob_sexton_marrow"]["blue_chance"]), 0.0)
	assert_eq(float(bosses["mob_pallbearer_ost"]["blue_chance"]), 0.0)


func test_bosses_reuse_shipped_silhouettes_and_keep_decoupled_aliases() -> void:
	for f in ["pallbearer_ost.json", "sexton_marrow.json"]:
		var b = _def(f)
		assert_not_null(b, "%s loads" % f)
		assert_true(b.elite, "%s is on the T-294 elite chassis" % f)
		assert_ne(b.render_kind, "", "%s reuses a shipped mesh — no new art" % f)
		assert_ne(b.mob_id, b.render_kind, "%s alias is decoupled from the silhouette" % f)
	assert_eq(_def("grave_husk.json").render_kind, "mob_skeletal_warrior")


# ---- Anchors: nothing chain-pulls, nothing respawns inside a pack ----


# One ENCOUNTER = one pull. The husk pair is deliberately a single pull (a 2 m pack), so spacing is
# measured between encounters — the pack's own centroid, each boss, and the respawn anchor.
func _encounter_points(svc: Object) -> Array:
	var points: Array = [svc.TRIAL_ENTRANCE]
	var pack := Vector3.ZERO
	var pack_n := 0
	for eid in _mobs:
		var mob = _mobs[eid]
		if mob.mob_id == _TRASH_ID:
			pack += mob.position
			pack_n += 1
		else:
			points.append(mob.position)
	if pack_n > 0:
		points.append(pack / float(pack_n))
	return points


func test_the_trash_pair_is_one_pull_not_two() -> void:
	var svc = _service({1: 2})
	svc.enter(1)
	var pack: Array = _seeded_of(_TRASH_ID)
	var gap: float = (pack[0].position as Vector3).distance_to(pack[1].position)
	assert_lte(gap, 8.0, "the two husks read as a single pack, %.2f m apart" % gap)


func test_every_encounter_clears_the_aggro_floor_from_every_other_and_from_the_respawn() -> void:
	var svc = _service({1: 2})
	svc.enter(1)
	var floor_gap: float = _SC.AGGRO_FLOOR + 2.0
	var points: Array = _encounter_points(svc)
	assert_eq(points.size(), 4, "entrance + husk pack + two bosses")
	for i in range(points.size()):
		for j in range(i + 1, points.size()):
			var gap: float = (points[i] as Vector3).distance_to(points[j])
			assert_gte(gap, floor_gap, "encounters %d/%d are %.2f m apart" % [i, j, gap])


func test_no_mob_stands_within_aggro_of_the_respawn_anchor() -> void:
	# The T-628 mistake inverted: a wipe must never put the learner back inside the pack that
	# killed them. Measured per MOB (not per encounter) — an individual husk is what aggros.
	var svc = _service({1: 2})
	svc.enter(1)
	for eid in _mobs:
		var gap: float = (svc.TRIAL_ENTRANCE as Vector3).distance_to(_mobs[eid].position)
		assert_gt(gap, _SC.AGGRO_FLOOR + 2.0, "%s is %.2f m away" % [_mobs[eid].mob_id, gap])
	assert_ne(svc.TRIAL_ENTRANCE, svc.CRYPT_ENTRANCE, "and it is not the crypt's own anchor")


func test_both_bosses_wait_to_be_pulled() -> void:
	# retaliate_only is what makes walking the spine corridor safe: the two boss anchors sit near
	# the route to each other, so proximity aggro would start the climax by accident.
	for f in ["pallbearer_ost.json", "sexton_marrow.json"]:
		assert_true(_def(f).retaliate_only, "%s never aggros on proximity" % f)


# ---- Role-free: no tank, no healer, no class-specific requirement ----


func _incoming_over_the_fight(boss) -> float:
	var seconds: float = float(boss.resources.max_hp) / MODEL_DPS
	return float(boss.melee_ability.base_damage) / boss.stats.weapon_speed * seconds


func test_each_boss_is_solo_winnable_by_the_squishiest_modeled_class() -> void:
	for f in ["pallbearer_ost.json", "sexton_marrow.json"]:
		var boss = _def(f)
		var incoming: float = _incoming_over_the_fight(boss)
		if boss.boss_mechanic == "training_dirge":
			incoming += float(boss.dirge_damage)  # worst case: the telegraph is never broken
		assert_lt(incoming, MODEL_HP, "%s costs %.1f of a modeled 105 HP" % [f, incoming])


func test_the_telegraph_breaks_on_damage_alone_so_a_priest_is_never_stuck() -> void:
	# Warriors have Pummel and mages have Counterspell; priests have NO dedicated interrupt, so the
	# damage threshold is their whole path through this mechanic. The modeled floor output must clear
	# it INSIDE the wind-up, with margin — the window is dirge_channel_ticks at the 20 Hz server tick.
	var boss = _def("sexton_marrow.json")
	assert_eq(boss.boss_mechanic, "training_dirge", "the survivable telegraph, NOT the crypt dirge")
	assert_gt(boss.dirge_interrupt_damage, 0, "a damage break exists at all")
	var window_secs: float = float(boss.dirge_channel_ticks) / float(_SC.TICK_RATE_HZ)
	assert_lte(
		float(boss.dirge_interrupt_damage),
		MODEL_DPS * window_secs * 0.9,
		"breakable by output alone, with margin inside the %.1fs window" % window_secs
	)
	assert_lt(float(boss.dirge_damage), MODEL_HP * 0.25, "eating it is a sting, never a wipe")


func test_no_trial_encounter_carries_a_tank_or_healer_shaped_mechanic() -> void:
	# The crypt's "dirge" pulses damage EVERY tick of the channel (T-540 one-shot a L1 mage) and the
	# phase_summon enrage assumes sustained healing. Neither may appear in the capstone.
	for f in ["grave_husk.json", "pallbearer_ost.json", "sexton_marrow.json"]:
		var m = _def(f)
		assert_ne(m.boss_mechanic, "dirge", "%s must not carry the lethal crypt pulse" % f)
		assert_ne(m.boss_mechanic, "phase_summon", "%s must not carry the enrage phase" % f)
		assert_eq(m.enrage_threshold, 0.0, "%s never enrages — no healer check" % f)


# ---- Headcount scaling reaches the live seed, and only through HP ----


func _party_store_with(members: Array) -> Dictionary:
	var store: Dictionary = _PL.new_store()
	store["parties"][1] = {"members": members, "leader": int(members[0])}
	for m in members:
		store["party_of"][int(m)] = 1
	return store


func test_a_solo_run_seeds_the_authored_numbers() -> void:
	var svc = _service({1: 2})
	svc.enter(1)
	assert_eq(
		_seeded_of("mob_sexton_marrow")[0].resources.max_hp,
		_def("sexton_marrow.json").resources.max_hp
	)


func test_a_trio_seeds_the_scaled_pool_but_the_authored_swing() -> void:
	var store := _party_store_with([1, 2, 3])
	var svc = _service({1: 2, 2: 2, 3: 3}, store)
	svc.enter(1)
	var authored = _def("sexton_marrow.json")
	var live = _seeded_of("mob_sexton_marrow")[0]
	var expected: int = int(round(float(authored.resources.max_hp) * _TS.hp_mult(3)))
	assert_eq(live.resources.max_hp, expected, "HP scaled for three")
	assert_eq(
		live.melee_ability.base_damage,
		authored.melee_ability.base_damage,
		"damage is NOT scaled — that is what would create a tank requirement"
	)


# ---- Never punish during learning ----


# T-724: the waiver decision is ALSO the only honest source for the client's "Your gear was
# damaged." line, so the hook reports its verdict and event_dispatch carries it on the broadcast.
# A trial death must say wear_applied=false; nothing else about the broadcast changes.
func test_a_death_in_the_trial_costs_no_durability_and_says_so() -> void:
	var master := FakeMaster.new()
	var svc = _service({1: 2})
	svc.enter(1)
	var payload: Dictionary = _ED.player_death(
		1, "learner", 105, svc.on_player_died(master, 1, "learner")
	)
	assert_eq(master.calls.size(), 0, "no apply_death_wear for a death inside the capstone")
	assert_eq(str(payload["type"]), "player_death", "still the same broadcast, one key richer")
	assert_false(bool(payload["wear_applied"]), "and it admits the death cost nothing")
	# A death that never reached the master wore nothing either: the flag records what HAPPENED,
	# not what the rules would normally do.
	assert_false(svc.on_player_died(null, 1, "learner"), "no master reached = nothing worn")
	assert_false(svc.on_player_died(master, 1, ""), "no character = nothing worn")


func test_a_death_anywhere_else_still_wears_gear() -> void:
	var master := FakeMaster.new()
	var svc = _service({1: 12})
	var payload: Dictionary = _ED.player_death(
		1, "veteran", 220, svc.on_player_died(master, 1, "veteran")  # open world
	)
	svc.enter(1)
	assert_true(svc.on_player_died(master, 1, "veteran"), "so does the L12 crypt")
	assert_eq(master.calls.size(), 2, "the T-364 penalty is untouched outside the trial")
	assert_eq(str(master.calls[0]["action"]), "apply_death_wear")
	assert_true(bool(payload["wear_applied"]), "T-724: an open-world death reports the real cost")


# ---- The quest: chains off graduation, resolves, and pays an arrival ----


func test_the_capstone_quest_chains_off_the_graduation_turn_in() -> void:
	var loaded := _content()
	var quest = loaded["quests"]["q_tut_04"]
	assert_eq(str(quest.prerequisite_quest), "q_tut_03", "T-710 auto-offers it at graduation")
	assert_eq(quest.giver_npc, "npc_village_parson")
	assert_eq(quest.turnin_npc, "npc_village_parson")
	assert_true(loaded["npcs"]["npc_village_parson"].gives_quests.has("q_tut_04"))
	assert_eq(quest.min_level, 1, "a graduate is never turned away from their own capstone")
	assert_eq(_CR.validate(loaded["quests"], loaded["items"], loaded["npcs"]), [])


func test_the_quest_targets_resolve_against_the_instance_spawn_set() -> void:
	var loaded := _content()
	var types: Array = loaded["quests"]["q_tut_04"].objectives.map(func(o): return o["type"])
	assert_eq(types, ["reach", "kill", "kill", "kill"], "walk to the stair, then clear it")
	assert_eq(
		_CR.validate_sources(
			loaded["quests"], loaded["mobs"], loaded["items"], loaded["gather_nodes"]
		),
		[],
		"no ghost kill targets — the instance spawn set is a real source"
	)


func test_the_run_carries_a_fresh_graduate_past_level_four() -> void:
	# The FLOOR: the turn-in plus only the four guaranteed kills (no summoned add, no other content).
	var quest = _content()["quests"]["q_tut_04"]
	var earned: int = GRADUATE_XP + int(quest.rewards["xp"])
	for f in ["grave_husk.json", "grave_husk.json", "pallbearer_ost.json", "sexton_marrow.json"]:
		earned += _def(f).xp
	assert_gt(earned, L4_TOTAL_XP, "%d XP clears the level-4 bar (%d)" % [earned, L4_TOTAL_XP])


# ---- T-725: the trash dwell is a LONG one, and it is the trial's own data that says so ----


func test_the_trial_trash_dwells_five_minutes_before_it_comes_back() -> void:
	# The measured 30 s dwell is open-world density tuning; in a teaching space it re-aggros a slow
	# first-timer from behind while they read quest text. The owner's call: ~5 minutes.
	var svc = _service({1: 2})
	svc.enter(1)
	var pack: Array = _seeded_of(_TRASH_ID)
	assert_eq(pack.size(), 2, "both husks seeded")
	for husk in pack:
		assert_eq(
			int(husk.respawn_ticks),
			TRIAL_DWELL_TICKS,
			"%s waits the authored long dwell, not the global default" % husk.mob_id
		)
	assert_eq(
		float(TRIAL_DWELL_TICKS) / float(_SC.TICK_RATE_HZ), 300.0, "which is 300 s at the tick rate"
	)
	assert_eq(TRIAL_DWELL_TICKS, _SC.MOB_RESPAWN_TICKS * 10, "ten times the open-world dwell")


func test_the_long_dwell_never_reaches_the_bosses() -> void:
	# Boss lifecycle is ENCOUNTER-scoped (retaliate_only, one pull, its own loot schedule). This
	# ticket tunes trash pacing only, so the boss entries omit the key and keep the default —
	# proof that the override is per-ENTRY data, not an instance-wide or instance-kind switch.
	var svc = _service({1: 2})
	svc.enter(1)
	for boss_id in _BOSS_IDS:
		var boss = _seeded_of(boss_id)[0]
		assert_eq(
			int(boss.respawn_ticks),
			_SC.MOB_RESPAWN_TICKS,
			"%s keeps the default dwell — its lifecycle is untouched" % boss_id
		)
		assert_eq(float(boss.spawn_chance), 1.0, "%s is not a variable-ratio source" % boss_id)


func test_the_open_world_keeps_its_own_dwells() -> void:
	# The same loader feeds both worlds: instanced tuning must not leak into spawns.json, and the
	# T-411 dwells already authored out there must survive the shared-tuning refactor.
	var world: Dictionary = _ML.load_spawn_table(_MOBS_DIR)
	assert_gt(world.size(), 0, "the open-world table loads")
	var defaults := 0
	for eid in world:
		assert_ne(
			int(world[eid].respawn_ticks),
			TRIAL_DWELL_TICKS,
			"no open-world spawn picked up the trial's dwell"
		)
		if int(world[eid].respawn_ticks) == _SC.MOB_RESPAWN_TICKS:
			defaults += 1
	assert_gt(defaults, 0, "the un-authored majority still inherits the global default")
	assert_eq(int(world[1101].respawn_ticks), 300, "the authored wolf dwell survives")
	assert_eq(int(world[2051].respawn_ticks), 2400, "so does the Ashmoor rare's")
	assert_almost_eq(float(world[2051].spawn_chance), 0.2, 0.001, "and its rare spawn_chance")


func test_the_long_dwell_still_folds_the_variable_ratio_roll() -> void:
	# T-414 semantics are unchanged by the longer base: an always-present source returns exactly
	# its dwell, and a rare one stays gone for a whole number of THOSE dwells, bounded by the cap.
	var svc = _service({1: 2})
	svc.enter(1)
	var rng := RandomNumberGenerator.new()
	rng.seed = 725
	var husk = _seeded_of(_TRASH_ID)[0]
	assert_eq(
		_ML.next_respawn_ticks(husk, rng),
		TRIAL_DWELL_TICKS,
		"spawn_chance 1.0 -> exactly the dwell"
	)
	husk.spawn_chance = 0.25
	for _i in range(50):
		var ticks: int = _ML.next_respawn_ticks(husk, rng)
		assert_eq(ticks % TRIAL_DWELL_TICKS, 0, "a rare returns on a whole dwell boundary")
		assert_gte(ticks, TRIAL_DWELL_TICKS, "never shorter than one dwell")
		assert_lte(ticks, TRIAL_DWELL_TICKS * RARE_CYCLE_CAP, "and bounded by the rare cycle cap")
	assert_eq(
		_SRESP.next_ticks(TRIAL_DWELL_TICKS, 0.0, rng, RARE_CYCLE_CAP),
		TRIAL_DWELL_TICKS * RARE_CYCLE_CAP,
		"spawn_chance 0 is the floor, never 'gone forever'"
	)
