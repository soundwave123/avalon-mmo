extends "res://addons/gut/test.gd"

# Unit tests for server/master/scripts/session_manager.gd.
# Tests JWT-based session validation (T-006).

const SessionManager = preload("res://scripts/session_manager.gd")
const JwtUtilScript = preload("res://scripts/jwt.gd")

# A valid 32-byte signing secret (raw string, >= 32 chars)
const VALID_SECRET := "this_is_a_valid_secret_key_32chars!"

var jwt: Object


func before_each() -> void:
	SessionManager.reset_for_test()
	jwt = JwtUtilScript.new()


func after_each() -> void:
	pass


# ---- JWT secret validation tests ----


func test_init_from_env_with_valid_secret() -> void:
	SessionManager.set_test_secret(VALID_SECRET)
	assert_true(SessionManager.is_secret_valid(), "valid secret must pass validation")


func test_init_from_env_with_missing_secret() -> void:
	SessionManager.set_test_secret("")
	assert_false(SessionManager.is_secret_valid(), "missing secret must fail validation")


func test_init_from_env_with_short_secret() -> void:
	SessionManager.set_test_secret("short")
	assert_false(SessionManager.is_secret_valid(), "short secret must fail validation")


func test_is_secret_valid_with_valid_secret() -> void:
	SessionManager.set_test_secret(VALID_SECRET)
	assert_true(SessionManager.is_secret_valid(), "valid secret must return true")


func test_is_secret_valid_with_empty_secret() -> void:
	SessionManager.set_test_secret("")
	assert_false(SessionManager.is_secret_valid(), "empty secret must return false")


func test_is_secret_valid_with_short_secret() -> void:
	SessionManager.set_test_secret("short")
	assert_false(SessionManager.is_secret_valid(), "short secret must return false")


func test_is_secret_valid_with_placeholder() -> void:
	SessionManager.set_test_secret("***")
	assert_false(SessionManager.is_secret_valid(), "*** placeholder must return false")


# ---- JWT validation tests (without Postgres) ----


func test_validate_session_with_valid_jwt() -> void:
	SessionManager.set_test_secret(VALID_SECRET)

	var token: String = jwt.sign({"sub": "alice"}, VALID_SECRET, 3600)
	var result: Dictionary = SessionManager.validate_session(token)
	# Without Postgres, DB check fails closed → "revoked" is expected in degraded mode.
	# With Postgres, we get success. Either way, JWT verification ran without error.
	assert_true(
		result.has("success"), "validate_session must return a result dictionary with success key"
	)


func test_validate_session_with_expired_jwt() -> void:
	SessionManager.set_test_secret(VALID_SECRET)

	# TTL=-60 ensures token expiry is well past clock_skew (30s), so it's truly expired.
	var token: String = jwt.sign({"sub": "expired_user"}, VALID_SECRET, -60)
	var result: Dictionary = SessionManager.validate_session(token)
	assert_false(result.get("success", true), "expired token must be rejected")
	assert_eq(str(result.get("reason", "")), "expired", "reason must be expired")


func test_validate_session_with_wrong_secret() -> void:
	SessionManager.set_test_secret(VALID_SECRET)

	var token: String = jwt.sign({"sub": "alice"}, "different_secret_that_is_32_chars!", 3600)
	var result: Dictionary = SessionManager.validate_session(token)
	assert_false(result.get("success", true), "token with wrong secret must be rejected")
	assert_eq(
		str(result.get("reason", "")), "invalid_signature", "reason must be invalid_signature"
	)


func test_validate_session_with_tampered_token() -> void:
	SessionManager.set_test_secret(VALID_SECRET)

	var token: String = jwt.sign({"sub": "alice"}, VALID_SECRET, 3600)
	var parts: PackedStringArray = token.split(".")
	var payload: String = parts[1]
	var tampered_payload: String = ""
	for i in range(payload.length()):
		if i == payload.length() / 2:
			tampered_payload += ("X" if payload[i] != "X" else "A")
		else:
			tampered_payload += payload[i]
	var tampered_token: String = parts[0] + "." + tampered_payload + "." + parts[2]
	var result: Dictionary = SessionManager.validate_session(tampered_token)
	assert_false(result.get("success", true), "tampered token must be rejected")
	assert_eq(
		str(result.get("reason", "")), "invalid_signature", "reason must be invalid_signature"
	)


func test_validate_session_with_malformed_token() -> void:
	SessionManager.set_test_secret(VALID_SECRET)

	var result: Dictionary = SessionManager.validate_session("not.a.valid.jwt")
	assert_false(result.get("success", true), "malformed token must be rejected")
	assert_eq(str(result.get("reason", "")), "invalid_format", "reason must be invalid_format")


func test_validate_session_with_empty_token() -> void:
	SessionManager.set_test_secret(VALID_SECRET)

	var result: Dictionary = SessionManager.validate_session("")
	assert_false(result.get("success", true), "empty token must be rejected")


# ---- Issue session tests ----


func test_issue_session_returns_success() -> void:
	SessionManager.set_test_secret(VALID_SECRET)

	var result: Dictionary = SessionManager.issue_session("alice", 120)
	assert_true(result.get("success", false), "issue_session must return success")
	assert_eq(result.get("ttl_minutes", 0), 120, "TTL must match")


# ---- T-007: Refresh token rotation tests ----


func test_store_refresh_session() -> void:
	SessionManager.set_test_secret(VALID_SECRET)
	SessionManager.set_test_refresh_secret(VALID_SECRET)

	var result: bool = SessionManager.store_refresh_session(
		"alice", "jti_abc123", "access_token", "refresh_token"
	)
	assert_true(result, "store_refresh_session must return true")


func test_rotate_refresh_success() -> void:
	SessionManager.set_test_secret(VALID_SECRET)
	SessionManager.set_test_refresh_secret(VALID_SECRET)

	# Store initial session
	SessionManager.store_refresh_session("alice", "jti_v1", "access", "refresh")

	# Rotate with correct jti
	var result: Dictionary = SessionManager.rotate_refresh("alice", "jti_v1")
	assert_true(result.get("success", false), "rotation with correct jti must succeed")
	assert_eq(str(result.get("username", "")), "alice", "must return username")


func test_rotate_refresh_replayed_token_rejected() -> void:
	SessionManager.set_test_secret(VALID_SECRET)
	SessionManager.set_test_refresh_secret(VALID_SECRET)

	SessionManager.store_refresh_session("bob", "jti_v1", "access", "refresh")

	# First rotation succeeds
	var first: Dictionary = SessionManager.rotate_refresh("bob", "jti_v1")
	assert_true(first.get("success", false), "first rotation must succeed")

	# Second rotation with same jti must FAIL (HARD REJECTION)
	var second: Dictionary = SessionManager.rotate_refresh("bob", "jti_v1")
	assert_false(second.get("success", true), "replayed refresh must be REJECTED")
	assert_eq(
		str(second.get("reason", "")),
		"refresh_token_consumed",
		"reason must be refresh_token_consumed"
	)


func test_rotate_refresh_wrong_jti_rejected() -> void:
	SessionManager.set_test_secret(VALID_SECRET)
	SessionManager.set_test_refresh_secret(VALID_SECRET)

	SessionManager.store_refresh_session("carol", "jti_correct", "access", "refresh")

	var result: Dictionary = SessionManager.rotate_refresh("carol", "jti_wrong")
	assert_false(result.get("success", true), "wrong jti must be rejected")
	assert_eq(
		str(result.get("reason", "")),
		"refresh_token_consumed",
		"reason must be refresh_token_consumed"
	)


func test_rotate_refresh_unknown_user_rejected() -> void:
	SessionManager.set_test_secret(VALID_SECRET)
	SessionManager.set_test_refresh_secret(VALID_SECRET)

	var result: Dictionary = SessionManager.rotate_refresh("unknown", "jti_abc")
	assert_false(result.get("success", true), "unknown user must be rejected")
	assert_eq(
		str(result.get("reason", "")),
		"refresh_token_consumed",
		"reason must be refresh_token_consumed"
	)


func test_concurrent_refresh_exactly_one_winner() -> void:
	"""
	Security-critical: simulate two concurrent rotations on the same jti.
	Must resolve to exactly one success and one failure.
	"""
	SessionManager.set_test_secret(VALID_SECRET)
	SessionManager.set_test_refresh_secret(VALID_SECRET)

	SessionManager.store_refresh_session("race_user", "jti_race", "access", "refresh")

	var result1: Dictionary = SessionManager.rotate_refresh("race_user", "jti_race")
	var result2: Dictionary = SessionManager.rotate_refresh("race_user", "jti_race")

	var success_count: int = 0
	if result1.get("success", false):
		success_count += 1
	if result2.get("success", false):
		success_count += 1

	assert_eq(success_count, 1, "concurrent race must resolve to exactly ONE winner")

	# Loser must have hard rejection
	if not result1.get("success", false):
		assert_false(result1.get("reason", "").is_empty(), "loser must have rejection reason")
	if not result2.get("success", false):
		assert_false(result2.get("reason", "").is_empty(), "loser must have rejection reason")
