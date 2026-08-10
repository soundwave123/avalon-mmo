extends GutTest

# T-754: the world's inbound master-response path — malformed frames must be rejected
# gracefully, and the type guard must actually be REACHABLE.
#
# The bug: _handle_packet declared `var response: Dictionary` and assigned
# JSON.parse_string() into it, so the `if not response is Dictionary` guard below was dead
# code. parse_string returns null on garbage and an Array on a non-object root; measured on
# 4.7.1 the typed assignment aborts the frame first, so the guard never ran. Worse,
# parse_string pushes its own engine ERROR on malformed input, which is why decode_response
# uses JSON.new().parse() instead.

const MasterClient = preload("res://scripts/master_client.gd")

var _client: MasterClient


func before_each() -> void:
	_client = MasterClient.new()


func after_each() -> void:
	if _client != null:
		_client.queue_free()
		_client = null


# ------------------------------------------------- the parse seam (was unreachable)


func test_decode_response_rejects_garbage_without_engine_errors() -> void:
	for raw: String in ["not json", "", "{", "}{", "\t", "{'single':1}"]:
		assert_null(MasterClient.decode_response(raw), "garbage %s should decode to null" % raw)
	# The bar the old parse_string path could not meet, even with a reachable guard.
	assert_engine_error_count(0, "malformed master frames must not raise engine errors")


func test_decode_response_rejects_valid_json_with_a_non_object_root() -> void:
	# These parse FINE — they are simply not objects. The old typed assign aborted here.
	for raw: String in ["[1,2]", "42", '"a string"', "null", "true", "[]", "[[1]]"]:
		assert_null(MasterClient.decode_response(raw), "non-object root %s must be null" % raw)
	assert_engine_error_count(0, "non-object JSON roots must not raise engine errors")


func test_decode_response_accepts_a_well_formed_object() -> void:
	var decoded: Variant = MasterClient.decode_response('{"id":7,"result":{"ok":true}}')
	assert_true(decoded is Dictionary, "a valid object frame must decode to a Dictionary")
	if decoded is Dictionary:
		assert_eq(int((decoded as Dictionary).get("id", 0)), 7)


# --------------------------------------------- the guard is now reachable end-to-end


func test_handle_packet_survives_non_dictionary_payloads() -> void:
	# The non-PackedByteArray branch: these reach the type guard directly. Pre-fix,
	# `response = data` aborted the frame for every one of them.
	for payload: Variant in [null, [], [1, 2], 5, 1.5, "str", true]:
		_client._handle_packet(payload)
	assert_engine_error_count(0, "non-Dictionary packets must be dropped, not coerced")


func test_handle_packet_leaves_pending_requests_untouched_on_garbage() -> void:
	# A malformed frame must not resolve or corrupt an in-flight correlated request.
	_client._pending[42] = null
	for payload: Variant in [null, [], "str", 7]:
		_client._handle_packet(payload)
	assert_true(_client._pending.has(42), "a malformed frame cleared a pending request")
	assert_null(_client._pending[42], "a malformed frame resolved a pending request")
	assert_engine_error_count(0, "malformed frames must not raise engine errors")


func test_handle_packet_still_correlates_a_valid_response() -> void:
	# The guard must reject malformed input WITHOUT breaking the happy path.
	_client._pending[9] = null
	_client._handle_packet({"id": 9, "result": {"valid": true}})
	assert_eq(_client._pending[9], {"valid": true}, "valid response failed to correlate")


func test_handle_packet_correlates_a_string_id() -> void:
	_client._pending[3] = null
	_client._handle_packet({"id": "3", "result": {"ok": 1}})
	assert_eq(_client._pending[3], {"ok": 1}, "string id failed to normalise to int")


func test_handle_packet_ignores_unmatched_and_missing_ids() -> void:
	_client._handle_packet({"result": {"ok": 1}})  # no id
	_client._handle_packet({"id": 999, "result": {"ok": 1}})  # unmatched
	assert_eq(_client._pending.size(), 0, "unmatched frames must not create pending entries")
	assert_engine_error_count(0, "id-less/unmatched frames must not raise engine errors")


# ------------------------------------------------------------------- fuzz-ish sweep


func test_fuzz_master_frame_shapes_are_all_survivable() -> void:
	var corpus: Array[String] = [
		"not json",
		"",
		"[]",
		"[1,2]",
		"42",
		"null",
		"true",
		'"s"',
		"{}",
		'{"id":[]}',
		'{"id":null}',
		'{"id":{},"result":1}',
		'{"id":1,"result":[]}',
		'{"id":"x","result":null}',
		'{"result":{"a":1}}',
	]
	_client._pending[1] = null
	for raw: String in corpus:
		var decoded: Variant = MasterClient.decode_response(raw)
		# Whatever decode returns, feeding it onward must never raise.
		_client._handle_packet(decoded)
	assert_engine_error_count(0, "no master-frame shape may raise an engine error")
	assert_true(corpus.size() >= 15, "fuzz corpus shrank below its floor")
