# T-280: server-authoritative party roster ops (pure — operate on a passed store dict so
# they unit-test with no scene tree). WoW party rules: 2-5 members, one leader, invite ->
# accept flow, leave/disband, auto-disband when only one member remains. main.gd owns the
# live store and broadcasts party_id per player; world_rpc routes the intents here.
# T-472: a RAID is a promoted party in the SAME record (raid_logic.convert stamps `cap`,
# `subgroup`, `assists`), so this module only reads those keys generically — the cap comes
# from the record (default MAX_PARTY) and subgroup auto-fill packs groups of MAX_PARTY.
extends RefCounted

const MAX_PARTY := 5
# T-736: invites expire and repeated declines back off (owner-directed anti-grief). All lazy —
# `now_ms` is the CALLER's millisecond clock (duel_service idiom), so no timers and the module
# stays pure/fake-clock testable. State is in-memory world state: a restart clears pendings AND
# decline ledgers (accepted for v1 — a cooldown is grief-throttling, not a ban).
const INVITE_TTL_MS := 45000  # an unanswered invite lapses; lapse is NOT a decline
const DECLINE_LIMIT := 3  # declines from one inviter to one target before the cooldown arms
const DECLINE_COOLDOWN_MS := 300000  # 5 min lockout; lapsing grants a fresh decline budget


# A fresh store. party_id -> {leader:int, members:[int]}; party_of peer->party_id;
# pending invitee_peer -> {party_id:int, from:int, expires:int, key:String}; next_id monotonic.
# declines "inviterName>inviteeName" -> {count:int, until:int} — USERNAME-keyed on purpose:
# peer ids are session-scoped, so a peer-keyed cooldown would evaporate on a relog (T-736).
static func new_store() -> Dictionary:
	return {"parties": {}, "party_of": {}, "pending": {}, "next_id": 1, "declines": {}}


# inviter invites invitee (both peer_ids). Creates a party led by inviter if they have
# none. Returns {ok, reason}. Sets a pending invite the invitee must accept.
# T-736: pair_key is the caller-resolved "inviterName>inviteeName" decline-ledger key.
static func invite(
	store: Dictionary, inviter: int, invitee: int, now_ms := 0, pair_key := ""
) -> Dictionary:
	if inviter == invitee:
		return {"ok": false, "reason": "cannot_invite_self"}
	if store["party_of"].has(invitee):
		return {"ok": false, "reason": "target_in_party"}
	var stale: Dictionary = store["pending"].get(invitee, {})
	if not stale.is_empty() and now_ms > int(stale.get("expires", now_ms)):
		store["pending"].erase(invitee)  # lapsed unanswered — slot freed, no decline counted
	if store["pending"].has(invitee):
		# One live invite per invitee: the modal can never stack, and a second suitor is
		# refused instead of silently replacing the first (anti-spam, T-736).
		return {"ok": false, "reason": "invite_pending"}
	var ledger: Dictionary = store.get("declines", {})
	var cd: Dictionary = ledger.get(pair_key, {})
	if int(cd.get("count", 0)) >= DECLINE_LIMIT:
		if now_ms < int(cd.get("until", 0)):
			# Server-enforced and silent for the DECLINER (nothing is ever pushed to them);
			# only the inviter learns via this refusal reason.
			return {"ok": false, "reason": "invite_cooldown"}
		ledger.erase(pair_key)  # cooldown lapsed — fresh budget
	var pid: int = store["party_of"].get(inviter, -1)
	if pid != -1:
		var party: Dictionary = store["parties"][pid]
		# T-472: a raid assist may invite too; a plain party stays leader-only.
		if int(party["leader"]) != inviter and not party.get("assists", []).has(inviter):
			return {"ok": false, "reason": "not_leader"}
		if party["members"].size() >= int(party.get("cap", MAX_PARTY)):
			return {"ok": false, "reason": "party_full"}
	store["pending"][invitee] = {
		"party_id": pid, "from": inviter, "expires": now_ms + INVITE_TTL_MS, "key": pair_key
	}
	return {"ok": true, "reason": ""}


# invitee accepts their pending invite. Lazily creates the party (with the inviter as
# leader) on the first accept so a declined invite leaves no empty party behind.
static func accept(store: Dictionary, invitee: int, now_ms := 0) -> Dictionary:
	var inv: Dictionary = store["pending"].get(invitee, {})
	if inv.is_empty():
		return {"ok": false, "reason": "no_invite"}
	if now_ms > int(inv.get("expires", now_ms)):  # T-736: lapsed — the offer is gone
		store["pending"].erase(invitee)
		return {"ok": false, "reason": "invite_expired"}
	store["pending"].erase(invitee)
	if store["party_of"].has(invitee):
		return {"ok": false, "reason": "already_in_party"}
	var pid: int = int(inv["party_id"])
	var inviter: int = int(inv["from"])
	if pid == -1:  # inviter had no party yet — create one led by them
		pid = int(store["next_id"])
		store["next_id"] = pid + 1
		store["parties"][pid] = {"leader": inviter, "members": [inviter]}
		store["party_of"][inviter] = pid
	var party: Dictionary = store["parties"].get(pid, {})
	if party.is_empty():
		return {"ok": false, "reason": "party_gone"}
	if party["members"].size() >= int(party.get("cap", MAX_PARTY)):
		return {"ok": false, "reason": "party_full"}
	party["members"].append(invitee)
	store["party_of"][invitee] = pid
	if party.has("subgroup"):  # T-472: raid — auto-seat the joiner in the first open subgroup
		party["subgroup"][invitee] = _auto_subgroup(party)
	return {"ok": true, "reason": "", "party_id": pid}


# T-472: first subgroup with a free seat (groups are cap/MAX_PARTY packs of MAX_PARTY).
# Explicit raid_set_group moves can leave earlier groups open; auto-fill re-uses those seats.
static func _auto_subgroup(party: Dictionary) -> int:
	var group_count: int = maxi(1, int(party.get("cap", MAX_PARTY)) / MAX_PARTY)
	for g in group_count:
		var seated := 0
		for m in party["subgroup"]:
			if int(party["subgroup"][m]) == g:
				seated += 1
		if seated < MAX_PARTY:
			return g
	return group_count - 1


# T-736 anti-grief: only a LIVE invite that is EXPLICITLY declined feeds the per-pair counter —
# a lapsed offer or a stray /party decline with nothing pending bumps nothing. The counter is
# read (and pruned) by invite() above; DECLINE_LIMIT arms the cooldown.
static func decline(store: Dictionary, invitee: int, now_ms := 0) -> Dictionary:
	var inv: Dictionary = store["pending"].get(invitee, {})
	store["pending"].erase(invitee)
	var key := str(inv.get("key", ""))
	if inv.is_empty() or key == "" or now_ms > int(inv.get("expires", now_ms)):
		return {"ok": true, "reason": ""}
	var cd: Dictionary = store.get("declines", {}).get(key, {"count": 0, "until": 0})
	cd["count"] = int(cd["count"]) + 1
	if int(cd["count"]) >= DECLINE_LIMIT:
		cd["until"] = now_ms + DECLINE_COOLDOWN_MS
	store["declines"][key] = cd
	return {"ok": true, "reason": ""}


# peer leaves their party. Leader leaving promotes the next member; a party that drops to
# a single member auto-disbands (WoW: a "party of one" isn't a party).
static func leave(store: Dictionary, peer: int) -> Dictionary:
	var pid: int = store["party_of"].get(peer, -1)
	if pid == -1:
		return {"ok": false, "reason": "not_in_party"}
	var party: Dictionary = store["parties"][pid]
	party["members"].erase(peer)
	store["party_of"].erase(peer)
	if party.has("subgroup"):  # T-472: raid map hygiene rides every removal path
		party["subgroup"].erase(peer)
		party.get("assists", []).erase(peer)
	if int(party["leader"]) == peer and not party["members"].is_empty():
		party["leader"] = int(party["members"][0])
	if party["members"].size() <= 1:
		return _disband_pid(store, pid)
	return {"ok": true, "reason": ""}


static func disband(store: Dictionary, leader: int) -> Dictionary:
	var pid: int = store["party_of"].get(leader, -1)
	if pid == -1:
		return {"ok": false, "reason": "not_in_party"}
	if int(store["parties"][pid]["leader"]) != leader:
		return {"ok": false, "reason": "not_leader"}
	return _disband_pid(store, pid)


static func _disband_pid(store: Dictionary, pid: int) -> Dictionary:
	var party: Dictionary = store["parties"].get(pid, {})
	for m in party.get("members", []):
		store["party_of"].erase(int(m))
	store["parties"].erase(pid)
	return {"ok": true, "reason": "", "disbanded": pid}


# {peer_id -> party_id} for the broadcast builder (only real 2+ parties appear).
static func party_of_map(store: Dictionary) -> Dictionary:
	return store["party_of"].duplicate()


# T-293: who gets kill credit for a mob death, extended to party scope. The `attackers`
# (threat holders — T-042) are ALWAYS credited. On top of that, each attacker's party-mates
# are credited too, but only if ALIVE and within `radius` of the mob — so a group sharing an
# elite kill all get the bounty, while a dead or far-off member doesn't leech. Credit is
# participation-based, NOT first-tap: two parties that both engage one elite both earn it
# (mirrors the threat-table rule). Pure — caller passes snapshots (positions: peer->Vector3,
# alive: [peer_id]); returns a deduped peer list.
static func credit_recipients(
	store: Dictionary,
	attackers: Array,
	positions: Dictionary,
	alive: Array,
	mob_pos: Vector3,
	radius: float
) -> Array:
	var out: Dictionary = {}
	for a in attackers:
		out[int(a)] = true
	for a in attackers:
		var pid: int = int(store["party_of"].get(int(a), -1))
		if pid == -1:
			continue
		var party: Dictionary = store["parties"].get(pid, {})
		for m in party.get("members", []):
			var mid: int = int(m)
			if out.has(mid) or not alive.has(mid) or not positions.has(mid):
				continue
			var mp: Vector3 = positions[mid]
			# Distance on the ground plane (x,y); z is height and irrelevant to credit range.
			if Vector2(mp.x, mp.y).distance_to(Vector2(mob_pos.x, mob_pos.y)) <= radius:
				out[mid] = true
	return out.keys()
