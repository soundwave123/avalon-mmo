extends RefCounted
# T-754: the master's RPC frame decoder — the ONE place untrusted bytes become typed values.
#
# Why this file exists (measured on the pinned 4.7.1, not assumed):
#   In GDScript 4 a typed assignment from a mismatched Variant is a RUNTIME error:
#     "Trying to assign value of type 'Array' to a variable of type 'Dictionary'"
#   It aborts the CURRENT function frame only — the caller resumes, and the aborted
#   function returns the DEFAULT of its declared return type ("" for String), not null.
#   So `_handle_message` did not crash the master: it silently returned an empty packet
#   and the caller's correlated request hung, while stderr filled with backtraces. A peer
#   that could reach the port could do this WITHOUT authenticating.
#
#   The same abort comes from the int()/bool()/float() constructors, which reject
#   Dictionary/Array/null outright ("Nonexistent 'int' constructor"). str() is total and
#   never aborts, which is why every other envelope read is safe.
#
# The rule this module enforces: parse to Variant, type-test, THEN assign typed — and do
# the shared-secret check before any caller-controlled payload is coerced at all.

# Slot names in the decoded frame, so main.gd and the tests agree on one vocabulary.
# Deliberately NOT named OK/ERROR: those shadow Godot's global Error enum inside this file.
const SLOT_OK := "ok"
const SLOT_ERROR := "error"
const MSG_ID := "msg_id"
const METHOD := "method"
const SECRET := "secret"
const RAW_PARAMS := "raw_params"


static func msg_id_of(raw_id: Variant) -> String:
	"""Normalise a wire id to the master's String-of-int key.

	int() aborts the calling frame on Dictionary/Array/null, so the type test is not
	cosmetic — {"id": []} was a pre-auth abort vector in its own right.
	"""
	if raw_id is int or raw_id is float:
		return str(int(raw_id))
	if raw_id is String or raw_id is StringName:
		return str(int(String(raw_id)))
	return "0"


static func decode(raw: String) -> Dictionary:
	"""Decode one wire frame into typed slots, or an {ok: false, error: ...} rejection.

	Uses JSON.new().parse() rather than JSON.parse_string(): parse_string pushes its own
	engine ERROR (core/io/json.cpp) on malformed input no matter what you assign it to,
	which would make "graceful rejection with zero engine errors" impossible to hold.
	The instance API returns an error code silently.
	"""
	var json := JSON.new()
	if json.parse(raw) != OK:
		return {SLOT_OK: false, MSG_ID: "", SLOT_ERROR: "invalid_json"}

	var data: Variant = json.data
	if typeof(data) != TYPE_DICTIONARY:
		return {SLOT_OK: false, MSG_ID: "", SLOT_ERROR: "invalid_json"}

	var frame: Dictionary = data
	return {
		SLOT_OK: true,
		MSG_ID: msg_id_of(frame.get("id", 0)),
		METHOD: str(frame.get("method", "")),
		SECRET: str(frame.get("secret", "")),
		# Deliberately NOT coerced here: the auth gate must run before we type-test payload.
		RAW_PARAMS: frame.get("params", {}),
	}


static func encode_response(id: String, payload: Dictionary) -> String:
	"""Encode one reply envelope. Lives here so both directions of the wire format are in
	one file (carved out of main.gd, which sits at the 1000-line cap)."""
	var resp: Dictionary = {}
	if not id.is_empty():
		resp["id"] = id
	resp["result"] = payload
	var json_str: String = JSON.stringify(resp)
	return json_str if not json_str.is_empty() else "{}"


static func shaped(source: Dictionary, key: String, fallback: Variant) -> Variant:
	"""Read `key` from an authenticated params bag, falling back when the shape is wrong.

	Every nested master read spells its own expectation in its default — `params.get("quest",
	{})` wants a Dictionary, `params.get("items", [])` wants an Array — so the fallback's
	type IS the schema. Returns `fallback` whenever the stored value's type differs, which
	makes the downstream typed assignment/parameter total.
	"""
	var value: Variant = source.get(key, fallback)
	if typeof(value) != typeof(fallback):
		return fallback
	return value
