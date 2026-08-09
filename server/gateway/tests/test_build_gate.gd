extends "res://addons/gut/test.gd"
# T-514: the pure client-build gate. Security-critical: it validates an UNTRUSTED, self-reported
# string, so the tests pin format validation, fail-closed behavior, and the opt-in semantics.

const BuildGate = preload("res://scripts/build_gate.gd")

const CUR := "2026-07-16T19:38:00Z"
const OLD := "2026-07-16T16:04:00Z"


func test_valid_build_accepts_iso_utc_instant() -> void:
	assert_true(BuildGate.is_valid_build(CUR))
	assert_true(BuildGate.is_valid_build("2026-01-01T00:00:00Z"))


func test_valid_build_rejects_malformed_or_oversized_or_empty() -> void:
	assert_false(BuildGate.is_valid_build(""), "empty is not a build")
	assert_false(BuildGate.is_valid_build("2026-07-16"), "date without time is rejected")
	assert_false(BuildGate.is_valid_build("latest"), "arbitrary words rejected")
	assert_false(BuildGate.is_valid_build("2026-07-16T19:38:00"), "missing Z rejected")
	assert_false(BuildGate.is_valid_build("x".repeat(64)), "oversized rejected before regex")
	# Injection-shaped payloads never match the anchored pattern.
	assert_false(BuildGate.is_valid_build("2026-07-16T19:38:00Z'; DROP TABLE"))
	assert_false(BuildGate.is_valid_build("%s%s%s"))


func test_gate_is_opt_in_disabled_when_minimum_unset_or_garbage() -> void:
	assert_false(BuildGate.gate_enabled(""), "no minimum => gate off")
	assert_false(BuildGate.gate_enabled("garbage"), "malformed minimum => gate off")
	assert_true(BuildGate.gate_enabled(CUR))
	# Gate off => everything is allowed, even an empty/garbage client build.
	assert_true(BuildGate.meets_minimum("", ""))
	assert_true(BuildGate.meets_minimum("anything", ""))


func test_older_build_rejected_equal_and_newer_accepted_when_gate_on() -> void:
	assert_false(BuildGate.meets_minimum(OLD, CUR), "an older build is refused")
	assert_true(BuildGate.meets_minimum(CUR, CUR), "the exact minimum is allowed")
	assert_true(BuildGate.meets_minimum("2026-07-17T08:00:00Z", CUR), "a newer build is allowed")


func test_missing_or_garbage_client_build_fails_closed_when_gate_on() -> void:
	assert_false(BuildGate.meets_minimum("", CUR), "no build while gate on => outdated")
	assert_false(BuildGate.meets_minimum("latest", CUR), "spoofed non-stamp => outdated")
	assert_false(BuildGate.meets_minimum("2026-07-16", CUR), "malformed stamp => outdated")
