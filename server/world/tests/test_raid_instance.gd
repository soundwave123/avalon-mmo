# T-473: the Vault of the First Hollowing — the Era-1 10-man raid instance on the T-331 seam.
# Proves the ENTRANCE GATE (a plain 5-party and an under-filled raid are rejected server-side; a
# T-472 raid of >5 is admitted), the seed path (vault bosses spawn INSTANCE-scoped from
# hollow_vault.json with aliases matching the weekly loot schedule), the wrong-threshold guard
# (a raid bound to the Vault cannot walk a member in through the crypt door), and the Vault's own
# exit/respawn anchors. Store-backed and headless (no sessions -> the T-380 proximity gate passes,
# its unit-test bypass).
extends GutTest

const _ISVC = preload("res://scripts/instance_service.gd")
const _IM = preload("res://scripts/instance_manager.gd")
const _PL = preload("res://scripts/party_logic.gd")
const _RL = preload("res://scripts/raid_logic.gd")
const _ML = preload("res://scripts/combat/mob_loader.gd")
const _DL = preload("res://scripts/combat/dungeon_loot.gd")
const PlayerSessions = preload("res://scripts/player_sessions.gd")

const _MOBS_DIR := "res://data/mobs"
# The three vault bosses — MUST equal the T-473 weekly entries in dungeon_schedule.json.
const _BOSS_IDS := ["mob_vault_sentinel", "mob_vault_dirgemother", "mob_vault_hollow_king"]

var _moves: Dictionary = {}
var _replies: Array = []


func before_each() -> void:
	_moves = {}
	_replies = []
	PlayerSessions._reset_for_test()


func _noop1(_a) -> void:
	pass


func _noop2(_a, _b) -> void:
	pass


func _record_move(peer: int, pos: Vector3) -> void:
	_moves[peer] = pos


func _record_reply(_peer: int, data: Dictionary) -> void:
	_replies.append(data)


# A party store of n peers 1..n led by 1; raid-converted when `raid` (subgroups auto-seat 5+5).
func _group(n: int, raid: bool) -> Dictionary:
	var s := _PL.new_store()
	for m in range(2, mini(n, 5) + 1):
		_PL.invite(s, 1, m)
		_PL.accept(s, m)
	if raid:
		_RL.convert(s, 1)
		for m in range(6, n + 1):
			_PL.invite(s, 1, m)
			_PL.accept(s, m)
	return s


# A wired instance_service over a live party store (party_of passed BY REF, the main.gd wiring).
func _service(party_store: Dictionary) -> Object:
	var svc = _ISVC.new()
	svc.setup(
		{},
		party_store["party_of"],
		Callable(self, "_noop2"),
		Callable(self, "_record_move"),
		Callable(self, "_noop1")
	)
	svc.setup_lfg({}, Callable(self, "_record_reply"))
	svc.setup_rift(party_store, Callable(), {})
	return svc


func _last_reason() -> String:
	return "" if _replies.is_empty() else str(_replies[-1].get("reason", ""))


# ---- Entrance gate: raid-of->5 only ----


func test_plain_five_party_is_rejected_at_the_vault_door() -> void:
	var s := _group(5, false)
	var svc = _service(s)
	assert_eq(svc.enter_raid(1), _IM.WORLD, "a 5-party is not a raid — turned away")
	assert_eq(_last_reason(), "requires_raid")
	assert_eq(_IM.instance_count(svc._store), 0, "no instance was allocated")


func test_underfilled_raid_is_rejected_full_raid_is_admitted() -> void:
	var five := _group(5, true)  # converted but still only 5 members — under the T-472 size
	assert_true(_RL.is_raid(five, 1), "the container IS a raid")
	var svc5 = _service(five)
	assert_eq(svc5.enter_raid(1), _IM.WORLD, "a raid of 5 is under the entry size")
	assert_eq(_last_reason(), "requires_raid")
	var six := _group(6, true)
	var svc6 = _service(six)
	assert_gt(svc6.enter_raid(1), _IM.WORLD, "a raid of 6 (>MAX_PARTY) crosses the threshold")
	var ten := _group(10, true)
	var svc10 = _service(ten)
	var iid: int = svc10.enter_raid(1)
	assert_gt(iid, _IM.WORLD, "a full 10-raid is admitted")
	for m in range(2, 11):
		assert_eq(svc10.enter_raid(m), iid, "every raid member joins the SAME instance")
	assert_eq(_IM.members(svc10._store, iid).size(), 10)


func test_solo_peer_is_rejected() -> void:
	var svc = _service(_PL.new_store())
	assert_eq(svc.enter_raid(42), _IM.WORLD)
	assert_eq(_last_reason(), "requires_raid")


# ---- Seed path: vault bosses are instance-scoped and match the weekly loot schedule ----


func test_vault_seeds_bosses_and_trash_instance_scoped() -> void:
	var s := _group(10, true)
	var svc = _service(s)
	var iid: int = svc.enter_raid(1)
	var seen: Dictionary = {}
	for eid in svc._mobs:
		var mob = svc._mobs[eid]
		assert_eq(int(mob.instance_id), iid, "%s is instance-scoped, never open-world" % mob.mob_id)
		seen[mob.mob_id] = true
	for alias in _BOSS_IDS:
		assert_true(seen.has(alias), "%s seeded from hollow_vault.json" % alias)
	assert_gt(svc._mobs.size(), 12, "trash packs seed alongside the bosses")
	assert_eq(_moves[1], svc.VAULT_ENTRANCE, "the entrant lands at the Vault antechamber")


func test_boss_files_ride_the_elite_chassis_and_the_weekly_schedule() -> void:
	var schedule := _DL.load_schedule()
	for f in ["vault_sentinel.json", "vault_dirgemother.json", "vault_hollow_king.json"]:
		var b = _ML.load_from_file(_MOBS_DIR + "/" + f, 8000)
		assert_not_null(b, "%s loads" % f)
		assert_true(b.elite, "%s is elite" % f)
		assert_ne(b.boss_mechanic, "", "%s has a T-332 boss mechanic" % f)
		assert_true(b.mob_id in _BOSS_IDS, "%s alias matches the schedule keys" % f)
		assert_eq(str(schedule[b.mob_id]["cadence"]), "weekly", "%s loot is weekly-locked" % f)
	var maldrath = _ML.load_from_file(_MOBS_DIR + "/crypt_maldrath.json", 8100)
	var king = _ML.load_from_file(_MOBS_DIR + "/vault_hollow_king.json", 8101)
	assert_gt(
		king.resources.max_hp,
		maldrath.resources.max_hp * 10,
		"the 10-man boss pool dwarfs the 5-man graduation boss (RAID_DPS 293 vs trio 75)"
	)
	assert_gt(king.render_scale, maldrath.render_scale, "and he towers over Maldrath")


# ---- Wrong-threshold guard + exit/respawn anchors ----


func test_crypt_door_cannot_join_the_raids_vault_instance() -> void:
	var s := _group(10, true)
	var svc = _service(s)
	var iid: int = svc.enter_raid(1)
	assert_gt(iid, _IM.WORLD)
	assert_eq(svc.enter(2), _IM.WORLD, "a raid-mate at the CRYPT door is turned away")
	assert_eq(_last_reason(), "wrong_threshold")
	assert_eq(_IM.instance_of(svc._store, 2), _IM.WORLD, "the join was rolled back")
	assert_eq(_IM.members(svc._store, iid), [1], "the vault instance is untouched")


func test_vault_exit_and_respawn_use_vault_anchors() -> void:
	var s := _group(10, true)
	var svc = _service(s)
	svc.enter_raid(1)
	assert_eq(svc.respawn_point(1), svc.VAULT_ENTRANCE, "a vault death corpse-runs INSIDE the raid")
	svc.leave(1)
	assert_eq(_moves[1], svc.VAULT_EXIT, "climbing out lands at the undercroft door, not the crypt")
	assert_eq(_IM.instance_count(svc._store), 0, "last one out tears the instance down")
	assert_true(svc._instance_kind.is_empty(), "the kind record dies with the instance")


func test_crypt_still_uses_crypt_anchors() -> void:
	var svc = _service(_PL.new_store())
	var iid: int = svc.enter(1)  # solo crypt entry (party_id -1), the T-331 behaviour unchanged
	assert_gt(iid, _IM.WORLD)
	assert_eq(_moves[1], svc.CRYPT_ENTRANCE)
	assert_eq(svc.respawn_point(1), svc.CRYPT_ENTRANCE)
	svc.leave(1)
	assert_eq(_moves[1], svc.CRYPT_EXIT)
