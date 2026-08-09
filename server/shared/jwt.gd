# JWT utility module — HS256 (HMAC-SHA256).
#
# Single source of truth for JWT signing and verification across
# gateway and master services. Loaded via class_name (globally
# available as JwtUtil.new()).
#
# Canonical location: server/shared/jwt.gd

# Usage: JwtUtil.new().sign(payload, secret, ttl)

# Internal mock time for deterministic testing.
var _mock_time: int = 0

# ---- Base64url encoding (RFC 7515 Section 2) ----


func base64url_encode(data: PackedByteArray) -> String:
	"""Encode bytes to base64url (no padding, - and _ instead of + and /)."""
	var encoded: String = Marshalls.raw_to_base64(data)
	# Convert to base64url: replace + with -, / with _, remove =
	encoded = encoded.replace("+", "-").replace("/", "_").replace("=", "")
	return encoded


func base64url_decode(encoded: String) -> PackedByteArray:
	"""Decode base64url (with padding restoration) back to bytes."""
	# Restore standard base64: replace - with +, _ with /
	var standard: String = encoded.replace("-", "+").replace("_", "/")
	# Add padding
	var mod := standard.length() % 4
	if mod == 2:
		standard += "=="
	elif mod == 3:
		standard += "="
	return Marshalls.base64_to_raw(standard)


# ---- JSON helpers (minimal, no external dependency) ----


func _dict_to_json_compact(d: Dictionary) -> String:
	"""Produce compact JSON from a dict. Handles nested dicts, arrays, strings, numbers, bools."""
	var parts: PackedStringArray = []
	var keys: Array = d.keys()
	keys.sort()
	for key in keys:
		parts.append('"%s":%s' % [key, _json_value(d[key])])
	return "{" + ",".join(parts) + "}"


func _json_value(val: Variant) -> String:
	match typeof(val):
		TYPE_STRING:
			# T-074: backslash must be escaped FIRST — the old quote-then-backslash order
			# turned a quote's escape (\") into an escaped backslash + RAW quote (\\").
			return '"%s"' % val.replace("\\", "\\\\").replace('"', '\\"')
		TYPE_FLOAT, TYPE_INT:
			return str(val)
		TYPE_BOOL:
			return "true" if val else "false"
		TYPE_DICTIONARY:
			return _dict_to_json_compact(val as Dictionary)
		TYPE_ARRAY:
			var items: PackedStringArray = []
			for item in val as Array:
				items.append(_json_value(item))
			return "[" + ",".join(items) + "]"
		_:
			return "null"


# ---- JWT signing ----


func sign(
	payload: Dictionary, secret: String, ttl_seconds: int = 7200, token_type: String = "access"
) -> String:
	"""
	Create a signed JWT (HS256).

	payload: Dictionary of custom claims (e.g. {"sub": "alice"}).
	secret: The signing secret string.
	ttl_seconds: Token time-to-live in seconds (default 7200 = 2 hours).
	token_type: Token type claim — "access" or "refresh" (default "access").

	Returns the full JWT string: header.payload.signature
	"""
	var now: int = _get_unix_time()

	# Standard header
	var header: Dictionary = {"alg": "HS256", "typ": "JWT"}

	# Merge payload with standard claims
	var full_payload: Dictionary = payload.duplicate()
	full_payload["iat"] = now
	full_payload["exp"] = now + ttl_seconds
	full_payload["type"] = token_type

	# Encode header and payload
	var header_b64: String = base64url_encode(_string_to_bytes(_dict_to_json_compact(header)))
	var payload_b64: String = base64url_encode(
		_string_to_bytes(_dict_to_json_compact(full_payload))
	)

	# Signing input
	var signing_input: String = header_b64 + "." + payload_b64
	var signature: String = _hmac_sha256(signing_input, secret)

	return signing_input + "." + signature


# gdlint: disable=max-returns
func verify(token: String, secret: String, clock_skew: int = 30) -> Dictionary:
	"""
	Verify a JWT and return the decoded payload if valid.

	token: The full JWT string.
	secret: The signing secret string.
	clock_skew: Allowable clock skew in seconds (default 30).

	Returns:
		{"valid": true, "payload": Dictionary} on success
		{"valid": false, "reason": String} on failure
	"""
	# Split into parts
	var parts: PackedStringArray = token.split(".")
	if parts.size() != 3:
		return {"valid": false, "reason": "invalid_format"}

	var header_b64: String = parts[0]
	var payload_b64: String = parts[1]
	var signature_b64: String = parts[2]

	# Verify signature (timing-safe)
	var crypto: Crypto = Crypto.new()
	var signing_input: String = header_b64 + "." + payload_b64
	var expected_sig: PackedByteArray = crypto.hmac_digest(
		HashingContext.HASH_SHA256, secret.to_utf8_buffer(), signing_input.to_utf8_buffer()
	)
	var actual_sig: PackedByteArray = _hex_to_bytes(signature_b64)
	if not _timing_safe_compare(expected_sig, actual_sig):
		return {"valid": false, "reason": "invalid_signature"}

	# Decode and verify header
	var header_bytes: PackedByteArray = base64url_decode(header_b64)
	var header_json: String = _bytes_to_string(header_bytes)
	var header: Variant = JSON.parse_string(header_json)
	if typeof(header) != TYPE_DICTIONARY:
		return {"valid": false, "reason": "invalid_header"}
	var h: Dictionary = header as Dictionary
	if h.get("alg", "") != "HS256":
		return {"valid": false, "reason": "unsupported_alg"}

	# Decode payload
	var payload_bytes: PackedByteArray = base64url_decode(payload_b64)
	var payload_json: String = _bytes_to_string(payload_bytes)
	var payload: Variant = JSON.parse_string(payload_json)
	if typeof(payload) != TYPE_DICTIONARY:
		return {"valid": false, "reason": "invalid_payload"}
	var p: Dictionary = payload as Dictionary

	# Check expiry with clock skew
	var exp: float = p.get("exp", 0)
	if exp == 0:
		return {"valid": false, "reason": "missing_exp"}
	var now: float = float(_get_unix_time())
	if now > exp + clock_skew:
		return {"valid": false, "reason": "expired"}

	return {"valid": true, "payload": p}


# gdlint: disable=max-returns
func verify_type(
	token: String, secret: String, expected_type: String, clock_skew: int = 30
) -> Dictionary:
	"""
	Verify a JWT AND check that its type claim matches the expected type.

	token: The full JWT string.
	secret: The signing secret string.
	expected_type: Expected type claim — "access" or "refresh".
	clock_skew: Allowable clock skew in seconds (default 30).

	Returns:
		{"valid": true, "payload": Dictionary} on success
		{"valid": false, "reason": String} on failure
	"""
	var result: Dictionary = verify(token, secret, clock_skew)
	if not result.get("valid", false):
		return result

	var payload: Dictionary = result["payload"]
	var actual_type: String = str(payload.get("type", ""))
	if actual_type != expected_type:
		return {"valid": false, "reason": "wrong_token_type"}

	return result


# ---- JTI generation (unique refresh token IDs) ----


static func generate_jti() -> String:
	"""Generate a unique JWT ID (jti) for refresh token tracking."""
	var random_bytes: PackedByteArray = PackedByteArray()
	for _i in range(16):
		random_bytes.append(randi() % 256)
	return random_bytes.hex_encode()


# ---- HMAC-SHA256 ----


func _hmac_sha256(data: String, secret: String) -> String:
	"""Compute HMAC-SHA256 and return hex-encoded signature."""
	var crypto: Crypto = Crypto.new()
	var hmac: PackedByteArray = crypto.hmac_digest(
		HashingContext.HASH_SHA256, secret.to_utf8_buffer(), data.to_utf8_buffer()
	)
	return hmac.hex_encode()


# ---- Timing-safe comparison ----


func _timing_safe_compare(a: PackedByteArray, b: PackedByteArray) -> bool:
	"""Constant-time comparison of two byte arrays to prevent timing attacks."""
	if a.size() != b.size():
		return false
	var result: int = 0
	for i in range(a.size()):
		result |= a[i] ^ b[i]
	return result == 0


# ---- Utility ----


func _string_to_bytes(s: String) -> PackedByteArray:
	var bytes: PackedByteArray = PackedByteArray()
	for c in s:
		bytes.append(ord(c))
	return bytes


func _hex_to_bytes(hex_str: String) -> PackedByteArray:
	"""Convert hex string to PackedByteArray (Godot 4.6 compatible)."""
	var bytes: PackedByteArray = PackedByteArray()
	var hex_chars: String = "0123456789abcdef"
	var i: int = 0
	while i + 1 < hex_str.length():
		var hi: int = hex_chars.find(hex_str[i].to_lower())
		var lo: int = hex_chars.find(hex_str[i + 1].to_lower())
		if hi >= 0 and lo >= 0:
			bytes.append(hi * 16 + lo)
		i += 2
	return bytes


func _bytes_to_string(bytes: PackedByteArray) -> String:
	return bytes.get_string_from_utf8()


# ---- Secret validation ----


func validate_secret(secret: String) -> bool:
	"""
	Validate JWT signing secret meets minimum requirements.

	Requires at least 32 bytes after base64 decoding (if base64-encoded)
	or 32 chars if raw string.

	Returns true if the secret is acceptable.
	"""
	if secret.is_empty():
		return false

	# Check if it looks like base64 (contains +, /, = or has length divisible by 4 with padding)
	if _is_base64(secret):
		var decoded: PackedByteArray = base64url_decode(secret)
		return decoded.size() >= 32

	# Raw string: check length
	return secret.length() >= 32


func _is_base64(s: String) -> bool:
	"""Heuristic: check if string looks like base64-encoded."""
	return s.contains("+") or s.contains("/") or s.contains("=") or s.length() % 4 == 0


# ---- Format validation (for world server) ----


func is_valid_jwt_format(token: String) -> bool:
	"""
	Check if a string has valid JWT structure (3 base64url dot-separated parts).
	Does NOT verify the signature — just structural validation.
	"""
	var parts: PackedStringArray = token.split(".")
	if parts.size() != 3:
		return false
	# Each part should be non-empty base64url
	for part in parts:
		if part.is_empty():
			return false
		# Base64url chars: A-Z, a-z, 0-9, -, _
		for i in range(part.length()):
			var c: String = part[i]
			if not c in "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_":
				return false
	return true


# ---- Test helpers ----


func set_mock_time(unix_time: int) -> void:
	"""Override unix time for deterministic testing. Set to 0 to reset."""
	_mock_time = unix_time


func _get_unix_time() -> int:
	"""Get unix time, respecting mock override."""
	if _mock_time > 0:
		return _mock_time
	return int(Time.get_unix_time_from_system())
