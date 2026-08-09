extends GutTest

# T-698: server tick / hot-path efficiency batch — ZERO behavior change. Each test asserts an
# efficiency transform is EQUIVALENT to the code it replaces (precompute == full scan, no-op copy
# == original, region-gate resume == ungated), never merely "the fast path runs".

const _CQ = preload("res://scripts/content/content_query.gd")
const _CONTENT = preload("res://scripts/content/content_registry.gd")
const _MAI = preload("res://scripts/combat/mob_ai.gd")
const _MD = preload("res://scripts/combat/mob_data.gd")
const _CS = preload("res://scripts/combat/combat_state.gd")
const _TT = preload("res://scripts/combat/threat_table.gd")
const _SZ = preload("res://scripts/sleeping_zones.gd")
const _WR = preload("res://scripts/world_regions.gd")
const _ML = preload("res://scripts/combat/mob_loader.gd")
const PlayerSessions = preload("res://scripts/player_sessions.gd")

var _quests: Dictionary
var _items: Dictionary


func before_all() -> void:
	var loaded := _CONTENT.load_all("res://data")
	assert_eq(loaded["errors"], [], "real seed content loads clean")
	_quests = loaded["quests"]
	_items = loaded["items"]


# ---- Fix 1b: reach-objective precompute == full scan (the live quest data) ----


func test_reach_precompute_list_matches_full_scan_everywhere() -> void:
	var reach_objs: Array = _CQ.reach_objectives(_quests)
	assert_gt(reach_objs.size(), 0, "the seed content has reach objectives to compare")
	# Every reach objective's own centre, its rim, and a far point — the precomputed list must
	# return byte-identical target arrays to the authoritative full scan at each probe.
	var probes: Array = []
	for row: Dictionary in reach_objs:
		var c: Vector3 = row["center"]
		probes.append(c)
		probes.append(c + Vector3(float(row["radius"]), 0.0, 0.0))
		probes.append(c + Vector3(9000.0, 9000.0, 0.0))
	probes.append(Vector3.ZERO)
	for p: Vector3 in probes:
		assert_eq(
			_CQ.reach_targets_from(reach_objs, p),
			_CQ.reach_targets_at(_quests, p),
			"precomputed reach list == full scan at %s" % p
		)


# ---- Fix 7: kill-quest index == the per-kill full scan, for every kill alias ----


func test_kill_quest_index_matches_per_kill_scan() -> void:
	var index: Dictionary = _CQ.kill_quest_index(_quests)
	# Collect every kill target authored across all quests, then assert the index probe equals the
	# old per-kill scan (kill_quest_defs) for each — plus a miss for an unknown alias.
	var targets: Dictionary = {}
	for quest_id in _quests:
		for obj: Dictionary in _quests[quest_id].objectives:
			if str(obj.get("type", "")) == "kill":
				targets[str(obj.get("target", ""))] = true
	assert_gt(targets.size(), 0, "seed content has kill objectives")
	for alias in targets:
		assert_eq(
			index.get(alias, {}),
			_CQ.kill_quest_defs(_quests, alias),
			"kill index[%s] == kill_quest_defs scan" % alias
		)
	assert_eq(index.get("mob_no_such_alias", {}), {}, "unknown alias -> empty (both paths)")


# ---- Fix 2: a no-op mob AI tick returns the ORIGINAL object, unchanged ----


func _idle_mob(pos: Vector3) -> Object:
	var mob = _MD.new()
	mob.entity_id = 5001
	mob.mob_type_id = 1
	mob.position = pos
	mob.spawn_position = pos
	mob.aggro_radius = 5.0
	mob.leash_radius = 15.0
	mob.melee_range = 2.0
	mob.mob_level = 5
	mob.ai_state = _MAI.MobAIState.IDLE
	mob.current_target_id = -1
	mob.combat_state = CombatState.new()
	var cr := CombatResources.new()
	cr.hp = 50
	cr.max_hp = 50
	mob.resources = cr
	return mob


func _rng() -> RandomNumberGenerator:
	var r := RandomNumberGenerator.new()
	r.seed = 7
	return r


func test_noop_idle_tick_returns_same_object_no_patrol() -> void:
	# No players, no patrol radius, not dead — the canonical no-op tick. It must return the SAME
	# instance (identity), never a copy.
	var mob = _idle_mob(Vector3(200.0, 200.0, 0.0))
	mob.patrol_radius = 0.0
	var r = _MAI.ai_tick(mob, {}, _TT.new(), 100, _rng())
	assert_true(r.new_mob == mob, "no-op idle tick returns the ORIGINAL mob (no _copy_mob)")
	assert_eq(r.events, [], "no-op tick emits no events")


func test_dead_mob_tick_returns_same_object() -> void:
	var mob = _idle_mob(Vector3(0.0, 0.0, 0.0))
	mob.combat_state.state = _CS.CombatStateEnum.DEAD
	var r = _MAI.ai_tick(mob, {}, _TT.new(), 100, _rng())
	assert_true(r.new_mob == mob, "a DEAD mob tick returns the original (respawn is main's timer)")


func test_dummy_and_stunned_ticks_return_same_object() -> void:
	var dummy = _idle_mob(Vector3(10.0, 10.0, 0.0))
	dummy.is_dummy = true
	assert_true(
		_MAI.ai_tick(dummy, {}, _TT.new(), 0, _rng()).new_mob == dummy, "dummy tick = identity"
	)
	var stunned = _idle_mob(Vector3(10.0, 10.0, 0.0))
	stunned.combat_state.stunned_until = 500
	assert_true(
		_MAI.ai_tick(stunned, {}, _TT.new(), 100, _rng()).new_mob == stunned, "stunned = identity"
	)


func test_aggro_flip_still_copies_and_leaves_input_untouched() -> void:
	# The mutation path MUST still copy — the input mob is never mutated (the T-025 hard constraint).
	var mob = _idle_mob(Vector3(10.0, 10.0, 0.0))
	var players := {42: {"position": Vector3(11.0, 10.0, 0.0), "level": 5}}
	var r = _MAI.ai_tick(mob, players, _TT.new(), 0, _rng())
	assert_false(r.new_mob == mob, "an aggro flip returns a COPY, not the input")
	assert_eq(r.new_mob.ai_state, _MAI.MobAIState.AGGROED, "the copy carries the new state")
	assert_eq(mob.ai_state, _MAI.MobAIState.IDLE, "the INPUT mob is never mutated")


# ---- Fix 3: precomputed mob spawn-region map == per-tick region_index scan ----


func test_mob_region_cache_matches_live_region_index() -> void:
	var wr = _WR.load_default()
	var mobs: Dictionary = _ML.load_spawn_table("res://data/mobs")
	var cache: Dictionary = _SZ.mob_regions(mobs, wr)
	assert_eq(cache.size(), mobs.size(), "every open-world mob is mapped once at load")
	for eid in mobs:
		var mob = mobs[eid]
		# The cached region must equal the on-the-fly scan the pre-T-698 gate ran per tick — and
		# is_mob_awake_cached must agree with is_mob_awake for the same awake set.
		assert_eq(
			cache[int(mob.entity_id)],
			wr.region_index(mob.position.x, mob.position.y),
			"cached spawn region == live region_index for mob %s" % eid
		)
		var awake := {cache[int(mob.entity_id)]: true}
		assert_eq(
			_SZ.is_mob_awake_cached(mob, awake, cache),
			_SZ.is_mob_awake(mob, awake, wr),
			"cached gate agrees with the live gate (awake case)"
		)
		var asleep := {999999: true}
		assert_eq(
			_SZ.is_mob_awake_cached(mob, asleep, cache),
			_SZ.is_mob_awake(mob, asleep, wr),
			"cached gate agrees with the live gate (asleep case)"
		)


func test_mob_region_empty_table_degrades_to_always_awake() -> void:
	var mobs: Dictionary = {1: _idle_mob(Vector3.ZERO)}
	var cache: Dictionary = _SZ.mob_regions(mobs, null)
	assert_eq(cache, {}, "no region table -> empty map")
	assert_true(_SZ.is_mob_awake_cached(mobs[1], {}, cache), "unmapped mob degrades to always-tick")


# ---- Fix 6: the read-only accessor returns the SAME data as the copying get ----


func test_get_player_view_matches_get_player_content() -> void:
	PlayerSessions._reset_for_test()
	var tok := "abcdef0123456789abcdef0123456789"
	assert_true(
		PlayerSessions.add_player(9, tok, "Ruin", Vector3(3.0, 4.0, 0.0), "acct"), "seed a session"
	)
	var copy := PlayerSessions.get_player(9)
	var view := PlayerSessions.get_player_view(9)
	assert_eq(view, copy, "the read-only view carries identical data to the copying get")
	# The distinguishing property: the view is the LIVE record (mutating it would leak); the copy
	# is independent. Prove the copy is a copy, and the view tracks live updates.
	copy["username"] = "Tampered"
	assert_eq(PlayerSessions.get_player_view(9)["username"], "Ruin", "the copy did NOT alias state")
	PlayerSessions.update_position(9, Vector3(5.0, 6.0, 0.0))
	assert_eq(
		PlayerSessions.get_player_view(9).get("pos"),
		PlayerSessions.get_player(9).get("pos"),
		"view + copy agree after a live position update"
	)
	assert_eq(PlayerSessions.get_player_view(404), {}, "an unknown peer -> empty (both paths)")
	PlayerSessions._reset_for_test()
