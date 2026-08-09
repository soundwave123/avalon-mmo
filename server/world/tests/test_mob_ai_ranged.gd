# T-350: ranged/kite mob AI (the gun mobs) — headless tick simulation. All injected `now`/rng, no
# OS time, no engine loop, no network — mirrors test_mob_ai.gd. Proves the keep-distance band: a
# ranged mob closes when beyond max, kites BACK when inside min, and fires a hitscan (with ranged/
# weapon metadata) only while standing inside [min, max]. A firing window emits `ranged_burst` shots.

extends GutTest

const _MAI = preload("res://scripts/combat/mob_ai.gd")
const _MD = preload("res://scripts/combat/mob_data.gd")
const _CS = preload("res://scripts/combat/combat_state.gd")
const _TT = preload("res://scripts/combat/threat_table.gd")
const _SC = preload("res://scripts/server_config.gd")

const _SPAWN := Vector3(0.0, 0.0, 0.0)


func _make_gunner(pos: Vector3, ai_state: int, burst: int = 1) -> Object:
	var mob = _MD.new()
	mob.entity_id = 2031
	mob.mob_type_id = 53
	mob.position = pos
	mob.spawn_position = _SPAWN
	mob.aggro_radius = 12.0
	mob.leash_radius = 40.0  # generous so the band tests never trip the leash
	mob.melee_range = 15.0
	mob.ai_state = ai_state
	mob.current_target_id = 42  # a firefight always has a locked target (set by AGGROED)
	mob.ranged = true
	mob.ranged_min = 8.0
	mob.ranged_max = 15.0
	mob.ranged_attack = "revolver"
	mob.ranged_burst = burst
	mob.combat_state = CombatState.new()
	var cr := CombatResources.new()
	cr.hp = 150
	cr.max_hp = 150
	cr.stamina = 40
	cr.max_stamina = 40
	mob.resources = cr
	var stats := CharacterStats.new()
	stats.weapon_speed = 1.0
	stats.dex_val = 26
	stats.skills = {"Marksmanship": 42}
	mob.stats = stats
	var ab := AbilityData.new()
	ab.id = 0
	ab.range_units = 15.0
	ab.base_damage = 19
	ab.variance_min = 1.0
	ab.variance_max = 1.0
	ab.attacker_skill_coeffs = {}
	ab.mitigation_skill_coeffs = {}
	ab.crit_multiplier = 2.0
	ab.threat_multiplier = 1.0
	mob.melee_ability = ab
	return mob


func _make_player(pos: Vector3) -> Dictionary:
	var cr := CombatResources.new()
	cr.hp = 300
	cr.max_hp = 300
	return {
		"position": pos,
		"combat_state": CombatState.new(),
		"resources": cr,
		"stats": CharacterStats.new(),
	}


func _rng() -> RandomNumberGenerator:
	var r := RandomNumberGenerator.new()
	r.seed = 99
	return r


func test_closes_when_beyond_max_range() -> void:
	# Target at 30m (past the 15m band): the mob moves TOWARD it and does not fire.
	var mob = _make_gunner(Vector3(0, 0, 0), _MAI.MobAIState.AGGROED)
	var players := {42: _make_player(Vector3(30, 0, 0))}
	var res = _MAI.ai_tick(mob, players, null, 0, _rng())
	assert_lt(
		res.new_mob.position.distance_to(Vector3(30, 0, 0)),
		30.0,
		"a gunner past max range closes the gap"
	)
	assert_eq(res.events.size(), 0, "no shot fired while still closing")


func test_kites_back_when_inside_min_range() -> void:
	# Target at 4m (inside the 8m min): the mob backs AWAY and holds fire.
	var mob = _make_gunner(Vector3(0, 0, 0), _MAI.MobAIState.MELEE)
	var players := {42: _make_player(Vector3(4, 0, 0))}
	var res = _MAI.ai_tick(mob, players, null, 0, _rng())
	assert_gt(
		res.new_mob.position.distance_to(Vector3(4, 0, 0)),
		mob.position.distance_to(Vector3(4, 0, 0)),
		"a gunner too close kites away from the target"
	)
	# Backing away moves it toward -X (away from the +X target).
	assert_lt(res.new_mob.position.x, 0.0, "kite step is directly away from the target")


func test_fires_hitscan_inside_band() -> void:
	# Target at 11m (inside 8-15): the mob holds position and fires a ranged damage event.
	var mob = _make_gunner(Vector3(0, 0, 0), _MAI.MobAIState.MELEE)
	var players := {42: _make_player(Vector3(11, 0, 0))}
	var res = _MAI.ai_tick(mob, players, null, 100, _rng())
	assert_eq(res.new_mob.ai_state, _MAI.MobAIState.MELEE, "firing state is MELEE (shared gate)")
	assert_gt(res.events.size(), 0, "a shot is fired inside the band")
	var ev: Dictionary = res.events[0]
	assert_eq(str(ev.get("type", "")), "damage", "the shot is a damage event")
	assert_true(bool(ev.get("ranged", false)), "the event carries the ranged flag")
	assert_eq(str(ev.get("weapon", "")), "revolver", "the event names the weapon for client VFX")
	assert_eq(int(ev.get("target_id", -1)), 42, "the shot targets the player")


func test_burst_emits_multiple_shots() -> void:
	# The tommy burst (3) fires three hitscan events in one firing window.
	var mob = _make_gunner(Vector3(0, 0, 0), _MAI.MobAIState.MELEE, 3)
	var players := {42: _make_player(Vector3(10, 0, 0))}
	var res = _MAI.ai_tick(mob, players, null, 100, _rng())
	assert_eq(res.events.size(), 3, "a 3-round burst emits three damage events")


func test_dead_target_evades() -> void:
	var mob = _make_gunner(Vector3(0, 0, 0), _MAI.MobAIState.MELEE)
	mob.current_target_id = 42
	var dead := _make_player(Vector3(11, 0, 0))
	dead["combat_state"].state = _CS.CombatStateEnum.DEAD
	var res = _MAI.ai_tick(mob, {42: dead}, null, 100, _rng())
	assert_eq(res.new_mob.ai_state, _MAI.MobAIState.EVADING, "a gunner evades once its target dies")


func test_rooted_gunner_holds_and_fires() -> void:
	# T-063 CC: a rooted gunner cannot reposition but still fires if it happens to be in-band.
	var mob = _make_gunner(Vector3(0, 0, 0), _MAI.MobAIState.MELEE)
	mob.combat_state.rooted_until = 500
	var players := {42: _make_player(Vector3(11, 0, 0))}
	var res = _MAI.ai_tick(mob, players, null, 100, _rng())
	assert_eq(res.new_mob.position, Vector3(0, 0, 0), "a rooted gunner does not move")
	assert_gt(res.events.size(), 0, "a rooted in-band gunner still fires")
