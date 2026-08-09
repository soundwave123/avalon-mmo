# T-361: pure channel-routing brain for player chat. Given a sender + a positions snapshot + the
# party store, it returns the set of recipient peer_ids for a channel. No I/O, no state, no OS time
# — every recipient decision is a pure function of its inputs, so the routing MATRIX (range cutoff,
# party isolation, instance boundary) is unit-testable headlessly.
#
# Channels:
#   say     — local: same soft-instance (T-331) AND within SAY_RADIUS planar (x,y) of the sender.
#   party   — the sender's party members (T-280), regardless of range/instance (out-of-band voice).
#   guild   — the sender's guildmates (T-362), regardless of range/instance — every online member
#             of the same guild_id (membership truth is master's; the world caches guild_id/peer).
#   world   — every online peer (a global channel; hard-capped by the rate limiter, chat_service).
#   help    — every online peer currently subscribed by server-held preference.
#   whisper — T-626: a targeted 1:1, resolved by exact username match against the online snapshot.
#             No range/instance check — cross-zone by design (WoW convention). yell (zone-wide) was
#             also planned by T-361 but never shipped; still not shipped here (out of this ticket's
#             scope — world chat already covers "reach everyone").
# The sender is always included so they see their own line echoed.

extends RefCounted

# Local-say hearing distance in world units (planar). AOI-shaped, ~30 m — a town-square radius.
const SAY_RADIUS := 30.0

const CHANNELS := ["say", "party", "guild", "world", "help", "whisper"]


static func is_channel(channel: String) -> bool:
	return CHANNELS.has(channel)


# Recipients for a message. `positions` is PlayerSessions.get_positions() shape:
#   peer_id -> {username, x, y, z, instance_id}. `party_of` is party_store["party_of"]
#   (peer_id -> party_id) and `parties` is party_store["parties"] (party_id -> {members,...}).
# Returns an Array[int] of peer_ids (includes the sender when the sender is online).
static func recipients(
	channel: String,
	sender_id: int,
	positions: Dictionary,
	party_of: Dictionary = {},
	parties: Dictionary = {},
	guild_of: Dictionary = {},
	help_subscribers: Dictionary = {},
	whisper_target: String = ""
) -> Array:
	match channel:
		"say":
			return _say_recipients(sender_id, positions)
		"party":
			return _party_recipients(sender_id, party_of, parties)
		"guild":
			return _guild_recipients(sender_id, guild_of)
		"world":
			return positions.keys()
		"help":
			var out: Array = []
			for pid in positions:
				if bool(help_subscribers.get(pid, false)):
					out.append(int(pid))
			return out
		"whisper":
			return _whisper_recipients(sender_id, positions, whisper_target)
		_:
			return []


static func _say_recipients(sender_id: int, positions: Dictionary) -> Array:
	if not positions.has(sender_id):
		return []
	var me: Dictionary = positions[sender_id]
	var my_instance := int(me.get("instance_id", 0))
	var mx := float(me.get("x", 0.0))
	var my := float(me.get("y", 0.0))
	var out: Array = []
	for pid in positions.keys():
		var p: Dictionary = positions[pid]
		# T-331 instance boundary: a shout in a crypt instance never leaks to the open world.
		if int(p.get("instance_id", 0)) != my_instance:
			continue
		var dx := float(p.get("x", 0.0)) - mx
		var dy := float(p.get("y", 0.0)) - my
		if dx * dx + dy * dy <= SAY_RADIUS * SAY_RADIUS:
			out.append(int(pid))
	return out


# guild_of is peer_id -> guild_id (the world's per-peer membership cache; 0/absent = guildless).
# Every online peer sharing the sender's non-zero guild_id hears the line; a guildless sender gets
# an empty set (the caller replies "not_in_guild", mirroring party).
static func _guild_recipients(sender_id: int, guild_of: Dictionary) -> Array:
	var my_guild := int(guild_of.get(sender_id, 0))
	if my_guild == 0:
		return []
	var out: Array = []
	for pid in guild_of.keys():
		if int(guild_of[pid]) == my_guild:
			out.append(int(pid))
	return out


static func _party_recipients(sender_id: int, party_of: Dictionary, parties: Dictionary) -> Array:
	var party_id := int(party_of.get(sender_id, -1))
	if party_id == -1:
		return []  # not in a party — caller replies "not_in_party"
	var party: Dictionary = parties.get(party_id, {})
	var out: Array = []
	for m in party.get("members", []):
		out.append(int(m))
	return out


# T-626: whisper_target is matched by exact username against the online positions snapshot — the
# same case-sensitive exact-match convention already used for /duel's target resolution
# (social_service._validate_duel_target). An empty or unmatched target routes nowhere; the caller
# (chat_service) replies with an explicit "unknown_player" rejection rather than silence. The
# self-whisper guard lives in chat_service (identity/business validation), not here — this stays a
# pure mechanical lookup.
static func _whisper_recipients(
	sender_id: int, positions: Dictionary, whisper_target: String
) -> Array:
	if whisper_target.is_empty() or not positions.has(sender_id):
		return []
	for pid in positions.keys():
		if str(positions[pid].get("username", "")) == whisper_target:
			return [sender_id, int(pid)]
	return []
