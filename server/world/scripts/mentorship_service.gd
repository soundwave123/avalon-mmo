# T-452: live coordinator around the pure mentorship policy. The client sends a toggle desire;
# payload fields are ignored and ceiling/stats/reward level derive from server truth.
extends RefCounted

const _SYNC = preload("res://scripts/combat/mentorship_sync.gd")
const _PL = preload("res://scripts/party_logic.gd")
const _RL = preload("res://scripts/raid_logic.gd")  # T-472: raid promotion/subgroup/assist/kick
const _TEF = preload("res://scripts/combat/talent_effects.gd")
const _CSTATS = preload("res://scripts/combat/character_stats.gd")
const _CR = preload("res://scripts/combat/combat_resources.gd")
const PlayerSessions = preload("res://scripts/player_sessions.gd")

var _party_store: Dictionary = {}
var _true_levels: Dictionary = {}  # shared main._char_level reference
var _effective_levels: Dictionary = {}  # shared combat/aggro rank-level view
var _apply: Callable = Callable()  # main._apply_combat_stats with authoritative cached inputs
var _reply: Callable = Callable()
var _opted_in: Dictionary = {}  # peer -> true (session-local opt-in; never client-authored state)
var _truth: Dictionary = {}  # peer -> {class, stats, talents, level}, all sourced from master
var _live: Dictionary = {}  # bound main stores: stats/classes/mods/resources
var _talent_defs: Callable = Callable()
var _send_kit: Callable = Callable()


func setup(
	party_store: Dictionary,
	true_levels: Dictionary,
	apply: Callable,
	reply: Callable,
	live_stores: Array = [],
	talent_defs: Callable = Callable(),
	send_kit: Callable = Callable(),
	effective_levels: Dictionary = {}
) -> void:
	_party_store = party_store
	_true_levels = true_levels
	_apply = apply
	_reply = reply
	if live_stores.size() == 4:
		_live = {
			"stats": live_stores[0],
			"classes": live_stores[1],
			"mods": live_stores[2],
			"resources": live_stores[3],
		}
	_talent_defs = talent_defs
	_send_kit = send_kit
	_effective_levels = effective_levels


# Apply the authoritative payload through the cap before any combat consumer sees it. This is the
# T-061/T-399 body carved out of capped main.gd; bound dictionaries remain main's live authority.
func apply_authoritative(
	peer: int,
	char_class: String,
	stats: Dictionary,
	talents: Dictionary,
	true_level: int,
	preserve: bool = false
) -> void:
	var effective := record_authoritative(peer, char_class, stats, talents, true_level)
	if _live.is_empty():
		return
	var defs: Dictionary = _talent_defs.call() if _talent_defs.is_valid() else {}
	var effective_talents := talents if reward_level(peer) >= true_level else {}
	_live["mods"][peer] = _TEF.ability_mods(effective_talents, defs)
	var previous_class := str(_live["classes"].get(peer, ""))
	if previous_class != "" and previous_class != char_class and _send_kit.is_valid():
		_send_kit.call(peer, char_class)
	var converted := _CSTATS.from_stat_vec(effective)
	_live["stats"][peer] = converted
	_live["classes"][peer] = char_class
	var resources := _CR.new()
	resources.derive_from_stats(converted)
	resources.set_class_resource(char_class, converted.int_val)
	if preserve:
		resources = preserve_resources(_live["resources"].get(peer), resources)
	_live["resources"][peer] = resources


# Record a master-authoritative stat payload and return the effective (possibly capped) COPY.
func record_authoritative(
	peer: int, char_class: String, stats: Dictionary, talents: Dictionary, true_level: int
) -> Dictionary:
	var level := maxi(1, true_level)
	_true_levels[peer] = level
	_truth[peer] = {
		"class": char_class,
		"stats": stats.duplicate(true),
		"talents": talents.duplicate(true),
		"level": level,
	}
	var effective_level := reward_level(peer)
	_effective_levels[peer] = effective_level
	return _SYNC.scale_stats(stats, level, effective_level)


# Toggle is the entire client desire. `_untrusted` is deliberately unused: a forged level, cap,
# role, or stat block cannot influence the calculation.
func toggle(peer: int, _untrusted: Dictionary = {}) -> Dictionary:
	var party_of: Dictionary = _party_store.get("party_of", {})
	if not party_of.has(peer):
		_send_status(peer, false, "not_in_party")
		return {"ok": false, "reason": "not_in_party"}
	if _opted_in.has(peer):
		_opted_in.erase(peer)
		_reapply(peer)
		_send_status(peer, true, "")
		return {"ok": true, "reason": ""}
	_opted_in[peer] = true
	if reward_level(peer) >= int(_true_levels.get(peer, 1)):
		_opted_in.erase(peer)
		_send_status(peer, false, "no_lower_party_member")
		return {"ok": false, "reason": "no_lower_party_member"}
	_reapply(peer)
	_send_status(peer, true, "")
	return {"ok": true, "reason": ""}


# T-643 (portal #90): the client's OWN stat sheet (player_stats push) used to always carry
# master's raw truth — T-588's "repush on any XP grant" fires on nearly every kill, so an opted-in
# mentor's displayed str/attack/etc silently reverted to full power the instant any kill granted
# XP, even mid-sync. Combat is otherwise unaffected: this only reshapes what a SYNCED peer is shown
# (world_rpc._repush_combat_stats); `_char_stats`/damage already read the capped vector via
# apply_authoritative, same seam max_hp uses.
func display_combat(peer: int, combat: Dictionary) -> Dictionary:
	if not _opted_in.has(peer):
		return combat
	var true_level: int = maxi(1, int(combat.get("level", 1)))
	var ceiling := reward_level(peer)
	var out := combat.duplicate(true)
	out["stats"] = _SYNC.scale_stats(combat.get("stats", {}), true_level, ceiling)
	out["level"] = mini(ceiling, true_level)
	return out


func reward_level(peer: int) -> int:
	return _SYNC.ceiling_for(peer, _party_store, _true_levels, _opted_in)


# T-481: server-held observation for an adjudicated content completion. No packet field enters it.
func credit_context(peer: int) -> Dictionary:
	return {"opted_in": _opted_in.has(peer), "effective_level": reward_level(peer)}


# T-280 party coordinator, carved from capped world_rpc.gd. T-452's toggle is one more desire in
# the same surface, so roster mutations and sync refreshes happen atomically in one owner.
func handle_party(msg_type: String, peer: int, player: Dictionary, data: Dictionary) -> void:
	var result := {"ok": false, "reason": "bad_intent"}
	match msg_type:
		"party_invite":
			var target := _peer_for_username(str(data.get("target", "")))
			if target == -1:
				result = {"ok": false, "reason": "player_not_found"}
			else:
				# T-736: username pair key — the decline cooldown must survive a relog (peer ids
				# are session-scoped); expiry/cooldowns ride the injected monotonic clock.
				var pair := "%s>%s" % [str(player.get("username", "")), str(data.get("target", ""))]
				result = _PL.invite(_party_store, peer, target, Time.get_ticks_msec(), pair)
				if result.get("ok", false):
					(
						_reply
						. call(
							target,
							{
								"type": "party_invite",
								"from": str(player.get("username", "")),
								"ttl_ms": _PL.INVITE_TTL_MS,  # T-736: drives the modal countdown
							}
						)
					)
		"party_accept":
			result = _PL.accept(_party_store, peer, Time.get_ticks_msec())
			if result.get("ok", false):
				var joined := _members_of(int(result.get("party_id", -1)))
				_notify_members(joined)
		"party_decline":
			result = _PL.decline(_party_store, peer, Time.get_ticks_msec())
		"party_leave":
			var affected := _members_of(int(_party_store["party_of"].get(peer, -1)))
			result = _PL.leave(_party_store, peer)
			_notify_members(affected)
		"party_disband":
			var affected := _members_of(int(_party_store["party_of"].get(peer, -1)))
			result = _PL.disband(_party_store, peer)
			if result.get("ok", false):
				_notify_members(affected)
		"party_mentor_sync":
			result = toggle(peer, data)
		"raid_convert", "raid_set_group", "raid_set_assist", "raid_kick":
			# Snapshot the roster BEFORE a kick so the removed peer still gets the clearing push.
			var raid_affected := _members_of(int(_party_store["party_of"].get(peer, -1)))
			result = _handle_raid(msg_type, peer, data)
			if result.get("ok", false):
				_notify_members(raid_affected)
	(
		_reply
		. call(
			peer,
			{
				"type": "party_result",
				"intent": msg_type,
				"ok": result.get("ok", false),
				"reason": result.get("reason", ""),
			}
		)
	)


# T-472: raid desires — every mutation is validated in pure raid_logic against the server-owned
# store; the target is resolved by username server-side (a forged peer_id field is never read).
func _handle_raid(msg_type: String, peer: int, data: Dictionary) -> Dictionary:
	if msg_type == "raid_convert":
		return _RL.convert(_party_store, peer)
	var target := _peer_for_username(str(data.get("target", "")))
	if target == -1:
		return {"ok": false, "reason": "player_not_found"}
	match msg_type:
		"raid_set_group":
			return _RL.set_subgroup(_party_store, peer, target, int(data.get("group", -1)))
		"raid_set_assist":
			return _RL.set_assist(_party_store, peer, target, bool(data.get("enabled", true)))
		"raid_kick":
			return _RL.kick(_party_store, peer, target)
	return {"ok": false, "reason": "bad_intent"}


func refresh_party_for(peer: int) -> void:
	party_changed(_members_of(int(_party_store.get("party_of", {}).get(peer, -1))))


# T-473: the LIVE party record (by ref) for the first partied peer in `peers` — world_rpc's dungeon
# loot path reads the T-472 loot_rule/loot_cursor off it. Empty Dictionary for solo recipients.
func party_record_for(peers: Array) -> Dictionary:
	var party_of: Dictionary = _party_store.get("party_of", {})
	for peer in peers:
		var pid := int(party_of.get(int(peer), -1))
		if pid != -1:
			return _party_store.get("parties", {}).get(pid, {})
	return {}


# T-644 (portal #89): other members of `peer`'s party (excluding peer) — the kill-loot fallback
# candidate order when the top-threat killer's bag is full. Empty for a solo peer.
func party_peers_of(peer: int) -> Array:
	var pid := int(_party_store.get("party_of", {}).get(peer, -1))
	if pid == -1:
		return []
	var members: Array = _members_of(pid)
	members.erase(peer)
	return members


# Party membership changes restore leavers immediately and recompute remaining opted-in mentors.
func party_changed(peers: Array) -> void:
	for member in peers:
		var peer := int(member)
		if not _party_store.get("party_of", {}).has(peer):
			_opted_in.erase(peer)
		_reapply(peer)


# Disconnect owns the same cleanup mutation as T-280, plus effective-stat restoration for survivors.
func peer_gone(peer: int) -> void:
	var pid := int(_party_store.get("party_of", {}).get(peer, -1))
	var affected: Array = (
		_party_store.get("parties", {}).get(pid, {}).get("members", []).duplicate()
	)
	_PL.leave(_party_store, peer)
	_opted_in.erase(peer)
	_truth.erase(peer)
	_true_levels.erase(peer)
	_effective_levels.erase(peer)
	party_changed(affected)
	# T-654 (#88): every OTHER exit (party_leave/party_disband/raid_kick in handle_party above)
	# pushes a party_update to the survivors; a disconnect never did, so the remaining member's
	# client roster kept rendering the gone peer as a permanent ghost frame until relog. `affected`
	# was snapshotted before _PL.leave() and still contains the disconnecting peer — drop it before
	# notifying so we don't RPC an already-closed connection.
	var survivors := affected.duplicate()
	survivors.erase(peer)
	if not survivors.is_empty():
		_notify_members(survivors)


# A sync toggle must not heal/refill the mentor. Preserve each current pool percentage while the
# effective maximum changes; class-resource/timer state is likewise carried and capped.
func preserve_resources(previous, derived):
	if previous == null:
		return derived
	derived.hp = _scaled_current(previous.hp, previous.max_hp, derived.max_hp)
	derived.mana = _scaled_current(previous.mana, previous.max_mana, derived.max_mana)
	derived.stamina = _scaled_current(previous.stamina, previous.max_stamina, derived.max_stamina)
	derived.rage = mini(previous.rage, derived.max_rage)
	derived.last_spend_tick = previous.last_spend_tick
	derived.last_combat_tick = previous.last_combat_tick
	return derived


func _reapply(peer: int) -> void:
	if not _apply.is_valid() or not _truth.has(peer):
		return
	var truth: Dictionary = _truth[peer]
	_apply.call(peer, truth["class"], truth["stats"], truth["talents"], truth["level"], true)


func _scaled_current(current: int, old_max: int, new_max: int) -> int:
	if old_max <= 0:
		return 0
	return clampi(int(round(float(current) * float(new_max) / float(old_max))), 0, new_max)


func _peer_for_username(name: String) -> int:
	for peer in PlayerSessions.get_positions():
		if str(PlayerSessions.get_positions()[peer].get("username", "")) == name:
			return int(peer)
	return -1


func _members_of(party_id: int) -> Array:
	var party: Dictionary = _party_store.get("parties", {}).get(party_id, {})
	return party.get("members", []).duplicate()


func _notify_members(peers: Array) -> void:
	for member in peers:
		var peer := int(member)
		var pid := int(_party_store.get("party_of", {}).get(peer, -1))
		var party: Dictionary = _party_store.get("parties", {}).get(pid, {})
		var names := []
		for roster_peer in party.get("members", []):
			names.append(_username_of(int(roster_peer)))
		var msg := {
			"type": "party_update",
			"members": names,
			"leader": _username_of(int(party.get("leader", -1))),
		}
		if party.has("subgroup"):  # T-472: raid extras (username-keyed for the client frames)
			msg["raid"] = true
			var subgroups := {}
			for roster_peer in party.get("members", []):
				var seat := int(roster_peer)
				subgroups[_username_of(seat)] = int(party["subgroup"].get(seat, 0))
			msg["subgroups"] = subgroups
			var assists := []
			for assist_peer in party.get("assists", []):
				assists.append(_username_of(int(assist_peer)))
			msg["assists"] = assists
		_reply.call(peer, msg)
	party_changed(peers)


func _username_of(peer: int) -> String:
	return str(PlayerSessions.get_player(peer).get("username", ""))


func _send_status(peer: int, ok: bool, reason: String) -> void:
	if not _reply.is_valid():
		return
	var true_level := int(_true_levels.get(peer, 1))
	var effective_level := reward_level(peer)
	(
		_reply
		. call(
			peer,
			{
				"type": "mentor_sync_status",
				"ok": ok,
				"reason": reason,
				"enabled": _opted_in.has(peer) and effective_level < true_level,
				"true_level": true_level,
				"effective_level": effective_level,
			}
		)
	)
