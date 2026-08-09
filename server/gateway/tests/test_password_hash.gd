extends GutTest

const PasswordHash = preload("res://scripts/password_hash.gd")


func test_sha256_salt_format_matches_owner_cli_contract() -> void:
	var encoded := PasswordHash.encode(
		"correct horse battery staple", "00112233445566778899aabbccddeeff"
	)
	assert_eq(
		encoded,
		(
			"sha256$00112233445566778899aabbccddeeff$"
			+ "8e3647f6a1551fe1c41c619ccf0f46da672cb3d3061a3139c9a4560bb534e06c"
		)
	)


func test_verify_accepts_only_the_matching_password() -> void:
	var encoded := PasswordHash.encode("friend-password", "fedcba98765432100123456789abcdef")
	assert_true(PasswordHash.verify("friend-password", encoded))
	assert_false(PasswordHash.verify("wrong-password", encoded))


func test_verify_rejects_malformed_or_unsupported_storage_values() -> void:
	for stored: String in [
		"",
		"md5$00112233445566778899aabbccddeeff$deadbeef",
		"sha256$short$deadbeef",
		"sha256$00112233445566778899aabbccddeeff$not-hex",
	]:
		assert_false(PasswordHash.verify("anything", stored), "reject malformed hash: %s" % stored)


func test_generate_salt_uses_128_bits_of_randomness() -> void:
	var first := PasswordHash.generate_salt()
	var second := PasswordHash.generate_salt()
	assert_eq(first.length(), 32)
	assert_eq(second.length(), 32)
	assert_ne(first, second, "independent accounts need independent random salts")
	assert_true(first.is_valid_hex_number(false))
	assert_true(second.is_valid_hex_number(false))
