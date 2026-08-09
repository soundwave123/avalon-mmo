# T-413: Crownfield — the first group-PvP vessel (3v3 instanced control-point skirmish). PURE
# module (duel_service/instance_manager style): RefCounted, no OS clock, no PlayerSessions — the
# social hub threads identity/positions/time in and applies the returned session moves itself.
# This store owns queue + match truth; the hub owns the trust boundary (session identity, rate
# limits, eligibility gates) and the ONLY payout path (the server-observed record_match master op).
#
# Shape (ticket Phase A + 2026-07-16 owner rulings): a consent LOBBY, not a matchmaker — the match
# launches the instant PLAYERS_NEEDED eligible peers are queued (WoW War-Games lesson: at tiny CCU
# entry must be player-initiated; six friends queueing = an instant match). One capture disc at
# arena center; a team scores 1 point per second of EXCLUSIVE live presence on it (Arathi-Basin
# accrual shape); first to SCORE_TARGET or the higher score at the MATCH_MS horn wins (tie ->
# earliest to reach the score; 0-0 -> void). REAL combat rules apply (owner veto of the knockout
# floor): players die real deaths with normal penalties, then respawn at their TEAM SPAWN inside
# the arena (respawn_spawn) — dying never deserts a match. Deserters (leave intent, leash-out,
# disconnect) stay on the roster but FORFEIT: no payout, no loss recorded (owner veto of
# deserters-as-losers); the match continues/ends as designed for everyone else.

extends RefCounted

const TEAM_SIZE := 3  # 3v3 — owner ruling 2026-07-16 (flipped from the 2v2 first vessel)
const PLAYERS_NEEDED := TEAM_SIZE * 2
const MATCH_MS := 360_000  # the 6-minute horn — bounded 5-8 min with entry, never a stalemate
const SCORE_TARGET := 100  # 100 exclusive-control seconds ends it outright
const SCORE_TICK_MS := 1000  # accrual granularity: 1 point per exclusive second
const POINT_RADIUS := 4.0  # the Crown disc (planar, around ARENA_CENTER)
const LEASH_RADIUS := 60.0  # beyond this from center you have LEFT the match (deserter)
# The arena stands on the DEAD-FLAT offset plain (height()==0 past r~330, the crypt/Ashmoor
# precedent) at world (0, 420) — greybox by decree, no art mandate. Server ground is planar (x,y).
const ARENA_CENTER := Vector2(0.0, 420.0)
const TEAM_SPAWNS := [Vector3(-16.0, 420.0, 0.0), Vector3(16.0, 420.0, 0.0)]
# BG instance ids live in their own range so they can never collide with the crypt coordinator's
# small monotonic ids — each match is its own broadcast bucket (positions_frames isolation free).
const IID_BASE := 500_000

var _queue: Array = []  # [{peer, name, entry(Vector3)}] in arrival order
# mid -> {iid, teams:[Array[peer],Array[peer]], names:{peer:name}, entry:{peer:Vector3},
#          active:{peer:true}, score:[int,int], reached:[int,int] (ms each team last GAINED, for
#          the tie-break), started(ms), last_accrue(ms), control(int: -1 none/contested)}
var _matches: Dictionary = {}
var _match_of: Dictionary = {}  # peer -> mid (roster membership survives desertion until _end)
var _next_mid: int = 1

# ---- queue (the consent lobby) ----------------------------------------------


func is_queued(peer_id: int) -> bool:
	for e in _queue:
		if int(e["peer"]) == peer_id:
			return true
	return false


func in_match(peer_id: int) -> bool:
	var mid: int = int(_match_of.get(peer_id, -1))
	return mid != -1 and bool(_matches[mid]["active"].has(peer_id))


func queue_size() -> int:
	return _queue.size()


# T-698: any live match? tick() iterates matches only, so the hub can skip its per-tick
# get_positions() rebuild entirely while nobody is on the Crownfield (the overwhelming case).
func active() -> bool:
	return not _matches.is_empty()


# Join the lobby. `entry` is the peer's CURRENT server position (they return there afterwards);
# `valid` is the hub's eligibility predicate, re-run over the whole lobby before a launch so a
# peer who wandered into the crypt (or started a duel/trade) after queueing can never be pulled
# into an arena. Returns {error} | {ok} | {ok, started: <match descriptor>} on the launching join.
func queue(peer_id: int, name: String, entry: Vector3, now: int, valid: Callable) -> Dictionary:
	if is_queued(peer_id):
		return {"error": "already_queued"}
	if _match_of.has(peer_id):
		return {"error": "in_match"}
	_queue.append({"peer": peer_id, "name": name, "entry": entry})
	_prune_queue(valid)
	if _queue.size() < PLAYERS_NEEDED:
		return {"ok": true, "queued": _queue.size()}
	return {"ok": true, "started": _launch(now)}


func unqueue(peer_id: int) -> Dictionary:
	for i in _queue.size():
		if int(_queue[i]["peer"]) == peer_id:
			_queue.remove_at(i)
			return {"ok": true}
	return {"error": "not_queued"}


func _prune_queue(valid: Callable) -> void:
	var kept: Array = []
	for e in _queue:
		if bool(valid.call(int(e["peer"]))):
			kept.append(e)
	_queue = kept


# Pop the first PLAYERS_NEEDED lobbyists into a fresh match. Teams split by queue order (the
# MMR-balanced split is the T-392 seam — banked owner row). Returns the launch descriptor the hub
# applies: per-peer instance move + spawn position.
func _launch(now: int) -> Dictionary:
	var mid := _next_mid
	_next_mid += 1
	var iid: int = IID_BASE + mid
	var m := {
		"iid": iid,
		"teams": [[], []],
		"names": {},
		"entry": {},
		"active": {},
		"score": [0, 0],
		"reached": [0, 0],
		"started": now,
		"last_accrue": now,
		"control": -1,
	}
	var moves: Array = []
	for i in PLAYERS_NEEDED:
		var e: Dictionary = _queue.pop_front()
		var peer: int = int(e["peer"])
		var team: int = i / TEAM_SIZE  # [q0,q1] vs [q2,q3]
		(m["teams"][team] as Array).append(peer)
		m["names"][peer] = str(e["name"])
		m["entry"][peer] = e["entry"]
		m["active"][peer] = true
		_match_of[peer] = mid
		# Teammates fan out along y so nobody spawns inside a teammate.
		var spawn: Vector3 = TEAM_SPAWNS[team] + Vector3(0.0, float(i % TEAM_SIZE) * 2.0, 0.0)
		moves.append({"peer": peer, "team": team, "spawn": spawn})
	_matches[mid] = m
	return {"mid": mid, "iid": iid, "moves": moves, "names": m["names"].duplicate()}


# ---- combat hooks ------------------------------------------------------------


# The executor consent predicate arm: TRUE only for two ACTIVE members of the SAME match on
# OPPOSITE teams. Cross-match, same-team, deserted, and stranger pairs all stay FALSE.
func eligible(a_id: int, b_id: int) -> bool:
	var mid: int = int(_match_of.get(a_id, -1))
	if mid == -1 or int(_match_of.get(b_id, -2)) != mid:
		return false
	var m: Dictionary = _matches[mid]
	if not (m["active"].has(a_id) and m["active"].has(b_id)):
		return false
	return _team_of(m, a_id) != _team_of(m, b_id)


# Real deaths apply in the Crownfield (2026-07-16 owner veto of the knockout floor): a player who
# dies mid-match respawns at their TEAM SPAWN inside the arena instance (not the world graveyard),
# so the match stays playable while dying carries the normal death penalty (durability wear) and
# does NOT desert them. The hub calls this from the respawn path; {} for a peer not in a live match
# (they respawn by the ordinary world/instance rule instead).
func respawn_spawn(peer_id: int) -> Dictionary:
	if not in_match(peer_id):
		return {}
	var m: Dictionary = _matches[int(_match_of[peer_id])]
	return {"spawn": TEAM_SPAWNS[_team_of(m, peer_id)]}


# ---- leaving (intent, leash, disconnect) --------------------------------------


# A peer leaves the lobby or deserts a live match. Deserters go INACTIVE and stay on the roster for
# team-liveness bookkeeping only — but they FORFEIT (2026-07-16 owner veto of deserters-as-losers):
# _end pays/records ACTIVE members only, so a deserter never appears in the payout and no loss is
# recorded for them. When a whole team is gone the other team wins by forfeit. Returns {} (nothing
# to do) | {left, entry} | {left, entry, ended}.
func leave(peer_id: int, now: int) -> Dictionary:
	unqueue(peer_id)
	var mid: int = int(_match_of.get(peer_id, -1))
	if mid == -1 or not _matches[mid]["active"].has(peer_id):
		return {}
	var m: Dictionary = _matches[mid]
	m["active"].erase(peer_id)
	var out := {"left": true, "entry": m["entry"][peer_id]}
	var team := _team_of(m, peer_id)
	if _live_count(m, team) == 0:
		out["ended"] = _end(mid, 1 - team, "forfeit", now)
	return out


# ---- the match tick ------------------------------------------------------------
# Called once per server tick by the hub with the live positions snapshot
# (PlayerSessions.get_positions() shape: peer -> {x, y, ...}). Returns relay/end events:
#   {type:"bg_leash", mid, peer, entry}            — a straggler was deserted out (hub returns them)
#   {type:"bg_control", mid, iid, control, score}  — the disc changed hands (relay a line)
#   {type:"bg_end", end:{...}}                     — the match resolved (hub records + returns all)
func tick(positions: Dictionary, now: int) -> Array:
	var events: Array = []
	for mid in _matches.keys():
		var m: Dictionary = _matches[mid]
		_leash_pass(mid, m, positions, now, events)
		if not _matches.has(mid):  # the leash pass may have forfeited the match away
			continue
		_score_pass(m, positions, now, events)
		var end := _end_condition(m, now)
		if end != -2:
			events.append({"type": "bg_end", "end": _end(mid, end, "score_or_horn", now)})
	return events


# Anyone farther than LEASH_RADIUS from center has left the field (walked off the flat, died to
# an edge case and respawned across the map, or was teleported by another system) — desert them.
func _leash_pass(mid: int, m: Dictionary, positions: Dictionary, now: int, events: Array) -> void:
	for peer in m["active"].keys().duplicate():
		var p: Dictionary = positions.get(int(peer), {})
		var pos := Vector2(float(p.get("x", 0.0)), float(p.get("y", 0.0)))
		if p.is_empty() or pos.distance_to(ARENA_CENTER) > LEASH_RADIUS:
			var r := leave(int(peer), now)
			if r.has("left"):
				events.append(
					{"type": "bg_leash", "mid": mid, "peer": int(peer), "entry": r["entry"]}
				)
			if r.has("ended"):
				events.append({"type": "bg_end", "end": r["ended"]})
				return


# Accrue 1 point per full second a team holds the disc EXCLUSIVELY (live members inside
# POINT_RADIUS while the other team has none). Contested or empty accrues nothing.
func _score_pass(m: Dictionary, positions: Dictionary, now: int, events: Array) -> void:
	var seconds: int = (now - int(m["last_accrue"])) / SCORE_TICK_MS
	if seconds <= 0:
		return
	m["last_accrue"] = int(m["last_accrue"]) + seconds * SCORE_TICK_MS
	var on_point := [0, 0]
	for team in 2:
		for peer in m["teams"][team]:
			if not m["active"].has(peer):
				continue
			var p: Dictionary = positions.get(int(peer), {})
			var pos := Vector2(float(p.get("x", 0.0)), float(p.get("y", 0.0)))
			if not p.is_empty() and pos.distance_to(ARENA_CENTER) <= POINT_RADIUS:
				on_point[team] += 1
	var control := -1
	if on_point[0] > 0 and on_point[1] == 0:
		control = 0
	elif on_point[1] > 0 and on_point[0] == 0:
		control = 1
	if control != -1:
		var before := int(m["score"][control])
		m["score"][control] = mini(before + seconds, SCORE_TARGET)
		if int(m["score"][control]) > before:
			m["reached"][control] = now  # last actual GAIN — the tie-break stamp
	if control != int(m["control"]):
		m["control"] = control
		(
			events
			. append(
				{
					"type": "bg_control",
					"mid": _mid_of(m),
					"iid": int(m["iid"]),
					"control": control,
					"score": m["score"].duplicate(),
				}
			)
		)


# -2 = keep playing; else the winning team (0/1), or -1 for a 0-0 void at the horn.
func _end_condition(m: Dictionary, now: int) -> int:
	var s0 := int(m["score"][0])
	var s1 := int(m["score"][1])
	if s0 >= SCORE_TARGET or s1 >= SCORE_TARGET:
		return 0 if s0 > s1 else (1 if s1 > s0 else _tiebreak(m))
	if now - int(m["started"]) < MATCH_MS:
		return -2
	if s0 == s1:
		return -1 if s0 == 0 else _tiebreak(m)
	return 0 if s0 > s1 else 1


# Equal non-zero scores: the team that REACHED the score first (older last-gain stamp) led longer.
func _tiebreak(m: Dictionary) -> int:
	return 0 if int(m["reached"][0]) <= int(m["reached"][1]) else 1


# Resolve + tear down. `winner` -1 == void (0-0 horn: nobody records). Only ACTIVE members ride the
# payout rosters — deserters FORFEIT (2026-07-16 owner veto: no payout, no loss recorded), so they
# never appear in `winners`/`losers`; `returns` carries the same still-active members the hub moves
# home. Erasing the match FIRST makes a double payout impossible: any later leave/tick/death-respawn
# for these peers finds no match.
func _end(mid: int, winner: int, reason: String, _now: int) -> Dictionary:
	var m: Dictionary = _matches[mid]
	_matches.erase(mid)
	var rosters: Array = [[], []]
	var returns: Array = []
	for team in 2:
		for peer in m["teams"][team]:
			if m["active"].has(peer):
				(rosters[team] as Array).append({"peer": int(peer), "name": str(m["names"][peer])})
				returns.append({"peer": int(peer), "entry": m["entry"][peer]})
			_match_of.erase(int(peer))
	return {
		"ended": true,
		"reason": reason,
		"winner": winner,
		"iid": int(m["iid"]),
		"score": m["score"].duplicate(),
		"winners": rosters[winner] if winner != -1 else [],
		"losers": rosters[1 - winner] if winner != -1 else [],
		"returns": returns,
	}


# ---- helpers -------------------------------------------------------------------


func _team_of(m: Dictionary, peer_id: int) -> int:
	return 0 if (m["teams"][0] as Array).has(peer_id) else 1


func _live_count(m: Dictionary, team: int) -> int:
	var n := 0
	for peer in m["teams"][team]:
		if m["active"].has(peer):
			n += 1
	return n


func _mid_of(m: Dictionary) -> int:
	return int(m["iid"]) - IID_BASE
