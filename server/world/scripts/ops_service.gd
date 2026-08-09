class_name OpsService
extends RefCounted

# T-511 world-authoritative GM operations. The browser can only express an operator desire; player
# identity, class, level, location and group membership all come from live server stores.
const PlayerSessions = preload("res://scripts/player_sessions.gd")
const Countdown = preload("res://scripts/maintenance_countdown.gd")
const Discovery = preload("res://scripts/social_discovery.gd")

const ACTIONS := ["who", "announce", "broadcast", "msg_group", "whisper", "kick", "ban"]
const MAX_TEXT := 1000
const MAX_REASON := 256

var _send: Callable
var _disconnect: Callable
var _master_call: Callable
var _party_store: Dictionary
var _classes: Dictionary
var _levels: Dictionary
var _guilds: Dictionary
var _countdown := Countdown.new()


func setup(
	send: Callable,
	disconnect: Callable,
	master_call: Callable,
	party_store: Dictionary,
	classes: Dictionary,
	levels: Dictionary,
	guilds: Dictionary
) -> void:
	_send = send
	_disconnect = disconnect
	_master_call = master_call
	_party_store = party_store
	_classes = classes
	_levels = levels
	_guilds = guilds


func handle(actor: String, verb: String, params: Dictionary, now_unix: float) -> Dictionary:
	var outcome: Dictionary
	if verb == "audit_tail":
		outcome = await _audit_tail(params)
	elif verb == "first_session_funnel":  # T-528: read-only onramp funnel (no audit write)
		outcome = await _funnel(params)
	elif not ACTIONS.has(verb):
		outcome = {"ok": false, "error": "unknown_verb"}
	else:
		var validated := _validate(verb, params)
		if not bool(validated.get("ok", false)):
			outcome = validated
		else:
			var clean: Dictionary = validated["params"]
			var audit_params := {
				"actor": actor,
				"action": verb,
				"target": _target_for(verb, clean),
				"reason": str(clean.get("reason", "")),
				"details": clean,
			}
			var audit: Dictionary = await _master_call.call("ops_apply", audit_params)
			if not bool(audit.get("ok", false)):
				outcome = {"ok": false, "error": str(audit.get("error", "audit_failed"))}
			else:
				outcome = _execute(verb, clean, audit, now_unix)
	return outcome


func _execute(verb: String, clean: Dictionary, audit: Dictionary, now_unix: float) -> Dictionary:
	var outcome := {"ok": true, "result": {"audit_id": int(audit.get("audit_id", 0))}}
	match verb:
		"who":
			outcome = {"ok": true, "result": {"players": _who(now_unix)}}
		"announce":
			_broadcast_payload(_countdown.start(int(clean["minutes"]), str(clean["reason"])))
			outcome = {"ok": true, "result": {"countdown": _countdown.current_notice()}}
		"broadcast":
			_send_many(PlayerSessions.list_players().keys(), _gm_payload(str(clean["text"])))
		"msg_group":
			var peers := _group_members(str(clean["kind"]), int(clean["id"]))
			if peers.is_empty():
				outcome = {"ok": false, "error": "group_not_found"}
			else:
				_send_many(peers, _gm_payload(str(clean["text"]), "group"))
		"whisper":
			var peer_id := _peer_for_name(str(clean["player"]))
			if peer_id < 0:
				outcome = {"ok": false, "error": "player_not_online"}
			else:
				_send.call(peer_id, _gm_payload(str(clean["text"]), "whisper"))
		"kick", "ban":
			var peer_id := _peer_for_name(str(clean["player"]))
			if verb == "ban" and not bool(audit.get("account_exists", false)):
				outcome = {"ok": false, "error": "account_not_found"}
			elif peer_id < 0:
				outcome = {"ok": false, "error": "player_not_online"}
			else:
				(
					_send
					. call(
						peer_id,
						{
							"type": "kicked",
							"reason": str(clean["reason"]),
							"banned": verb == "ban",
						}
					)
				)
				_disconnect.call(peer_id)
	return outcome


func tick(delta_seconds: float) -> void:
	for notice: Dictionary in _countdown.advance(delta_seconds):
		_broadcast_payload(notice)


func on_login(peer_id: int) -> void:
	var notice := _countdown.current_notice()
	if not notice.is_empty():
		_send.call(peer_id, notice)


func _audit_tail(params: Dictionary) -> Dictionary:
	var result: Dictionary = await _master_call.call(
		"ops_tail", {"limit": clampi(int(params.get("limit", 50)), 1, 200)}
	)
	if not bool(result.get("ok", false)):
		return {"ok": false, "error": str(result.get("error", "audit_unavailable"))}
	return {"ok": true, "result": {"rows": result.get("rows", [])}}


# T-528: delegate the first-session funnel rollup to the master (single telemetry reader). Read-only
# — no ops.audit_log row, mirroring _audit_tail. The master runs the pure aggregation over T-186.
func _funnel(params: Dictionary) -> Dictionary:
	var days := clampi(int(params.get("days", 14)), 1, 90)
	var result: Dictionary = await _master_call.call("first_session_funnel", {"days": days})
	if not bool(result.get("ok", false)):
		return {"ok": false, "error": str(result.get("error", "funnel_unavailable"))}
	return {"ok": true, "result": result.get("result", {})}


func _validate(verb: String, params: Dictionary) -> Dictionary:
	var clean := params.duplicate(true)
	if verb == "announce":
		var minutes := int(params.get("minutes", 0))
		var reason := _clean(str(params.get("reason", "")), MAX_REASON)
		if minutes < 1 or minutes > 1440 or reason == "":
			return {"ok": false, "error": "invalid_announcement"}
		clean = {"minutes": minutes, "reason": reason}
	elif verb in ["broadcast", "whisper", "msg_group"]:
		var text := _clean(str(params.get("text", "")), MAX_TEXT)
		if text == "":
			return {"ok": false, "error": "empty_message"}
		clean["text"] = text
	if verb in ["whisper", "kick", "ban"]:
		var player := _clean(str(params.get("player", "")), 64)
		if player == "":
			return {"ok": false, "error": "missing_player"}
		clean["player"] = player
	if verb in ["kick", "ban"]:
		var reason := _clean(str(params.get("reason", "")), MAX_REASON)
		if reason == "":
			return {"ok": false, "error": "missing_reason"}
		clean["reason"] = reason
	if verb == "msg_group":
		var kind := str(params.get("kind", ""))
		var group_id := int(params.get("id", 0))
		if not kind in ["party", "guild", "raid"] or group_id <= 0:
			return {"ok": false, "error": "invalid_group"}
		clean["kind"] = kind
		clean["id"] = group_id
	return {"ok": true, "params": clean}


func _who(now_unix: float) -> Array:
	var sessions := PlayerSessions.list_players()
	var positions := PlayerSessions.get_positions()
	var peers: Array = sessions.keys()
	peers.sort()
	var rows: Array = []
	for value in peers:
		var peer_id := int(value)
		var session: Dictionary = sessions[peer_id]
		var pos: Dictionary = positions.get(peer_id, {})
		(
			rows
			. append(
				{
					"name": str(session.get("username", "")),
					"class": str(_classes.get(peer_id, "")),
					"level": int(_levels.get(peer_id, 1)),
					"zone": Discovery.zone_for(pos),
					"pos":
					{
						"x": float(pos.get("x", 0.0)),
						"y": float(pos.get("y", 0.0)),
						"z": float(pos.get("z", 0.0)),
					},
					"session_age_seconds":
					maxi(int(now_unix - float(session.get("connected_at", now_unix))), 0),
					"peer_id": peer_id,
				}
			)
		)
	return rows


func _group_members(kind: String, group_id: int) -> Array:
	var out: Array = []
	if kind == "guild":
		for peer_id in _guilds:
			if int(_guilds[peer_id]) == group_id and PlayerSessions.get_player(int(peer_id)) != {}:
				out.append(int(peer_id))
		return out
	var party: Dictionary = _party_store.get("parties", {}).get(group_id, {})
	if party.is_empty() or (kind == "raid" and not party.has("subgroup")):
		return out
	for peer_id in party.get("members", []):
		if not PlayerSessions.get_player(int(peer_id)).is_empty():
			out.append(int(peer_id))
	return out


func _peer_for_name(player_name: String) -> int:
	for peer_id in PlayerSessions.list_players():
		var username := str(PlayerSessions.get_player(int(peer_id)).get("username", ""))
		if username.to_lower() == player_name.to_lower():
			return int(peer_id)
	return -1


func _broadcast_payload(payload: Dictionary) -> void:
	_send_many(PlayerSessions.list_players().keys(), payload)


func _send_many(peer_ids: Array, payload: Dictionary) -> void:
	var sorted := peer_ids.duplicate()
	sorted.sort()
	for peer_id in sorted:
		_send.call(int(peer_id), payload)


func _gm_payload(text: String, channel: String = "system") -> Dictionary:
	return {"type": "chat", "channel": channel, "from": "Game Master", "text": text, "gm": true}


func _target_for(verb: String, params: Dictionary) -> String:
	if verb == "msg_group":
		return "%s:%d" % [str(params.get("kind", "")), int(params.get("id", 0))]
	if verb in ["whisper", "kick", "ban"]:
		return str(params.get("player", ""))
	if verb in ["announce", "broadcast"]:
		return "all"
	return ""


func _clean(value: String, limit: int) -> String:
	return value.replace("\n", " ").replace("\r", " ").strip_edges().left(limit)
