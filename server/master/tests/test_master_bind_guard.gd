extends "res://addons/gut/test.gd"
# T-378: the master's "public bind ⇒ secret required" boot guard (T-377 vector 8b).
# Tests the pure predicate (bind_secret_ok) instead of a real boot — no TCP/DB, no hang —
# plus the _handle_message choke point: with a secret set, EVERY method (known or not) is
# rejected before _dispatch unless the request carries the secret. There is no per-method
# bypass because _dispatch is only reachable through _handle_message.

const Main = preload("res://scripts/main.gd")

var _main: Main


func before_each() -> void:
	_main = Main.new()


func after_each() -> void:
	if _main != null:
		_main.free()
		_main = null


# ---- boot-guard predicate: loopback + no secret stays allowed (dev) --------------------


func test_loopback_ipv4_without_secret_boots() -> void:
	assert_true(Main.bind_secret_ok("127.0.0.1", ""))


func test_localhost_without_secret_boots() -> void:
	assert_true(Main.bind_secret_ok("localhost", ""))


func test_loopback_ipv6_without_secret_boots() -> void:
	assert_true(Main.bind_secret_ok("::1", ""))


# ---- boot-guard predicate: public bind + no secret REFUSES (fail-closed) ---------------


func test_wildcard_bind_without_secret_refuses() -> void:
	assert_false(Main.bind_secret_ok("0.0.0.0", ""))


func test_lan_bind_without_secret_refuses() -> void:
	assert_false(Main.bind_secret_ok("192.168.1.50", ""))


func test_ipv6_wildcard_bind_without_secret_refuses() -> void:
	assert_false(Main.bind_secret_ok("::", ""))


# ---- boot-guard predicate: public bind + secret is the supported sharding config -------


func test_wildcard_bind_with_secret_boots() -> void:
	assert_true(Main.bind_secret_ok("0.0.0.0", "s3cr3t-long-enough"))


func test_loopback_with_secret_boots() -> void:
	assert_true(Main.bind_secret_ok("127.0.0.1", "s3cr3t-long-enough"))


# ---- the choke point: secret (when set) gates every method before _dispatch ------------


func test_missing_secret_rejected_before_dispatch() -> void:
	_main._rpc_shared_secret = "hunter2"
	var raw := JSON.stringify({"id": 1, "method": "adjust_coins", "params": {}})
	var resp: Dictionary = JSON.parse_string(_main._handle_message(raw))
	assert_eq(str(resp["result"].get("error", "")), "unauthorized")


func test_wrong_secret_rejected_before_dispatch() -> void:
	_main._rpc_shared_secret = "hunter2"
	var raw := JSON.stringify(
		{"id": 1, "method": "issue_session", "secret": "wrong", "params": {"username": "victim"}}
	)
	var resp: Dictionary = JSON.parse_string(_main._handle_message(raw))
	assert_eq(str(resp["result"].get("error", "")), "unauthorized")


func test_correct_secret_reaches_dispatch() -> void:
	_main._rpc_shared_secret = "hunter2"
	# An unknown method proves the request PASSED the auth gate and reached _dispatch
	# (unknown_method is _dispatch's verdict) without touching Postgres in the test env.
	var raw := JSON.stringify({"id": 1, "method": "no_such_method", "secret": "hunter2"})
	var resp: Dictionary = JSON.parse_string(_main._handle_message(raw))
	assert_eq(str(resp["result"].get("error", "")), "unknown_method")
