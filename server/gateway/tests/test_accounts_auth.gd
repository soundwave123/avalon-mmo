extends GutTest

const Auth = preload("res://scripts/auth.gd")


func before_each() -> void:
	Auth.reset_for_test()


func test_accounts_mode_rejects_unknown_user_and_wrong_password() -> void:
	Auth.set_test_auth_mode("accounts")
	Auth.set_test_account(
		"tester_one",
		(
			"sha256$00112233445566778899aabbccddeeff$"
			+ "95ab623fcfd71a52f16e9e06067677df10d3d2fdd029d62c694963b00d01d959"
		),
		true
	)
	assert_false(Auth.validate_login("unknown_user", "dev"), "wire login cannot auto-create")
	assert_false(Auth.validate_login("tester_one", "wrong"))


func test_accounts_mode_accepts_created_active_tester_only() -> void:
	Auth.set_test_auth_mode("accounts")
	var encoded := Auth.PasswordHash.encode("issued-once", "0123456789abcdeffedcba9876543210")
	Auth.set_test_account("tester_two", encoded, true)
	assert_true(Auth.validate_login("tester_two", "issued-once"))
	Auth.set_test_account("tester_two", encoded, false)
	assert_false(Auth.validate_login("tester_two", "issued-once"), "disabled account must fail")


func test_default_auth_mode_is_accounts_not_dev_stub() -> void:
	var encoded := Auth.PasswordHash.encode("real", "aabbccddeeff00112233445566778899")
	Auth.set_test_account("player1", encoded, true)
	assert_false(Auth.validate_login("player1", "dev"))
	assert_true(Auth.validate_login("player1", "real"))


func test_postgres_boolean_text_is_normalized_without_mixed_type_comparison() -> void:
	assert_true(Auth._db_bool("t"))
	assert_false(Auth._db_bool("f"))
