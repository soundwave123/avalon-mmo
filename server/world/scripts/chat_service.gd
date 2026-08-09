# T-361: the server-authoritative chat coordinator. Validates every inbound "chat" intent, then
# fans it out to the right recipients. It is the ONLY place a player message becomes visible to
# others, so three invariants live here:
#   1. Sender identity comes from the SESSION (PlayerSessions), NEVER from the wire — a client
#      cannot spoof `from`.
#   2. Rate-limited per peer (anti-spam), length-capped, and profanity-masked before relay.
#   3. Routed per channel by the pure ChatRouter (say=range+instance, party=members, world=global,
#      whisper=T-626 targeted-by-name — see chat_router.gd's channel table for the full matrix).
#
# RefCounted; wired by world/main.gd the same way world_rpc is: an injected `_reply` Callable
# (main._send_to_peer) plus the shared party store. Clock is injected (now_msec) so the rate-limit
# window is unit-testable without OS time.

extends RefCounted

const PlayerSessions = preload("res://scripts/player_sessions.gd")
const _ROUTER = preload("res://scripts/chat_router.gd")
const _FILTER = preload("res://scripts/chat_filter.gd")
const _EMOTES = preload("res://scripts/emote_catalog.gd")

const _PROFANITY_PATH := "res://data/chat/profanity.json"

# Per-peer anti-spam budget. Local/party get a conversational allowance; the global WORLD channel is
# throttled hard (it is the one unbounded fan-out) so a single peer cannot spam every online player.
const NORMAL_WINDOW_MS := 5000
const NORMAL_MAX_MSGS := 6
const WORLD_WINDOW_MS := 15000
const WORLD_MAX_MSGS := 1

var _reply: Callable  # main._send_to_peer(peer_id, dict)
var _party_store: Dictionary = {}  # T-280 shared store (party_of + parties)
var _profanity: Dictionary = {}  # word -> true (loaded once at setup)
var _emotes: Dictionary = {}  # T-361 item 3: id -> {self, other, clip} (loaded once at setup)
var _windows: Dictionary = {}  # peer_id -> {normal:{start,count}, world:{start,count}}
# T-361 item 2: peer_id -> {username: true} — a recipient never hears a sender they ignore.
# SHARED store (social_service owns + refreshes it); default {} keeps ignore-less callers working.
var _ignores: Dictionary = {}
# T-362: peer_id -> guild_id — SHARED store (social_service owns + refreshes it), so the "guild"
# channel routes to guildmates without a per-message master round-trip. Default {} = no guild chat.
var _guilds: Dictionary = {}
# T-451: peer_id -> true, seeded from master's persisted preference; shared with SocialService so
# a successful opt-out changes routing immediately without reconnecting.
var _help_subscribers: Dictionary = {}
# T-477: shared SocialService store, peer -> mentor/mentee row. Only a server-eligible `mentor`
# opt-in annotates help lines; the packet's own `mentor` field is never read.
var _mentorship_entries: Dictionary = {}


func setup(
	reply: Callable,
	party_store: Dictionary,
	ignores: Dictionary = {},
	guilds: Dictionary = {},
	help_subscribers: Dictionary = {},
	mentorship_entries: Dictionary = {}
) -> void:
	_reply = reply
	_party_store = party_store
	_ignores = ignores
	_guilds = guilds
	_help_subscribers = help_subscribers
	_mentorship_entries = mentorship_entries
	_profanity = _FILTER.load_word_set(_PROFANITY_PATH)
	_emotes = _EMOTES.load_catalog()


func handles(msg_type: String) -> bool:
	return msg_type == "chat" or msg_type == "emote"


# Validate → rate-limit → sanitize/mask → route. `now_msec` is injected (Time.get_ticks_msec() in
# main; a controlled value in tests). No reply on a dropped message except an explicit error case.
func handle(msg_type: String, sender_id: int, data: Dictionary, now_msec: int) -> void:
	var player: Dictionary = PlayerSessions.get_player(sender_id)
	if player.is_empty():
		return  # unknown/unhandshaked peer — never trust the wire for identity
	if msg_type == "emote":
		_handle_emote(sender_id, player, data, now_msec)
		return
	var channel := str(data.get("channel", "say"))
	if not _ROUTER.is_channel(channel):
		return
	var text: String = _FILTER.sanitize(str(data.get("text", "")))
	if text.is_empty():
		return
	if not _allow(sender_id, channel, now_msec):
		_reply.call(sender_id, {"type": "chat_rejected", "reason": "rate_limited"})
		return
	# Identity is the session's username — the client-claimed "from"/"username" is ignored entirely.
	var from := str(player.get("username", ""))
	# T-626: whisper is a targeted channel — resolve the target BEFORE routing. `self_whisper` short-
	# circuits the route call (positions always contains the sender, so the router's exact-match
	# lookup would otherwise "succeed" against yourself) and folds into the SAME rejection branch
	# below as the other scoped-channel failures, keeping this function's return count in budget.
	var whisper_target := ""
	var self_whisper := false
	if channel == "whisper":
		whisper_target = str(data.get("target", ""))
		self_whisper = whisper_target == from
	var recipients: Array = []
	if not self_whisper and (channel != "help" or bool(_help_subscribers.get(sender_id, false))):
		recipients = _route(channel, sender_id, whisper_target)
	# Scoped channel with no live recipients means the sender lacks membership/subscription, or
	# (whisper) the named target is unknown/offline/themselves — the online snapshot has no such
	# reachable username.
	if self_whisper or (recipients.is_empty() and channel in ["party", "guild", "help", "whisper"]):
		var reason := "not_in_party"
		if channel == "guild":
			reason = "not_in_guild"
		elif channel == "help":
			reason = "not_subscribed"
		elif channel == "whisper":
			reason = "cannot_whisper_self" if self_whisper else "unknown_player"
		_reply.call(sender_id, {"type": "chat_rejected", "reason": reason})
		return
	var payload := {
		"type": "chat",
		"channel": channel,
		"from": from,
		"text": _FILTER.mask(text, _profanity),
	}
	if channel == "help":
		payload["mentor"] = (
			_mentorship_entries.has(sender_id)
			and str(_mentorship_entries[sender_id].get("kind", "")) == "mentor"
		)
	elif channel == "whisper":
		payload["to"] = whisper_target
	for pid in recipients:
		# Ignore suppression: the ignorer never receives the ignored sender's lines. The sender
		# still sees their own echo (WoW behavior — an ignored troll gets no feedback signal).
		if int(pid) != sender_id and _ignores.get(int(pid), {}).has(from):
			continue
		# T-626: whisper needs a PER-RECIPIENT label — the sender's own echo reads "[To Bob]", the
		# target's copy reads "[From Alice]" — both derived server-side, never trusted from a client.
		if channel == "whisper":
			var out := payload.duplicate()
			out["direction"] = "out" if int(pid) == sender_id else "in"
			_reply.call(int(pid), out)
			continue
		_reply.call(int(pid), payload)


# T-361 item 3: an emote is a LOCAL action (routed like `say`) driven by a data-file id. The client
# sends ONLY the id (an intent); the server validates it against the catalog (unknown id → rejected,
# fail-closed), resolves the actor name FROM THE SESSION (the wire's `from`/`username` is ignored),
# draws from the shared `say` anti-spam budget, and fans out per say-range + the instance boundary.
# Each recipient gets their own line: the actor sees "You wave.", everyone else "<Actor> waves." —
# and an ignorer never hears the emote at all (same one-directional rule as chat).
func _handle_emote(sender_id: int, player: Dictionary, data: Dictionary, now_msec: int) -> void:
	var id := str(data.get("id", "")).to_lower()
	if not _EMOTES.is_emote(id, _emotes):
		_reply.call(sender_id, {"type": "chat_rejected", "reason": "unknown_emote"})
		return
	if not _allow(sender_id, "say", now_msec):
		_reply.call(sender_id, {"type": "chat_rejected", "reason": "rate_limited"})
		return
	var from := str(player.get("username", ""))
	var lines: Dictionary = _EMOTES.resolve(id, from, _emotes)
	var clip := str(lines.get("clip", ""))
	for pid in _route("say", sender_id):
		var rpid := int(pid)
		if rpid != sender_id and _ignores.get(rpid, {}).has(from):
			continue
		var text := str(lines["self"]) if rpid == sender_id else str(lines["other"])
		_reply.call(rpid, {"type": "emote", "id": id, "from": from, "text": text, "clip": clip})


func _route(channel: String, sender_id: int, whisper_target: String = "") -> Array:
	return _ROUTER.recipients(
		channel,
		sender_id,
		PlayerSessions.get_positions(),
		_party_store.get("party_of", {}),
		_party_store.get("parties", {}),
		_guilds,
		_help_subscribers,
		whisper_target
	)


# Sliding fixed-window rate limiter. WORLD draws from its own stricter budget so local chatter and a
# global shout can't cannibalise each other's allowance. Consumes budget only when allowed.
func _allow(peer_id: int, channel: String, now_msec: int) -> bool:
	var bucket := "world" if channel == "world" else "normal"
	var window_ms := WORLD_WINDOW_MS if bucket == "world" else NORMAL_WINDOW_MS
	var max_msgs := WORLD_MAX_MSGS if bucket == "world" else NORMAL_MAX_MSGS
	var peer: Dictionary = _windows.get(peer_id, {})
	var w: Dictionary = peer.get(bucket, {"start": now_msec, "count": 0})
	if now_msec - int(w["start"]) >= window_ms:
		w = {"start": now_msec, "count": 0}
	if int(w["count"]) >= max_msgs:
		peer[bucket] = w
		_windows[peer_id] = peer
		return false
	w["count"] = int(w["count"]) + 1
	peer[bucket] = w
	_windows[peer_id] = peer
	return true


func forget(peer_id: int) -> void:
	_windows.erase(peer_id)
