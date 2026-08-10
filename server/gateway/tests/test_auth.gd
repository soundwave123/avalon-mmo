extends "res://addons/gut/test.gd"

# Unit tests for server/gateway/scripts/auth.gd.
# Tests JWT-based authentication (T-006).

const Auth = preload("res://scripts/auth.gd")
const JwtUtilScript = preload("res://scripts/jwt.gd")

# A valid 32-byte signing secret (raw string, >= 32 chars)
const VALID_SECRET := "this_is_a_valid_secret_key_32chars!"

var jwt: JwtUtilScript


func before_each() -> void:
	Auth.reset_for_test()
	jwt = JwtUtilScript.new()


func test_validate_login_accepts_valid_creds() -> void:
	Auth.set_test_auth_mode("dev")
	assert_true(Auth.validate_login("alice", "dev"), "valid credentials must pass")


func test_validate_login_rejects_empty_username() -> void:
	Auth.set_test_auth_mode("dev")
	assert_false(Auth.validate_login("", "dev"), "empty username must fail")


func test_validate_login_rejects_wrong_password() -> void:
	Auth.set_test_auth_mode("dev")
	assert_false(Auth.validate_login("alice", "wrong"), "wrong password must fail")


func test_issue_token_returns_valid_jwt() -> void:
	# Set a valid secret for testing
	Auth.set_test_secret(VALID_SECRET)

	var token: String = Auth.issue_token("alice")
	assert_false(token.is_empty(), "token must not be empty")
	assert_true(jwt.is_valid_jwt_format(token), "token must have valid JWT format")

	# Verify the token
	var result: Dictionary = jwt.verify(token, VALID_SECRET)
	assert_true(_b(result.get("valid", false)), "issued token must verify")
	var payload: Dictionary = result["payload"]
	assert_eq(str(payload.get("sub", "")), "alice", "sub claim must match username")


func test_issue_token_returns_empty_without_secret() -> void:
	# Without a valid secret, token issuance should fail
	var token: String = Auth.issue_token("alice")
	assert_true(token.is_empty(), "token must be empty when secret validation fails")


func test_verify_token_accepts_valid() -> void:
	Auth.set_test_secret(VALID_SECRET)

	var token: String = Auth.issue_token("bob")
	var result: Dictionary = Auth.verify_token(token)
	assert_true(_b(result.get("valid", false)), "valid token must be accepted")


func test_verify_token_rejects_wrong_secret() -> void:
	Auth.set_test_secret(VALID_SECRET)

	var token: String = Auth.issue_token("charlie")
	# Change secret to simulate wrong key
	Auth.set_test_secret("different_secret_that_is_32_chars!")
	var result: Dictionary = Auth.verify_token(token)
	assert_false(_b(result.get("valid", true)), "token with wrong secret must be rejected")


# ---- T-007: Refresh token tests ----


func test_issue_tokens_returns_access_and_refresh() -> void:
	Auth.set_test_secret(VALID_SECRET)
	Auth.set_test_refresh_secret(VALID_SECRET)

	var result: Dictionary = Auth.issue_tokens("alice")
	assert_false(result.has("error"), "must not have error")
	assert_true(result.has("access_token"), "must have access_token")
	assert_true(result.has("refresh_token"), "must have refresh_token")
	assert_false(str(result["access_token"]).is_empty(), "access_token must not be empty")
	assert_false(str(result["refresh_token"]).is_empty(), "refresh_token must not be empty")


func test_issue_tokens_fails_without_refresh_secret() -> void:
	Auth.set_test_secret(VALID_SECRET)
	# No refresh secret set
	Auth.set_test_refresh_secret("")

	var result: Dictionary = Auth.issue_tokens("alice")
	assert_true(result.has("error"), "must have error when refresh secret missing")


func test_rotate_refresh_token_valid() -> void:
	Auth.set_test_secret(VALID_SECRET)
	Auth.set_test_refresh_secret(VALID_SECRET)

	# First, issue tokens (this stores the session)
	var tokens: Dictionary = Auth.issue_tokens("alice")
	var refresh_token: String = tokens["refresh_token"]

	# Rotate should succeed
	var result: Dictionary = Auth.rotate_refresh_token(refresh_token)
	assert_true(_b(result.get("success", false)), "valid rotation must succeed")
	assert_true(result.has("access_token"), "must return new access_token")
	assert_true(result.has("refresh_token"), "must return new refresh_token")


func test_rotate_refresh_token_reused_rejected() -> void:
	Auth.set_test_secret(VALID_SECRET)
	Auth.set_test_refresh_secret(VALID_SECRET)

	var tokens: Dictionary = Auth.issue_tokens("bob")
	var refresh_token: String = tokens["refresh_token"]

	# First rotation succeeds
	var first: Dictionary = Auth.rotate_refresh_token(refresh_token)
	assert_true(_b(first.get("success", false)), "first rotation must succeed")

	# Second rotation with SAME token must FAIL (401)
	var second: Dictionary = Auth.rotate_refresh_token(refresh_token)
	assert_false(_b(second.get("success", true)), "reused refresh token must be REJECTED")
	assert_eq(
		str(second.get("reason", "")),
		"refresh_token_consumed",
		"reason must be refresh_token_consumed"
	)


func test_rotate_refresh_token_expired() -> void:
	Auth.set_test_secret(VALID_SECRET)
	Auth.set_test_refresh_secret(VALID_SECRET)

	# Issue a refresh token that's already expired
	var jwt := Auth.JwtUtil.new()
	var expired_refresh: String = jwt.sign(
		{"sub": "expired_user", "jti": "expired_jti_1234567890abcdef"},
		VALID_SECRET,
		-3600,
		"refresh"
	)

	var result: Dictionary = Auth.rotate_refresh_token(expired_refresh)
	assert_false(_b(result.get("success", true)), "expired refresh token must be rejected")
	assert_eq(str(result.get("reason", "")), "expired", "reason must be expired")


func test_rotate_refresh_token_wrong_secret() -> void:
	Auth.set_test_secret(VALID_SECRET)
	Auth.set_test_refresh_secret(VALID_SECRET)

	var jwt := Auth.JwtUtil.new()
	# Sign with wrong secret
	var wrong_token: String = jwt.sign(
		{"sub": "alice", "jti": "wrong_secret_jti_12345678"},
		"different_secret_that_is_32_chars!",
		86400,
		"refresh"
	)

	var result: Dictionary = Auth.rotate_refresh_token(wrong_token)
	assert_false(_b(result.get("success", true)), "wrong secret must be rejected")
	assert_eq(
		str(result.get("reason", "")), "invalid_signature", "reason must be invalid_signature"
	)


func test_rotate_refresh_token_wrong_type() -> void:
	Auth.set_test_secret(VALID_SECRET)
	Auth.set_test_refresh_secret(VALID_SECRET)

	var jwt := Auth.JwtUtil.new()
	# Present an access token to the refresh endpoint
	var access_token: String = jwt.sign({"sub": "alice"}, VALID_SECRET, 900, "access")

	var result: Dictionary = Auth.rotate_refresh_token(access_token)
	assert_false(_b(result.get("success", true)), "access token must be rejected as refresh")
	assert_eq(str(result.get("reason", "")), "wrong_token_type", "reason must be wrong_token_type")


func test_rotate_refresh_concurrent_race() -> void:
	"""
	Critical security test: two concurrent refreshes on the same jti
	must resolve to exactly ONE winner and ONE loser.
	"""
	Auth.set_test_secret(VALID_SECRET)
	Auth.set_test_refresh_secret(VALID_SECRET)

	var tokens: Dictionary = Auth.issue_tokens("race_user")
	var refresh_token: String = tokens["refresh_token"]

	# Simulate two concurrent requests with the same refresh token
	var result1: Dictionary = Auth.rotate_refresh_token(refresh_token)
	var result2: Dictionary = Auth.rotate_refresh_token(refresh_token)

	# Exactly one must succeed, one must fail
	var success_count: int = 0
	if result1.get("success", false):
		success_count += 1
	if result2.get("success", false):
		success_count += 1

	assert_eq(success_count, 1, "concurrent race must resolve to exactly ONE winner")

	# The loser must have a hard rejection reason
	if not _b(result1.get("success", false)):
		var reason_1 := str(result1.get("reason", ""))
		assert_false(reason_1.is_empty(), "loser must have a rejection reason")
	if not _b(result2.get("success", false)):
		var reason_2 := str(result2.get("reason", ""))
		assert_false(reason_2.is_empty(), "loser must have a rejection reason")


func test_is_secret_valid_requires_both_secrets() -> void:
	Auth.reset_for_test()
	# Only access secret set
	Auth.set_test_secret(VALID_SECRET)
	assert_false(Auth.is_secret_valid(), "must fail without refresh secret")

	# Only refresh secret set
	Auth.reset_for_test()
	Auth.set_test_refresh_secret(VALID_SECRET)
	assert_false(Auth.is_secret_valid(), "must fail without access secret")

	# Both set
	Auth.reset_for_test()
	Auth.set_test_secret(VALID_SECRET)
	Auth.set_test_refresh_secret(VALID_SECRET)
	assert_true(Auth.is_secret_valid(), "must pass with both secrets")


# ---- T-074: username charset allowlist ----


func test_valid_username_accepts_allowlisted_charset() -> void:
	for u: String in ["abc", "player1", "kit_warrior", "a-b_c9", "abcdefghij0123456789"]:
		assert_true(Auth.valid_username(u), "'%s' must pass the allowlist" % u)


func test_valid_username_rejects_injection_surfaces() -> void:
	# Quotes break jwt.gd's JSON, tabs corrupt database.gd's TSV, unicode breaks
	# _string_to_bytes, uppercase/short/long are out of policy.
	var bad := [
		'evil"name', "tab\tname", "uniçode", "UPPER", "ab", "abcdefghij01234567890", "a b", ""
	]
	for u: String in bad:
		assert_false(Auth.valid_username(str(u)), "'%s' must be rejected" % str(u))


func test_validate_login_uses_allowlist() -> void:
	Auth.set_test_auth_mode("dev")
	assert_false(Auth.validate_login('evil"name', "dev"), "allowlist must gate login")
	assert_true(Auth.validate_login("player1", "dev"))


# T-757: typed pass-throughs. bool()/int() constructor calls and GUT's untyped assert
# parameters both flag hard-Variant arguments under the unsafe_call_argument=2 gate;
# a typed assignment through an explicit Variant parameter is the warning-clean
# equivalent (and now also asserts the value's runtime type).
static func _b(v: Variant) -> bool:
	var typed: bool = v
	return typed
