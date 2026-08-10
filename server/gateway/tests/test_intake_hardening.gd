extends "res://addons/gut/test.gd"

# T-754: the gateway's PUBLIC (0.0.0.0) frame intake — malformed frames must be rejected
# with ZERO engine errors.
#
# The gateway's TYPE guard was already correct (parse to Variant -> `is Dictionary` ->
# typed assign; it is the idiom the master now copies, and the sweep found no typed
# coercion of wire data anywhere in this service — every nested read is str()/int()/bool()).
# What was NOT correct: it parsed with JSON.parse_string(), which pushes its own engine
# ERROR plus a GDScript backtrace on every malformed input regardless of the destination
# type. On the one listener bound to the public interface, with no authentication in front
# of it, that is an unauthenticated stderr-flood primitive. JSON.new().parse() reports the
# same failure silently via a return code.
#
# Scope note, measured not assumed: jwt.gd ALSO parses with parse_string, but its two calls
# sit AFTER the timing-safe signature check, so they are unreachable without the signing
# secret. That is not an unauthenticated vector and jwt.gd (a byte-identical shared file)
# was deliberately left alone.

const Main = preload("res://scripts/main.gd")


func test_malformed_frames_decode_to_null_without_engine_errors() -> void:
	for raw: String in ["not json", "", "{", "}{", "\t", '{"a":}', "[1,", '{"a":1']:
		# T-757 @warning_ignore reason: decode_frame returns Variant BY DESIGN (null means
		# rejected frame) and assert_null's parameter is untyped — no typed form exists.
		@warning_ignore("unsafe_call_argument")
		assert_null(Main.decode_frame(raw), "garbage frame must decode to null: %s" % raw)
	assert_engine_error_count(0, "a malformed frame must not raise an engine error")


func test_valid_json_with_a_non_object_root_is_rejected() -> void:
	# These parse fine but are not frames. The guard catches them; the point is silence.
	for raw: String in ["[1,2]", "42", '"a string"', "null", "true", "[]", "[[1]]", "-1.5"]:
		# T-757 @warning_ignore reason: same by-design-Variant assert_null pairing as above.
		@warning_ignore("unsafe_call_argument")
		assert_null(Main.decode_frame(raw), "non-object root must decode to null: %s" % raw)
	assert_engine_error_count(0, "a non-object root must not raise an engine error")


func test_a_well_formed_frame_still_decodes() -> void:
	var decoded: Variant = Main.decode_frame('{"type":"login","username":"alice"}')
	assert_true(decoded is Dictionary, "a valid frame must decode to a Dictionary")
	if decoded is Dictionary:
		var decoded_dict: Dictionary = decoded
		assert_eq(str(decoded_dict.get("type", "")), "login")
	assert_engine_error_count(0, "the happy path must not raise an engine error")


func test_numeric_overflow_is_a_known_engine_warning_not_an_abort() -> void:
	# KNOWN RESIDUAL, documented rather than hidden. "1e999" makes Godot's number tokenizer
	# emit an "Exponent too high" WARNING from built_in_strtod (core/string/ustring.cpp),
	# BELOW the JSON API — measured: both JSON.new().parse() and JSON.parse_string() do it,
	# so no API choice avoids it, and it is not something this ticket can close.
	#
	# What matters is that it is only a log line: the parse SUCCEEDS (err == OK, value ==
	# inf), nothing aborts, and decode_frame still rejects the bare number for not being an
	# object. Deliberately kept out of the fuzz corpus above so that test's zero-error
	# assertion stays meaningful.
	# T-757 @warning_ignore reason: by-design-Variant assert_null pairing (see above).
	@warning_ignore("unsafe_call_argument")
	assert_null(Main.decode_frame("1e999"), "an overflowing bare number is still not a frame")
	@warning_ignore("unsafe_call_argument")
	assert_null(Main.decode_frame("-1e999"), "same for the negative case")
	# Declare the two engine warnings so they are accounted for, not silently tolerated.
	assert_engine_error_count(2, "exactly two 'Exponent too high' warnings, one per input")


func test_fuzz_frame_corpus_is_silent_and_consistent() -> void:
	# Every shape a hostile peer can put on the wire, including deeply nested and oversized.
	var corpus: Array[String] = [
		"not json",
		"",
		" ",
		"{",
		"}",
		"[",
		"]",
		"null",
		"true",
		"false",
		"0",
		"-1",
		'"str"',
		"[1,2,3]",
		'{"type":[]}',
		'{"type":null}',
		'{"type":{"nested":[1,2]}}',
		'{"unclosed":',
		'{"dup":1,"dup":2}',
		'{"deep":{"a":{"b":{"c":[1,{"d":2}]}}}}',
	]
	var objects: int = 0
	for raw: String in corpus:
		var decoded: Variant = Main.decode_frame(raw)
		# decode_frame is total: it returns a Dictionary or null, never anything else.
		assert_true(
			decoded == null or decoded is Dictionary,
			"decode_frame returned a non-Dictionary non-null for: %s" % raw
		)
		if decoded is Dictionary:
			objects += 1
	assert_eq(objects, 5, "exactly the object-rooted frames should survive")
	assert_true(corpus.size() >= 20, "fuzz corpus shrank below its floor")

	assert_engine_error_count(0, "no frame shape may raise an engine error")
