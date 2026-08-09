class_name OpsChannel
extends Node

# Loopback-only, one-request-per-connection JSON-lines transport for T-511. This is deliberately
# separate from ENet: no game client dispatch can ever reach an ops verb.
const LOOPBACK_BIND := "127.0.0.1"
const DEFAULT_PORT := 9215
const MAX_REQUEST_BYTES := 64 * 1024
const _OPS_SERVICE = preload("res://scripts/ops_service.gd")

var _server := TCPServer.new()
var _secret := ""
var _service = _OPS_SERVICE.new()
var _peers: Dictionary = {}  # StreamPeerTCP -> partial UTF-8 line


func setup(world: Node, master_client: Node, stores: Array) -> Error:
	_service.setup(
		Callable(world, "_send_to_peer"),
		Callable(world, "_disconnect_peer"),
		Callable(master_client, "call_master"),
		stores[0],
		stores[1],
		stores[2],
		stores[3]
	)
	_secret = OS.get_environment("AVALON_OPS_SECRET").strip_edges()
	var port_env := OS.get_environment("AVALON_OPS_PORT")
	var port := int(port_env) if port_env != "" else DEFAULT_PORT
	if not bind_secret_ok(LOOPBACK_BIND, _secret):
		printerr("[ops] disabled: AVALON_OPS_SECRET is required; no listener was opened")
		set_process(false)
		return ERR_UNAUTHORIZED
	var err := _server.listen(port, LOOPBACK_BIND)
	if err != OK:
		printerr("[ops] failed to bind tcp://%s:%d (error %d)" % [LOOPBACK_BIND, port, err])
		set_process(false)
		return err
	print("[ops] listening on tcp://%s:%d (authenticated JSON-lines)" % [LOOPBACK_BIND, port])
	set_process(true)
	return OK


func _process(delta: float) -> void:
	_service.tick(delta)
	while _server.is_connection_available():
		var peer := _server.take_connection()
		if peer != null:
			peer.set_no_delay(true)
			_peers[peer] = ""
	for peer: StreamPeerTCP in _peers.keys():
		peer.poll()
		if peer.get_status() != StreamPeerSocket.STATUS_CONNECTED:
			_drop(peer)
			continue
		var available := peer.get_available_bytes()
		if available <= 0:
			continue
		var read: Array = peer.get_data(available)
		if int(read[0]) != OK:
			_drop(peer)
			continue
		var buffer := str(_peers[peer]) + (read[1] as PackedByteArray).get_string_from_utf8()
		if buffer.to_utf8_buffer().size() > MAX_REQUEST_BYTES:
			_respond(peer, {"ok": false, "error": "request_too_large"})
			continue
		if not buffer.contains("\n"):
			_peers[peer] = buffer
			continue
		_peers.erase(peer)
		_process_request(peer, buffer.get_slice("\n", 0))


func on_login(peer_id: int) -> void:
	_service.on_login(peer_id)


static func bind_secret_ok(bind_addr: String, secret: String) -> bool:
	return bind_addr == LOOPBACK_BIND and secret != ""


static func secret_ok(expected: String, provided: String) -> bool:
	if expected == "" or provided == "":
		return false
	return Crypto.new().constant_time_compare(expected.to_utf8_buffer(), provided.to_utf8_buffer())


static func parse_request(raw: String) -> Dictionary:
	var json := JSON.new()
	if json.parse(raw) != OK or not (json.data is Dictionary):
		return {"ok": false, "error": "invalid_json"}
	var request := json.data as Dictionary
	if (
		str(request.get("secret", "")) == ""
		or str(request.get("actor", "")).strip_edges() == ""
		or str(request.get("verb", "")).strip_edges() == ""
		or not (request.get("params", {}) is Dictionary)
	):
		return {"ok": false, "error": "invalid_request"}
	return {"ok": true, "request": request}


func _process_request(peer: StreamPeerTCP, raw: String) -> void:
	var parsed := parse_request(raw)
	if not bool(parsed.get("ok", false)):
		_respond(peer, parsed)
		return
	var request: Dictionary = parsed["request"]
	if not secret_ok(_secret, str(request.get("secret", ""))):
		_respond(peer, {"ok": false, "error": "unauthorized"})
		return
	var result: Dictionary = await _service.handle(
		str(request["actor"]).strip_edges().left(80),
		str(request["verb"]).strip_edges(),
		request["params"],
		Time.get_unix_time_from_system()
	)
	_respond(peer, result)


func _respond(peer: StreamPeerTCP, response: Dictionary) -> void:
	peer.put_data((JSON.stringify(response) + "\n").to_utf8_buffer())
	peer.disconnect_from_host()
	_peers.erase(peer)


func _drop(peer: StreamPeerTCP) -> void:
	peer.disconnect_from_host()
	_peers.erase(peer)


func _exit_tree() -> void:
	for peer: StreamPeerTCP in _peers.keys():
		peer.disconnect_from_host()
	_peers.clear()
	_server.stop()
