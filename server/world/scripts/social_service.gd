# T-363/T-361: the world-side SOCIAL hub — one _receive_message seam for chat (owned ChatService),
# trade, friends/ignore, guilds, discovery, mentorship, PvP/duel/BG, and the T-683 guild bank. The
# trust boundary + relay: identity is ALWAYS the session's (never the wire's), gated on server
# positions + rate-limited; the MASTER owns all durable state. RefCounted.
# T-698: bg_tick early-outs on _bg.active() — no match, no per-tick get_positions() rebuild.

extends RefCounted

const PlayerSessions = preload("res://scripts/player_sessions.gd")
const _CHAT = preload("res://scripts/chat_service.gd")
const _CQ = preload("res://scripts/content/content_query.gd")
const _DUELSVC = preload("res://scripts/duel_service.gd")  # T-381: consensual-duel rules/store
const _BGSVC = preload("res://scripts/battleground_service.gd")  # T-413: Crownfield lobby/match
const _DISC = preload("res://scripts/social_discovery.gd")  # T-451: pure seekers + /who truth

# Face-to-face (WoW-style) ranges: both parties within this planar range, same instance.
const TRADE_RADIUS := 6.0
const DUEL_RADIUS := 10.0  # T-381: a duel challenge is likewise face-to-face
# Anti-spam budget for master-round-trip ops (trade + social share one window per peer).
const OP_WINDOW_MS := 5000
const OP_MAX := 10

const _TRADE_INTENTS := [
	"trade_request",
	"trade_accept",
	"trade_decline",
	"trade_cancel",
	"trade_offer_item",
	"trade_retract_item",
	"trade_offer_coins",
	"trade_confirm",
	"trade_unconfirm",
]
const _SOCIAL_INTENTS := [
	"social_add_friend",
	"social_remove_friend",
	"social_add_ignore",
	"social_remove_ignore",
	"social_list",
	"help_subscription",
]
# T-362: guild management verbs. NONE grants rank/membership by assertion — create pays a sink,
# accept consumes a master-held invite, and every management verb is rank-gated on the master.
const _GUILD_INTENTS := [
	"guild_create",
	"guild_invite",
	"guild_accept",
	"guild_decline",
	"guild_leave",
	"guild_kick",
	"guild_promote",
	"guild_demote",
	"guild_disband",
	"guild_roster",
	"guild_set_recruitment",
	"guild_browse",
]
const _GUILD_BANK_PREFIX := "guild_bank_"  # T-683: bank verbs route by prefix; rank is master-side
const _DISCOVERY_INTENTS := ["guild_seek", "guild_unseek", "guild_seek_list", "player_who"]
# T-477: opt-in signals + read only. Party formation remains the normal T-280 `party_invite` path.
const _MENTORSHIP_INTENTS := ["mentor_flag", "mentor_unflag", "mentor_list"]
# T-390: the READ-ONLY PvP ladder surface. NEITHER verb sets a rating or reports a win —
# leaderboard is a public top-N read, pvp_rating the caller's OWN standing (session identity).
# Match ingestion is the SERVER-OBSERVED record_match master op with NO client route — a forged
# "I won / set my MMR" never reaches it. T-391 adds pvp_tracks (browse/activate/spend): the only
# mutation is a master-side overdraft-guarded honor SPEND (honor granted solely in record_match).
# T-401: pvp_set_title wears an already-owned `title:` unlock via the master's fail-closed
# pvp_track_op set_title (ownership re-validated there); grants nothing; rides this rate limit.
const _PVP_INTENTS := ["pvp_leaderboard", "pvp_rating", "pvp_tracks", "pvp_set_title"]
# T-381: consensual-duel intents. NONE grants anything — request/accept/decline/cancel only move the
# session-scoped pair store; the ONLY state mutation this surface reaches is the SERVER-OBSERVED
# record_match at a duel's end (winner/loser resolved from the pair, never the wire). There is NO
# client-routable "duel_result"/"record_match" verb — a forged win never lands (see handles()).
const _DUEL_INTENTS := ["duel_request", "duel_accept", "duel_decline", "duel_cancel"]
# T-413: Crownfield battleground intents. bg_queue/bg_unqueue only move the consent lobby;
# bg_status is a read. NO verb reports a score, a win, or an end — the match is adjudicated by the
# server tick (bg_tick) and paid ONLY through the server-observed record_match master op, exactly
# like duels. There is no client-routable "bg_result"/"bg_score"/"bg_win" (adversarial-tested).
const _BG_INTENTS := ["bg_queue", "bg_unqueue", "bg_status"]

var _chat = _CHAT.new()
var _duel = _DUELSVC.new()  # T-381: session-scoped duel pair store (owned here like _chat)
var _bg = _BGSVC.new()  # T-413: battleground lobby + match store (owned here like _duel)
var _reply: Callable
var _title_update: Callable = Callable()  # T-401: push a set title to the world's nameplate store
var _master = null  # MasterClient (call_master)
var _world_rpc = null  # content authority — item_registry for trade-commit capacity checks
var _ignores: Dictionary = {}  # peer_id -> {username: true} (shared with ChatService)
var _guilds: Dictionary = {}  # peer_id -> guild_id (T-362; shared with ChatService guild routing)
var _guild_names: Dictionary = {}  # peer_id -> authoritative guild name (T-451 /who)
var _guild_ranks: Dictionary = {}  # peer_id -> authoritative rank (officer seeker-board gate)
var _help_subscribers: Dictionary = {}  # peer_id -> true (shared with ChatService)
var _levels: Dictionary = {}  # injected world truth refs; never populated from a packet
var _classes: Dictionary = {}
var _seekers: Dictionary = _DISC.new_store()
var _mentorship: Dictionary = _DISC.new_mentorship_store()
var _party_store: Dictionary = {}
var _trading: Dictionary = {}  # peer_id -> username (has a live/pending trade session)
var _windows: Dictionary = {}  # peer_id -> {start, count}


func setup(
	reply: Callable, party_store: Dictionary, master, world_rpc, title_update := Callable()
) -> void:
	_reply = reply
	_master = master
	_world_rpc = world_rpc
	_party_store = party_store
	_title_update = title_update  # T-401: world-side nameplate title setter (optional in tests)
	_chat.setup(reply, party_store, _ignores, _guilds, _help_subscribers, _mentorship["entries"])


func setup_discovery(levels: Dictionary, classes: Dictionary) -> void:
	_levels = levels
	_classes = classes


func handles(msg_type: String) -> bool:
	return (
		_chat.handles(msg_type)
		or _TRADE_INTENTS.has(msg_type)
		or _SOCIAL_INTENTS.has(msg_type)
		or _GUILD_INTENTS.has(msg_type)
		or msg_type.begins_with(_GUILD_BANK_PREFIX)
		or _DISCOVERY_INTENTS.has(msg_type)
		or _MENTORSHIP_INTENTS.has(msg_type)
		or _PVP_INTENTS.has(msg_type)
		or _DUEL_INTENTS.has(msg_type)
		or _BG_INTENTS.has(msg_type)
	)


func handle(msg_type: String, sender_id: int, data: Dictionary, now_msec: int) -> void:
	if _chat.handles(msg_type):
		_prune_mentorship()
		_chat.handle(msg_type, sender_id, data, now_msec)
		return
	# Identity from the SESSION — an unhandshaked peer gets silence, a spoofed "username"/"from"
	# on the wire is never read.
	var player: Dictionary = PlayerSessions.get_player(sender_id)
	if player.is_empty():
		return
	if not _allow(sender_id, now_msec):
		var reply_type := "trade_result"
		if _MENTORSHIP_INTENTS.has(msg_type):
			reply_type = "mentor_result"
		elif _GUILD_INTENTS.has(msg_type) or _DISCOVERY_INTENTS.has(msg_type):
			reply_type = "guild_result"
		elif _SOCIAL_INTENTS.has(msg_type):
			reply_type = "social_result"
		_reply.call(sender_id, {"type": reply_type, "ok": false, "reason": "rate_limited"})
		return
	if _TRADE_INTENTS.has(msg_type):
		_handle_trade(msg_type, sender_id, str(player.get("username", "")), data)
	elif _SOCIAL_INTENTS.has(msg_type):
		_handle_social(msg_type, sender_id, str(player.get("username", "")), data)
	elif _GUILD_INTENTS.has(msg_type) or msg_type.begins_with(_GUILD_BANK_PREFIX):
		_handle_guild(msg_type, sender_id, str(player.get("username", "")), data)
	elif _DISCOVERY_INTENTS.has(msg_type):
		_handle_discovery(msg_type, sender_id, data)
	elif _MENTORSHIP_INTENTS.has(msg_type):
		_handle_mentorship(msg_type, sender_id, data)
	elif _PVP_INTENTS.has(msg_type):
		_handle_pvp(msg_type, sender_id, str(player.get("username", "")), data)
	elif _DUEL_INTENTS.has(msg_type):
		_handle_duel(msg_type, sender_id, str(player.get("username", "")), data, now_msec)
	elif _BG_INTENTS.has(msg_type):
		_handle_bg(msg_type, sender_id, str(player.get("username", "")), now_msec)


# T-361 item 2: master-returned ignore list cached per peer so chat filtering is synchronous.
# main.gd seeds it at handshake from the get_character_combat payload; social ops refresh it.
func set_ignores(peer_id: int, names: Array) -> void:
	var flags: Dictionary = {}
	for n in names:
		flags[str(n)] = true
	_ignores[peer_id] = flags


# T-361/T-362: one login seed from the get_character_combat payload — chat-filter cache + guild-chat
# cache. main.gd calls this once at handshake so neither seed grows the (at-cap) main.gd.
func seed_login(peer_id: int, combat: Dictionary) -> void:
	set_ignores(peer_id, combat.get("ignores", []))
	set_guild_profile(
		peer_id,
		int(combat.get("guild_id", 0)),
		str(combat.get("guild_name", "")),
		int(combat.get("guild_rank", -1))
	)
	set_help(peer_id, bool(combat.get("help_subscribed", true)))
	# T-679: tell master how many guildmates are online now (from the authoritative _guilds session
	# cache, never client-asserted) so the guild's "N members online together" milestone tracks the
	# concurrent peak (master keeps it as a MAX). Fire-and-forget — a dropped tick is harmless.
	var gid := int(combat.get("guild_id", 0))
	if gid != 0 and _master != null:
		var online := 0
		for peer_gid in _guilds.values():
			online += 1 if int(peer_gid) == gid else 0
		if online > 0:
			_master.call_master(
				"guild_op", {"action": "note_presence", "guild_id": gid, "online_count": online}
			)


# T-362: guild-chat routing cache. guild_id 0 (guildless) erases the entry so a stale membership
# never leaks a line to a guild the player already left.
func set_guild(peer_id: int, guild_id: int) -> void:
	if guild_id == 0:
		_guilds.erase(peer_id)
	else:
		_guilds[peer_id] = guild_id
		_DISC.unflag(_seekers, peer_id)


func set_guild_profile(peer_id: int, guild_id: int, guild_name: String, guild_rank: int) -> void:
	set_guild(peer_id, guild_id)
	if guild_id == 0:
		_guild_names.erase(peer_id)
		_guild_ranks.erase(peer_id)
	else:
		_guild_names[peer_id] = guild_name
		_guild_ranks[peer_id] = guild_rank


func set_help(peer_id: int, subscribed: bool) -> void:
	if subscribed:
		_help_subscribers[peer_id] = true
	else:
		_help_subscribers.erase(peer_id)


func help_subscribed(peer_id: int) -> bool:
	return bool(_help_subscribers.get(peer_id, false))


func forget(peer_id: int) -> void:
	_chat.forget(peer_id)
	_ignores.erase(peer_id)
	_guilds.erase(peer_id)
	_guild_names.erase(peer_id)
	_guild_ranks.erase(peer_id)
	_help_subscribers.erase(peer_id)
	_DISC.unflag(_seekers, peer_id)
	_DISC.unflag(_mentorship, peer_id)
	_windows.erase(peer_id)
	# T-381: a mid-duel disconnect forfeits to the opponent (the T-015 orphan lesson) — end + record
	# it (winner is the survivor, resolved server-side) and drop any pending offer to/from the leaver.
	var ended: Dictionary = _duel.on_disconnect(peer_id)
	if not ended.is_empty():
		_finish_duel(ended)
	# T-413: a disconnect deserts the lobby/match (deserters take the loss at the end; an emptied
	# team forfeits). The session move is harmless on a peer that is already gone.
	_apply_bg_leave(peer_id, _bg.leave(peer_id, 0))  # time is unused on the leave path
	if _trading.has(peer_id):
		var username: String = str(_trading[peer_id])
		_trading.erase(peer_id)
		# A mid-trade disconnect cancels the session server-side — the survivor is notified and
		# NOTHING has moved (the swap only ever happens atomically at double-confirm).
		_trade_master(peer_id, {"username": username, "action": "cancel"})


# ---- trade (T-363) ---------------------------------------------------------


func _handle_trade(msg_type: String, sender_id: int, username: String, data: Dictionary) -> void:
	var op := {"username": username, "action": msg_type.trim_prefix("trade_")}
	match msg_type:
		"trade_request":
			var target := str(data.get("target", ""))
			var check := _validate_request_target(sender_id, username, target)
			if check != "":
				_reply.call(sender_id, {"type": "trade_result", "ok": false, "reason": check})
				return
			op["target_username"] = target
		"trade_offer_item":
			op["slot_index"] = int(data.get("slot_index", -1))
			op["count"] = int(data.get("count", 0))
		"trade_retract_item":
			op["slot_index"] = int(data.get("slot_index", -1))
		"trade_offer_coins":
			op["amount"] = int(data.get("amount", -1))
		"trade_confirm":
			# The commit needs item defs for stacking/capacity checks (content lives world-side).
			op["item_registry"] = _item_registry()
	_trade_master(sender_id, op)


# The one master round-trip + fan-out. Errors go to the actor; session views go to BOTH parties.
func _trade_master(sender_id: int, op: Dictionary) -> void:
	var result: Dictionary = await _master.call_master("trade_op", op)
	if result.has("error"):
		_reply.call(
			sender_id, {"type": "trade_result", "ok": false, "reason": str(result["error"])}
		)
		return
	var ended := bool(result.get("ended", false))
	var payload_base := {
		"type": "trade_update",
		"ended": ended,
		"completed": bool(result.get("completed", false)),
		"reason": str(result.get("reason", "")),
	}
	for entry: Dictionary in result.get("views", []):
		var uname := str(entry.get("username", ""))
		for pid in PlayerSessions.find_live_peers_by_username(uname):
			var payload := payload_base.duplicate()
			payload["view"] = entry.get("view", {})
			_reply.call(int(pid), payload)
			if ended:
				_trading.erase(int(pid))
			else:
				_trading[int(pid)] = uname


# Server-side gates on starting a trade: the target is a LIVE peer (resolved from sessions, not
# the wire), not yourself, same instance, and within face-to-face range.
func _validate_request_target(sender_id: int, username: String, target: String) -> String:
	if target == "" or target == username:
		return "bad_target"
	var peers := PlayerSessions.find_live_peers_by_username(target)
	if peers.is_empty():
		return "target_offline"
	var positions: Dictionary = PlayerSessions.get_positions()
	var me: Dictionary = positions.get(sender_id, {})
	var them: Dictionary = positions.get(int(peers[0]), {})
	if me.is_empty() or them.is_empty():
		return "target_offline"
	if int(me.get("instance_id", 0)) != int(them.get("instance_id", 0)):
		return "too_far"
	var dx := float(me.get("x", 0.0)) - float(them.get("x", 0.0))
	var dy := float(me.get("y", 0.0)) - float(them.get("y", 0.0))
	if dx * dx + dy * dy > TRADE_RADIUS * TRADE_RADIUS:
		return "too_far"
	return ""


# ---- friends / ignore (T-361 item 2) ---------------------------------------


func _handle_social(msg_type: String, sender_id: int, username: String, data: Dictionary) -> void:
	if msg_type == "help_subscription":
		var subscribed := bool(data.get("subscribed", true))
		var help_result: Dictionary = await _master.call_master(
			"social_op", {"username": username, "action": "set_help", "subscribed": subscribed}
		)
		if help_result.has("error"):
			_reply.call(
				sender_id,
				{"type": "help_subscription", "ok": false, "reason": str(help_result["error"])}
			)
			return
		set_help(sender_id, bool(help_result.get("help_subscribed", true)))
		(
			_reply
			. call(
				sender_id,
				{
					"type": "help_subscription",
					"ok": true,
					"subscribed": help_subscribed(sender_id),
				}
			)
		)
		return
	var op := {
		"username": username,
		"action": msg_type.trim_prefix("social_"),
		"target_name": str(data.get("name", "")),
	}
	var result: Dictionary = await _master.call_master("social_op", op)
	if result.has("error"):
		_reply.call(
			sender_id, {"type": "social_result", "ok": false, "reason": str(result["error"])}
		)
		return
	# Refresh the chat-filter cache from the authoritative reply, then decorate friends with
	# ONLINE status from live sessions (presence is world knowledge, not master's).
	set_ignores(sender_id, result.get("ignored", []))
	var online: Dictionary = {}
	for entry in PlayerSessions.get_positions().values():
		online[str(entry.get("username", ""))] = true
	var friends: Array = []
	for fname in result.get("friends", []):
		friends.append({"name": str(fname), "online": online.has(str(fname))})
	(
		_reply
		. call(
			sender_id,
			{
				"type": "social_list",
				"friends": friends,
				"ignored": result.get("ignored", []),
			}
		)
	)


# ---- guilds (T-362) ---------------------------------------------------------


func _handle_guild(msg_type: String, sender_id: int, username: String, data: Dictionary) -> void:
	var op := {"username": username, "action": msg_type.trim_prefix("guild_")}
	match msg_type:
		"guild_create":
			op["name"] = str(data.get("name", ""))
		"guild_invite", "guild_kick", "guild_promote", "guild_demote":
			# Target is a NAME on the wire; the master resolves it to an id (client can't inject one).
			op["target_name"] = str(data.get("name", data.get("target", "")))
		"guild_set_recruitment":
			op["open"] = bool(data.get("open", false))
			op["blurb"] = str(data.get("blurb", ""))
	if msg_type.begins_with(_GUILD_BANK_PREFIX):
		op.merge(data)  # T-683: forward the bank verb's params (username/action stay server-set)
	if msg_type == "guild_disband" or msg_type.begins_with(_GUILD_BANK_PREFIX):
		op["item_registry"] = _item_registry()  # item defs live world-side (as trade); bank splice/payout
	var result: Dictionary = await _master.call_master("guild_op", op)
	if result.has("error"):
		_reply.call(
			sender_id, {"type": "guild_result", "ok": false, "reason": str(result["error"])}
		)
		return
	_apply_guild_result(msg_type, sender_id, username, result)


# Master op succeeded: keep the world's guild-chat cache truthful and push fresh views to everyone
# affected. The master is authority; this only mirrors online presence + panel state.
func _apply_guild_result(
	msg_type: String, sender_id: int, username: String, result: Dictionary
) -> void:
	if msg_type.begins_with(_GUILD_BANK_PREFIX):
		result.merge({"type": "guild_bank", "action": msg_type}, true)  # T-683: actor-only vault reply
		_reply.call(sender_id, result)
		return
	match msg_type:
		"guild_browse":
			_reply.call(sender_id, {"type": "guild_discovery", "guilds": result.get("guilds", [])})
		"guild_invite":
			# Prompt the target's live peer(s); the actor just gets an ack.
			var tname := str(result.get("invited", ""))
			for pid in PlayerSessions.find_live_peers_by_username(tname):
				(
					_reply
					. call(
						int(pid),
						{
							"type": "guild_invite",
							"from": username,
							"guild_name": str(result.get("guild_name", "")),
						}
					)
				)
			_reply.call(sender_id, {"type": "guild_result", "ok": true, "reason": "invited"})
		"guild_disband":
			for name in result.get("member_names", []):
				_set_guild_by_name(str(name), 0)
				for pid in PlayerSessions.find_live_peers_by_username(str(name)):
					_reply.call(int(pid), {"type": "guild_disbanded"})
		"guild_leave":
			_set_guild_by_name(username, 0)
			_reply.call(sender_id, {"type": "guild_result", "ok": true, "reason": "left"})
		"guild_decline":
			_reply.call(sender_id, {"type": "guild_result", "ok": true, "reason": "declined"})
		_:
			# create / accept / kick / promote / demote / roster / recruitment edit return a roster.
			if msg_type == "guild_kick":
				_set_guild_by_name(str(result.get("kicked", "")), 0)
				for pid in PlayerSessions.find_live_peers_by_username(
					str(result.get("kicked", ""))
				):
					_reply.call(int(pid), {"type": "guild_disbanded"})  # "you were removed"
			if result.has("members"):
				_broadcast_roster(result)


# Push a roster view to every ONLINE member and refresh their guild-chat cache from the same truth.
func _broadcast_roster(result: Dictionary) -> void:
	var gid := int(result.get("guild_id", 0))
	var online: Dictionary = {}
	for entry in PlayerSessions.get_positions().values():
		online[str(entry.get("username", ""))] = true
	var members: Array = []
	for m: Dictionary in result.get("members", []):
		var mname := str(m.get("name", ""))
		(
			members
			. append(
				{
					"name": mname,
					"rank": int(m.get("rank", 2)),
					"rank_name": str(m.get("rank_name", "")),
					"is_leader": bool(m.get("is_leader", false)),
					"online": online.has(mname),
				}
			)
		)
		_set_guild_by_name(mname, gid)
		for pid in PlayerSessions.find_live_peers_by_username(mname):
			set_guild_profile(
				int(pid), gid, str(result.get("guild_name", "")), int(m.get("rank", 2))
			)
	# Per-recipient payload: each member is told which row is THEM ("you") so the panel can gate its
	# management controls to the viewer's real rank — the server still re-checks every verb.
	for m2: Dictionary in members:
		var mname := str(m2.get("name", ""))
		var payload := {
			"type": "guild_roster",
			"guild_id": gid,
			"guild_name": str(result.get("guild_name", "")),
			"members": members,
			"you": mname,
			"recruitment_open": bool(result.get("recruitment_open", false)),
			"recruitment_blurb": str(result.get("recruitment_blurb", "")),
		}
		for pid in PlayerSessions.find_live_peers_by_username(mname):
			_reply.call(int(pid), payload)


func _set_guild_by_name(username: String, guild_id: int) -> void:
	for pid in PlayerSessions.find_live_peers_by_username(username):
		if guild_id == 0:
			set_guild_profile(int(pid), 0, "", -1)
		else:
			set_guild(int(pid), guild_id)


# ---- social discovery (T-451) ---------------------------------------------


func _handle_discovery(msg_type: String, sender_id: int, data: Dictionary) -> void:
	_DISC.prune_guilded(_seekers, _guilds)
	_prune_mentorship()
	if msg_type == "player_who":
		var filters: Dictionary = (
			data.get("filters", {}) if data.get("filters", {}) is Dictionary else {}
		)
		(
			_reply
			. call(
				sender_id,
				{
					"type": "guild_who",
					"players":
					_DISC.who(
						PlayerSessions.get_positions(),
						_levels,
						_classes,
						_guilds,
						_guild_names,
						filters,
						_mentorship
					),
				}
			)
		)
		return
	if msg_type == "guild_seek":
		if int(_guilds.get(sender_id, 0)) > 0:
			_reply.call(sender_id, {"type": "guild_result", "ok": false, "reason": "in_guild"})
			return
		_DISC.flag(
			_seekers,
			sender_id,
			int(_levels.get(sender_id, 1)),
			_DISC.role_for_class(str(_classes.get(sender_id, ""))),
			str(data.get("note", ""))
		)
	elif msg_type == "guild_unseek":
		_DISC.unflag(_seekers, sender_id)
	elif (
		msg_type == "guild_seek_list"
		and not _DISC.can_browse_seekers(int(_guild_ranks.get(sender_id, -1)))
	):
		_reply.call(sender_id, {"type": "guild_result", "ok": false, "reason": "no_permission"})
		return
	_reply.call(sender_id, {"type": "guild_seek_board", "players": seeking_board()})


func seeking_board() -> Array:
	var out: Array = []
	for row: Dictionary in _DISC.board(_seekers):
		var enriched := row.duplicate()
		enriched.erase("peer")
		enriched["name"] = str(PlayerSessions.get_player(int(row["peer"])).get("username", ""))
		out.append(enriched)
	return out


# ---- mentorship discovery (T-477) -----------------------------------------


func _handle_mentorship(msg_type: String, sender_id: int, data: Dictionary) -> void:
	_prune_mentorship()
	if msg_type == "mentor_flag":
		if _party_store.get("party_of", {}).has(sender_id):
			_reply.call(sender_id, {"type": "mentor_result", "ok": false, "reason": "in_party"})
			return
		var pos: Dictionary = PlayerSessions.get_positions().get(sender_id, {})
		var result := _DISC.flag_mentorship(
			_mentorship,
			sender_id,
			str(data.get("kind", "")),
			int(_levels.get(sender_id, 0)),
			_DISC.role_for_class(str(_classes.get(sender_id, ""))),
			_DISC.zone_for(pos),
			str(data.get("note", ""))
		)
		if not bool(result["ok"]):
			_reply.call(
				sender_id, {"type": "mentor_result", "ok": false, "reason": str(result["reason"])}
			)
			return
	elif msg_type == "mentor_unflag":
		_DISC.unflag(_mentorship, sender_id)
	_reply.call(
		sender_id, {"type": "mentor_board", "players": mentorship_board(str(data.get("kind", "")))}
	)


func mentorship_board(kind: String = "") -> Array:
	_prune_mentorship()
	var out: Array = []
	for row: Dictionary in _DISC.mentorship_board(_mentorship, kind):
		var player := PlayerSessions.get_player(int(row["peer"]))
		if player.is_empty():
			continue
		var enriched := row.duplicate()
		enriched.erase("peer")
		enriched["name"] = str(player.get("username", ""))
		out.append(enriched)
	return out


func _prune_mentorship() -> void:
	_DISC.prune_mentorship(_mentorship, _levels, _party_store.get("party_of", {}))


# ---- PvP ladder read (T-390) ------------------------------------------------


# READ-ONLY. The client sends only a DESIRE to view (bracket / limit) — never a rating, a win, or a
# username. Identity for "my rating" is the SESSION's username; the master owns all rating truth and
# this path can only read it (record_match is a server-observed master op with no client route).
func _handle_pvp(msg_type: String, sender_id: int, username: String, data: Dictionary) -> void:
	# T-401: wear a title. The chosen id is a DESIRE — the master re-validates it against the caller's
	# unlock set (fail-closed); only on success does the world push it to the nameplate store + reply.
	if msg_type == "pvp_set_title":
		var st := {"action": "set_title", "title": str(data.get("title", "")), "username": username}
		var sres: Dictionary = await _master.call_master("pvp_track_op", st)
		if sres.has("error"):
			_reply.call(
				sender_id, {"type": "pvp_result", "ok": false, "reason": str(sres["error"])}
			)
			return
		var title := str(sres.get("title", ""))
		if _title_update.is_valid():
			_title_update.call(sender_id, title)  # rides the next positions broadcast (T-372 delta)
		_reply.call(
			sender_id, {"type": "pvp_result", "ok": true, "reason": "title_set", "title": title}
		)
		return
	# T-391: the track surface rides its own master op (browse/activate/spend; spend is the only
	# mutation and it is overdraft-guarded master-side). action/track are DESIRES, never grants.
	if msg_type == "pvp_tracks":
		var top := {
			"action": str(data.get("action", "browse")),
			"track": str(data.get("track", "")),
			"username": username,
		}
		var tr: Dictionary = await _master.call_master("pvp_track_op", top)
		tr["type"] = "pvp_tracks"
		_reply.call(sender_id, tr)
		return
	var op := {
		"action": "leaderboard" if msg_type == "pvp_leaderboard" else "rating",
		"bracket": str(data.get("bracket", "duel")),
		"username": username,
	}
	if msg_type == "pvp_leaderboard":
		op["limit"] = int(data.get("limit", 10))
	var result: Dictionary = await _master.call_master("pvp_op", op)
	if result.has("error"):
		_reply.call(sender_id, {"type": "pvp_result", "ok": false, "reason": str(result["error"])})
		return
	result["type"] = msg_type  # pvp_leaderboard | pvp_rating
	_reply.call(sender_id, result)


# ---- duels (T-381) ----------------------------------------------------------
# The consent surface for player→player combat. `pvp_eligible` is injected into ability_executor and
# is TRUE only for an ACTIVE consensual duel between the pair (default FALSE = no PvP). Duel state
# lives in the pure `_duel` module; this hub is the trust boundary + relay (identity from session,
# proximity gated, rate-limited) and the FIRST live caller of the server-observed record_match.


# Executor consent predicate (bound by world/main.gd in _ready). Delegates to the pure pair store —
# TRUE only when attacker & target are in an active duel with each other; FALSE is the fail-closed
# default (no zones, no open-world flagging for the demo).
func pvp_eligible(attacker_id: int, target_id: int) -> bool:
	# T-413: the battleground arm — TRUE for opposing ACTIVE teams in the same match; same-team,
	# cross-match, and deserted pairs stay FALSE. Default remains fail-closed (no open-world PvP).
	return _duel.eligible(attacker_id, target_id) or _bg.eligible(attacker_id, target_id)


# Post-damage duel-end hook (called by main.gd after a PLAYER takes a hit, with the live resources
# store). If the hit reached the HP floor the duel ends: the loser is clamped to `floor_hp` (kept
# ALIVE, so the alive→dead edge — and its T-364 durability wear — never fires) and the match is
# recorded + relayed. Returns TRUE to tell the caller to SKIP the normal death check; else FALSE.
func on_duel_hit(target_id: int, combat_resources: Dictionary, _now: int) -> bool:
	if not combat_resources.has(target_id):
		return false
	var res = combat_resources[target_id]
	var ended: Dictionary = _duel.on_hit(target_id, int(res.hp), int(res.max_hp))
	if not ended.is_empty():
		res.hp = maxi(int(res.hp), int(ended["floor_hp"]))  # loser stays alive at the floor
		_finish_duel(ended)
		return true
	# T-413: the Crownfield runs REAL combat rules (2026-07-16 owner veto of the knockout floor) —
	# a BG death falls through to the ordinary player death path (real death, normal durability
	# wear); the respawn is redirected to the team spawn by bg_respawn_point, keeping the match live.
	return false


# request/accept/decline/cancel. Identity is the SESSION's (never the wire); a challenge is
# gated like trade; the pair store enforces the forged-accept + already-dueling guards.
func _handle_duel(
	msg_type: String, sender_id: int, username: String, data: Dictionary, now_msec: int
) -> void:
	match msg_type:
		"duel_request":
			var target := str(data.get("target", ""))
			var peer := _validate_duel_target(sender_id, username, target)
			if peer < 0:
				_duel_line(sender_id, "You cannot duel %s right now." % target)
				return
			var tname := str(PlayerSessions.get_player(peer).get("username", target))
			var req: Dictionary = _duel.request(sender_id, username, peer, tname, now_msec)
			if req.has("error"):
				_duel_line(sender_id, "Duel request failed (%s)." % str(req["error"]))
				return
			_duel_line(peer, "%s challenges you to a duel — type /duel accept." % username)
			_duel_line(sender_id, "You challenge %s to a duel." % tname)
		"duel_accept":
			var positions: Dictionary = PlayerSessions.get_positions()
			var me: Dictionary = positions.get(sender_id, {})
			var anchor := Vector2(float(me.get("x", 0.0)), float(me.get("y", 0.0)))
			var acc: Dictionary = _duel.accept(sender_id, anchor, now_msec)
			if acc.has("error"):
				_duel_line(sender_id, "No duel to accept.")
				return
			_duel_line(int(acc["a_id"]), "The duel begins! Fight %s." % str(acc["b_name"]))
			_duel_line(int(acc["b_id"]), "The duel begins! Fight %s." % str(acc["a_name"]))
		"duel_decline":
			var dec: Dictionary = _duel.decline(sender_id)
			if dec.has("ok"):
				_duel_line(int(dec["challenger_id"]), "%s declined your duel." % username)
				_duel_line(sender_id, "You decline the duel.")
		"duel_cancel":
			var can: Dictionary = _duel.cancel(sender_id)
			if can.has("ok"):
				_duel_line(int(can["target_id"]), "%s withdrew their duel challenge." % username)
				_duel_line(sender_id, "You withdraw the duel challenge.")


# A finished duel: FIRST live caller of the server-observed record_match (Elo + honor, T-390/391).
# Winner/loser are the SERVER-resolved names from the pair store, never a client claim; the master
# stamps its own season. The result (rating delta + honor) relays to both live peers as chat lines.
func _finish_duel(ended: Dictionary) -> void:
	var wname := str(ended.get("winner_name", ""))
	var lname := str(ended.get("loser_name", ""))
	var result: Dictionary = await _master.call_master(
		"record_match", {"winner": wname, "loser": lname, "bracket": "duel"}
	)
	var winner_id := int(ended.get("winner_id", -1))
	var loser_id := int(ended.get("loser_id", -1))
	if result.has("error"):
		_duel_line(winner_id, "You won the duel against %s." % lname)
		_duel_line(loser_id, "You were defeated by %s." % wname)
		return
	var w: Dictionary = result.get("winner", {})
	var l: Dictionary = result.get("loser", {})
	var honor: Dictionary = result.get("honor", {})
	_duel_line(
		winner_id,
		(
			"You won the duel against %s! (rating %+d, +%d honor)"
			% [lname, int(w.get("delta", 0)), int(honor.get("winner_honor", 0))]
		)
	)
	_duel_line(
		loser_id,
		(
			"You were defeated by %s. (rating %+d, +%d honor)"
			% [wname, int(l.get("delta", 0)), int(honor.get("loser_honor", 0))]
		)
	)


# One duel notice → a peer's chat log as a system line (the demo UX: chat-line offers/results, the
# cheapest surface — no new panel). Rides the client's existing "chat" category via channel system.
func _duel_line(peer_id: int, text: String) -> void:
	if peer_id < 0:
		return
	_reply.call(peer_id, {"type": "chat", "channel": "system", "from": "", "text": text})


# A duel challenge target must be a live peer (resolved from sessions, not the wire), not yourself,
# same instance, within DUEL_RADIUS. Returns the target peer_id, or -1 if it fails any gate.
func _validate_duel_target(sender_id: int, username: String, target: String) -> int:
	if target == "" or target == username:
		return -1
	var peers := PlayerSessions.find_live_peers_by_username(target)
	if peers.is_empty():
		return -1
	var positions: Dictionary = PlayerSessions.get_positions()
	var me: Dictionary = positions.get(sender_id, {})
	var them: Dictionary = positions.get(int(peers[0]), {})
	if me.is_empty() or them.is_empty():
		return -1
	if int(me.get("instance_id", 0)) != int(them.get("instance_id", 0)):
		return -1
	var dx := float(me.get("x", 0.0)) - float(them.get("x", 0.0))
	var dy := float(me.get("y", 0.0)) - float(them.get("y", 0.0))
	if dx * dx + dy * dy > DUEL_RADIUS * DUEL_RADIUS:
		return -1
	return int(peers[0])


# ---- battleground (T-413) ----------------------------------------------------
# The Crownfield trust boundary: identity from the session, rate-limited with the rest of the hub,
# eligibility gated server-side. The pure _bg store owns lobby/match truth; this hub applies its
# session moves (PlayerSessions is the same authority the duel/trade gates already read) and is
# the ONLY caller of the server-observed record_match for the "bg" bracket.


# Once per server tick (main._process): leash stragglers home, accrue the score, resolve ends.
func bg_tick(now_msec: int) -> void:
	if not _bg.active():  # T-698: no match -> no O(players) get_positions() rebuild per tick
		return
	for ev: Dictionary in _bg.tick(PlayerSessions.get_positions(), now_msec):
		match str(ev["type"]):
			"bg_leash":
				_bg_return(int(ev["peer"]), ev["entry"])
				_duel_line(int(ev["peer"]), "You deserted the Crownfield.")
			"bg_control":
				var line := "The Crown is contested!"
				if int(ev["control"]) != -1:
					var sc: Array = ev["score"]
					line = (
						"Team %d holds the Crown! (%d - %d)"
						% [int(ev["control"]) + 1, int(sc[0]), int(sc[1])]
					)
				_bg_relay_match(int(ev["iid"]), line)
			"bg_end":
				_finish_bg(ev["end"])


func _handle_bg(msg_type: String, sender_id: int, username: String, now_msec: int) -> void:
	match msg_type:
		"bg_queue":
			if not _bg_eligible_to_queue(sender_id):
				_duel_line(sender_id, "You cannot queue for the Crownfield right now.")
				return
			var pos: Vector3 = PlayerSessions.get_player(sender_id).get("pos", Vector3.ZERO)
			var r: Dictionary = _bg.queue(sender_id, username, pos, now_msec, _bg_eligible_to_queue)
			if r.has("error"):
				_duel_line(sender_id, "Crownfield queue failed (%s)." % str(r["error"]))
			elif r.has("started"):
				_launch_bg(r["started"])
			else:
				_duel_line(
					sender_id,
					(
						"Queued for the Crownfield (%d of %d)."
						% [int(r.get("queued", 1)), _BGSVC.PLAYERS_NEEDED]
					)
				)
		"bg_unqueue":
			if _bg.unqueue(sender_id).has("ok"):
				_duel_line(sender_id, "You leave the Crownfield queue.")
		"bg_status":
			_duel_line(
				sender_id,
				(
					"Crownfield: %d queued%s."
					% [_bg.queue_size(), " — you are in a match" if _bg.in_match(sender_id) else ""]
				)
			)


# The lobby eligibility predicate, also re-run over the WHOLE lobby before any launch: a live
# session, in the open world (never inside the crypt/another arena), not dueling, not mid-trade.
func _bg_eligible_to_queue(peer_id: int) -> bool:
	return (
		not PlayerSessions.get_player(peer_id).is_empty()
		and PlayerSessions.get_instance(peer_id) == 0
		and not _duel.is_dueling(peer_id)
		and not _trading.has(peer_id)
	)


# Apply a launch descriptor: move all four into the match's own instance bucket at their team
# camps. Instance ids come from the store's dedicated range — never client-supplied.
func _launch_bg(started: Dictionary) -> void:
	var iid := int(started["iid"])
	for mv: Dictionary in started["moves"]:
		var peer := int(mv["peer"])
		PlayerSessions.set_instance(peer, iid)
		PlayerSessions.update_position(peer, mv["spawn"])
		_duel_line(peer, "The Crownfield match begins! Hold the Crown at the center to score.")


# A resolved match: return the still-active players home, then pay through the SERVER-OBSERVED
# record_match — one call per cross-team pair, bracket "bg" (honor reason "bg_match"). The store
# erased the match before returning the descriptor, so a second payout attempt has nothing to pay.
func _finish_bg(end: Dictionary) -> void:
	for ret: Dictionary in end["returns"]:
		_bg_return(int(ret["peer"]), ret["entry"])
	var sc: Array = end["score"]
	if int(end["winner"]) == -1:  # 0-0 at the horn — void, nothing to record (banked owner row)
		for ret: Dictionary in end["returns"]:
			_duel_line(int(ret["peer"]), "The Crownfield match ends unclaimed — no contest.")
		return
	# Deserters are excluded from both rosters (they forfeit — no payout, no loss recorded), so the
	# sides can be uneven; record one match per pair over the ACTIVE minimum. A full-team desertion
	# leaves the winners with no opponent to record against — the forfeit ends the match, unpaid.
	var winners: Array = end["winners"]
	var losers: Array = end["losers"]
	for i in mini(winners.size(), losers.size()):
		var wname := str((winners[i] as Dictionary)["name"])
		var lname := str((losers[i] as Dictionary)["name"])
		var result: Dictionary = await _master.call_master(
			"record_match", {"winner": wname, "loser": lname, "bracket": "bg"}
		)
		var honor: Dictionary = result.get("honor", {})
		_duel_line(
			int((winners[i] as Dictionary)["peer"]),
			(
				"Victory in the Crownfield! (%d - %d, +%d honor)"
				% [int(sc[0]), int(sc[1]), int(honor.get("winner_honor", 0))]
			)
		)
		_duel_line(
			int((losers[i] as Dictionary)["peer"]),
			(
				"Defeat in the Crownfield. (%d - %d, +%d honor)"
				% [int(sc[0]), int(sc[1]), int(honor.get("loser_honor", 0))]
			)
		)


func _apply_bg_leave(peer_id: int, r: Dictionary) -> void:
	if r.has("left"):
		_bg_return(peer_id, r["entry"])
	if r.has("ended"):
		_finish_bg(r["ended"])


# Back to the open world at the position they queued from.
func _bg_return(peer_id: int, entry) -> void:
	PlayerSessions.set_instance(peer_id, 0)
	PlayerSessions.update_position(peer_id, entry)


# T-413: where a Crownfield death respawns (2026-07-16 owner ruling — real deaths, in-arena
# respawn). main._handle_player_respawn calls this BEFORE the ordinary instance/graveyard rule:
# a live BG member is sent to their TEAM SPAWN inside the arena (dying keeps them in the match),
# everyone else gets {} and falls through to the normal respawn point.
func bg_respawn_point(peer_id: int) -> Dictionary:
	return _bg.respawn_spawn(peer_id)


# One line to every live member of a match's instance bucket (control flips / score calls).
func _bg_relay_match(iid: int, line: String) -> void:
	var positions: Dictionary = PlayerSessions.get_positions()
	for pid in positions:
		if int(positions[pid].get("instance_id", 0)) == iid:
			_duel_line(int(pid), line)


# ---- shared plumbing --------------------------------------------------------


func _item_registry() -> Dictionary:
	# world_rpc is the content authority but sits AT the gdlint file cap, so no public accessor
	# fits there today — read its registry store directly (same-process seam, documented debt).
	if _world_rpc == null:
		return {}
	return _CQ.item_registry(_world_rpc._content_items)


func _allow(peer_id: int, now_msec: int) -> bool:
	var w: Dictionary = _windows.get(peer_id, {"start": now_msec, "count": 0})
	if now_msec - int(w["start"]) >= OP_WINDOW_MS:
		w = {"start": now_msec, "count": 0}
	if int(w["count"]) >= OP_MAX:
		_windows[peer_id] = w
		return false
	w["count"] = int(w["count"]) + 1
	_windows[peer_id] = w
	return true
