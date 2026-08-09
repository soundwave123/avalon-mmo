extends "res://addons/gut/test.gd"

# gdlint: disable=max-public-methods
# Unit tests for server/shared/jwt.gd — JWT signing and verification (HS256).
# Tests the security-critical path: signing, verification, tamper detection,
# expiry handling, and secret validation.

const JwtUtilScript = preload("res://scripts/jwt.gd")

# A valid 32-byte signing secret (raw string, >= 32 chars)
const VALID_SECRET := "this_is_a_valid_secret_key_32chars!"

var jwt: Object


func before_each() -> void:
	jwt = JwtUtilScript.new()


func after_each() -> void:
	pass


# ---- Signing tests ----


func test_sign_produces_valid_jwt_format() -> void:
	var token: String = jwt.sign({"sub": "alice"}, VALID_SECRET, 3600)
	assert_true(jwt.is_valid_jwt_format(token), "signed token must have valid JWT format")
	var parts: PackedStringArray = token.split(".")
	assert_eq(parts.size(), 3, "token must have 3 dot-separated parts")
	for part in parts:
		assert_false(part.is_empty(), "each JWT part must be non-empty")


func test_sign_includes_standard_claims() -> void:
	var token: String = jwt.sign({"sub": "bob"}, VALID_SECRET, 3600)
	var result: Dictionary = jwt.verify(token, VALID_SECRET)
	assert_true(result.get("valid", false), "signed token must verify")
	var payload: Dictionary = result["payload"]
	assert_eq(str(payload.get("sub", "")), "bob", "payload must include sub claim")
	assert_true(payload.has("iat"), "payload must include iat claim")
	assert_true(payload.has("exp"), "payload must include exp claim")


func test_sign_includes_correct_ttl() -> void:
	var token: String = jwt.sign({"sub": "charlie"}, VALID_SECRET, 1800)
	var result: Dictionary = jwt.verify(token, VALID_SECRET)
	assert_true(result.get("valid", false), "signed token must verify")
	var payload: Dictionary = result["payload"]
	var iat: float = payload.get("iat", 0)
	var exp: float = payload.get("exp", 0)
	var actual_ttl: float = exp - iat
	assert_true(
		actual_ttl >= 1799 and actual_ttl <= 1801, "TTL should be ~1800s, got %f" % actual_ttl
	)


# ---- Verification tests (security-critical) ----


func test_verify_accepts_valid_token() -> void:
	var token: String = jwt.sign({"sub": "alice"}, VALID_SECRET, 3600)
	var result: Dictionary = jwt.verify(token, VALID_SECRET)
	assert_true(result.get("valid", false), "valid token must be accepted")
	assert_eq(str(result["payload"].get("sub", "")), "alice", "sub claim must match")


func test_verify_rejects_wrong_secret() -> void:
	var token: String = jwt.sign({"sub": "alice"}, VALID_SECRET, 3600)
	var result: Dictionary = jwt.verify(token, "different_secret_that_is_32_chars!")
	assert_false(result.get("valid", true), "token with wrong secret must be rejected")
	assert_eq(
		str(result.get("reason", "")), "invalid_signature", "reason must be invalid_signature"
	)


func test_verify_rejects_tampered_token() -> void:
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
	var result: Dictionary = jwt.verify(tampered_token, VALID_SECRET)
	assert_false(result.get("valid", true), "tampered token must be rejected")
	assert_eq(
		str(result.get("reason", "")), "invalid_signature", "reason must be invalid_signature"
	)


func test_verify_rejects_expired_token() -> void:
	# Sign token with past time so it's genuinely expired when verified.
	var past_time: int = 1000000
	jwt.set_mock_time(past_time)
	var token: String = jwt.sign({"sub": "expired_user"}, VALID_SECRET, 0)
	# Set mock time to well after expiry (exp = past_time + 0, clock_skew = 30).
	# past_time + 100 > past_time + 30, so token is expired.
	jwt.set_mock_time(past_time + 100)
	var result: Dictionary = jwt.verify(token, VALID_SECRET)
	assert_false(result.get("valid", true), "expired token must be rejected")
	assert_eq(str(result.get("reason", "")), "expired", "reason must be expired")


func test_verify_rejects_malformed_token() -> void:
	var result: Dictionary = jwt.verify("not.a.valid.jwt.token", VALID_SECRET)
	assert_false(result.get("valid", true), "malformed token must be rejected")
	assert_eq(str(result.get("reason", "")), "invalid_format", "reason must be invalid_format")


func test_verify_rejects_empty_token() -> void:
	var result: Dictionary = jwt.verify("", VALID_SECRET)
	assert_false(result.get("valid", true), "empty token must be rejected")


func test_verify_rejects_single_part_token() -> void:
	var result: Dictionary = jwt.verify("eyJhbG...NiJ9", VALID_SECRET)
	assert_false(result.get("valid", true), "single-part token must be rejected")


func test_verify_rejects_two_part_token() -> void:
	var result: Dictionary = jwt.verify("part1.part2", VALID_SECRET)
	assert_false(result.get("valid", true), "two-part token must be rejected")


# ---- Secret validation tests (fail-fast guard) ----


func test_validate_secret_accepts_valid_32_chars() -> void:
	assert_true(jwt.validate_secret(VALID_SECRET), "32-char secret must be valid")


func test_validate_secret_accepts_longer_secret() -> void:
	var long_secret: String = "this_is_a_very_long_secret_key_that_exceeds_32_characters_easily"
	assert_true(jwt.validate_secret(long_secret), "long secret must be valid")


func test_validate_secret_rejects_empty() -> void:
	assert_false(jwt.validate_secret(""), "empty secret must be rejected")


func test_validate_secret_rejects_short_secret() -> void:
	assert_false(jwt.validate_secret("short"), "short secret must be rejected")


func test_validate_secret_rejects_underscore_placeholder() -> void:
	assert_false(jwt.validate_secret("***"), "*** placeholder must be rejected")


func test_validate_secret_rejects_short_placeholder() -> void:
	assert_false(jwt.validate_secret("CHANGE_ME_32_BYTE"), "CHANGE_ME placeholder must be rejected")


# ---- Format validation (world server use) ----


func test_is_valid_jwt_format_accepts_real_token() -> void:
	var token: String = jwt.sign({"sub": "alice"}, VALID_SECRET, 3600)
	assert_true(jwt.is_valid_jwt_format(token), "real JWT must pass format check")


func test_is_valid_jwt_format_rejects_hex_token() -> void:
	assert_false(
		jwt.is_valid_jwt_format("abcdef0123456789abcdef0123456789"), "hex token must be rejected"
	)


func test_is_valid_jwt_format_rejects_empty() -> void:
	assert_false(jwt.is_valid_jwt_format(""), "empty must be rejected")


func test_is_valid_jwt_format_rejects_spaces() -> void:
	assert_false(jwt.is_valid_jwt_format("hello world"), "spaces must be rejected")


# ---- Base64url encoding tests ----


func test_base64url_encode_decodes_roundtrip() -> void:
	var original: PackedByteArray = _str_to_bytes("Hello, World!")
	var encoded: String = jwt.base64url_encode(original)
	var decoded: PackedByteArray = jwt.base64url_decode(encoded)
	assert_eq(decoded, original, "roundtrip must produce identical bytes")


func test_base64url_encode_no_special_chars() -> void:
	var encoded: String = jwt.base64url_encode(PackedByteArray([0x00, 0x01, 0x02, 0x03]))
	assert_false(encoded.contains("+"), "must not contain +")
	assert_false(encoded.contains("/"), "must not contain /")
	assert_false(encoded.contains("="), "must not contain =")


func test_base64url_decode_with_padding() -> void:
	var encoded: String = jwt.base64url_encode(PackedByteArray([0x61, 0x62]))
	var decoded: PackedByteArray = jwt.base64url_decode(encoded)
	assert_eq(decoded, PackedByteArray([0x61, 0x62]), "decode must work without padding")


static func _str_to_bytes(s: String) -> PackedByteArray:
	var bytes: PackedByteArray = PackedByteArray()
	for c in s:
		bytes.append(ord(c))
	return bytes


# ---- T-074: JSON escape order — backslash BEFORE quote ----


func test_sign_escapes_backslash_and_quote_correctly() -> void:
	# The old order ('"'→'\\"' then '\\'→'\\\\') corrupted any payload containing a quote
	# into an escaped backslash + RAW quote — broken JSON that fails round-trip.
	var token: String = jwt.sign({"sub": 'a"b\\c'}, VALID_SECRET, 3600)
	var result: Dictionary = jwt.verify(token, VALID_SECRET)
	assert_true(bool(result.get("valid", false)), "token with quote+backslash must verify")
	assert_eq(
		str(result.get("payload", {}).get("sub", "")),
		'a"b\\c',
		"payload must round-trip the original string"
	)
