# T-381: consensual-duel rules + the session-scoped pair store. PURE (RefCounted, no OS clock, no
# PlayerSessions) — the social hub owns an instance and threads identity/positions/time in, like
# ChatService. This is the ONLY source of PvP eligibility for the demo: `eligible(a, b)` is TRUE
# only while a and b are in an ACTIVE duel with each other; the executor's consent gate reads it.
#
# Lifecycle (WoW shape, minimal): request -> the target holds a pending offer (TTL) -> accept flags
# both in-duel around an anchor -> the duel ends the instant a combatant reaches the HP FLOOR (10%
# max, NOT death — no death penalty fires), or on a leash break (>40u from the anchor), or on either
# party's disconnect. The winner/loser are resolved HERE from the pair, never from the wire.
#
# Time is the caller's millisecond clock (social hub) and is used ONLY for the request TTL; the
# HP-floor end needs no clock. Nothing here persists — a logout wipes the pair (session-scoped).

extends RefCounted

const REQUEST_TTL_MS := 30000  # a pending challenge auto-expires after 30s (checked on accept)
const HP_FLOOR_PCT := 0.10  # a duel ends when a combatant drops to/below 10% of max HP
const LEASH_UNITS := 40.0  # a duelist more than 40 units from the anchor forfeits (leash break)

# target_peer_id -> {challenger_id, challenger_name, target_name, expires}
var _pending: Dictionary = {}
# peer_id -> {opponent_id, opponent_name, self_name, anchor: Vector2, started}
var _duels: Dictionary = {}

# ---- challenge lifecycle ----------------------------------------------------


# A challenges B. Fail-closed on self-target or either party already dueling. Records a pending
# offer keyed by the TARGET (a peer holds one inbound offer at a time; a re-challenge replaces it).
func request(
	challenger_id: int, challenger_name: String, target_id: int, target_name: String, now: int
) -> Dictionary:
	if challenger_id == target_id:
		return {"error": "bad_target"}
	if is_dueling(challenger_id) or is_dueling(target_id):
		return {"error": "already_dueling"}
	_pending[target_id] = {
		"challenger_id": challenger_id,
		"challenger_name": challenger_name,
		"target_name": target_name,
		"expires": now + REQUEST_TTL_MS,
	}
	return {
		"ok": true,
		"challenger_id": challenger_id,
		"challenger_name": challenger_name,
		"target_id": target_id,
		"target_name": target_name,
	}


# The challenged peer accepts. FORGED-ACCEPT DEFENSE: an accept for a target with no live pending
# offer is rejected ("no_request") — a client cannot flag itself into a duel that was never offered.
# On success both sides are flagged in-duel around `anchor` (the caller's midpoint of the two).
func accept(target_id: int, anchor: Vector2, now: int) -> Dictionary:
	var p: Dictionary = _pending.get(target_id, {})
	if p.is_empty():
		return {"error": "no_request"}
	if now > int(p["expires"]):
		_pending.erase(target_id)
		return {"error": "expired"}
	var challenger_id := int(p["challenger_id"])
	if is_dueling(challenger_id) or is_dueling(target_id):
		_pending.erase(target_id)
		return {"error": "already_dueling"}
	var challenger_name := str(p["challenger_name"])
	var target_name := str(p["target_name"])
	_pending.erase(target_id)
	_duels[challenger_id] = {
		"opponent_id": target_id,
		"opponent_name": target_name,
		"self_name": challenger_name,
		"anchor": anchor,
		"started": now,
	}
	_duels[target_id] = {
		"opponent_id": challenger_id,
		"opponent_name": challenger_name,
		"self_name": target_name,
		"anchor": anchor,
		"started": now,
	}
	return {
		"ok": true,
		"a_id": challenger_id,
		"a_name": challenger_name,
		"b_id": target_id,
		"b_name": target_name,
	}


# The challenged peer declines; the pending offer is dropped. Returns the challenger to notify.
func decline(target_id: int) -> Dictionary:
	var p: Dictionary = _pending.get(target_id, {})
	if p.is_empty():
		return {"error": "no_request"}
	_pending.erase(target_id)
	return {"ok": true, "challenger_id": int(p["challenger_id"])}


# The challenger cancels their own outstanding offer (pending is keyed by target, so scan for it).
func cancel(challenger_id: int) -> Dictionary:
	for tid in _pending.keys():
		if int(_pending[tid]["challenger_id"]) == challenger_id:
			_pending.erase(tid)
			return {"ok": true, "target_id": int(tid)}
	return {"error": "no_request"}


# ---- active-duel queries + end conditions -----------------------------------


func is_dueling(peer_id: int) -> bool:
	return _duels.has(peer_id)


func opponent_of(peer_id: int) -> int:
	return int(_duels.get(peer_id, {}).get("opponent_id", -1))


# The executor consent predicate: TRUE only when a and b are in an active duel WITH EACH OTHER.
func eligible(a_id: int, b_id: int) -> bool:
	return int(_duels.get(a_id, {}).get("opponent_id", -1)) == b_id and b_id != a_id


# A dueling player just took damage to `hp`/`max_hp`. If that reaches the HP floor the duel ENDS:
# the opponent wins, the loser is NOT killed (caller restores `floor_hp`), so no death penalty
# fires. Returns {} while the duel continues (or the target isn't dueling) — the caller then runs
# the normal death check. `floor_hp` is the minimum survivable HP the caller clamps the loser to.
func on_hit(target_id: int, hp: int, max_hp: int) -> Dictionary:
	if not is_dueling(target_id):
		return {}
	var floor_hp := int(ceil(float(max_hp) * HP_FLOOR_PCT))
	if hp > floor_hp:
		return {}
	return _end(target_id, opponent_of(target_id), floor_hp, "hp_floor")


# Leash break: a duelist beyond LEASH_UNITS of the anchor forfeits (the opponent wins). Pure — the
# caller supplies the peer's planar position. {} when in-range or not dueling.
func check_leash(peer_id: int, pos: Vector2) -> Dictionary:
	if not is_dueling(peer_id):
		return {}
	var anchor: Vector2 = _duels[peer_id]["anchor"]
	if pos.distance_to(anchor) <= LEASH_UNITS:
		return {}
	return _end(peer_id, opponent_of(peer_id), 0, "leash")


# Session-scoped cleanup on disconnect (the T-015 orphan lesson): a dueling peer forfeits to its
# opponent; a pending offer to/from the peer is dropped. Returns an end descriptor if a duel ended.
func on_disconnect(peer_id: int) -> Dictionary:
	_pending.erase(peer_id)  # drop an inbound offer to the leaver
	for tid in _pending.keys():  # drop an outbound offer from the leaver
		if int(_pending[tid]["challenger_id"]) == peer_id:
			_pending.erase(tid)
	if not is_dueling(peer_id):
		return {}
	return _end(peer_id, opponent_of(peer_id), 0, "disconnect")


# Resolve + tear down a finished duel. Erases both entries and returns the SERVER-resolved winner/
# loser (names captured from the store, never the wire) for the caller's record_match + relay.
func _end(loser_id: int, winner_id: int, floor_hp: int, reason: String) -> Dictionary:
	var loser_name := str(_duels.get(loser_id, {}).get("self_name", ""))
	var winner_name := str(_duels.get(winner_id, {}).get("self_name", ""))
	_duels.erase(loser_id)
	_duels.erase(winner_id)
	return {
		"ended": true,
		"reason": reason,
		"winner_id": winner_id,
		"winner_name": winner_name,
		"loser_id": loser_id,
		"loser_name": loser_name,
		"floor_hp": floor_hp,
	}
