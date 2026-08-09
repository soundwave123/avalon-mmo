extends Node
# T-382: a FORGED ENet peer — the integration half of the adversarial net. Unlike the trusted
# `client_net.gd`/pilot, this is a raw client that completes a REAL session handshake and then sends
# the intents a cheat client would, driving them through the world's actual `_receive_message`
# dispatch + the master round-trip (not the pure authority units in test_adversarial_client.gd). It
# asserts nothing itself — it records what the SERVER did (rejections, rate-limits, a kick) into a
# JSON result the shell harness (scripts/test-adversarial-e2e.sh) reads and gates on.
#
# Env (Flatpak arg-passing workaround — same convention as test_client.gd):
#   AVALON_HOST / AVALON_PORT        — world server (default 127.0.0.1:9200)
#   AVALON_TOKEN                     — a valid session token (JWT); master must validate it
#   AVALON_RESULT_FILE              — where to write the JSON verdict
#   AVALON_FORGE_TARGET             — a mob entity id to forge a hit against (default 1001)
#   AVALON_FLOOD_COUNT             — how many get_inventory intents to flood (default 400)
#
# Exit 0 always; the harness judges the result file. A crash/timeout leaves no file → harness fails.

var _host: String = "127.0.0.1"
var _port: int = 9200
var _token: String = ""
var _result_file: String = ""
var _forge_target: int = 1001
var _flood_count: int = 400

var _enet: ENetMultiplayerPeer
var _my_peer_id: int = 0
var _handshake_ok: bool = false
var _handshake_sent: bool = false
var _phase: int = 0  # 0 pre-handshake, 1 forge combat, 2 forge grants, 3 flood, 4 settle, 5 done
var _elapsed: float = 0.0
var _phase_timer: float = 0.0
var _flood_sent: int = 0

# What the SERVER told us — the evidence the harness gates on.
var _ability_rejections: Array = []  # reasons the server rejected forged casts
var _intent_rejections: int = 0  # `intent_rejected` (rate_limited) responses to the flood
var _self_grant_replies: int = 0  # any reply at all to a forged grant intent (must stay 0)
var _server_disconnected: bool = false
var _finished: bool = false


func _ready() -> void:
	_parse_env()
	if _token.is_empty():
		_finish("no token provided")
		return
	_enet = ENetMultiplayerPeer.new()
	var err := _enet.create_client(_host, _port)
	if err != OK:
		_finish("failed to create ENet client (err=%d)" % err)
		return
	get_tree().get_multiplayer().set_multiplayer_peer(_enet)
	get_tree().get_multiplayer().connected_to_server.connect(_on_connected)
	get_tree().get_multiplayer().connection_failed.connect(
		func() -> void: _finish("connect_failed")
	)
	get_tree().get_multiplayer().server_disconnected.connect(_on_server_disconnected)
	set_process(true)


func _parse_env() -> void:
	var h := OS.get_environment("AVALON_HOST")
	if h != "":
		_host = h
	var p := OS.get_environment("AVALON_PORT")
	if p != "":
		_port = int(p)
	_token = OS.get_environment("AVALON_TOKEN")
	_result_file = OS.get_environment("AVALON_RESULT_FILE")
	var t := OS.get_environment("AVALON_FORGE_TARGET")
	if t != "":
		_forge_target = int(t)
	var f := OS.get_environment("AVALON_FLOOD_COUNT")
	if f != "":
		_flood_count = int(f)


func _on_connected() -> void:
	_my_peer_id = get_tree().get_multiplayer().get_unique_id()
	print("[adv-peer] connected peer_id=%d" % _my_peer_id)


func _on_server_disconnected() -> void:
	# Being kicked mid-flood is the EXPECTED win — the server threw the flooder off.
	_server_disconnected = true
	if _phase >= 3 and not _finished:
		_finish("")


func _process(delta: float) -> void:
	_elapsed += delta
	_phase_timer += delta
	if _elapsed > 30.0 and not _finished:
		_finish("timeout")
		return

	# Send the handshake once the ENet link is up.
	if _my_peer_id != 0 and not _handshake_sent:
		_handshake_sent = true
		_receive_message.rpc({"type": "session", "token": _token})
		return
	if not _handshake_ok:
		return

	match _phase:
		1:
			# Forge combat: an out-of-range hit + rapid dup-target spam on a real mob. The caster
			# spawns at origin; the mob sits far off at its spawn, so the server must reject the cast
			# out of range — the client's "I hit them" claim is never trusted.
			_receive_message.rpc_id(
				1, {"type": "use_ability", "ability_id": 1, "target_id": _forge_target}
			)
			if _phase_timer > 1.0:
				_advance(2)
		2:
			# Forge self-grant: verbs that would grant loot/coin/kill-credit if the server trusted
			# the wire. They are NOT in any inbound allow-list, so the world must ignore them (no
			# reply, no state change). Any reply here is a boundary breach.
			for verb in ["grant_loot", "credit_kill", "adjust_coins", "carry_gear"]:
				_receive_message.rpc_id(1, {"type": verb, "amount": 9999, "item_id": "itm_gold"})
			if _phase_timer > 0.5:
				_advance(3)
		3:
			# Flood the cheapest master-round-trip intent as fast as the tick allows. The per-peer
			# budget must throttle it (intent_rejected: rate_limited) then disconnect us.
			for _i in range(20):
				if _flood_sent >= _flood_count:
					break
				_receive_message.rpc_id(1, {"type": "get_inventory"})
				_flood_sent += 1
			if _flood_sent >= _flood_count and _phase_timer > 0.5:
				_advance(4)
		4:
			# Settle — give the server a moment to deliver the final rejections / the kick.
			if _phase_timer > 2.0:
				_finish("")


func _advance(next_phase: int) -> void:
	_phase = next_phase
	_phase_timer = 0.0


# The server pushes replies via _receive_client_message; it also broadcasts via _receive_message.
@rpc("any_peer", "reliable")
func _receive_message(data: Dictionary, _mirror: bool = false) -> void:
	_handle_server_msg(data)


@rpc("any_peer", "reliable")
func _receive_client_message(data: Dictionary, _mirror: bool = false) -> void:
	_handle_server_msg(data)


func _handle_server_msg(data: Dictionary) -> void:
	var t := str(data.get("type", ""))
	if t == "handshake_ok":
		if not _handshake_ok:
			_handshake_ok = true
			_advance(1)
			print("[adv-peer] handshake_ok — beginning forgeries")
	elif t == "ability_rejected":
		_ability_rejections.append(str(data.get("reason", "")))
	elif t == "intent_rejected":
		if str(data.get("reason", "")) == "rate_limited":
			_intent_rejections += 1
	elif t in ["grant_loot", "credit_kill", "adjust_coins", "carry_gear", "loot_granted"]:
		# A forged-grant verb echoed back to us = the server acted on it. Must never happen.
		_self_grant_replies += 1


func _finish(err: String) -> void:
	if _finished:
		return
	_finished = true
	set_process(false)
	var saw_range_reject := "out_of_range" in _ability_rejections
	var pass_test := (
		err == ""
		and _handshake_ok
		and saw_range_reject
		and _intent_rejections > 0
		and _server_disconnected
		and _self_grant_replies == 0
	)
	var result := {
		"pass": pass_test,
		"error": err,
		"handshake_ok": _handshake_ok,
		"ability_rejections": _ability_rejections,
		"saw_out_of_range_reject": saw_range_reject,
		"intent_rate_limited": _intent_rejections,
		"self_grant_replies": _self_grant_replies,
		"server_disconnected": _server_disconnected,
		"flood_sent": _flood_sent,
	}
	if _result_file != "":
		var file := FileAccess.open(_result_file, FileAccess.WRITE)
		if file != null:
			file.store_string(JSON.stringify(result))
			file.close()
	print("[adv-peer] result: %s" % JSON.stringify(result))
	get_tree().quit(0 if pass_test else 1)
