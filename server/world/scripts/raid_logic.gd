# T-472: raid container ops (T-433 build wave 1, owner-decided 10-man first tier).
#
# DESIGN DECISION (recorded in the ticket): a raid is a PROMOTION of an existing T-280 party —
# the same store record and party_id, stamped with `cap` (MAX_RAID), `subgroup` (peer -> group
# index) and `assists` (peer list). It is NOT a parallel container of party objects, so every
# party-scoped consumer composes with zero changes: kill-credit (T-293) walks `members` and
# dedupes, the broadcast party_id and the T-331 instance key stay one id for the whole raid,
# and the T-452 mentorship ceiling conservatively scopes to the WHOLE raid (cap-only — a
# subgroup shuffle can never raise a synced mentor's reward level).
#
# Pure-module discipline (party_logic.gd exemplar): every function operates on the passed
# store, no scene tree, no OS time, no globals; the Era-2 widening to 20 is MAX_RAID 10 -> 20
# (subgroup count derives as cap / MAX_PARTY).
extends RefCounted

const _PL = preload("res://scripts/party_logic.gd")

const MAX_RAID := 10  # Era 1 (T-433 owner ruling); Era 2 raises this to 20
const SUBGROUPS := MAX_RAID / _PL.MAX_PARTY  # party-shaped subgroups (2 now, 4 in Era 2)


# Leader promotes their party into a raid: existing members all seat in subgroup 0 (a party is
# <= MAX_PARTY so they fit), assists start empty, and the loot-rule seam is reserved for T-473
# (the value is a placeholder this wave — no loot distribution logic reads it yet).
static func convert(store: Dictionary, leader: int) -> Dictionary:
	var pid: int = int(store["party_of"].get(leader, -1))
	if pid == -1:
		return {"ok": false, "reason": "not_in_party"}
	var party: Dictionary = store["parties"][pid]
	if int(party["leader"]) != leader:
		return {"ok": false, "reason": "not_leader"}
	if party.has("subgroup"):
		return {"ok": false, "reason": "already_raid"}
	party["cap"] = MAX_RAID
	party["assists"] = []
	party["loot_rule"] = "round_robin"  # T-473 seam: master/round-robin attaches here
	var subgroup := {}
	for m in party["members"]:
		subgroup[int(m)] = 0
	party["subgroup"] = subgroup
	return {"ok": true, "reason": "", "party_id": pid}


static func is_raid(store: Dictionary, peer: int) -> bool:
	var pid: int = int(store["party_of"].get(peer, -1))
	return store["parties"].get(pid, {}).has("subgroup")


# Leader or assist seats `target` in subgroup `group` (0-based). Server-authoritative: the
# actor's authority, the target's membership, the group index range, and the MAX_PARTY seat
# count are all validated here — a client cannot move itself or overfill a subgroup.
static func set_subgroup(store: Dictionary, actor: int, target: int, group: int) -> Dictionary:
	var check := _raid_authority(store, actor, target)
	if not check["ok"]:
		return check
	var party: Dictionary = check["party"]
	if group < 0 or group >= SUBGROUPS:
		return {"ok": false, "reason": "bad_group"}
	if int(party["subgroup"].get(target, -1)) == group:
		return {"ok": true, "reason": ""}
	var seated := 0
	for m in party["subgroup"]:
		if int(party["subgroup"][m]) == group:
			seated += 1
	if seated >= _PL.MAX_PARTY:
		return {"ok": false, "reason": "group_full"}
	party["subgroup"][target] = group
	return {"ok": true, "reason": ""}


# Leader grants/revokes the assist role (may invite, move subgroups, kick non-officers).
# The leader cannot be an assist; only the leader manages the assist list.
static func set_assist(store: Dictionary, leader: int, target: int, enabled: bool) -> Dictionary:
	var check := _raid_authority(store, leader, target)
	if not check["ok"]:
		return check
	var party: Dictionary = check["party"]
	if int(party["leader"]) != leader:
		return {"ok": false, "reason": "not_leader"}
	if target == leader:
		return {"ok": false, "reason": "leader_is_not_assist"}
	var assists: Array = party["assists"]
	if enabled and not assists.has(target):
		assists.append(target)
	elif not enabled:
		assists.erase(target)
	return {"ok": true, "reason": ""}


# Kick semantics mirror party leave exactly (same removal path — subgroup/assist hygiene,
# auto-disband at one member): leader kicks anyone but self; an assist kicks only rank-and-file
# (never the leader, never another assist). Works on a plain party too (leader-only there).
static func kick(store: Dictionary, actor: int, target: int) -> Dictionary:
	if actor == target:
		return {"ok": false, "reason": "cannot_kick_self"}
	var pid: int = int(store["party_of"].get(actor, -1))
	if pid == -1 or int(store["party_of"].get(target, -2)) != pid:
		return {"ok": false, "reason": "not_in_group"}
	var party: Dictionary = store["parties"][pid]
	var actor_is_leader := int(party["leader"]) == actor
	var actor_is_assist: bool = party.get("assists", []).has(actor)
	if not actor_is_leader and not actor_is_assist:
		return {"ok": false, "reason": "not_leader"}
	if not actor_is_leader:
		if int(party["leader"]) == target or party.get("assists", []).has(target):
			return {"ok": false, "reason": "cannot_kick_officer"}
	return _PL.leave(store, target)


# Shared guard: actor and target are in the SAME raid, and actor is leader or assist.
# Returns {ok, reason} plus the live party record on success.
static func _raid_authority(store: Dictionary, actor: int, target: int) -> Dictionary:
	var pid: int = int(store["party_of"].get(actor, -1))
	if pid == -1:
		return {"ok": false, "reason": "not_in_party"}
	var party: Dictionary = store["parties"][pid]
	if not party.has("subgroup"):
		return {"ok": false, "reason": "not_a_raid"}
	if int(party["leader"]) != actor and not party.get("assists", []).has(actor):
		return {"ok": false, "reason": "not_leader"}
	if int(store["party_of"].get(target, -2)) != pid:
		return {"ok": false, "reason": "target_not_in_raid"}
	return {"ok": true, "reason": "", "party": party}
