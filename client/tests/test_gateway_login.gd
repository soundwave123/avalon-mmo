extends "res://addons/gut/test.gd"

const GatewayLogin = preload("res://scripts/net/gateway_login.gd")

var _login: Control


func before_each() -> void:
	_login = GatewayLogin.new()
	add_child_autofree(_login)
	_login.setup("play.avalon.example")


func test_setup_builds_keyboard_friendly_secret_login_form() -> void:
	var username := _login.get_node("Frame/VBox/Username") as LineEdit
	var password := _login.get_node("Frame/VBox/Password") as LineEdit
	var submit := _login.get_node("Frame/VBox/LogIn") as Button

	assert_eq(username.placeholder_text, "Username")
	assert_true(password.secret, "password must be visually masked")
	assert_eq(password.secret_character, "•")
	assert_eq(submit.text, "Log in")
	assert_true(_login.visible)


func test_tab_focus_chain_steps_username_to_password() -> void:
	# T-494: focus starts in Username (setup grabs it); Tab must step Username -> Password.
	var username := _login.get_node("Frame/VBox/Username") as LineEdit
	var password := _login.get_node("Frame/VBox/Password") as LineEdit
	assert_eq(
		username.get_node(username.focus_next),
		password,
		"Tab from Username lands on Password",
	)
	assert_eq(
		password.get_node(password.focus_previous),
		username,
		"Shift-Tab from Password returns to Username",
	)


func test_modal_swallows_stray_keys_so_nothing_behind_the_form_can_act() -> void:
	# T-494: the form is a true modal gate. A key its fields did not consume is swallowed here
	# (_unhandled_key_input runs after gui input) so nothing mounted behind it can ever act on it.
	_login._unhandled_key_input(_key(KEY_C))
	assert_true(get_viewport().is_input_handled(), "a stray hotkey is consumed by the login modal")


func _key(code: int) -> InputEventKey:
	var ev := InputEventKey.new()
	ev.keycode = code
	ev.physical_keycode = code
	ev.pressed = true
	return ev


func test_login_request_matches_gateway_contract_exactly() -> void:
	assert_eq(
		GatewayLogin.login_request("alice", "correct horse"),
		{"type": "login", "username": "alice", "password": "correct horse", "build": ""},
	)


# T-514: the build stamp rides the login request so the gateway can refuse outdated clients.
func test_login_request_carries_the_client_build() -> void:
	assert_eq(
		GatewayLogin.login_request("alice", "pw", "2026-07-16T19:38:00Z"),
		{
			"type": "login",
			"username": "alice",
			"password": "pw",
			"build": "2026-07-16T19:38:00Z",
		},
	)


func test_login_ok_emits_token_and_port_once_and_clears_password() -> void:
	watch_signals(_login)
	(_login.get_node("Frame/VBox/Password") as LineEdit).text = "correct horse"
	var raw := (
		JSON
		. stringify(
			{
				"type": "login_ok",
				"access_token": "signed.jwt.token",
				"world": {"host": "127.0.0.1", "port": 9200},
			}
		)
	)

	assert_true(_login._handle_gateway_message(raw))
	assert_signal_emit_count(_login, "authenticated", 1)
	assert_signal_emitted_with_parameters(_login, "authenticated", ["signed.jwt.token", 9200])
	assert_signal_emit_count(_login, "login_failed", 0)
	assert_eq((_login.get_node("Frame/VBox/Password") as LineEdit).text, "")


func test_login_err_emits_failure_once_and_keeps_form_available() -> void:
	watch_signals(_login)

	assert_true(
		_login._handle_gateway_message(
			JSON.stringify({"type": "login_err", "reason": "invalid_credentials"})
		)
	)
	assert_signal_emit_count(_login, "login_failed", 1)
	assert_signal_emitted_with_parameters(_login, "login_failed", ["invalid_credentials"])
	assert_signal_emit_count(_login, "authenticated", 0)
	assert_false((_login.get_node("Frame/VBox/LogIn") as Button).disabled)


# ---- T-740: the choose-your-own-password state of this same form ----


func _arrive_at_password_choice() -> void:
	# Exactly how a real first login gets here: type the one-time password, submit, and let the
	# gateway answer password_change_required instead of a session. The fixture stands in for the
	# real 12 readable characters — to this form a one-time password is just an opaque string.
	(_login.get_node("Frame/VBox/Username") as LineEdit).text = "roy"
	(_login.get_node("Frame/VBox/Password") as LineEdit).text = "issued-once"
	_login._account = "roy"
	_login._one_time_password = "issued-once"
	assert_true(
		_login._handle_gateway_message(JSON.stringify({"type": "password_change_required"}))
	)


func test_password_change_required_swaps_the_form_and_asks_nothing_retyped() -> void:
	watch_signals(_login)
	_arrive_at_password_choice()
	assert_signal_emit_count(_login, "login_failed", 0, "a forced change is not a failure")
	assert_signal_emit_count(_login, "authenticated", 0, "and it is not a session either")
	var new_password := _login.get_node("Frame/VBox/NewPassword") as LineEdit
	var confirm := _login.get_node("Frame/VBox/ConfirmPassword") as LineEdit
	assert_true(new_password.visible)
	assert_true(confirm.visible)
	assert_true(new_password.secret, "a chosen password is masked like any other")
	assert_true((_login.get_node("Frame/VBox/SetPassword") as Button).visible)
	assert_false((_login.get_node("Frame/VBox/Username") as LineEdit).visible)
	assert_false((_login.get_node("Frame/VBox/LogIn") as Button).visible)
	assert_string_contains(_login._status.text, "one-time")
	assert_eq(
		new_password.get_node(new_password.focus_next), confirm, "Tab steps to the confirm field"
	)


func test_set_password_request_matches_gateway_contract_exactly() -> void:
	assert_eq(
		GatewayLogin.set_password_request("roy", "issued-once", "my own password"),
		{
			"type": "set_password",
			"username": "roy",
			"password": "issued-once",
			"new_password": "my own password",
		},
	)


func test_submitting_a_matching_password_queues_one_set_password_request() -> void:
	_arrive_at_password_choice()
	(_login.get_node("Frame/VBox/NewPassword") as LineEdit).text = "my own password"
	(_login.get_node("Frame/VBox/ConfirmPassword") as LineEdit).text = "my own password"
	_login._socket = null  # no live socket in a unit test
	_login._submit_password_choice()
	# Without a socket the form must fail closed rather than silently swallow the submission.
	assert_eq(_login._status.text, "Login failed: connection closed")
	assert_true((_login.get_node("Frame/VBox/Username") as LineEdit).visible, "login form is back")


func test_short_and_mismatched_passwords_never_reach_the_wire() -> void:
	_arrive_at_password_choice()
	var new_password := _login.get_node("Frame/VBox/NewPassword") as LineEdit
	var confirm := _login.get_node("Frame/VBox/ConfirmPassword") as LineEdit

	new_password.text = "short"
	confirm.text = "short"
	_login._submit_password_choice()
	assert_string_contains(_login._status.text, "at least 8")
	assert_true(_login._request.is_empty(), "nothing was queued for the gateway")
	assert_true(new_password.visible, "the player stays on the form to fix it")

	new_password.text = "my own password"
	confirm.text = "my own passwrod"
	_login._submit_password_choice()
	assert_string_contains(_login._status.text, "don't match")
	assert_true(_login._request.is_empty())
	assert_eq(_login._one_time_password, "issued-once", "the OTP is still held for the retry")


func test_the_password_choice_form_never_times_out_under_the_player() -> void:
	# T-740: 10 s is a fine deadline for a server round trip and an absurd one for inventing a
	# password. _process must not fail while the choice form is up.
	_arrive_at_password_choice()
	watch_signals(_login)
	_login._elapsed = 999.0
	_login._process(0.016)  # no socket -> returns early, but the guard is the point
	assert_signal_emit_count(_login, "login_failed", 0)
	assert_true(_login._choosing)


func test_set_password_err_returns_to_the_login_form_with_the_reason() -> void:
	watch_signals(_login)
	_arrive_at_password_choice()
	assert_true(
		_login._handle_gateway_message(
			JSON.stringify({"type": "set_password_err", "reason": "rate_limited"})
		)
	)
	assert_signal_emit_count(_login, "login_failed", 1)
	assert_signal_emitted_with_parameters(_login, "login_failed", ["rate_limited"])
	assert_true((_login.get_node("Frame/VBox/Username") as LineEdit).visible)
	assert_false((_login.get_node("Frame/VBox/NewPassword") as LineEdit).visible)
	assert_string_contains(_login._status.text, "Too many attempts")
	assert_eq(_login._one_time_password, "", "a rejected credential is not kept in memory")


func test_login_ok_after_setting_a_password_goes_straight_into_the_world() -> void:
	watch_signals(_login)
	_arrive_at_password_choice()
	var raw := (
		JSON
		. stringify(
			{
				"type": "login_ok",
				"access_token": "signed.jwt.token",
				"world": {"host": "127.0.0.1", "port": 9200},
			}
		)
	)
	assert_true(_login._handle_gateway_message(raw))
	assert_signal_emit_count(_login, "authenticated", 1, "one round trip, no second login")
	assert_signal_emitted_with_parameters(_login, "authenticated", ["signed.jwt.token", 9200])
	assert_eq(_login._one_time_password, "", "the spent one-time password is wiped")


func test_malformed_gateway_reply_fails_closed() -> void:
	watch_signals(_login)

	assert_false(_login._handle_gateway_message("not json"))
	assert_signal_emit_count(_login, "login_failed", 1)
	assert_signal_emitted_with_parameters(_login, "login_failed", ["malformed_response"])
	assert_signal_emit_count(_login, "authenticated", 0)
