extends GutTest

# T-413: Crownfield battleground — the pure store (lobby → launch → score → end) plus the social
# hub trust boundary (queue gates, real-death respawn, teleports, and the ONE payout path: the
# server-observed record_match with bracket "bg"). Rules reflect the 2026-07-16 owner rulings: 3v3,
# real deaths that respawn at the team spawn (knockout floor vetoed), and deserters that FORFEIT
# (no payout, no recorded loss). StubMaster counts every payout call so the double-payout guard is
# asserted directly.

const _BGSVC = preload("res://scripts/battleground_service.gd")
const _SVC = preload("res://scripts/social_service.gd")
const PlayerSessions = preload("res://scripts/player_sessions.gd")

const TOK := [
	"aaaaaaaa11111111aaaaaaaa11111111",  # gitleaks:allow
	"bbbbbbbb22222222bbbbbbbb22222222",  # gitleaks:allow
	"cccccccc33333333cccccccc33333333",  # gitleaks:allow
	"dddddddd44444444dddddddd44444444",  # gitleaks:allow
	"eeeeeeee55555555eeeeeeee55555555",  # gitleaks:allow
	"ffffffff66666666ffffffff66666666",  # gitleaks:allow
]

var _sent: Array = []
var _master: StubMaster = null


class StubMaster:
	extends RefCounted
	var calls: Array = []
	var reply: Dictionary = {"ok": true, "honor": {"winner_honor": 27, "loser_honor": 20}}

	func call_master(method: String, params: Dictionary) -> Dictionary:
		calls.append({"method": method, "params": params})
		return reply

	func record_calls() -> Array:
		return calls.filter(func(c): return str(c["method"]) == "record_match")


func before_each() -> void:
	PlayerSessions._reset_for_test()
	_sent = []
	_master = StubMaster.new()


func _svc() -> RefCounted:
	var s = _SVC.new()
	s.setup(
		func(pid: int, msg: Dictionary): _sent.append({"pid": pid, "msg": msg}), {}, _master, null
	)
	return s


# PLAYERS_NEEDED live open-world peers, queued in order. Returns the hub with the match LAUNCHED.
func _launched():
	var s = _svc()
	for i in _BGSVC.PLAYERS_NEEDED:
		PlayerSessions.add_player(i + 1, TOK[i], "p%d" % (i + 1), Vector3(float(i), 0.0, 0.0))
	for i in _BGSVC.PLAYERS_NEEDED:
		s.handle("bg_queue", i + 1, {}, 1000)
	return s


func _pos_of(pid: int) -> Vector3:
	return PlayerSessions.get_player(pid).get("pos", Vector3.ZERO)


func _move_all_to(pids: Array, pos: Vector3) -> void:
	for pid in pids:
		PlayerSessions.update_position(int(pid), pos)


# ---- lobby → launch ----------------------------------------------------------


func test_final_queue_launches_match_teams_and_instance() -> void:
	var s = _launched()
	# All six moved into the SAME dedicated instance bucket, off the open world.
	var iid := PlayerSessions.get_instance(1)
	assert_gte(iid, _BGSVC.IID_BASE, "bg instance ids live in the dedicated range")
	for pid in [2, 3, 4, 5, 6]:
		assert_eq(PlayerSessions.get_instance(pid), iid, "one bucket for the whole match")
	# Queue order split: [1,2,3] vs [4,5,6] — opposing pairs eligible, teammates not.
	assert_true(s.pvp_eligible(1, 4), "cross-team combat is consented")
	assert_true(s.pvp_eligible(6, 2))
	assert_false(s.pvp_eligible(1, 2), "teammates are never eligible")
	assert_false(s.pvp_eligible(4, 6))
	# Spawned at their team camps (planar x of TEAM_SPAWNS); teammates fan out, none stacked.
	assert_eq(_pos_of(1).x, _BGSVC.TEAM_SPAWNS[0].x)
	assert_eq(_pos_of(4).x, _BGSVC.TEAM_SPAWNS[1].x)
	assert_ne(_pos_of(1).y, _pos_of(2).y, "teammates do not spawn stacked")
	assert_ne(_pos_of(2).y, _pos_of(3).y)


func test_double_queue_and_requeue_while_in_match_rejected() -> void:
	var s = _svc()
	PlayerSessions.add_player(1, TOK[0], "p1", Vector3.ZERO)
	s.handle("bg_queue", 1, {}, 1000)
	s.handle("bg_queue", 1, {}, 1001)  # double-queue — the store refuses a second entry
	var bg = s._bg
	assert_eq(bg.queue_size(), 1, "double queue never inflates the lobby")
	# In a launched match, another bg_queue is refused (in_match).
	s = _launched()
	s.handle("bg_queue", 1, {}, 2000)
	assert_eq(s._bg.queue_size(), 0, "a match member cannot re-enter the lobby")


func test_queue_gates_dueling_and_instanced_players() -> void:
	var s = _svc()
	for i in 4:
		PlayerSessions.add_player(i + 1, TOK[i], "p%d" % (i + 1), Vector3(float(i), 0.0, 0.0))
	# Peer 4 wanders into the crypt (instance 7) after 3 queue; peer 4's queue must be refused.
	PlayerSessions.set_instance(4, 7)
	for i in 4:
		s.handle("bg_queue", i + 1, {}, 1000)
	assert_eq(s._bg.queue_size(), 3, "an instanced peer never enters the lobby")
	assert_eq(PlayerSessions.get_instance(1), 0, "no launch happened")


func test_stale_lobbyist_pruned_before_launch() -> void:
	var s = _svc()
	for i in 4:
		PlayerSessions.add_player(i + 1, TOK[i], "p%d" % (i + 1), Vector3(float(i), 0.0, 0.0))
	for i in 3:
		s.handle("bg_queue", i + 1, {}, 1000)
	# Peer 2 starts a crypt run AFTER queueing — the 4th join must prune them, not launch with them.
	PlayerSessions.set_instance(2, 9)
	s.handle("bg_queue", 4, {}, 2000)
	assert_eq(s._bg.queue_size(), 3, "stale entry pruned; lobby waits for a real fourth")
	assert_eq(PlayerSessions.get_instance(1), 0, "peer 1 was never pulled into an arena")


# ---- scoring + end conditions --------------------------------------------------


func test_exclusive_control_scores_and_wins_at_target() -> void:
	var s = _launched()
	var iid := PlayerSessions.get_instance(1)
	# Team 1 (peers 1,2,3) stands on the Crown; team 2 stays home.
	_move_all_to([1, 2, 3], Vector3(_BGSVC.ARENA_CENTER.x, _BGSVC.ARENA_CENTER.y, 0.0))
	s.bg_tick(1000 + _BGSVC.SCORE_TARGET * 1000 + 1000)  # enough exclusive seconds in one pass
	assert_eq(_master.record_calls().size(), 3, "match ended: one record_match per active pair")
	for c in _master.record_calls():
		assert_eq(str(c["params"]["bracket"]), "bg", "payout rides the bg bracket")
		assert_true(str(c["params"]["winner"]).begins_with("p"), "server-resolved usernames")
	# Winners are team 1 (p1/p2/p3) — the payout pairs them against p4/p5/p6.
	var winners := _master.record_calls().map(func(c): return str(c["params"]["winner"]))
	assert_true("p1" in winners and "p2" in winners and "p3" in winners, "the controlling team won")
	# Everyone returned to the open world at their queue positions.
	for pid in [1, 2, 3, 4, 5, 6]:
		assert_eq(PlayerSessions.get_instance(pid), 0, "returned to the open world")
	assert_eq(Vector2(_pos_of(1).x, _pos_of(1).y), Vector2.ZERO, "returned to the queue spot")
	assert_ne(PlayerSessions.get_instance(1), iid)


func test_contested_crown_scores_nothing_and_horn_voids_scoreless_match() -> void:
	var s = _launched()
	# All six on the disc — contested for the whole match: 0-0 at the horn -> VOID.
	_move_all_to([1, 2, 3, 4, 5, 6], Vector3(_BGSVC.ARENA_CENTER.x, _BGSVC.ARENA_CENTER.y, 0.0))
	s.bg_tick(1000 + _BGSVC.MATCH_MS + 1000)
	assert_eq(_master.record_calls().size(), 0, "a scoreless void pays and records NOTHING")
	for pid in [1, 2, 3, 4, 5, 6]:
		assert_eq(PlayerSessions.get_instance(pid), 0, "void still returns everyone home")


func test_horn_decides_by_score_not_target() -> void:
	var s = _launched()
	_move_all_to([4, 5, 6], Vector3(_BGSVC.ARENA_CENTER.x, _BGSVC.ARENA_CENTER.y, 0.0))
	s.bg_tick(1000 + 30 * 1000)  # 30 exclusive seconds for team 2 — below target
	assert_eq(_master.record_calls().size(), 0, "match still running below the target")
	_move_all_to([4, 5, 6], _BGSVC.TEAM_SPAWNS[1])  # step off; nobody scores further
	s.bg_tick(1000 + _BGSVC.MATCH_MS + 1000)  # the horn
	assert_eq(_master.record_calls().size(), 3, "the horn resolves on score")
	var winners := _master.record_calls().map(func(c): return str(c["params"]["winner"]))
	assert_true(
		"p4" in winners and "p5" in winners and "p6" in winners, "leading team wins at horn"
	)


# ---- real deaths (knockout floor VETOED 2026-07-16) ------------------------------


func test_bg_hit_is_a_real_death_and_respawns_at_team_spawn() -> void:
	var s = _launched()
	var res := {1: MiniRes.new(100, 0)}  # peer 1 dropped to 0 — a REAL death, no floor clamp
	# on_duel_hit no longer consumes the check: a bg hit falls through to the ordinary death path.
	assert_false(
		s.on_duel_hit(1, res, 0), "a bg death is NOT intercepted — real combat rules apply"
	)
	assert_eq(res[1].hp, 0, "hp is not clamped to a knockout floor (floor vetoed)")
	# The respawn hook redirects a live bg member to their TEAM SPAWN inside the arena.
	var rp: Dictionary = s.bg_respawn_point(1)
	assert_false(rp.is_empty(), "a live bg member respawns inside the arena, not the graveyard")
	assert_eq(rp["spawn"].x, _BGSVC.TEAM_SPAWNS[0].x, "respawn is the team spawn")
	assert_true(s._bg.in_match(1), "dying does NOT desert the match — the player stays in")
	assert_true(s.bg_respawn_point(999).is_empty(), "a non-bg peer uses the normal respawn point")


class MiniRes:
	extends RefCounted
	var hp: int
	var max_hp: int

	func _init(mx: int, cur: int) -> void:
		max_hp = mx
		hp = cur


# ---- desertion / forfeit (deserters FORFEIT — no payout, no loss recorded, 2026-07-16) ----------


func test_team_wipe_by_desertion_forfeits_and_records_no_deserter() -> void:
	var s = _launched()
	# Team 1 (peers 1,2,3) all disconnect: forfeit — team 2 wins by desertion.
	s.forget(1)
	s.forget(2)
	assert_eq(_master.record_calls().size(), 0, "partial desertion does not end a 3v3")
	s.forget(3)  # team 1 fully gone -> forfeit ends the match
	# Deserters FORFEIT: no payout, no recorded loss. With every loser deserted the winners have no
	# active opponent to record against, so a full-team desertion pays no one.
	assert_eq(_master.record_calls().size(), 0, "a full-team desertion records no one")
	var losers := _master.record_calls().map(func(c): return str(c["params"]["loser"]))
	assert_false("p1" in losers or "p2" in losers or "p3" in losers, "a deserter is NEVER recorded")
	# Replaying every end trigger finds no match — a double payout is impossible.
	s.forget(4)
	s.bg_tick(1000 + _BGSVC.MATCH_MS + 1000)
	assert_eq(_master.record_calls().size(), 0, "no second payout exists to trigger")


func test_deserter_excluded_from_payout_while_others_record_normally() -> void:
	var s = _launched()
	s.forget(6)  # one team-2 member (team 2 = [4,5,6]) deserts mid-match — forfeits
	assert_eq(_master.record_calls().size(), 0, "one deserter does not end a 3v3")
	# Team 1 takes the Crown to the target and wins by score.
	_move_all_to([1, 2, 3], Vector3(_BGSVC.ARENA_CENTER.x, _BGSVC.ARENA_CENTER.y, 0.0))
	s.bg_tick(1000 + _BGSVC.SCORE_TARGET * 1000 + 1000)
	# 3 active winners vs 2 active losers (p6 deserted) -> pair over the active minimum = 2.
	assert_eq(
		_master.record_calls().size(), 2, "one pair per active opponent; the deserter unpaired"
	)
	var losers := _master.record_calls().map(func(c): return str(c["params"]["loser"]))
	assert_false("p6" in losers, "the deserter never appears in the payout")
	assert_true("p4" in losers and "p5" in losers, "the remaining losers record normally")


func test_leash_deserts_a_straggler() -> void:
	var s = _launched()
	# Peer 3 ends up across the map (a respawn/teleport edge) — the leash deserts them out.
	PlayerSessions.update_position(3, Vector3(0.0, 0.0, 0.0))
	s.bg_tick(2000)
	assert_false(s._bg.in_match(3), "beyond the leash you have left the field")
	assert_eq(PlayerSessions.get_instance(3), 0, "leashed straggler returned to the world")
	assert_true(s._bg.in_match(4), "the rest of the match fights on")
