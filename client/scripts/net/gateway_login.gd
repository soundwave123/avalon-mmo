class_name GatewayLogin
extends Control

# T-500: code-built portable login. Raw WebSocketPeer + JSON mirrors the gateway's T-002 contract;
# gameplay still travels directly over ENet after the gateway returns a signed access token.
signal authenticated(access_token: String, world_port: int)
signal login_failed(reason: String)

const UiTheme = preload("res://scripts/ui/ui_theme.gd")
const CharacterSelect = preload("res://scripts/ui/character_select.gd")  # T-507
# T-705: preloaded, not referenced by class_name — a source-run client's global class cache is a
# gitignored local artifact that can lag a new script (s26 import-cache trap), and the neighbours
# in this file already use the preload-const idiom.
const BootClock = preload("res://scripts/net/boot_clock.gd")
const DisconnectPolicy = preload("res://scripts/net/disconnect_policy.gd")  # T-704 reason→copy
# T-742: the gateway port now resolves through ServerConnectionConfig (env override ->
# server.cfg `port` key -> 9001 default) so self-hosts can run on non-default ports.
const TIMEOUT_SECS := 10.0
# T-740: mirrors Auth.MIN_PASSWORD_LENGTH on the gateway. Checked here only to spare the player a
# round trip — the server enforces it regardless.
const MIN_PASSWORD_LENGTH := 8

static var _pending_notice := ""

var _host := ""
var _socket: WebSocketPeer = null
var _request: Dictionary = {}
var _sent := false
var _elapsed := 0.0
var _username: LineEdit = null
var _password: LineEdit = null
var _manage: CheckBox = null  # T-507: force the character screen (alts for 1-char accounts)
var _submit: Button = null
var _status: Label = null
# T-740: the choose-your-own-password state of this same form.
var _new_password: LineEdit = null
var _confirm_password: LineEdit = null
var _set_password: Button = null
var _choosing := false
var _account := ""  # username the pending set_password belongs to
var _one_time_password := ""  # held only between login and set_password, then wiped
var _sending_status := "Signing in…"


func mount(parent: Node, host: String, on_authenticated: Callable) -> void:
	parent.add_child(self)
	setup(host, on_authenticated)


func setup(host: String, on_authenticated := Callable()) -> void:
	_host = host
	_build_form()
	if on_authenticated.is_valid():
		authenticated.connect(on_authenticated)
	visible = true
	_username.grab_focus.call_deferred()


static func login_request(
	username: String, password: String, build := "", manage := false
) -> Dictionary:
	# T-514: the server gate reads `build` before issuing a token; an outdated build is refused.
	# T-507: `manage` asks the gateway for the character screen even on a 0/1-character account.
	var request := {"type": "login", "username": username, "password": password, "build": build}
	if manage:
		request["manage"] = true
	return request


# T-740: the one-time password rides back so the gateway can re-validate it. The client never
# claims "you told me a change was required" — the server proves that from the account row on
# every attempt, and this request either logs the player in or changes nothing.
static func set_password_request(
	username: String, one_time_password: String, new_password: String
) -> Dictionary:
	return {
		"type": "set_password",
		"username": username,
		"password": one_time_password,
		"new_password": new_password,
	}


static func queue_disconnect_notice(state: Dictionary) -> void:
	_pending_notice = disconnect_message(state)


# T-704: the recovery path has already rendered its copy (terminal reason, "Reconnecting… (attempt
# N)", give-up) — queue it verbatim for the next form build.
static func queue_notice_text(message: String) -> void:
	_pending_notice = message


# T-704: the reason→copy table moved to DisconnectPolicy so the login form and the reconnect logic
# read from one source; this stays as the call site every existing caller already uses.
static func disconnect_message(state: Dictionary) -> String:
	return DisconnectPolicy.message_for(state)


static func _clear_notice_for_test() -> void:
	_pending_notice = ""


# T-494: defence in depth. The client root does not build the HUD or its hotkey listener until this
# form authenticates, so nothing behind the modal exists to steal a keystroke. Even so, swallow any
# key the form's own fields did not consume (this runs AFTER gui input) so the login stays a true
# modal gate regardless of what else a future boot path might mount underneath it.
func _unhandled_key_input(event: InputEvent) -> void:
	if visible and event is InputEventKey:
		get_viewport().set_input_as_handled()


func _build_form() -> void:
	if _username != null:
		return
	theme = UiTheme.build()
	mouse_filter = Control.MOUSE_FILTER_STOP
	z_index = 200
	anchor_left = 0.0
	anchor_top = 0.0
	anchor_right = 1.0
	anchor_bottom = 1.0
	offset_left = 0.0
	offset_top = 0.0
	offset_right = 0.0
	offset_bottom = 0.0

	var shade := ColorRect.new()
	shade.name = "Shade"
	shade.color = Color(0.01, 0.015, 0.025, 0.88)
	add_child(shade)
	_fill_parent(shade)

	var frame := PanelContainer.new()
	frame.name = "Frame"
	frame.theme_type_variation = "SolidWindow"
	add_child(frame)
	frame.anchor_left = 0.5
	frame.anchor_top = 0.5
	frame.anchor_right = 0.5
	frame.anchor_bottom = 0.5
	frame.offset_left = -240.0
	frame.offset_top = -180.0
	frame.offset_right = 240.0
	frame.offset_bottom = 180.0

	var vbox := VBoxContainer.new()
	vbox.name = "VBox"
	vbox.add_theme_constant_override("separation", 12)
	frame.add_child(vbox)

	var title := Label.new()
	title.text = "Enter Avalon"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 26)
	title.add_theme_color_override("font_color", UiTheme.GOLD_BRIGHT)
	vbox.add_child(title)

	var destination := Label.new()
	destination.text = "Server: %s" % _host
	destination.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	destination.add_theme_color_override("font_color", UiTheme.PARCHMENT_DIM)
	vbox.add_child(destination)

	_username = LineEdit.new()
	_username.name = "Username"
	_username.placeholder_text = "Username"
	_username.text_submitted.connect(func(_text): _password.grab_focus())
	vbox.add_child(_username)

	_password = LineEdit.new()
	_password.name = "Password"
	_password.placeholder_text = "Password"
	_password.secret = true
	_password.secret_character = "•"
	_password.text_submitted.connect(func(_text): _begin_login())
	vbox.add_child(_password)

	# T-494 keyboard UX: focus starts in Username (setup grabs it), Tab steps Username -> Password,
	# Enter in either field advances / submits. Wire the focus chain explicitly so it is deterministic.
	_username.focus_next = _username.get_path_to(_password)
	_password.focus_previous = _password.get_path_to(_username)

	# T-507: opt-in character management. Accounts with 2+ characters get the screen regardless;
	# this box is how a single-character account reaches create-alt/delete without losing the
	# default drop-straight-in flow.
	_manage = CheckBox.new()
	_manage.name = "ManageCharacters"
	_manage.text = "Choose character at login"
	vbox.add_child(_manage)

	_submit = Button.new()
	_submit.name = "LogIn"
	_submit.text = "Log in"
	_submit.pressed.connect(_begin_login)
	vbox.add_child(_submit)

	# T-740: one form, two states. These are built alongside the login fields and start hidden, so
	# a `password_change_required` only has to flip visibility — the socket, the account and the
	# one-time password all stay exactly where they are, and the player re-types nothing.
	_new_password = _secret_field(
		"NewPassword", "Choose a password (at least %d characters)" % MIN_PASSWORD_LENGTH
	)
	_new_password.text_submitted.connect(func(_text): _confirm_password.grab_focus())
	vbox.add_child(_new_password)

	_confirm_password = _secret_field("ConfirmPassword", "Type it again")
	_confirm_password.text_submitted.connect(func(_text): _submit_password_choice())
	vbox.add_child(_confirm_password)

	_set_password = Button.new()
	_set_password.name = "SetPassword"
	_set_password.text = "Set password and play"
	_set_password.visible = false
	_set_password.pressed.connect(_submit_password_choice)
	vbox.add_child(_set_password)

	_new_password.focus_next = _new_password.get_path_to(_confirm_password)
	_confirm_password.focus_previous = _confirm_password.get_path_to(_new_password)

	_status = Label.new()
	_status.name = "Status"
	_status.text = (
		_pending_notice if _pending_notice != "" else "Use the credentials you were given."
	)
	if _pending_notice != "":
		# T-704: the notice reaching the label is the whole point of the ticket — log the render so a
		# support session (and the E2E) can prove the player was told, not just that we meant to.
		print("[login] notice shown: %s" % _pending_notice.replace("\n", " "))
	_pending_notice = ""
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.add_theme_color_override("font_color", UiTheme.PARCHMENT_DIM)
	vbox.add_child(_status)
	set_process(false)


func _secret_field(node_name: String, placeholder: String) -> LineEdit:
	var field := LineEdit.new()
	field.name = node_name
	field.placeholder_text = placeholder
	field.secret = true
	field.secret_character = "•"
	field.visible = false
	return field


func _begin_login() -> void:
	var username := _username.text.strip_edges()
	if username == "" or _password.text == "":
		_status.text = "Enter both username and password."
		return
	# T-740: kept in memory only until the set_password reply lands (or the attempt fails), so a
	# forced password change costs the player one round trip instead of a second login.
	_account = username
	_one_time_password = _password.text
	BootClock.mark_login_submit()  # T-705: closes the launch→login-submit phase of the boot funnel
	var build := ServerConnectionConfig.resolve_build(
		OS.get_executable_path(), OS.get_environment("AVALON_CLIENT_BUILD")
	)
	_request = login_request(username, _password.text, build, _manage.button_pressed)
	_socket = WebSocketPeer.new()
	var gateway_port := ServerConnectionConfig.resolve_runtime_gateway_port(
		OS.get_executable_path(), OS.get_environment("AVALON_GATEWAY_PORT")
	)
	var url := "ws://%s:%d" % [_url_host(_host), gateway_port]
	var err := _socket.connect_to_url(url)
	if err != OK:
		_fail("connection_failed")
		return
	_sent = false
	_elapsed = 0.0
	_submit.disabled = true
	_status.text = "Connecting…"
	set_process(true)


func _process(delta: float) -> void:
	if _socket == null:
		return
	_elapsed += delta
	_socket.poll()
	_drain_packets()
	if _socket == null:
		return
	var state := _socket.get_ready_state()
	if state == WebSocketPeer.STATE_OPEN and not _sent:
		_socket.send_text(JSON.stringify(_request))
		_request.clear()
		_password.clear()
		_sent = true
		_status.text = _sending_status
	elif state == WebSocketPeer.STATE_CLOSED:
		_fail("connection_closed")
	elif _elapsed >= TIMEOUT_SECS and not _choosing:
		# T-740: the clock is on the SERVER, never on the player. While the choose-a-password form
		# is up we keep polling (the socket must stay alive) but the timeout is suspended — a
		# 10-second deadline to invent a password would be an instant, unexplained failure.
		_fail("timeout")


func _drain_packets() -> void:
	while _socket != null and _socket.get_available_packet_count() > 0:
		var packet := _socket.get_packet()
		if not _socket.was_string_packet():
			_fail("malformed_response")
			return
		if _handle_gateway_message(packet.get_string_from_utf8()):
			return


func _handle_gateway_message(raw: String) -> bool:
	var json := JSON.new()
	if json.parse(raw) != OK:
		_fail("malformed_response")
		return false
	var parsed: Variant = json.data
	if not (parsed is Dictionary):
		_fail("malformed_response")
		return false
	return _dispatch_gateway_message(parsed as Dictionary)


# Returns true when this frame ended the exchange (handled or failed), false when the reply was
# unusable. Split out from the parse above so each half stays readable as the protocol grows.
func _dispatch_gateway_message(message: Dictionary) -> bool:
	match str(message.get("type", "")):
		"login_ok":
			return _handle_login_ok(message)
		# T-740: right credentials, but that password was one-time. Same socket, same attempt —
		# the player picks a password and the reply to THAT is the login_ok above.
		"password_change_required":
			_show_password_choice()
			return true
		"set_password_err":
			_restore_login_form()
			_fail(str(message.get("reason", "invalid_credentials")))
			return true
		"login_err":
			_fail(str(message.get("reason", "invalid_credentials")))
			return true
	_fail("malformed_response")
	return false


func _handle_login_ok(message: Dictionary) -> bool:
	var token := str(message.get("access_token", ""))
	var world: Variant = message.get("world", {})
	if token == "" or not (world is Dictionary) or int(world.get("port", 0)) <= 0:
		_fail("malformed_response")
		return false
	if bool(message.get("select", false)):
		# T-507: hand the live socket to the character-select screen; it re-emits our
		# `authenticated` with a character-bound token. 0/1-char accounts (no `select`)
		# keep the pre-T-507 drop-straight-in path below.
		_open_character_select(message, int(world.get("port", 9200)))
	else:
		_finish_socket()
		visible = false
		_password.clear()
		_forget_one_time_password()
		authenticated.emit(token, int(world.get("port", 9200)))
		queue_free()
	return true


# T-740: swap the login fields for the choose-your-own-password pair. The socket stays open and
# _sent stays true, so nothing is re-sent until the player submits.
func _show_password_choice() -> void:
	_choosing = true
	for control in [_username, _password, _manage, _submit]:
		control.visible = false
	for control in [_new_password, _confirm_password, _set_password]:
		control.visible = true
	_new_password.clear()
	_confirm_password.clear()
	_set_password.disabled = false
	_status.text = (
		"That was a one-time password. Choose your own (at least %d characters) to finish."
		% MIN_PASSWORD_LENGTH
	)
	_new_password.grab_focus.call_deferred()
	# Logged like the T-704 notice: a support session (and the E2E) can prove the player was
	# actually shown the step, not merely that we intended to.
	print("[login] password change required — choose-your-own-password form shown")


func _submit_password_choice() -> void:
	var chosen := _new_password.text
	if chosen.length() < MIN_PASSWORD_LENGTH:
		_status.text = "Use at least %d characters." % MIN_PASSWORD_LENGTH
		return
	if chosen != _confirm_password.text:
		_status.text = "Those two don't match. Type the same password twice."
		return
	if _socket == null or _socket.get_ready_state() != WebSocketPeer.STATE_OPEN:
		_restore_login_form()
		_fail("connection_closed")
		return
	_request = set_password_request(_account, _one_time_password, chosen)
	_new_password.clear()
	_confirm_password.clear()
	_set_password.disabled = true
	_choosing = false
	_sent = false  # hands the request to _process, which owns every send on this socket
	_elapsed = 0.0
	_sending_status = "Saving your password…"
	_status.text = _sending_status


func _restore_login_form() -> void:
	_choosing = false
	_sending_status = "Signing in…"
	for control in [_new_password, _confirm_password, _set_password]:
		control.visible = false
	for control in [_username, _password, _manage, _submit]:
		control.visible = true


func _forget_one_time_password() -> void:
	_account = ""
	_one_time_password = ""


# T-507: mount the character screen on top of this form and DONATE the open socket to it.
# This form stops polling (the screen polls) but stays alive to relay `authenticated`.
func _open_character_select(message: Dictionary, world_port: int) -> void:
	set_process(false)
	var socket := _socket
	_socket = null
	_password.clear()
	_forget_one_time_password()
	var screen: CharacterSelect = CharacterSelect.new()
	screen.chosen.connect(
		func(access_token: String) -> void:
			visible = false
			authenticated.emit(access_token, world_port)
			queue_free()
	)
	screen.aborted.connect(
		func(_reason: String) -> void:
			screen.queue_free()
			visible = true
			_submit.disabled = false
			_status.text = "Connection lost. Please log in again."
			set_process(false)
	)
	screen.setup(socket, message.get("characters", []), self)
	visible = true  # keep the shade behind the screen; the form frame hides under it


func _fail(reason: String) -> void:
	_finish_socket()
	_request.clear()
	_forget_one_time_password()  # T-740: never keep a spent or rejected credential around
	if _password != null:
		_password.clear()
	if _submit != null:
		_submit.disabled = false
	if _set_password != null:
		_set_password.disabled = false
	if _status != null:
		if reason == "outdated_build":
			_status.text = "Your game is out of date. Download the latest version and relaunch."
		elif reason == "rate_limited":
			_status.text = "Too many attempts. Wait a minute, then try again."
		else:
			_status.text = "Login failed: %s" % reason.replace("_", " ")
	login_failed.emit(reason)


func _finish_socket() -> void:
	set_process(false)
	if _socket != null and _socket.get_ready_state() == WebSocketPeer.STATE_OPEN:
		_socket.close(1000, "login complete")
	_socket = null


static func _fill_parent(control: Control) -> void:
	control.anchor_left = 0.0
	control.anchor_top = 0.0
	control.anchor_right = 1.0
	control.anchor_bottom = 1.0
	control.offset_left = 0.0
	control.offset_top = 0.0
	control.offset_right = 0.0
	control.offset_bottom = 0.0


static func _url_host(host: String) -> String:
	return "[%s]" % host if host.contains(":") and not host.begins_with("[") else host
