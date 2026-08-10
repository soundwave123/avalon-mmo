extends Node
# Master server RPC client.
#
# Manages WebSocket connection to master server for session validation.
# Uses fail-closed model: if master is unreachable after retries, reject
# new sessions rather than accepting unvalidated tokens.
#
# Wire contract (world→master):
#   REQUEST:  validate_session params = {token: String, date_key: YYYY-MM-DD UTC String}
#   RESPONSE: {"id": int, "result": {"success": bool, "username": String}}  (success)
#             {"id": int, "result": {"success": false, "reason": String}}    (failure)
#
# Translation to what world/main.gd expects:
#   {"success": true, "username"} → {"valid": true, "username": String}
#   {"success": false, "reason"}  → {"valid": false, "error": String}

# Request-id correlation: req_id -> result data
# Uses frame-polling loop (no Signal.new() — not constructible in GDScript 4.x).
# NOTE: validate_session is NOT safe for concurrent calls — _timer, _timeout, and
# response_received are shared instance state. Only one in-flight validation at a time.
signal response_received

const MAX_RETRIES := 3
const RETRY_DELAY_SEC := 1.0
# T-322 killed the content-scale payloads; 5s covers real master latency with margin.
const REQUEST_TIMEOUT_SEC := 5.0

const MASTER_HOST := "127.0.0.1"
const MASTER_PORT := 9100

var _ws: WebSocketPeer
var _connected: bool = false
var _retries: int = 0
var _degraded: bool = false

var _pending: Dictionary = {}  # req_id -> result (null = no response yet)
# T-074: read once — attached to every request when the deployment sets it.
var _rpc_shared_secret: String = OS.get_environment("AVALON_RPC_SHARED_SECRET")
var _timer: SceneTreeTimer
var _timeout: bool = false
var _next_req_id: int = 1
# T-041: per-request deadlines (msec) for call_master — concurrency-safe, unlike the single-slot
# _timer/_timeout that validate_session uses. Keyed by req_id so overlapping calls don't collide.
var _deadlines: Dictionary = {}


func _init() -> void:
	_ws = WebSocketPeer.new()
	# T-320: the npc_indicators request outgrew the default 64KB WS buffers (T-293/T-302/T-311
	# content growth) — an oversized frame stalls delivery for seconds, every in-flight reply
	# then misses the deadline and gets discarded as unmatched. Size for content-scale payloads.
	_ws.inbound_buffer_size = 1 << 20
	_ws.outbound_buffer_size = 1 << 20


func connect_to_master(host: String = MASTER_HOST, port: int = MASTER_PORT) -> void:
	if _connected or _degraded:
		return

	var url := "ws://%s:%d" % [host, port]
	var err := _ws.connect_to_url(url)
	if err != OK:
		printerr("[master_client] FATAL: failed to initiate WebSocket to master at %s" % url)
		_enter_degraded_mode()
		return

	print("[master_client] connecting to master at %s" % url)


func _process(_delta: float) -> void:
	if _ws.get_ready_state() == WebSocketPeer.STATE_CLOSED:
		if not _degraded:
			_retries += 1
			if _retries >= MAX_RETRIES:
				_enter_degraded_mode()
				return
			print("[master_client] retry %d/%d after disconnect" % [_retries, MAX_RETRIES])

	if _ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
		if not _connected:
			_connected = true
			_retries = 0
			print("[master_client] connected to master")

	_ws.poll()

	var packet: Variant
	while _ws.get_available_packet_count() > 0:
		packet = _ws.get_packet()
		_handle_packet(packet)


static func decode_response(raw_text: String) -> Variant:
	"""Parse one master frame; returns the Dictionary, or null when the frame is unusable.

	T-754: pure + static so the malformed-frame cases are testable without a live socket
	(the same seam pattern as _translate_master_response). Uses JSON.new().parse() rather
	than JSON.parse_string() because the static helper pushes its OWN engine ERROR on
	malformed input regardless of the destination type — a garbled frame would spam stderr
	even after the type guard became reachable. The instance API reports silently.
	"""
	var json := JSON.new()
	if json.parse(raw_text) != OK:
		return null
	var parsed: Variant = json.data
	return parsed if parsed is Dictionary else null


func _handle_packet(data: Variant) -> void:
	# T-754: this used to declare `var response: Dictionary` and assign the parse result
	# straight into it, which made the `if not response is Dictionary` guard below dead
	# code — parse_string returns null on garbage and an Array on a non-object root, so the
	# typed assignment aborted the frame BEFORE the guard could ever run. Receive as
	# Variant, type-test, then assign typed (the world_regions.gd idiom).
	var parsed: Variant = null
	if data is PackedByteArray:
		if not _ws.was_string_packet():
			# Binary packet — ignore (not part of our JSON protocol)
			return
		parsed = decode_response(data.get_string_from_utf8())
	else:
		parsed = data

	# Now reachable for every malformed shape: null, Array, scalar, garbage JSON.
	if not parsed is Dictionary:
		return
	var response: Dictionary = parsed

	# Extract request id for correlation — normalise to int to match world-side keys.
	var req_id: Variant = response.get("id", null)
	if req_id == null:
		return
	if req_id is String:
		req_id = int(req_id)
	if not _pending.has(req_id):
		# Unmatched response — discard
		return

	# Read then erase (Dictionary has no .pop() in GDScript 4.x)
	var result: Variant = response.get("result", null)
	_pending.erase(req_id)
	_pending[req_id] = result
	response_received.emit()


func _translate_master_response(master_result: Variant) -> Dictionary:
	"""Translate master's RPC response format to what world/main.gd expects.

	Master returns:
		{"success": true, "username": String}  →  {"valid": true, "username": String}
		{"success": false, "reason": String}   →  {"valid": false, "error": String}

	Returns {"valid": false, "error": "malformed_response"} if the result is unexpected.
	"""
	if not master_result is Dictionary:
		return {"valid": false, "error": "malformed_response"}

	var result: Dictionary = master_result

	if result.get("success", false):
		var translated := {"valid": true, "username": str(result.get("username", ""))}
		# T-507: the master-resolved acting character rides the handshake result.
		translated["character_id"] = int(result.get("character_id", 0))
		translated["character_name"] = str(result.get("character_name", ""))
		if result.has("daily"):
			translated["daily"] = result["daily"]
		# T-706: account graduation flag for the fresh-spawn pin. Missing (older master) reads as
		# FRESH — the failure mode is a clustered spawn, never a stranded first-timer. Truthy read
		# via the codebase-standard db-bool idiom (T-563: bool(<String>) is a crash, not a cast).
		var td: Variant = result.get("tutorial_done", false)
		translated["tutorial_done"] = td if td is bool else str(td).to_lower() in ["t", "true", "1"]
		return translated

	# Failure path
	return {"valid": false, "error": str(result.get("reason", "unknown_error"))}


func validate_session(token: String) -> Dictionary:
	"""Send validate_session RPC to master. Returns translated result.

	Fail-closed on:
		- Not connected to master → "master_unreachable"
		- Send failed → "send_failed"
		- Timeout (3s) → "timeout"
		- Malformed response → "malformed_response"
	"""
	if _degraded:
		return {"valid": false, "error": "master_unreachable"}

	if not _connected:
		return {"valid": false, "error": "master_unreachable"}

	# Build request
	var req_id: int = _next_req_id
	_next_req_id += 1

	var request: Dictionary = {
		"id": req_id,
		"method": "validate_session",
		"params": {"token": token, "date_key": Time.get_date_string_from_system(true)},
	}

	# Register pending request
	_pending[req_id] = null

	# Send
	var json_text: String = JSON.stringify(request)
	var send_err: int = _ws.send_text(json_text)
	if send_err != OK:
		_pending.erase(req_id)
		printerr("[master_client] send failed (error %d)" % send_err)
		return {"valid": false, "error": "send_failed"}

	# Await response or timeout (NOT safe for concurrent calls — see class docs)
	_timeout = false
	_timer = get_tree().create_timer(REQUEST_TIMEOUT_SEC)
	_timer.timeout.connect(_on_timeout, CONNECT_ONE_SHOT)

	# Frame-polling loop: check _pending and _timeout every frame.
	# (await signal or get_tree().process_frame is NOT a race — await binds tighter than or,
	# so the process_frame part would be dead code. Poll the frame directly instead.)
	while true:
		await get_tree().process_frame
		if _pending.get(req_id) != null:
			break
		if _timeout:
			break
		if not _pending.has(req_id):
			break

	# Cleanup — SceneTreeTimer has no .stop() in Godot 4.6.x; just null out ref.
	_timer = null

	# Read BEFORE erase — erase clears the value
	var result: Variant = _pending.get(req_id, null)
	_pending.erase(req_id)
	_timeout = false

	if result == null:
		return {"valid": false, "error": "timeout"}
	return _translate_master_response(result)


func _on_timeout() -> void:
	_timeout = true


# T-041: generic correlated RPC. Safe for overlapping in-flight calls — each request gets its own
# req_id and deadline (no shared _timeout). Returns the master's raw `result` payload on success, or
# {"error": "<reason>"} on any transport failure (fail-closed, mirroring validate_session). Added
# alongside validate_session (which keeps its single-flight path + white-box tests); unifying the
# two is a tracked cleanup, not done here.
func call_master(method: String, params: Dictionary) -> Dictionary:
	if _degraded or not _connected:
		return {"error": "master_unreachable"}

	var req_id: int = _next_req_id
	_next_req_id += 1
	_pending[req_id] = null
	_deadlines[req_id] = Time.get_ticks_msec() + int(REQUEST_TIMEOUT_SEC * 1000.0)

	var request: Dictionary = {"id": req_id, "method": method, "params": params}
	# T-074: shared-secret auth for the master RPC surface (required when master has it set).
	if _rpc_shared_secret != "":
		request["secret"] = _rpc_shared_secret
	var send_err: int = _ws.send_text(JSON.stringify(request))
	if send_err != OK:
		_pending.erase(req_id)
		_deadlines.erase(req_id)
		printerr("[master_client] call_master send failed (error %d)" % send_err)
		return {"error": "send_failed"}

	# Poll this request's own slot + deadline every frame (concurrency-safe).
	while true:
		await get_tree().process_frame
		if not _pending.has(req_id):
			# Cleared by _enter_degraded_mode — master became unreachable mid-flight.
			_deadlines.erase(req_id)
			return {"error": "master_unreachable"}
		if _pending[req_id] != null:
			break
		if Time.get_ticks_msec() >= int(_deadlines[req_id]):
			_pending.erase(req_id)
			_deadlines.erase(req_id)
			return {"error": "timeout"}

	var result: Variant = _pending[req_id]
	_pending.erase(req_id)
	_deadlines.erase(req_id)
	if not result is Dictionary:
		return {"error": "malformed_response"}
	return result


func _enter_degraded_mode() -> void:
	_degraded = true
	_connected = false
	# Clear any pending requests — set _timeout so waiting loops also exit
	_timeout = true
	for req_id in _pending.keys():
		_pending[req_id] = null  # wake waiting coroutines with null result
	_pending.clear()
	response_received.emit()  # wake all waiting coroutines
	printerr("[master_client] DEGRADED MODE: master unreachable after %d retries" % MAX_RETRIES)


func _exit_degraded_mode() -> void:
	_degraded = false
	print("[master_client] exited degraded mode, master reconnected")


func is_degraded() -> bool:
	return _degraded


func get_connection_status() -> bool:
	return _connected and not _degraded
