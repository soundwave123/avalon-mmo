# T-073/T-649 (portal #89): kill-loot delivery. Try the top-threat killer first, then other
# in-range party members' bag space; if NOBODY has room, HOLD the drop for retry instead of
# destroying it — the fail-closed idiom T-609/T-567 already established elsewhere (never let a
# grant failure silently eat a player's property). Carved out of world_rpc.gd (at the gdlint file
# cap) as its own service, the same way _craft/_ach/_flight/_daily/_wardrobe already are.
extends RefCounted

const PlayerSessions = preload("res://scripts/player_sessions.gd")

var _master = null  # MasterClient (call_master)
var _reply: Callable = Callable()  # world_rpc._reply -> main._send_to_peer(peer_id, dict)
var _funnel = null  # T-705: funnel_events.gd (null until main injects telemetry — then a no-op)


func setup(master, reply: Callable) -> void:
	_master = master
	_reply = reply


# T-705: `first_loot` is the beat, and a held drop is the failure reason — both are only knowable
# HERE, after the master says who (if anyone) actually had room for the item.
func set_funnel(funnel) -> void:
	_funnel = funnel


# `fallback_peers` are OTHER party members of the killer (mentorship_service.party_peers_of) —
# candidates get one shared master round-trip that tries each in order, killer first.
func deliver(
	killer_peer_id: int,
	fallback_peers: Array,
	items: Array,
	item_registry: Dictionary,
	quest_defs: Dictionary,
	push_quest_delta: Callable
) -> void:
	if _master == null or items.is_empty():
		return
	var candidates := _candidates(killer_peer_id, fallback_peers)
	if candidates.is_empty():
		return
	var usernames: Array = []
	for c: Dictionary in candidates:
		usernames.append(c["username"])
	var r: Dictionary = await (
		_master
		. call_master(
			"grant_loot",
			{
				"usernames": usernames,
				"items": items,
				"item_registry": item_registry,
				"quest_defs": quest_defs,
			}
		)
	)
	if bool(r.get("ok", false)):
		var granted_to := str(r.get("granted_to", ""))
		print("[world] loot_granted %s %s" % [granted_to, str(items)])
		var granted_peer := _peer_for(candidates, granted_to)
		if granted_peer != -1 and _funnel != null:
			_funnel.loot(granted_peer, items)  # T-705: the first-loot beat, for whoever received it
		if granted_peer != -1 and push_quest_delta.is_valid():
			for credited_id in r.get("credited", []):  # T-058: loot collect-credit -> delta
				push_quest_delta.call(granted_peer, granted_to, str(credited_id))
	else:
		print("[world] loot_grant FAILED %s %s (%s)" % [str(usernames), str(items), str(r)])
		if _funnel != null:  # T-705: "your bags are full" is a quit-risk moment, not just a notice
			_funnel.rejected(killer_peer_id, "loot", str(r.get("reason", "bag_full")))
		_notify_held(killer_peer_id, items)


# De-duped [{peer_id, username}], killer first, dropping anyone with no live session/username.
func _candidates(killer_peer_id: int, fallback_peers: Array) -> Array:
	var seen := {}
	var out: Array = []
	for pid in [killer_peer_id] + fallback_peers:
		var uname: String = str(PlayerSessions.get_player(int(pid)).get("username", ""))
		if uname == "" or seen.has(uname):
			continue
		seen[uname] = true
		out.append({"peer_id": int(pid), "username": uname})
	return out


func _peer_for(candidates: Array, username: String) -> int:
	for c: Dictionary in candidates:
		if str(c["username"]) == username:
			return int(c["peer_id"])
	return -1


# T-575 idiom: a held drop must be VISIBLE, not silent — "bags full, lost" is explicitly not
# acceptable (T-643/portal #89's own wording); the item is held server-side for retry, never gone.
func _notify_held(peer_id: int, items: Array) -> void:
	if not _reply.is_valid():
		return
	var wire_items: Array = []
	for it: Dictionary in items:
		(
			wire_items
			. append(
				{
					"item_id": str(it.get("item_id", it.get("item", ""))),
					"count": int(it.get("count", 1)),
				}
			)
		)
	_reply.call(peer_id, {"type": "loot_notice", "reason": "bag_full_held", "items": wire_items})
