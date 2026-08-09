class_name PasswordHash
extends RefCounted

# T-501 credential format shared with scripts/tester-accounts.sh:
# sha256$<16-byte salt as hex>$<SHA-256(salt_hex + ":" + password) as hex>

const _SCHEME := "sha256"
const _SALT_BYTES := 16
const _SALT_PATTERN := "^[0-9a-f]{32}$"
const _DIGEST_PATTERN := "^[0-9a-f]{64}$"


static func generate_salt() -> String:
	return Crypto.new().generate_random_bytes(_SALT_BYTES).hex_encode()


static func encode(password: String, salt_hex: String) -> String:
	if not _matches(_SALT_PATTERN, salt_hex):
		return ""
	var context := HashingContext.new()
	if context.start(HashingContext.HASH_SHA256) != OK:
		return ""
	if context.update((salt_hex + ":" + password).to_utf8_buffer()) != OK:
		return ""
	return "%s$%s$%s" % [_SCHEME, salt_hex, context.finish().hex_encode()]


static func verify(password: String, stored: String) -> bool:
	var parts := stored.split("$", false)
	if parts.size() != 3 or parts[0] != _SCHEME:
		return false
	var salt_hex := str(parts[1])
	var trusted_digest := str(parts[2])
	if not _matches(_SALT_PATTERN, salt_hex) or not _matches(_DIGEST_PATTERN, trusted_digest):
		return false
	var encoded := encode(password, salt_hex)
	if encoded.is_empty():
		return false
	var received_digest := str(encoded.get_slice("$", 2))
	return Crypto.new().constant_time_compare(
		trusted_digest.to_utf8_buffer(), received_digest.to_utf8_buffer()
	)


static func _matches(pattern: String, value: String) -> bool:
	var regex := RegEx.new()
	return regex.compile(pattern) == OK and regex.search(value) != null
