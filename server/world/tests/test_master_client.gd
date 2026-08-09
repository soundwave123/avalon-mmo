extends GutTest

# Test master_client.gd — WebSocket RPC client for master validation.

const MasterClient = preload("res://scripts/master_client.gd")
const ServerConfig = preload("res://scripts/server_config.gd")

var _client: MasterClient


func before_each() -> void:
	_client = MasterClient.new()


func after_each() -> void:
	if _client != null:
		_client.queue_free()
		_client = null


func test_initial_state_not_degraded() -> void:
	assert_true(not _client.is_degraded(), "should not be degraded on init")
	assert_true(not _client.get_connection_status(), "should not be connected on init")


func test_degraded_mode_blocks_validation() -> void:
	# Simulate degraded mode
	_client._degraded = true

	var result: Dictionary = await _client.validate_session("abcdef0123456789abcdef0123456789")
	assert_true(result.has("valid"), "degraded response has valid key")
	assert_true(not result["valid"], "degraded response is invalid")
	assert_true(result.has("error"), "degraded response has error key")


func test_connect_to_master_invalid_host() -> void:
	# Cannot test actual network connection in unit tests.
	# Verify degraded mode behavior directly instead.
	_client._enter_degraded_mode()
	assert_true(_client.is_degraded(), "should be degraded after _enter_degraded_mode")
	assert_true(not _client.get_connection_status(), "should not be connected in degraded mode")


func test_validate_session_returns_expected_format() -> void:
	# Unit-test the success→valid / reason→error translation directly.
	# This proves the seam-contract mapping is correct without needing a live socket.

	# --- Success path ---
	var success_result: Dictionary = _client._translate_master_response(
		{"success": true, "username": "alice", "daily": {"streak": 3}}
	)
	assert_true(success_result.has("valid"), "success response has valid key")
	assert_true(success_result["valid"], "success response is valid=true")
	assert_true(success_result.has("username"), "success response has username key")
	assert_eq(success_result["username"], "alice", "username is preserved")
	assert_eq(int(success_result["daily"]["streak"]), 3, "daily login state survives translation")
	assert_false(success_result.has("error"), "success response has no error key")

	# --- Failure path ---
	var failure_result: Dictionary = _client._translate_master_response(
		{"success": false, "reason": "revoked"}
	)
	assert_true(failure_result.has("valid"), "failure response has valid key")
	assert_true(not failure_result["valid"], "failure response is valid=false")
	assert_true(failure_result.has("error"), "failure response has error key")
	assert_true(typeof(failure_result["error"]) == TYPE_STRING, "error is a String")
	assert_eq(failure_result["error"], "revoked", "reason maps to error")


func test_translate_carries_tutorial_done_and_defaults_to_fresh() -> void:
	# T-706: the graduation flag rides the handshake for the fresh-spawn pin. A missing flag
	# (older master) or a db-string boolean must read FRESH/graduated safely — never crash.
	var graduated: Dictionary = _client._translate_master_response(
		{"success": true, "username": "alice", "tutorial_done": true}
	)
	assert_true(bool(graduated["tutorial_done"]), "a graduated account translates true")
	var missing: Dictionary = _client._translate_master_response(
		{"success": true, "username": "bob"}
	)
	assert_false(bool(missing["tutorial_done"]), "missing flag defaults to fresh (pin to hub[0])")
	var db_string: Dictionary = _client._translate_master_response(
		{"success": true, "username": "cid", "tutorial_done": "t"}
	)
	assert_true(bool(db_string["tutorial_done"]), "a 't' db-string reads true (T-563 idiom)")


func test_validate_session_fails_closed_when_unreachable() -> void:
	# Without master running, validate_session returns fail-closed.
	# Confirms the response shape world/main.gd expects on failure.
	var token: String = "abcdef0123456789abcdef0123456789"
	var result: Dictionary = await _client.validate_session(token)
	assert_true(result.has("valid"), "response has valid key")
	assert_true(not result["valid"], "unreachable returns valid=false")
	assert_true(result.has("error"), "response has error key")
	assert_true(typeof(result["error"]) == TYPE_STRING, "error is a String")
	assert_true(not result["error"].is_empty(), "error is non-empty")


func test_validate_session_times_out_when_master_silent() -> void:
	# Test the polling + timeout loop that validate_session uses.
	# Cannot mock WebSocketPeer.send_text (built-in method, not assignable in GDScript),
	# so we exercise the exact same polling logic directly.
	_client._connected = true
	_client._timeout = false

	# Set up pending state as if send succeeded
	var req_id: int = _client._next_req_id
	_client._pending[req_id] = null

	# Start a short timer that fires _on_timeout
	var test_timer: SceneTreeTimer = get_tree().create_timer(0.5)
	test_timer.timeout.connect(_client._on_timeout, CONNECT_ONE_SHOT)

	# Poll exactly like validate_session does
	var start_time: float = Time.get_ticks_msec()
	while true:
		await get_tree().process_frame
		if _client._pending.get(req_id) != null:
			break
		if _client._timeout:
			break
		if not _client._pending.has(req_id):
			break

	var elapsed_ms: float = Time.get_ticks_msec() - start_time

	var exited_on_timeout: bool = _client._timeout

	# Cleanup (mimics validate_session post-loop cleanup)
	_client._pending.erase(req_id)
	_client._timeout = false

	assert_true(exited_on_timeout, "loop exited on timeout, not response")
	# SceneTreeTimer advances in game time, which can run faster than wall time headless.
	assert_true(elapsed_ms >= 250, "timeout was not immediate (got %.0fms)" % elapsed_ms)
	assert_true(elapsed_ms < 1500, "did not hang (got %.0fms)" % elapsed_ms)


# ---- T-041: generic call_master transport --------------------------------


func test_handle_packet_correlates_distinct_request_ids() -> void:
	# The property that makes overlapping in-flight requests safe: each response routes to its own
	# _pending slot by id. (validate_session's old shared _timeout could not do this.)
	_client._pending[1] = null
	_client._pending[2] = null
	_client._handle_packet({"id": 1, "result": {"a": 1}})
	_client._handle_packet({"id": 2, "result": {"b": 2}})
	assert_eq(_client._pending[1], {"a": 1}, "response 1 routed to slot 1")
	assert_eq(_client._pending[2], {"b": 2}, "response 2 routed to slot 2")


func test_call_master_unreachable_when_degraded() -> void:
	_client._degraded = true
	var result: Dictionary = await _client.call_master("get_quest_log", {"username": "alice"})
	assert_eq(result.get("error", ""), "master_unreachable")


func test_call_master_unreachable_when_not_connected() -> void:
	# Fresh client is not connected → fail-closed, no socket needed.
	var result: Dictionary = await _client.call_master("get_quest_log", {"username": "alice"})
	assert_eq(result.get("error", ""), "master_unreachable")
