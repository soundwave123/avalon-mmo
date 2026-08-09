extends GutTest

const OpsChannel = preload("res://scripts/ops_channel.gd")


func test_bind_guard_requires_loopback_and_nonempty_secret() -> void:
	assert_true(OpsChannel.bind_secret_ok("127.0.0.1", "strong-ops-secret"))
	assert_false(OpsChannel.bind_secret_ok("127.0.0.1", ""), "missing secret disables listener")
	assert_false(OpsChannel.bind_secret_ok("0.0.0.0", "strong-ops-secret"))
	assert_false(OpsChannel.bind_secret_ok("192.168.1.20", "strong-ops-secret"))


func test_authentication_fails_closed_for_missing_or_wrong_secret() -> void:
	assert_false(OpsChannel.secret_ok("expected-secret", ""))
	assert_false(OpsChannel.secret_ok("expected-secret", "wrong-secret"))
	assert_true(OpsChannel.secret_ok("expected-secret", "expected-secret"))


func test_request_parser_requires_actor_verb_params_and_never_defaults_auth() -> void:
	assert_eq(OpsChannel.parse_request("not json"), {"ok": false, "error": "invalid_json"})
	assert_eq(
		OpsChannel.parse_request(JSON.stringify({"secret": "s", "actor": "gm"}))["error"],
		"invalid_request"
	)
	var parsed: Dictionary = OpsChannel.parse_request(
		JSON.stringify({"secret": "s", "actor": "gm", "verb": "who", "params": {}})
	)
	assert_true(parsed["ok"])
	assert_eq(parsed["request"]["verb"], "who")
