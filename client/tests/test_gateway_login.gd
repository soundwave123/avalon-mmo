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


func test_malformed_gateway_reply_fails_closed() -> void:
	watch_signals(_login)

	assert_false(_login._handle_gateway_message("not json"))
	assert_signal_emit_count(_login, "login_failed", 1)
	assert_signal_emitted_with_parameters(_login, "login_failed", ["malformed_response"])
	assert_signal_emit_count(_login, "authenticated", 0)
