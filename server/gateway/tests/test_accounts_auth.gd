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


# ---- T-740: one-time passwords ----
#
# The flag lives on the account row, so every assertion below reads it back from storage rather
# than from anything the caller passed in — that is exactly the property the gateway relies on.


func _seed_otp_account(username: String, otp: String) -> void:
	Auth.set_test_auth_mode("accounts")
	Auth.set_test_account(
		username, Auth.PasswordHash.encode(otp, Auth.PasswordHash.generate_salt()), true, true
	)


func test_one_time_password_validates_but_is_flagged_for_change() -> void:
	_seed_otp_account("tester_otp", "Qk7mRt2vXb9d")
	var check := Auth.check_login("tester_otp", "Qk7mRt2vXb9d")
	assert_true(check["ok"], "the one-time password is a real credential")
	assert_true(check["password_is_otp"], "and the gateway must be told it is one-time")
	assert_true(Auth.validate_login("tester_otp", "Qk7mRt2vXb9d"), "legacy call site still works")


func test_normal_account_is_never_asked_to_change_its_password() -> void:
	Auth.set_test_auth_mode("accounts")
	var encoded := Auth.PasswordHash.encode("their-own-password", Auth.PasswordHash.generate_salt())
	Auth.set_test_account("tester_settled", encoded, true)
	var check := Auth.check_login("tester_settled", "their-own-password")
	assert_true(check["ok"])
	assert_false(check["password_is_otp"], "accounts that predate T-740 default to false")
	assert_eq(
		Auth.set_password("tester_settled", "their-own-password", "something-else")["reason"],
		"not_required",
		"there is no OTP to spend, so this path must refuse to rewrite the password",
	)


func test_set_password_swaps_the_hash_and_clears_the_flag() -> void:
	_seed_otp_account("tester_new", "Qk7mRt2vXb9d")
	var before := str(Auth.test_account_row("tester_new")["password_hash"])
	assert_true(Auth.set_password("tester_new", "Qk7mRt2vXb9d", "my own password")["ok"])
	var row := Auth.test_account_row("tester_new")
	assert_false(row["password_is_otp"], "the flag is cleared in the same write")
	assert_ne(row["password_hash"], before, "a fresh salt+digest replaced the provisioned one")
	assert_true(Auth.validate_login("tester_new", "my own password"), "the chosen password works")
	assert_false(Auth.check_login("tester_new", "my own password")["password_is_otp"])


func test_the_one_time_password_is_dead_after_it_is_spent() -> void:
	_seed_otp_account("tester_spent", "Qk7mRt2vXb9d")
	assert_true(Auth.set_password("tester_spent", "Qk7mRt2vXb9d", "my own password")["ok"])
	assert_false(Auth.validate_login("tester_spent", "Qk7mRt2vXb9d"), "OTP no longer logs in")
	assert_eq(
		Auth.set_password("tester_spent", "Qk7mRt2vXb9d", "a third password")["reason"],
		"invalid_credentials",
		"a replayed OTP cannot set the password a second time",
	)
	assert_true(Auth.validate_login("tester_spent", "my own password"), "the chosen one survives")


func test_set_password_refuses_a_wrong_one_time_password() -> void:
	_seed_otp_account("tester_wrong", "Qk7mRt2vXb9d")
	assert_eq(
		Auth.set_password("tester_wrong", "not-the-otp", "my own password")["reason"],
		"invalid_credentials",
	)
	assert_true(
		Auth.test_account_row("tester_wrong")["password_is_otp"],
		"a failed attempt leaves the account exactly as it was",
	)
	assert_true(Auth.validate_login("tester_wrong", "Qk7mRt2vXb9d"), "the real OTP still works")


func test_short_or_recycled_passwords_are_rejected_server_side() -> void:
	_seed_otp_account("tester_short", "Qk7mRt2vXb9d")
	assert_eq(Auth.MIN_PASSWORD_LENGTH, 8, "length is the only rule we impose")
	assert_eq(
		Auth.set_password("tester_short", "Qk7mRt2vXb9d", "1234567")["reason"],
		"password_too_short",
		"7 characters is one short of the minimum",
	)
	assert_eq(
		Auth.set_password("tester_short", "Qk7mRt2vXb9d", "Qk7mRt2vXb9d")["reason"],
		"password_unchanged",
		"keeping the one-time password as your own defeats the whole ticket",
	)
	assert_true(Auth.test_account_row("tester_short")["password_is_otp"], "nothing was written")
	assert_true(Auth.set_password("tester_short", "Qk7mRt2vXb9d", "12345678")["ok"], "8 is enough")


func test_set_password_cannot_touch_an_unknown_or_disabled_account() -> void:
	Auth.set_test_auth_mode("accounts")
	assert_eq(
		Auth.set_password("no_such_user", "Qk7mRt2vXb9d", "my own password")["reason"],
		"invalid_credentials",
	)
	var encoded := Auth.PasswordHash.encode("Qk7mRt2vXb9d", Auth.PasswordHash.generate_salt())
	Auth.set_test_account("tester_off", encoded, false, true)
	assert_eq(
		Auth.set_password("tester_off", "Qk7mRt2vXb9d", "my own password")["reason"],
		"invalid_credentials",
		"a disabled account is not a password-reset seam",
	)
