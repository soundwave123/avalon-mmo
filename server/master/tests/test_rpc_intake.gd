extends "res://addons/gut/test.gd"
# T-754: malformed-frame hardening on the master's untrusted RPC intake.
#
# The bug these tests pin: `var params: Dictionary = data.get("params", {})` ran BEFORE the
# shared-secret gate, so {"params": []} from any peer that could reach the port aborted
# _handle_message pre-authentication. Measured on 4.7.1, a typed-assign mismatch aborts the
# current frame and the function returns the DEFAULT of its return type — "" for String.
# That is the assertion handle used throughout: a hardened handler ALWAYS returns a
# non-empty, parseable JSON envelope. An aborted one returns "".
#
# Runs against the real Main + real _dispatch, no TCP and no DB (test-mode stores).

const Main = preload("res://scripts/main.gd")
const RpcIntake = preload("res://scripts/rpc_intake.gd")
const CharacterManager = preload("res://scripts/character_manager.gd")
const DiscoveryStore = preload("res://scripts/discovery_store.gd")
const TelemetryStore = preload("res://scripts/telemetry_store.gd")
const QuestStateMachine = preload("res://scripts/quest_state_machine.gd")

var _main: Main


func before_each() -> void:
	CharacterManager.reset_for_test()
	DiscoveryStore.reset_for_test()
	TelemetryStore.reset_for_test()
	_main = Main.new()


func after_each() -> void:
	if _main != null:
		_main.free()
		_main = null


func _handled(raw: String) -> Dictionary:
	"""Drive the real intake and assert it produced a well-formed envelope.

	Returns the decoded response so callers can assert on its content.
	"""
	var out: String = _main._handle_message(raw)
	assert_false(
		out.is_empty(), "handler returned '' — a typed coercion aborted the frame: %s" % raw
	)
	var parsed: Variant = JSON.parse_string(out)
	assert_true(parsed is Dictionary, "handler emitted non-object JSON for: %s" % raw)
	return parsed if parsed is Dictionary else {}


func _result_of(raw: String) -> Dictionary:
	var envelope: Dictionary = _handled(raw)
	var result: Variant = envelope.get("result", null)
	assert_true(result is Dictionary, "envelope carried no result object for: %s" % raw)
	return result if result is Dictionary else {}


# ---------------------------------------------------------------- the reported bug


func test_non_dictionary_params_is_rejected_not_coerced() -> void:
	# The exact frame from the audit. Pre-fix this aborted _handle_message and returned "".
	var result: Dictionary = _result_of('{"method":"issue_session","params":[],"id":1}')
	assert_eq(result.get("error", ""), "invalid_params")
	# The DoD's real bar: rejection must be graceful, not "it errored but we survived".
	assert_engine_error_count(0, "malformed params must not raise an engine error")


func test_non_dictionary_params_rejected_for_every_scalar_shape() -> void:
	for payload: String in _non_dict_corpus():
		var raw: String = '{"method":"issue_session","params":%s,"id":1}' % payload
		var result: Dictionary = _result_of(raw)
		assert_eq(result.get("error", ""), "invalid_params", "params=%s should reject" % payload)
	assert_engine_error_count(0, "no shape of malformed params may raise an engine error")


func test_params_rejection_happens_before_dispatch_side_effects() -> void:
	# A malformed accept_quest must not partially mutate character state.
	CharacterManager.ensure_character("alice")
	var cid: int = int(CharacterManager.get_character("alice")["id"])
	var result: Dictionary = _result_of('{"method":"accept_quest","params":"nope","id":7}')
	assert_eq(result.get("error", ""), "invalid_params")
	assert_eq(CharacterManager.get_quests(cid).size(), 0, "rejected frame still wrote a quest")


# ------------------------------------------------- the pre-auth ORDERING (the real fix)


func test_unauthenticated_malformed_params_never_reaches_coercion() -> void:
	# With a secret set, a bad-params frame from an UNAUTHENTICATED peer must come back
	# "unauthorized" — proving the auth gate now precedes the payload type-test.
	_main._rpc_shared_secret = "s3cret-shared-value-for-tests"
	var result: Dictionary = _result_of('{"method":"issue_session","params":[],"id":1}')
	assert_eq(result.get("error", ""), "unauthorized")


func test_authenticated_malformed_params_reports_invalid_params() -> void:
	_main._rpc_shared_secret = "s3cret-shared-value-for-tests"
	var raw: String = '{"method":"issue_session","params":[],"id":1,"secret":"s3cret-shared-value-for-tests"}'
	assert_eq(_result_of(raw).get("error", ""), "invalid_params")


# ------------------------------------------------ the second pre-auth vector (id slot)


func test_container_and_null_ids_do_not_abort() -> void:
	# int() has no Dictionary/Array/null constructor — it aborts the frame the same way a
	# typed assign does. {"id": []} was an unauthenticated abort vector the audit missed.
	for id_payload: String in ["[]", "{}", "null", '"abc"', "true"]:
		var raw: String = '{"method":"issue_session","params":{},"id":%s}' % id_payload
		var out: String = _main._handle_message(raw)
		assert_false(out.is_empty(), "id=%s aborted the handler" % id_payload)
	assert_engine_error_count(0, "container/null ids must not raise an engine error")


func test_msg_id_of_normalises_every_shape_without_aborting() -> void:
	assert_eq(RpcIntake.msg_id_of(5), "5")
	assert_eq(RpcIntake.msg_id_of(5.0), "5")
	assert_eq(RpcIntake.msg_id_of("12"), "12")
	assert_eq(RpcIntake.msg_id_of("abc"), "0")
	assert_eq(RpcIntake.msg_id_of([]), "0")
	assert_eq(RpcIntake.msg_id_of({}), "0")
	assert_eq(RpcIntake.msg_id_of(null), "0")


# ------------------------------------------------------------------- malformed JSON


func test_malformed_json_root_rejected_gracefully() -> void:
	for raw: String in ["not json at all", "", "[1,2]", '"a string"', "42", "null", "{"]:
		var out: String = _main._handle_message(raw)
		assert_false(out.is_empty(), "raw=%s aborted the handler" % raw)
		var envelope: Variant = JSON.parse_string(out)
		assert_true(envelope is Dictionary, "raw=%s produced non-object JSON" % raw)


func test_decode_uses_the_silent_json_api() -> void:
	# JSON.parse_string() pushes its own engine ERROR on malformed input regardless of the
	# destination type; JSON.new().parse() returns a code silently. decode() must use the
	# latter or "zero engine errors" is unachievable. Assert the graceful shape.
	var decoded: Dictionary = RpcIntake.decode("}{ not json")
	assert_false(bool(decoded.get(RpcIntake.SLOT_OK, true)))
	assert_eq(decoded.get(RpcIntake.SLOT_ERROR, ""), "invalid_json")


func test_decode_leaves_params_untyped_for_the_caller_to_test() -> void:
	var decoded: Dictionary = RpcIntake.decode('{"method":"m","params":[1],"id":3}')
	assert_true(bool(decoded.get(RpcIntake.SLOT_OK, false)))
	# The whole point: decode must NOT have coerced this to a Dictionary.
	assert_true(decoded.get(RpcIntake.RAW_PARAMS, null) is Array)
	assert_eq(decoded.get(RpcIntake.MSG_ID, ""), "3")


# ------------------------------------------------------------------- shaped() helper


func test_shaped_falls_back_on_type_mismatch() -> void:
	var bag: Dictionary = {"quest": [], "items": {}, "good": {"a": 1}, "n": null}
	assert_eq(RpcIntake.shaped(bag, "quest", {}), {})
	assert_eq(RpcIntake.shaped(bag, "items", []), [])
	assert_eq(RpcIntake.shaped(bag, "good", {}), {"a": 1})
	assert_eq(RpcIntake.shaped(bag, "n", {}), {})
	assert_eq(RpcIntake.shaped(bag, "missing", {}), {})


# ------------------------------------------------------------------- the fuzz sweep


func _corpus() -> Array:
	"""Wrong-shape values for ANY envelope slot, as raw JSON fragments.

	Includes "{}" and '{"k":[]}' because those are wrong for the id/method/secret slots even
	though they are legal for params — the envelope sweep must tolerate all of them.
	"""
	return ["[]", "{}", "5", "-1", "1.5", '"s"', "null", "true", "[[]]", '{"k":[]}', "[null]"]


func _non_dict_corpus() -> Array:
	"""The subset that is specifically NOT a Dictionary — the params slot must reject these.

	A Dictionary params bag with malformed MEMBERS is a different (post-auth, nested) case
	and is covered by the shaped() guards, not by envelope rejection.
	"""
	return ["[]", "5", "-1", "1.5", '"s"', "null", "true", "[[]]", "[null]"]


func test_fuzz_every_envelope_slot_rejects_consistently() -> void:
	# Drive the REAL dispatch with malformed values in each envelope slot. Every frame must
	# come back as a non-empty, parseable JSON object carrying a result — never "" (abort).
	var slots: Array[String] = ["method", "params", "id", "secret"]
	var frames_checked: int = 0
	for slot: String in slots:
		for fragment: String in _corpus():
			var raw: String = (
				'{"method":"issue_session","params":{},"id":1,"secret":"","%s":%s}'
				% [slot, fragment]
			)
			var out: String = _main._handle_message(raw)
			assert_false(out.is_empty(), "slot=%s value=%s aborted the handler" % [slot, fragment])
			var envelope: Variant = JSON.parse_string(out)
			assert_true(
				envelope is Dictionary, "slot=%s value=%s emitted non-object" % [slot, fragment]
			)
			if envelope is Dictionary:
				assert_true(
					(envelope as Dictionary).has("result"),
					"slot=%s value=%s lost the result envelope" % [slot, fragment]
				)
			frames_checked += 1
	assert_eq(frames_checked, slots.size() * _corpus().size())
	assert_true(frames_checked >= 40, "fuzz corpus shrank below its floor")
	assert_engine_error_count(0, "the whole malformed-envelope corpus must stay error-free")


func test_fuzz_malformed_params_across_the_real_method_surface() -> void:
	# Same corpus, but sweeping the dispatch arms the audit flagged as carrying nested
	# typed reads — these are the arms where a bad params bag used to abort deepest.
	var methods: Array[String] = [
		"issue_session",
		"validate_session",
		"accept_quest",
		"turn_in",
		"abandon_quest",
		"talk",
		"grant_loot",
		"equip",
		"unequip",
		"drop",
		"spend_talent",
		"record_events",
	]
	CharacterManager.ensure_character("alice")
	for method: String in methods:
		for fragment: String in _non_dict_corpus():
			var raw: String = '{"method":"%s","params":%s,"id":2}' % [method, fragment]
			var result: Dictionary = _result_of(raw)
			assert_eq(
				result.get("error", ""),
				"invalid_params",
				"method=%s params=%s did not reject cleanly" % [method, fragment]
			)
	assert_engine_error_count(0, "no dispatch arm may raise on a malformed params bag")


func test_unknown_method_with_valid_params_still_answers() -> void:
	var out: String = _main._handle_message('{"method":"no_such_method","params":{},"id":9}')
	assert_false(out.is_empty())
