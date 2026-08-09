# addons/database/pg_pipe.gd
# T-701 sidecar driver: JSON-lines over loopback TCP to avalon-dbd
# (tools/db/avalon_dbd.py), one persistent socket shared process-wide.
#
# Failure bounds to "slow, never wrong":
# - fallback to the subprocess path is signaled (delivered=false) ONLY when the
#   request provably never reached the sidecar (no secret, no connection, or the
#   send itself errored — a partial line without its newline is never executed);
# - once a request has been fully sent, a timeout/disconnect is reported as a
#   FAILED query (same contract as a psql crash today), never re-run elsewhere.
class_name PgPipe
extends RefCounted

const LOOPBACK := "127.0.0.1"
const DEFAULT_PORT := 9217
const CONNECT_TIMEOUT_MS := 500
const REPLY_TIMEOUT_MS := 30000
const DEAD_WINDOW_MS := 3000
const MAX_REPLY_BYTES := 8 * 1024 * 1024

static var _peer: StreamPeerTCP = null
static var _buffer := PackedByteArray()
static var _next_id: int = 0
static var _dead_until_ms: int = 0


# Returns {"delivered": bool, "status": int, "out": String, "error": String}.
# delivered=false -> safe to fall back to the subprocess driver.
static func request(sql: String, params: Array) -> Dictionary:
	var secret := OS.get_environment("AVALON_DBD_SECRET").strip_edges()
	if secret == "":
		return _undelivered("no_secret")
	if Time.get_ticks_msec() < _dead_until_ms:
		return _undelivered("dead_window")
	if not _ensure_connected():
		return _undelivered("connect_failed")
	var out_params: Array = []
	for p: Variant in params:
		out_params.append(null if p == null else str(p))
	_next_id += 1
	var line := (
		JSON.stringify({"id": _next_id, "secret": secret, "sql": sql, "params": out_params}) + "\n"
	)
	if _peer.put_data(line.to_utf8_buffer()) != OK:
		_drop(true)
		return _undelivered("send_failed")
	return _read_reply(_next_id)


static func _ensure_connected() -> bool:
	if _peer != null:
		_peer.poll()
		if _peer.get_status() == StreamPeerTCP.STATUS_CONNECTED:
			return true
		_drop(false)
	var port_env := OS.get_environment("AVALON_DBD_PORT")
	var port := int(port_env) if port_env != "" else DEFAULT_PORT
	var peer := StreamPeerTCP.new()
	if peer.connect_to_host(LOOPBACK, port) != OK:
		_dead_until_ms = Time.get_ticks_msec() + DEAD_WINDOW_MS
		return false
	var deadline := Time.get_ticks_msec() + CONNECT_TIMEOUT_MS
	while Time.get_ticks_msec() < deadline:
		peer.poll()
		var status := peer.get_status()
		if status == StreamPeerTCP.STATUS_CONNECTED:
			peer.set_no_delay(true)
			_peer = peer
			_buffer = PackedByteArray()
			return true
		if status != StreamPeerTCP.STATUS_CONNECTING:
			break
		OS.delay_usec(200)
	peer.disconnect_from_host()
	_dead_until_ms = Time.get_ticks_msec() + DEAD_WINDOW_MS
	return false


static func _read_reply(expected_id: int) -> Dictionary:
	var deadline := Time.get_ticks_msec() + REPLY_TIMEOUT_MS
	while Time.get_ticks_msec() < deadline:
		_peer.poll()
		if _peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			_drop(true)
			return _failed("sidecar_disconnected_mid_request")
		var available := _peer.get_available_bytes()
		if available <= 0:
			OS.delay_usec(100)
			continue
		var read: Array = _peer.get_data(available)
		if int(read[0]) != OK:
			_drop(true)
			return _failed("read_error")
		_buffer.append_array(read[1] as PackedByteArray)
		if _buffer.size() > MAX_REPLY_BYTES:
			_drop(true)
			return _failed("reply_too_large")
		var newline := _buffer.find(10)
		if newline < 0:
			continue
		var raw := _buffer.slice(0, newline).get_string_from_utf8()
		_buffer = _buffer.slice(newline + 1)
		return _parse_reply(raw, expected_id)
	_drop(true)
	return _failed("reply_timeout")


static func _parse_reply(raw: String, expected_id: int) -> Dictionary:
	var json := JSON.new()
	if json.parse(raw) != OK or not (json.data is Dictionary):
		_drop(true)
		return _failed("invalid_reply_json")
	var reply := json.data as Dictionary
	if int(reply.get("id", -1)) != expected_id:
		_drop(true)
		return _failed("reply_id_mismatch")
	var status := int(reply.get("status", 1))
	return {
		"delivered": true,
		"status": status,
		"out": str(reply.get("out", "")),
		"error": str(reply.get("error", "")),
	}


static func _drop(mark_dead: bool) -> void:
	if _peer != null:
		_peer.disconnect_from_host()
		_peer = null
	_buffer = PackedByteArray()
	if mark_dead:
		_dead_until_ms = Time.get_ticks_msec() + DEAD_WINDOW_MS


static func _undelivered(reason: String) -> Dictionary:
	return {"delivered": false, "status": 1, "out": "", "error": reason}


static func _failed(reason: String) -> Dictionary:
	return {"delivered": true, "status": 1, "out": "", "error": reason}
