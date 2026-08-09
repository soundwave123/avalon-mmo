# T-334 board, T-719 carve: the LFG-lite intents, lifted out of instance_service.gd so that file had
# room under the gdlint 1000-line cap for the Shallow Graves routing. Nothing here is instance-
# shaped — it is a roster of players who want a group — so it was always the most separable half of
# that module; instance_service keeps a public `lfg` handle and routes the three intents into it.
# Behaviour is byte-identical to the pre-carve methods.
#
# lfg_flag {level}  -> join the board (role derived server-side from the session class — the wire
#                      is never trusted; level is an honest display HINT, documented as such).
# lfg_unflag        -> leave the board.
# lfg_list          -> read the board (any player; a leader invites via the normal party_invite).
# Every op first prunes players who joined a party since (clear-on-group-up), then acks the actor
# with the live board so the client renders exactly what the server holds.
extends RefCounted

const _LFG = preload("res://scripts/lfg_logic.gd")
const _PS = preload("res://scripts/player_sessions.gd")

var _store: Dictionary = _LFG.new_store()
var _party_of: Dictionary = {}  # main._party_store["party_of"] (by ref) — the clear-on-group truth
var _char_class: Dictionary = {}  # main._char_class (by ref) — the server-true role source
var _reply: Callable = Callable()  # main._send_to_peer(peer_id, dict)


func setup(party_of: Dictionary, char_class: Dictionary, reply: Callable) -> void:
	_party_of = party_of
	_char_class = char_class
	_reply = reply


func handle(msg_type: String, peer_id: int, data: Dictionary) -> void:
	_LFG.prune_partied(_store, _party_of)
	var ok := true
	var reason := ""
	match msg_type:
		"lfg_flag":
			if _party_of.has(peer_id):
				ok = false
				reason = "in_party"
			else:
				var role: String = _LFG.role_for_class(str(_char_class.get(peer_id, "")))
				_LFG.flag(_store, peer_id, int(data.get("level", 1)), role)
		"lfg_unflag":
			_LFG.unflag(_store, peer_id)
	if _reply.is_valid():
		_reply.call(
			peer_id,
			{"type": "lfg_board", "intent": msg_type, "ok": ok, "reason": reason, "board": board()}
		)


# T-334's clear-on-disconnect rule.
func on_peer_gone(peer_id: int) -> void:
	_LFG.unflag(_store, peer_id)


# The board enriched with usernames (peer ids are meaningless to players; party_invite takes a
# username). A row whose session vanished without a disconnect event still lists — harmless, it
# prunes on the peer's own next op or disconnect.
func board() -> Array:
	var out: Array = []
	for row in _LFG.board(_store):
		var enriched: Dictionary = row.duplicate()
		enriched["name"] = str(_PS.get_player(int(row["peer"])).get("username", ""))
		out.append(enriched)
	return out
