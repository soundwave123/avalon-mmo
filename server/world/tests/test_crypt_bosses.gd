# T-332: Hollowed Crypt bosses — integration through the real T-331 instance spawn path + the
# T-294 balance gate. Proves the three bosses seed instance-scoped (NOT open-world), carry the elite
# chassis with UNIQUE kill-credit aliases matching the T-333 loot schedule, and that their live
# mechanics mutate the running world: the Warden summons capped adds that STAY dead, the dirge only
# damages same-instance players, and the modeled L12-15 gate holds (solo loses / trio wins).

extends GutTest

const _ISVC = preload("res://scripts/instance_service.gd")
const _ML = preload("res://scripts/combat/mob_loader.gd")
const _CS = preload("res://scripts/combat/combat_state.gd")
const _MAI = preload("res://scripts/combat/mob_ai.gd")
const _AA = preload("res://scripts/combat/auto_attack.gd")
const _SC = preload("res://scripts/server_config.gd")
const PlayerSessions = preload("res://scripts/player_sessions.gd")  # T-380: hermetic enter() gate

const _MOBS_DIR := "res://data/mobs"

# The three boss aliases — MUST equal the T-333 dungeon_schedule.json keys (loot) and the T-335
# quest kill targets. Unique per boss and distinct from the render silhouette (the T-294 rule).
const _BOSS_IDS := ["mob_crypt_aldric", "mob_crypt_vharis", "mob_crypt_maldrath"]

# Modeled L12-15 party (see the T-332 progress log for the derivation — DESIGN targets, not measured
# client numbers; the live 3-player E2E is the orchestrator's per the systems-lane split).
const SOLO_HP := 280.0
const SOLO_DPS := 45.0
const GROUP_DPS := 75.0  # tank 22 + melee dps 45 + healer 8
const HEALER_HPS := 55.0  # single-target sustain on the tank


func _rng() -> RandomNumberGenerator:
	var r := RandomNumberGenerator.new()
	r.seed = 11
	return r


func _noop1(_a) -> void:
	pass


func _noop2(_a, _b) -> void:
	pass


# A wired instance_service with the crypt seeded into instance 1 (bosses + trash), store-backed.
func _seeded_service() -> Object:
	var svc = _ISVC.new()
	var mobs: Dictionary = {}
	# party_of {1: -1} = peer 1 solo (party_id -1).
	var party_of := {1: -1}
	svc.setup(
		mobs, party_of, Callable(self, "_noop2"), Callable(self, "_noop2"), Callable(self, "_noop1")
	)
	# T-380: enter() is now proximity-gated on the peer's live session position; a stale far session
	# left by an earlier suite would block the seed. Clearing it → peer 1 has no session → gate bypass.
	PlayerSessions._reset_for_test()
	svc.enter(1)  # allocates instance 1 + seeds the crypt (bosses ride hollowed_crypt.json)
	return svc


func _find(mobs: Dictionary, alias: String):
	for eid in mobs:
		if mobs[eid].mob_id == alias:
			return mobs[eid]
	return null


# ---- Content: the three bosses on the elite chassis, decoupled aliases ----


func test_boss_files_are_elite_with_unique_aliases():
	var seen: Dictionary = {}
	for f in ["crypt_aldric.json", "crypt_vharis.json", "crypt_maldrath.json"]:
		var b = _ML.load_from_file(_MOBS_DIR + "/" + f, 7000)
		assert_not_null(b, "%s loads" % f)
		assert_true(b.elite, "%s is elite" % f)
		assert_ne(b.render_kind, "", "%s reuses a base undead mesh via render_kind" % f)
		assert_ne(b.mob_id, b.render_kind, "%s alias is decoupled from the render silhouette" % f)
		assert_ne(b.boss_mechanic, "", "%s has a boss mechanic" % f)
		assert_true(b.mob_id in _BOSS_IDS, "%s alias matches the T-333 loot schedule" % f)
		seen[b.mob_id] = true
	assert_eq(seen.size(), 3, "three distinct boss aliases")


func test_bosses_are_bigger_than_crypt_trash():
	# An elite must read as elite: visibly higher HP than the trash it reuses the mesh of.
	var warrior = _ML.load_from_file(_MOBS_DIR + "/skeletal_warrior.json", 7100)
	var aldric = _ML.load_from_file(_MOBS_DIR + "/crypt_aldric.json", 7101)
	assert_gt(aldric.resources.max_hp, warrior.resources.max_hp * 4, "Warden dwarfs a skeleton")
	assert_gt(
		aldric.melee_ability.base_damage, warrior.melee_ability.base_damage, "and hits far harder"
	)


func test_maldrath_towers_and_phases():
	var m = _ML.load_from_file(_MOBS_DIR + "/crypt_maldrath.json", 7200)
	assert_gt(m.render_scale, 1.0, "the Hollow King is scaled up")
	assert_eq(m.boss_mechanic, "phase_summon", "phase mechanic")
	assert_gt(m.resources.max_hp, 2000, "the graduation boss has the biggest pool")


# ---- Seed path: bosses are INSTANCE-scoped, never open world ----


func test_bosses_seed_into_the_instance_not_the_world():
	var svc = _seeded_service()
	var mobs: Dictionary = svc._mobs
	for alias in _BOSS_IDS:
		var b = _find(mobs, alias)
		assert_not_null(b, "%s seeded into the crypt instance" % alias)
		if b != null:
			assert_eq(int(b.instance_id), 1, "%s is scoped to instance 1" % alias)


func test_world_spawn_table_has_no_crypt_bosses():
	# The open-world spawns.json must still hold exactly the 3 T-294 elites — the crypt bosses live
	# only in the instance file (else two pugs would collide on them in the open world).
	var world := _ML.load_spawn_table(_MOBS_DIR)
	for id in world:
		assert_false(
			world[id].mob_id in _BOSS_IDS, "%s must not be an open-world spawn" % world[id].mob_id
		)


# ---- Warden Aldric: summons capped adds that stay dead ----


func test_warden_summons_capped_adds_that_stay_dead():
	var svc = _seeded_service()
	var mobs: Dictionary = svc._mobs
	var aldric = _find(mobs, "mob_crypt_aldric")
	aldric.ai_state = _MAI.MobAIState.MELEE  # engage it
	var boss_eid: int = aldric.entity_id

	# Opening tick: raise the add wave.
	svc.tick_bosses({}, 0, _rng())
	assert_eq(_live_adds(mobs, boss_eid), 2, "the Warden raises 2 skeletal-warrior adds")
	for eid in mobs:
		if mobs[eid].summoned_by == boss_eid:
			assert_true(mobs[eid].temporary, "adds are temporary")
			assert_eq(int(mobs[eid].instance_id), 1, "adds inherit the boss instance")
			assert_eq(mobs[eid].render_kind, "mob_skeletal_warrior", "adds reuse the skeleton mesh")

	# Same cadence window: no over-summon past the cap.
	svc.tick_bosses({}, 5, _rng())
	assert_eq(_live_adds(mobs, boss_eid), 2, "cap holds inside the cadence window")

	# Kill one add: it is swept (no respawn) — teaching focus-fire.
	_kill_one_add(mobs, boss_eid)
	svc.tick_bosses({}, 6, _rng())
	assert_eq(_live_adds(mobs, boss_eid), 1, "a killed add stays dead (swept, no respawn)")

	# Next cadence: the wave refills back to the cap.
	svc.tick_bosses({}, 300, _rng())
	assert_eq(_live_adds(mobs, boss_eid), 2, "the next wave refills to the cap")


func _live_adds(mobs: Dictionary, boss_eid: int) -> int:
	var n := 0
	for eid in mobs:
		if (
			mobs[eid].summoned_by == boss_eid
			and mobs[eid].combat_state.state != _CS.CombatStateEnum.DEAD
		):
			n += 1
	return n


func _kill_one_add(mobs: Dictionary, boss_eid: int) -> void:
	for eid in mobs:
		if mobs[eid].summoned_by == boss_eid:
			mobs[eid].combat_state.state = _CS.CombatStateEnum.DEAD
			return


# ---- Vharis dirge: AoE damage is INSTANCE-scoped (two parties at the same coords don't cross) ----


func test_dirge_only_hits_same_instance_players():
	var svc = _seeded_service()
	var mobs: Dictionary = svc._mobs
	var vharis = _find(mobs, "mob_crypt_vharis")
	vharis.ai_state = _MAI.MobAIState.MELEE

	# Two players on the SAME crypt coords, in DIFFERENT instances — instance injected in the snapshot
	# (hermetic; no global PlayerSessions state, which leaks token/order across the full suite).
	var players := {
		1: {"position": vharis.position, "instance_id": 1},  # same instance as the boss
		2: {"position": vharis.position, "instance_id": 2},  # a different party's instance
	}

	svc.tick_bosses(players, 0, _rng())  # begins the channel
	assert_eq(
		_find(mobs, "mob_crypt_vharis").combat_state.state,
		_CS.CombatStateEnum.CHANNELING,
		"the dirge channels"
	)
	var events: Array = svc.tick_bosses(players, 60, _rng())  # mid-channel pulse
	var hit: Dictionary = {}
	for ev in events:
		if str(ev.get("type", "")) == "damage":
			hit[int(ev.get("target_id", -1))] = true
	assert_true(hit.has(1), "the same-instance player takes dirge damage")
	assert_false(hit.has(2), "a player in another instance is NOT hit (isolation holds)")


# ---- Balance gate (T-294 method): solo loses, trio wins ----


func _boss_dps(mob, enraged: bool) -> float:
	var st: int = _AA.compute_swing_ticks(mob.resources.max_stamina, mob.stats.weapon_speed)
	var interval_s: float = float(st) / float(_SC.TICK_RATE_HZ)
	var dmg: float = float(mob.melee_ability.base_damage)
	if enraged:
		dmg *= mob.enrage_mult
	return dmg / interval_s


func test_gate_solo_loses_every_boss():
	for f in ["crypt_aldric.json", "crypt_vharis.json", "crypt_maldrath.json"]:
		var boss = _ML.load_from_file(_MOBS_DIR + "/" + f, 8000)
		var enraged: bool = f == "crypt_maldrath.json"  # a solo lingers into Maldrath's phase 2
		var boss_ttk: float = float(boss.resources.max_hp) / SOLO_DPS
		var solo_ttd: float = SOLO_HP / _boss_dps(boss, enraged)
		assert_lt(
			solo_ttd,
			boss_ttk,
			"%s: solo dies in %.1fs, boss needs %.1fs — solo LOSES" % [f, solo_ttd, boss_ttk]
		)


func test_gate_trio_wins_every_boss():
	for f in ["crypt_aldric.json", "crypt_vharis.json", "crypt_maldrath.json"]:
		var boss = _ML.load_from_file(_MOBS_DIR + "/" + f, 8100)
		var enraged: bool = f == "crypt_maldrath.json"
		# A healer out-sustains the boss's tank damage (even Maldrath's phase-2 enrage), so the trio
		# never wipes on melee...
		assert_gte(
			HEALER_HPS,
			_boss_dps(boss, enraged),
			"%s: a healer out-sustains the tank (trio survives)" % f
		)
		# ...and the group's DPS clears the pool inside a lean run window.
		var boss_ttk: float = float(boss.resources.max_hp) / GROUP_DPS
		assert_lt(boss_ttk, 45.0, "%s: trio clears it in %.1fs — trio WINS" % [f, boss_ttk])
