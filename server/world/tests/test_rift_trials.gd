# T-393: Rift Trials through the real T-331 instance chassis — the acceptance loop. Proves the
# seed is scaled by the MASTER-read keystone tier (never a wire field), a timed clear / a blown
# timer / an abandoned run are all SERVER-adjudicated exactly once, and the adjudication hands the
# master the holder + members + honest scaled reward block. The fake master returns canned rift_op
# answers (await on a non-coroutine resolves immediately, the test_rift_era precedent).
extends GutTest

const _ISVC = preload("res://scripts/instance_service.gd")
const _IM = preload("res://scripts/instance_manager.gd")
const _CS = preload("res://scripts/combat/combat_state.gd")
const _RS = preload("res://scripts/combat/rift_scaling.gd")
const PlayerSessions = preload("res://scripts/player_sessions.gd")
const _TOKEN := "abcdef0123456789abcdef0123456789"  # gitleaks:allow — hex session token
const _PORCH := Vector3(14.0, -12.5, 0.0)  # standing on the crypt porch (CRYPT_PORCH)


class _FakeRiftMaster:
	var tier: int = 1
	var calls: Array = []  # [[method, params], ...]

	func call_master(method: String, params: Dictionary) -> Dictionary:
		calls.append([method, params.duplicate(true)])
		match str(params.get("action", "")):
			"keystone":
				return {"ok": true, "tier": tier, "season": 2}
			"result":
				var cleared := bool(params.get("cleared", false))
				return {
					"ok": true,
					"cleared": cleared,
					"tier": tier,
					"new_tier": tier + 1 if cleared else maxi(1, tier - 1),
					"season": 2,
					"rewards": [],
				}
			"leaderboard":
				return {"ok": true, "season": 2, "entries": [{"username": "ace", "tier": 7}]}
		return {"error": "unknown_action"}

	func result_calls() -> Array:
		var out: Array = []
		for c in calls:
			if str((c[1] as Dictionary).get("action", "")) == "result":
				out.append(c[1])
		return out


var _master: _FakeRiftMaster
var _mobs: Dictionary = {}
var _replies: Array = []  # [[peer, msg], ...]
var _now: int = 1_000


func before_each() -> void:
	PlayerSessions._reset_for_test()
	_master = _FakeRiftMaster.new()
	_mobs = {}
	_replies = []
	_now = 1_000


func _noop1(_a) -> void:
	pass


func _noop2(_a, _b) -> void:
	pass


func _rec_reply(peer: int, msg: Dictionary) -> void:
	_replies.append([peer, msg])


func _fake_now() -> int:
	return _now


func _svc(with_master: bool = true) -> Object:
	var svc = _ISVC.new()
	svc.setup(
		_mobs, {}, Callable(self, "_noop2"), Callable(self, "_noop2"), Callable(self, "_noop1")
	)
	svc.setup_lfg({}, Callable(self, "_rec_reply"), _master if with_master else null)
	svc.setup_rift_clock(Callable(self, "_fake_now"))
	return svc


func _seed_session(peer: int, username: String) -> void:
	PlayerSessions.add_player(peer, _TOKEN, username, _PORCH)


func _rng() -> RandomNumberGenerator:
	var r := RandomNumberGenerator.new()
	r.seed = 7
	return r


func _kill_bosses(iid: int) -> int:
	var killed := 0
	for eid in _mobs:
		var mob = _mobs[eid]
		if int(mob.instance_id) == iid and mob.boss_mechanic != "":
			mob.combat_state.state = _CS.CombatStateEnum.DEAD
			killed += 1
	return killed


func test_handles_the_rift_intents() -> void:
	var svc = _svc()
	assert_true(svc.handles("enter_rift_instance"))
	assert_true(svc.handles("rift_status"))
	assert_true(svc.handles("rift_leaderboard"))


func test_seed_is_scaled_by_the_master_keystone_tier() -> void:
	# Baseline: an unscaled crypt instance in a parallel service (same iid -> same entity ids).
	var base_mobs := _mobs
	var crypt = _ISVC.new()
	crypt.setup(
		base_mobs, {}, Callable(self, "_noop2"), Callable(self, "_noop2"), Callable(self, "_noop1")
	)
	_seed_session(1, "runner")
	crypt.enter(1)
	var base_hp: Dictionary = {}
	var base_dmg: Dictionary = {}
	for eid in base_mobs:
		base_hp[eid] = int(base_mobs[eid].resources.max_hp)
		base_dmg[eid] = int(base_mobs[eid].melee_ability.base_damage)
	# The rift at tier 5, in a fresh service/mob store.
	_mobs = {}
	_master.tier = 5
	var svc = _svc()
	var iid: int = await svc.enter_rift(1)
	assert_ne(iid, _IM.WORLD, "rift instance allocated")
	var p: Dictionary = _RS.params_for(5)
	assert_gt(_mobs.size(), 0, "rift seeded mobs")
	for eid in _mobs:
		assert_eq(
			int(_mobs[eid].resources.max_hp),
			int(round(float(base_hp[eid]) * float(p["hp_mult"]))),
			"hp scaled by the tier-5 multiplier"
		)
		assert_eq(
			int(_mobs[eid].melee_ability.base_damage),
			int(round(float(base_dmg[eid]) * float(p["dmg_mult"]))),
			"damage scaled by the tier-5 multiplier"
		)


func test_forged_tier_in_the_intent_payload_is_ignored() -> void:
	_seed_session(1, "runner")
	_master.tier = 3
	var svc = _svc()
	# The attacker names tier 999 in the packet; the payload is not even passed to enter_rift.
	svc.handle("enter_rift_instance", 1, {"tier": 999, "action": "result", "cleared": true})
	var run: Dictionary = svc._rift_runs.get(1, {})
	assert_eq(int(run.get("tier", -1)), 3, "run tier is the MASTER keystone, not the packet")
	# and the only master traffic was the keystone READ — never a result/set write
	assert_eq(_master.result_calls().size(), 0, "no forged verdict reached the master")


func test_timed_clear_adjudicates_once_with_honest_scaled_reward() -> void:
	_seed_session(1, "runner")
	_master.tier = 4
	var svc = _svc()
	var iid: int = await svc.enter_rift(1)
	assert_gt(_kill_bosses(iid), 0, "the crypt bosses exist in the rift seed")
	_now += 10  # well inside the timer
	svc.tick_bosses({}, 0, _rng())
	var results: Array = _master.result_calls()
	assert_eq(results.size(), 1, "exactly one verdict")
	var res: Dictionary = results[0]
	assert_true(bool(res["cleared"]), "a boss-dead-in-time run CLEARS")
	assert_eq(str(res["holder"]), "runner")
	assert_eq(res["members"], ["runner"])
	var reward: Dictionary = res["reward"]
	assert_eq(float(reward["weight"]), _RS.reward_weight(4), "reward weight matches the tier curve")
	assert_gt((reward["pool"] as Array).size(), 0, "published reward pool rides the verdict")
	assert_gt(float(reward["base_chance"]), 0.0, "published base odds ride the verdict")
	# a second tick must NOT re-adjudicate
	svc.tick_bosses({}, 0, _rng())
	assert_eq(_master.result_calls().size(), 1, "no double adjudication")
	# and the members were toasted with the verdict
	var toasts := _replies.filter(
		func(r): return str((r[1] as Dictionary).get("type", "")) == "rift_result"
	)
	assert_eq(toasts.size(), 1, "one rift_result toast to the runner")
	assert_true(bool((toasts[0][1] as Dictionary)["cleared"]))


func test_blown_timer_adjudicates_fail() -> void:
	_seed_session(1, "runner")
	_master.tier = 2
	var svc = _svc()
	await svc.enter_rift(1)
	_now += _RS.timer_secs(2) + 1  # the deadline passes; bosses still alive
	svc.tick_bosses({}, 0, _rng())
	var results: Array = _master.result_calls()
	assert_eq(results.size(), 1, "one verdict")
	assert_false(bool(results[0]["cleared"]), "a blown timer FAILS (keystone downgrade)")


func test_abandoning_the_run_adjudicates_fail() -> void:
	_seed_session(1, "runner")
	var svc = _svc()
	await svc.enter_rift(1)
	svc.leave(1)  # last member out before any verdict -> teardown -> fail
	var results: Array = _master.result_calls()
	assert_eq(results.size(), 1, "one verdict on teardown")
	assert_false(bool(results[0]["cleared"]), "bailing out can never dodge the downgrade")
	# and a cleared run's teardown does NOT re-adjudicate (state erased with the instance)
	assert_false(svc._rift_runs.has(1), "run record died with the instance")


func test_enter_far_from_the_porch_is_denied() -> void:
	PlayerSessions.add_player(9, _TOKEN, "farmer", Vector3(300.0, 300.0, 0.0))
	var svc = _svc()
	var iid: int = await svc.enter_rift(9)
	assert_eq(iid, _IM.WORLD, "no rift from across the map")
	assert_eq(_mobs.size(), 0, "nothing seeded")


func test_rift_status_and_leaderboard_reads_force_the_master_action() -> void:
	_seed_session(1, "runner")
	_master.tier = 6
	var svc = _svc()
	svc.handle("rift_status", 1, {"action": "result", "cleared": true})  # forged fields
	svc.handle("rift_leaderboard", 1, {"action": "result", "limit": 999})
	for c in _master.calls:
		var action := str((c[1] as Dictionary).get("action", ""))
		assert_true(action in ["keystone", "leaderboard"], "reads stay reads: %s" % action)
	var lb := _replies.filter(
		func(r): return str((r[1] as Dictionary).get("type", "")) == "rift_leaderboard"
	)
	assert_eq(lb.size(), 1)
	var status := _replies.filter(
		func(r): return str((r[1] as Dictionary).get("type", "")) == "rift_status"
	)
	assert_eq(status.size(), 1)
	assert_eq(int((status[0][1] as Dictionary)["tier"]), 6, "status reports the master tier")
