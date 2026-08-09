extends RefCounted

# T-480 carve: the T-064/T-065 talent + class-selection handlers, moved verbatim out of
# world_rpc.gd at its 1000-line cap (the daily_service / npc_indicator_view precedent). The
# behavior is unchanged: master validates + persists every spend/lock; this seam only routes.
# world_rpc injects itself (weakly) so the stat-repush / gear-broadcast seams stay single-owner.

const _BB = preload("res://scripts/broadcast_builder.gd")  # T-225: gear derivation
const _PS = preload("res://scripts/player_sessions.gd")  # T-716: session identity rename

# T-064/T-065 spend/request/class; T-508 adds the respec (reroll_talents) route; T-716 set_name.
const INTENTS := [
	"spend_talent",
	"request_talents",
	"set_class",
	"reroll_talents",
	"set_gender",
	"set_name",
]

# WEAK ref on purpose: world_rpc owns this service, so a strong back-ref would be a RefCounted
# cycle — neither side would ever free, and a replaced world_rpc's in-flight fire-and-forget
# coroutines would outlive it and reply into the next instance's world (caught by TD-002 tests).
var _rpc_ref: WeakRef = null


func setup(rpc) -> void:
	_rpc_ref = weakref(rpc)


func handles(msg_type: String) -> bool:
	return INTENTS.has(msg_type)


func handle(msg_type: String, peer_id: int, player: Dictionary, data: Dictionary) -> void:
	var rpc = _rpc_ref.get_ref() if _rpc_ref != null else null
	if rpc == null:  # host already torn down — nothing to route to
		return
	match msg_type:
		"spend_talent":
			await _spend_talent(rpc, peer_id, player, data)
		"request_talents":
			await _request_talents(rpc, peer_id, player)
		"set_class":
			await _set_class(rpc, peer_id, player, data)
		"set_gender":
			await _set_gender(rpc, peer_id, player, data)
		"set_name":
			await _set_name(rpc, peer_id, player, data)
		"reroll_talents":
			await _reroll_talents(rpc, peer_id, player)


func _spend_talent(rpc, peer_id: int, player: Dictionary, data: Dictionary) -> void:
	var talent_id: String = str(data.get("talent_id", ""))
	if not rpc._content_talents.has(talent_id):
		(
			rpc
			. _reply
			. call(
				peer_id,
				{
					"type": "spend_talent_result",
					"talent_id": talent_id,
					"ok": false,
					"reason": "unknown_talent",
				}
			)
		)
		return
	var result: Dictionary = await (
		rpc
		. _master
		. call_master(
			"spend_talent",
			{
				"username": player.get("username", ""),
				"talent": rpc._content_talents[talent_id],
				"talent_defs": rpc._content_talents,
			}
		)
	)
	(
		rpc
		. _reply
		. call(
			peer_id,
			{
				"type": "spend_talent_result",
				"talent_id": talent_id,
				"ok": result.get("ok", false),
				"reason": result.get("reason", ""),
				"ranks": result.get("ranks", 0),
				"points_left": result.get("points_left", 0),
			}
		)
	)
	# A successful spend changes the combat profile — re-derive live stats + sheet (T-061/T-399).
	if bool(result.get("ok", false)):
		await rpc._repush_combat_stats(peer_id, str(player.get("username", "")))


func _request_talents(rpc, peer_id: int, player: Dictionary) -> void:
	var result: Dictionary = await rpc._master.call_master(
		"get_talents", {"username": player.get("username", "")}
	)
	(
		rpc
		. _reply
		. call(
			peer_id,
			{
				"type": "talents",
				"talents": result.get("talents", {}),
				"points_available": result.get("points_available", 0),
				"points_spent": result.get("points_spent", 0),
				# T-065: the class's tree defs (display metadata — server still gates spends).
				"defs": _class_talent_defs(rpc, str(result.get("class", ""))),
			}
		)
	)


# T-508: respec — master wipes every spent point wholesale; we then re-send authoritative talent
# state (so the panel re-renders cleared with a full budget) and re-derive combat stats, since a
# wiped build changes the profile (mirrors the _spend_talent repush).
func _reroll_talents(rpc, peer_id: int, player: Dictionary) -> void:
	var result: Dictionary = await rpc._master.call_master(
		"reroll_talents", {"username": player.get("username", "")}
	)
	# Push the authoritative talent state back regardless of outcome (cleared on success, unchanged
	# on a no-op); the client only ever renders server truth.
	await _request_talents(rpc, peer_id, player)
	if bool(result.get("ok", false)):
		await rpc._repush_combat_stats(peer_id, str(player.get("username", "")))


# T-065: the display-facing talent defs for one class, ordered tree -> tier.
func _class_talent_defs(rpc, char_class: String) -> Array:
	var out: Array = []
	for talent_id in rpc._content_talents:
		var tal: Dictionary = rpc._content_talents[talent_id]
		if str(tal.get("class", "")) == char_class:
			out.append(tal)
	out.sort_custom(
		func(a, b):
			if str(a.get("tree", "")) != str(b.get("tree", "")):
				return str(a.get("tree", "")) < str(b.get("tree", ""))
			return int(a.get("tier", 0)) < int(b.get("tier", 0))
	)
	return out


# T-065: one-shot class selection — master validates + locks; success refreshes stats/kit (T-061).
func _set_class(rpc, peer_id: int, player: Dictionary, data: Dictionary) -> void:
	var result: Dictionary = await rpc._master.call_master(
		"set_class", {"username": player.get("username", ""), "class": str(data.get("class", ""))}
	)
	(
		rpc
		. _reply
		. call(
			peer_id,
			{
				"type": "set_class_result",
				"ok": result.get("ok", false),
				"reason": result.get("reason", ""),
				"class": result.get("class", ""),
			}
		)
	)
	if not bool(result.get("ok", false)):
		return
	# T-319: the class lock granted a starting weapon — push it into the gear broadcast now.
	if rpc._gear_update.is_valid() and result.has("slots"):
		rpc._gear_update.call(peer_id, _BB.equipped_from_slots(result["slots"]))
	# T-061 seam: re-derive stats/kit live after the class lock; T-399 fold keeps gear in.
	await rpc._repush_combat_stats(peer_id, str(player.get("username", "")))


# T-520: gender selection at character creation, BEFORE class. Master validates + persists it
# one-shot (like set_class). This route only forwards + acks server truth; gender has NO combat/stat
# consequence, so (unlike _set_class) it does NOT repush stats or touch gear. The client shows the
# class panel next off this ack.
func _set_gender(rpc, peer_id: int, player: Dictionary, data: Dictionary) -> void:
	var result: Dictionary = await rpc._master.call_master(
		"set_gender",
		{"username": player.get("username", ""), "gender": str(data.get("gender", ""))}
	)
	(
		rpc
		. _reply
		. call(
			peer_id,
			{
				"type": "set_gender_result",
				"ok": result.get("ok", false),
				"reason": result.get("reason", ""),
				"gender": result.get("gender", ""),
			}
		)
	)


# T-716: the creation NAME step (after class, before the Handbook). Master validates charset,
# length and live-name uniqueness and persists it one-shot.
#
# The rename is the interesting part: `username` on this session IS the character name (T-507), and
# it is the key every later master round-trip addresses (quests, XP, rested, kill credit,
# durability). So a success MUST rebind the live session identity before anything else runs —
# PlayerSessions is the authority, and the kit-refresh seam re-reads it to resync world main's
# display/telemetry cache and push a kit built from the new identity. Failure is a plain ack: the
# client shows the plain-English reason and lets the player type another name.
func _set_name(rpc, peer_id: int, player: Dictionary, data: Dictionary) -> void:
	var previous := str(player.get("username", ""))
	var result: Dictionary = await rpc._master.call_master(
		"set_name", {"username": previous, "name": str(data.get("name", ""))}
	)
	var chosen := str(result.get("name", ""))
	if bool(result.get("ok", false)) and chosen != "":
		_PS.rename_player(peer_id, chosen)
		if rpc._kit_refresh.is_valid():
			await rpc._kit_refresh.call(peer_id)
	(
		rpc
		. _reply
		. call(
			peer_id,
			{
				"type": "set_name_result",
				"ok": result.get("ok", false),
				"reason": result.get("reason", ""),
				"name": chosen,
				"previous_name": previous,
			}
		)
	)
