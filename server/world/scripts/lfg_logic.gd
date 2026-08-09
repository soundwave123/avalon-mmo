# T-334: LFG-lite board ops (pure — operate on a passed store dict so they unit-test with no
# scene tree; the party_logic.gd precedent). A SIGNALS BOARD, not a matchmaker: players flag
# "looking for the Hollowed Crypt", the board lists {peer, level, role}, and a party leader
# invites off it via the normal T-280 party_invite intent. Server-authoritative: role is derived
# HERE from the session's true class (never trusted from the wire); the list clears a player on
# party-join and on disconnect. No auto-grouping, no cross-server — honest to the single world.
extends RefCounted

# The trinity read of the three shipped classes (m6-direction: tank/heal/dps role legibility).
const CLASS_ROLES := {"warrior": "tank", "priest": "heal", "mage": "dps"}


# A fresh store. entries: peer_id -> {level:int, role:String}.
static func new_store() -> Dictionary:
	return {"entries": {}}


# The server-authoritative role for a class ("dps" for anything unknown — a safe floor).
static func role_for_class(char_class: String) -> String:
	return str(CLASS_ROLES.get(char_class, "dps"))


# Flag a peer as looking-for-group. Idempotent (re-flagging refreshes level/role). `role` must
# come from role_for_class(session class) — callers never pass client-supplied roles.
static func flag(store: Dictionary, peer: int, level: int, role: String) -> void:
	store["entries"][peer] = {"level": level, "role": role}


# Remove a peer from the board (unflag intent, party-join, or disconnect). Idempotent.
static func unflag(store: Dictionary, peer: int) -> void:
	store["entries"].erase(peer)


static func is_flagged(store: Dictionary, peer: int) -> bool:
	return store["entries"].has(peer)


# Drop every flagged peer who has since joined a party (party_of: peer -> party_id, the T-280
# membership truth, held by reference). Called before every board read/mutation so "the list
# clears on group-up" holds WITHOUT a hook inside the party path — world_rpc.gd sits at the
# 1000-line cap, so the clear is enforced at the LFG seam, not the party seam. Returns the
# pruned peer ids (empty when nothing changed).
static func prune_partied(store: Dictionary, party_of: Dictionary) -> Array:
	var dropped: Array = []
	for p in store["entries"]:
		if party_of.has(p):
			dropped.append(p)
	for p in dropped:
		store["entries"].erase(p)
	return dropped


# The board as the client renders it: [{peer:int, level:int, role:String}], sorted by peer_id
# (signup order under monotonic ENet ids) so two clients always see the same stable list.
static func board(store: Dictionary) -> Array:
	var peers: Array = store["entries"].keys()
	peers.sort()
	var out: Array = []
	for p in peers:
		var e: Dictionary = store["entries"][p]
		out.append({"peer": int(p), "level": int(e["level"]), "role": str(e["role"])})
	return out


static func count(store: Dictionary) -> int:
	return store["entries"].size()
