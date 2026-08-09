extends "res://addons/gut/test.gd"

# Test: Gateway refuses to start with missing/short JWT secret (T-006)

const JwtUtilScript = preload("res://scripts/jwt.gd")

var jwt: Object


func before_each() -> void:
	jwt = JwtUtilScript.new()


func after_each() -> void:
	pass


func test_secret_validation_rejects_empty() -> void:
	assert_false(jwt.validate_secret(""), "empty secret must be rejected")


func test_secret_validation_rejects_short() -> void:
	assert_false(jwt.validate_secret("short"), "short secret must be rejected")


func test_secret_validation_rejects_placeholder() -> void:
	assert_false(jwt.validate_secret("***"), "*** placeholder must be rejected")


func test_secret_validation_rejects_change_me() -> void:
	assert_false(jwt.validate_secret("CHANGE_ME_32_BYTE"), "CHANGE_ME placeholder must be rejected")


func test_secret_validation_accepts_32_chars() -> void:
	var valid_secret: String = "this_is_a_valid_secret_key_32chars!"
	assert_true(jwt.validate_secret(valid_secret), "32-char secret must be valid")


func test_secret_validation_accepts_longer_secret() -> void:
	var long_secret: String = "this_is_a_very_long_secret_key_that_exceeds_32_characters_easily"
	assert_true(jwt.validate_secret(long_secret), "long secret must be valid")
