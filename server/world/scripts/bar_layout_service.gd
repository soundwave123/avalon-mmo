extends RefCounted

# T-422c: the world's action-bar layout intent seam. Owns two per-peer facts: the saved slot order
# (seeded from the master combat payload at spawn, read back by main to ship the class kit already
# ordered) and the character's KNOWN kit ids (fed by main every time it builds the kit — spawn +
# after training). Handles the `set_bar_layout` intent: it validates the client's desired order is a
# permutation of the KNOWN ids server-side (BarLayoutOps.sanitize — fail-closed on any unknown /
# duplicate / unowned id; the client can't place an unlearned ability), persists the validated order
# via master, and replies. Server-authority: the client sends only its DESIRED ordering; the world
# decides what is legal and what gets stored. Routed through main's per-peer intent limiter.

const _BLO = preload("res://scripts/bar_layout_ops.gd")
const PlayerSessions = preload("res://scripts/player_sessions.gd")

var _master = null  # MasterClient (call_master)
var _reply: Callable  # main._send_to_peer(peer_id, dict)
var _layout: Dictionary = {}  # peer_id -> Array[int] saved slot order (seeded at spawn)
var _known: Dictionary = {}  # peer_id -> Array[int] the character's known kit ids (fed by main)


func setup(master, reply: Callable) -> void:
	_master = master
	_reply = reply


func handles(msg_type: String) -> bool:
	return msg_type == "set_bar_layout"


# main feeds the current known kit ids whenever it builds the kit (spawn + after a trainer unlock),
# so validation never re-derives the registry here and can't drift from what the client was shown.
func set_known(peer_id: int, known_ids: Array) -> void:
	_known[peer_id] = known_ids


# Seed the saved layout from the master combat payload at spawn ([] = default order). Stored raw for
# ordering — order_kit tolerates ids no longer known (a since-forgotten ability just drops out).
func seed(peer_id: int, layout: Array) -> void:
	_layout[peer_id] = layout


# The saved order for a peer, so main ships the class kit already ordered (BarLayoutOps.order_kit).
# No forget() on disconnect is needed: ENet may reuse a peer_id, but the next handshake re-seeds
# both caches (seed + set_known) BEFORE any set_bar_layout can arrive, so no stale entry leaks.
func bar_layout_for(peer_id: int) -> Array:
	return _layout.get(peer_id, [])


# Handle set_bar_layout: validate the desired order against the KNOWN kit, persist, reply.
func handle(_msg_type: String, peer_id: int, data: Dictionary) -> void:
	var player: Dictionary = PlayerSessions.get_player(peer_id)
	if player.is_empty():
		return
	var clean: Array = _BLO.sanitize(data.get("layout", []), _known.get(peer_id, []))
	if clean.is_empty():
		_reply.call(peer_id, {"type": "bar_layout_result", "ok": false, "reason": "invalid_layout"})
		return
	_layout[peer_id] = clean
	if _master != null:
		await _master.call_master(
			"save_bar_layout", {"username": str(player.get("username", "")), "layout": clean}
		)
	_reply.call(peer_id, {"type": "bar_layout_result", "ok": true, "layout": clean})
