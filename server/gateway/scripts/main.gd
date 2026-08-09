extends Node

# Avalon gateway server.
#
# Implements a raw WebSocket server (not WebSocketMultiplayerPeer)
# so we can send/receive plain WebSocket TEXT frames that any client
# — Godot, browser, websocat, anything RFC 6455 compliant — can speak.
# WebSocketMultiplayerPeer adds a Godot-specific multiplayer envelope
# we don't want here; the gateway is a request/response auth endpoint,
# not a multiplayer peer. The pattern follows the Godot 4.6 docs'
# "Minimal server example" using TCPServer + WebSocketPeer.accept_stream.

const Auth = preload("res://scripts/auth.gd")
const ServerConfig = preload("res://scripts/server_config.gd")
const LoginRateLimiter = preload("res://scripts/login_rate_limiter.gd")
const BuildGate = preload("res://scripts/build_gate.gd")  # T-514: outdated-client gate
const CharacterRoster = preload("res://scripts/character_roster.gd")  # T-507: multi-character

# Hardcoded world address for v1. Future tickets pull this from
# master based on player landing zone.
const WORLD_HOST := "127.0.0.1"
const WORLD_PORT := 9200

var _tcp: TCPServer
var _peers: Dictionary = {}  # peer_id -> WebSocketPeer
var _peer_ips: Dictionary = {}  # peer_id -> TCP source IP
# T-507: peer_id -> authenticated username. Set ONLY by a successful login on this socket;
# every char_* op takes its acting account from here, never from the message body.
var _peer_auth: Dictionary = {}
var _next_peer_id: int = 1
var _shutting_down: bool = false
var _login_limiter := LoginRateLimiter.new(5, 60_000)
# T-514: minimum client build (ISO-8601 UTC). Blank/unset => gate disabled (dev/local/harness).
var _min_build := str(OS.get_environment("AVALON_MIN_BUILD")).strip_edges()


func _ready() -> void:
	print("[gateway] Avalon gateway starting")
	Engine.max_fps = 60  # T-698: headless _process free-ran uncapped for no benefit
	if BuildGate.gate_enabled(_min_build):
		print("[gateway] build gate ON — minimum client build %s" % _min_build)

	# FAIL-FAST: Validate JWT secrets on startup (T-006/T-007)
	Auth.init_from_env()
	if not Auth.is_secret_valid():
		print(
			(
				"[gateway] FATAL: AVALON_JWT_SECRET or AVALON_JWT_REFRESH_SECRET "
				+ "missing or too short (< 32 bytes). Refusing to start."
			)
		)
		get_tree().quit.bind(1).call_deferred()
		return

	_tcp = TCPServer.new()
	var err := _tcp.listen(ServerConfig.LISTEN_PORT_WS)
	if err != OK:
		printerr(
			(
				"[gateway] FATAL: failed to bind ws://0.0.0.0:%d (err=%d)"
				% [ServerConfig.LISTEN_PORT_WS, err]
			)
		)
		get_tree().quit.bind(1).call_deferred()
		return

	print("[gateway] listening on ws://0.0.0.0:%d" % ServerConfig.LISTEN_PORT_WS)
	set_process(true)


func _process(_delta: float) -> void:
	if _shutting_down:
		return

	# Accept new connections
	while _tcp.is_connection_available():
		var ws := WebSocketPeer.new()
		var stream: StreamPeerTCP = _tcp.take_connection()
		var err := ws.accept_stream(stream)
		if err != OK:
			push_warning("[gateway] accept_stream failed (err=%d)" % err)
			continue
		var peer_id := _next_peer_id
		_next_peer_id += 1
		_peers[peer_id] = ws
		_peer_ips[peer_id] = stream.get_connected_host()
		print("[gateway] client connected: peer_id=%d" % peer_id)

	# Service existing peers
	for peer_id in _peers.keys():
		var ws: WebSocketPeer = _peers[peer_id]
		ws.poll()
		var state := ws.get_ready_state()

		if state == WebSocketPeer.STATE_OPEN:
			while ws.get_available_packet_count() > 0:
				var packet := ws.get_packet()
				var packet_str := packet.get_string_from_utf8()
				_handle_message(peer_id, ws, packet_str)
		elif state == WebSocketPeer.STATE_CLOSED:
			_peers.erase(peer_id)
			_peer_ips.erase(peer_id)
			_peer_auth.erase(peer_id)  # T-507: login state dies with the socket
			# Note: not logging close codes for now; useful later for diagnostics.


func _handle_message(peer_id: int, ws: WebSocketPeer, raw: String) -> void:
	var parsed: Variant = JSON.parse_string(raw)

	# Reject anything that isn't a Dictionary, including null and
	# primitives. JSON.parse_string returns null on parse failure
	# and on bare-null input; both are invalid frames.
	if not (parsed is Dictionary):
		_send_err_and_close(peer_id, ws, "malformed_request")
		return

	var msg: Dictionary = parsed
	var msg_type: String = str(msg.get("type", ""))

	match msg_type:
		"login":
			_process_login_request(peer_id, ws, msg)
		"refresh":
			_process_refresh_request(peer_id, ws, msg)
		# T-507: roster ops on the SAME socket after login (the login handler keeps it open).
		"char_create", "char_delete", "char_select":
			_process_char_request(peer_id, ws, msg_type, msg)
		_:
			_send_err_and_close(peer_id, ws, "unknown_message_type")


func _process_login_request(peer_id: int, ws: WebSocketPeer, request: Dictionary) -> void:
	var username := str(request.get("username", ""))
	var password := str(request.get("password", ""))
	var source := str(_peer_ips.get(peer_id, "unknown:%d" % peer_id))
	var now_ms := Time.get_ticks_msec()

	if not _login_limiter.can_attempt(source, now_ms):
		_send_err_and_close(peer_id, ws, "rate_limited")
		return

	# T-514: refuse stale clients BEFORE any credential/token work. Not a credential failure, so it
	# is not counted against the rate limiter — an honest client retries once it has updated. The
	# build string is untrusted; BuildGate validates it (fail-closed) and it never leaves this echo.
	var client_build := str(request.get("build", ""))
	if not BuildGate.meets_minimum(client_build, _min_build):
		_send_text(
			ws, {"type": "login_err", "reason": BuildGate.REJECT_REASON, "required": _min_build}
		)
		ws.close(1000, BuildGate.REJECT_REASON)
		print("[gateway] login_err outdated_build peer_id=%d (min=%s)" % [peer_id, _min_build])
		return

	if not Auth.validate_login(username, password):
		_login_limiter.record_failure(source, now_ms)
		_send_err_and_close(peer_id, ws, "invalid_credentials")
		return

	# T-007: Issue both access and refresh tokens
	var tokens: Dictionary = Auth.issue_tokens(username)

	if tokens.has("error"):
		_send_err_and_close(peer_id, ws, "token_issuance_failed")
		return

	# T-507: authenticate the socket for roster ops + attach the character roster. `select`
	# tells the client to show the character-select screen: always when the account holds 2+
	# characters, or on request ("manage": true — the login form's alt-management path).
	# 0/1-character accounts keep today's drop-in: the master auto-resolves their character.
	_peer_auth[peer_id] = username
	var characters := CharacterRoster.list_characters(username)
	var wants_manage := bool(request.get("manage", false))

	var response := {
		"type": "login_ok",
		"access_token": tokens["access_token"],
		"refresh_token": tokens["refresh_token"],
		"characters": characters,
		"select": characters.size() >= 2 or wants_manage,
		"world":
		{
			"host": WORLD_HOST,
			"port": WORLD_PORT,
		},
	}
	_send_text(ws, response)
	# Do NOT close immediately — client closes after reading login_ok (or, T-507, keeps the
	# socket open for char_* roster ops until selection). Closing same-frame causes a race
	# where client sees STATE_CLOSED before get_available_packet_count() returns > 0.
	print("[gateway] login_ok issued tokens for %s (%d chars)" % [username, characters.size()])


# T-507: char_create / char_delete / char_select on an authenticated login socket.
# The acting account comes from _peer_auth (the login that happened on THIS socket) — the
# ownership boundary a client cannot cross for another account's characters.
func _process_char_request(
	peer_id: int, ws: WebSocketPeer, msg_type: String, request: Dictionary
) -> void:
	var username := str(_peer_auth.get(peer_id, ""))
	if username == "":
		_send_err_and_close(peer_id, ws, "not_authenticated")
		return
	match msg_type:
		"char_create":
			var created := CharacterRoster.create_character(
				username, str(request.get("name", "")).strip_edges().to_lower()
			)
			if not bool(created.get("ok", false)):
				_send_text(
					ws, {"type": "char_create_err", "reason": str(created.get("reason", ""))}
				)
				return
			_send_text(ws, {"type": "char_create_ok", "character": created.get("character", {})})
			print(
				"[gateway] char_create %s -> %s" % [username, created["character"].get("name", "")]
			)
		"char_delete":
			var deleted := CharacterRoster.delete_character(
				username, int(request.get("character_id", 0))
			)
			if not bool(deleted.get("ok", false)):
				_send_text(
					ws, {"type": "char_delete_err", "reason": str(deleted.get("reason", ""))}
				)
				return
			_send_text(
				ws,
				{
					"type": "char_delete_ok",
					"character_id": int(request.get("character_id", 0)),
					"characters": CharacterRoster.list_characters(username),
				}
			)
		"char_select":
			_process_char_select(ws, username, int(request.get("character_id", 0)))


func _process_char_select(ws: WebSocketPeer, username: String, character_id: int) -> void:
	# Ownership gate BEFORE any token is signed; the master re-validates the claim later.
	var character := CharacterRoster.owned_character(username, character_id)
	if character.is_empty():
		_send_text(ws, {"type": "char_select_err", "reason": "not_owned"})
		return
	var tokens: Dictionary = Auth.issue_tokens(
		username, int(character.get("id", 0)), str(character.get("name", ""))
	)
	if tokens.has("error"):
		_send_text(ws, {"type": "char_select_err", "reason": "token_issuance_failed"})
		return
	_send_text(
		ws,
		{
			"type": "char_select_ok",
			"access_token": tokens["access_token"],
			"refresh_token": tokens["refresh_token"],
			"character": character,
		}
	)
	print("[gateway] char_select %s -> %s" % [username, character.get("name", "")])


func _process_refresh_request(peer_id: int, ws: WebSocketPeer, request: Dictionary) -> void:
	"""T-007: Handle refresh token rotation request."""
	var refresh_token := str(request.get("refresh_token", ""))

	if refresh_token.is_empty():
		_send_err_and_close(peer_id, ws, "missing_refresh_token")
		return

	var result: Dictionary = Auth.rotate_refresh_token(refresh_token)

	if not result.get("success", false):
		var reason: String = result.get("reason", "refresh_token_consumed")
		var err_response := {"type": "refresh_err", "reason": reason}
		_send_text(ws, err_response)
		ws.close(1000, reason)
		print("[gateway] refresh_err: %s, peer disconnected" % reason)
		return

	var response := {
		"type": "refresh_ok",
		"access_token": result["access_token"],
		"refresh_token": result["refresh_token"],
	}
	_send_text(ws, response)
	ws.close(1000, "refresh_ok")
	print("[gateway] refresh_ok issued new tokens, peer disconnected")


func _send_text(ws: WebSocketPeer, obj: Dictionary) -> void:
	ws.send_text(JSON.stringify(obj))


func _send_err_and_close(peer_id: int, ws: WebSocketPeer, reason: String) -> void:
	_send_text(ws, {"type": "login_err", "reason": reason})
	ws.close(1000, reason)
	print("[gateway] login_err sent to peer_id=%d (%s)" % [peer_id, reason])


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		print("[gateway] shutting down")
		_shutting_down = true
		for peer_id in _peers.keys():
			var ws: WebSocketPeer = _peers[peer_id]
			ws.close(1001, "server shutdown")
		if _tcp != null:
			_tcp.stop()
		get_tree().quit.bind(0).call_deferred()
