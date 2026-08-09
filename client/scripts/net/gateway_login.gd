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
const GATEWAY_PORT := 9001
const TIMEOUT_SECS := 10.0

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


static func queue_disconnect_notice(state: Dictionary) -> void:
	_pending_notice = disconnect_message(state)


static func disconnect_message(state: Dictionary) -> String:
	var reason := str(state.get("reason", "")).replace("\n", " ").replace("\r", " ").strip_edges()
	match str(state.get("kind", "error")):
		"maintenance":
			var suffix := "\n%s" % reason if reason != "" else ""
			return "Server is down for maintenance — back soon.%s" % suffix
		"ban":
			return "Account banned by a Game Master: %s" % reason
		"kick":
			return "Disconnected by a Game Master: %s" % reason
		_:
			return "Connection lost. Please try again."


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

	_status = Label.new()
	_status.name = "Status"
	_status.text = (
		_pending_notice if _pending_notice != "" else "Use the credentials you were given."
	)
	_pending_notice = ""
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.add_theme_color_override("font_color", UiTheme.PARCHMENT_DIM)
	vbox.add_child(_status)
	set_process(false)


func _begin_login() -> void:
	var username := _username.text.strip_edges()
	if username == "" or _password.text == "":
		_status.text = "Enter both username and password."
		return
	BootClock.mark_login_submit()  # T-705: closes the launch→login-submit phase of the boot funnel
	var build := ServerConnectionConfig.resolve_build(
		OS.get_executable_path(), OS.get_environment("AVALON_CLIENT_BUILD")
	)
	_request = login_request(username, _password.text, build, _manage.button_pressed)
	_socket = WebSocketPeer.new()
	var url := "ws://%s:%d" % [_url_host(_host), GATEWAY_PORT]
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
		_status.text = "Signing in…"
	elif state == WebSocketPeer.STATE_CLOSED:
		_fail("connection_closed")
	elif _elapsed >= TIMEOUT_SECS:
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
	var message := parsed as Dictionary
	match str(message.get("type", "")):
		"login_ok":
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
				authenticated.emit(token, int(world.get("port", 9200)))
				queue_free()
			return true
		"login_err":
			_fail(str(message.get("reason", "invalid_credentials")))
			return true
		_:
			_fail("malformed_response")
			return false


# T-507: mount the character screen on top of this form and DONATE the open socket to it.
# This form stops polling (the screen polls) but stays alive to relay `authenticated`.
func _open_character_select(message: Dictionary, world_port: int) -> void:
	set_process(false)
	var socket := _socket
	_socket = null
	_password.clear()
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
	if _password != null:
		_password.clear()
	if _submit != null:
		_submit.disabled = false
	if _status != null:
		if reason == "outdated_build":
			_status.text = "Your game is out of date. Download the latest version and relaunch."
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
