class_name CharacterSelect
extends Control

# T-507: character-select screen. Mounted by GatewayLogin when login_ok says `select` (the
# account holds 2+ characters, or the login form's "choose character" box was ticked) and
# takes over the SAME authenticated gateway socket for roster ops:
#
#   char_select {character_id} -> char_select_ok {access_token, ...}  -> enter world
#   char_create {name}         -> char_create_ok {character}
#   char_delete {character_id} -> char_delete_ok {characters}   (two-step confirm, below)
#
# Single-character accounts never see this screen (login_ok auto-drops, the pre-T-507 UX).
# All authority is server-side: the gateway checks ownership before signing the character
# into the session token, and the master re-validates that claim at the world handshake.
# Class/gender stay unchosen at create — the in-world T-520/T-065 panels run on first entry.

signal chosen(access_token: String)
signal aborted(reason: String)

const UiTheme = preload("res://scripts/ui/ui_theme.gd")
const MAX_SLOTS := 3  # mirrors the gateway cap; the server remains the enforcer

var _socket: WebSocketPeer = null
var _characters: Array = []
var _pending_delete_id: int = 0  # armed by the first Delete press; 0 = disarmed
var _rows: VBoxContainer = null
var _name_edit: LineEdit = null
var _create_button: Button = null
var _status: Label = null


static func select_request(character_id: int) -> Dictionary:
	return {"type": "char_select", "character_id": character_id}


static func create_request(name: String) -> Dictionary:
	return {"type": "char_create", "name": name}


static func delete_request(character_id: int) -> Dictionary:
	return {"type": "char_delete", "character_id": character_id}


static func row_label(character: Dictionary) -> String:
	var name := str(character.get("name", "?"))
	var level := int(character.get("level", 1))
	var locked: Variant = character.get("class_locked", false)
	var has_class: bool = locked is bool and locked or str(locked) in ["t", "true"]
	if has_class:
		return "%s — %s, level %d" % [name, str(character.get("class", "")).capitalize(), level]
	return "%s — level %d (class unchosen)" % [name, level]


func setup(socket: WebSocketPeer, characters: Array, parent: Node) -> void:
	_socket = socket
	_characters = characters.duplicate()
	parent.add_child(self)
	_build_ui()
	_rebuild_rows()
	set_process(true)


func _process(_delta: float) -> void:
	if _socket == null:
		return
	_socket.poll()
	while _socket != null and _socket.get_available_packet_count() > 0:
		var packet := _socket.get_packet()
		if _socket.was_string_packet():
			_handle_message(packet.get_string_from_utf8())
	if _socket != null and _socket.get_ready_state() == WebSocketPeer.STATE_CLOSED:
		_socket = null
		_status.text = "Connection to the login server was lost. Please log in again."
		aborted.emit("connection_closed")


func _handle_message(raw: String) -> void:
	var parsed: Variant = JSON.parse_string(raw)
	if not (parsed is Dictionary):
		return
	var message: Dictionary = parsed
	match str(message.get("type", "")):
		"char_select_ok":
			var token := str(message.get("access_token", ""))
			if token == "":
				_status.text = "Malformed response from the login server."
				return
			_close_socket("character selected")
			visible = false
			chosen.emit(token)
			queue_free()
		"char_select_err":
			_status.text = "Could not enter world: %s" % _pretty(message)
		"char_create_ok":
			_characters.append(message.get("character", {}))
			_name_edit.clear()
			_status.text = "Character created. Class is chosen in the world."
			_rebuild_rows()
		"char_create_err":
			_status.text = "Could not create character: %s" % _pretty(message)
		"char_delete_ok":
			_characters = message.get("characters", [])
			_status.text = "Character deleted."
			_pending_delete_id = 0
			_rebuild_rows()
		"char_delete_err":
			_status.text = "Could not delete character: %s" % _pretty(message)
			_pending_delete_id = 0


func _pretty(message: Dictionary) -> String:
	return str(message.get("reason", "unknown_error")).replace("_", " ")


func _on_select_pressed(character_id: int) -> void:
	_pending_delete_id = 0
	_send(select_request(character_id))
	_status.text = "Entering world…"


# Two-step delete confirmation: the first press ARMS (row button relabels to "Confirm");
# the second press within the armed state sends. Any other action disarms.
func _on_delete_pressed(character_id: int) -> void:
	if _pending_delete_id == character_id:
		_send(delete_request(character_id))
		_status.text = "Deleting…"
		return
	_pending_delete_id = character_id
	_status.text = "Press Confirm to permanently delete this character."
	_rebuild_rows()


func _on_create_pressed() -> void:
	_pending_delete_id = 0
	var name := _name_edit.text.strip_edges().to_lower()
	if name == "":
		_status.text = "Enter a name for the new character."
		return
	_send(create_request(name))
	_status.text = "Creating %s…" % name


func _send(payload: Dictionary) -> void:
	if _socket != null and _socket.get_ready_state() == WebSocketPeer.STATE_OPEN:
		_socket.send_text(JSON.stringify(payload))


func _close_socket(reason: String) -> void:
	set_process(false)
	if _socket != null and _socket.get_ready_state() == WebSocketPeer.STATE_OPEN:
		_socket.close(1000, reason)
	_socket = null


# ---- UI construction (code-built, portable — mirrors GatewayLogin) ----


func _build_ui() -> void:
	theme = UiTheme.build()
	mouse_filter = Control.MOUSE_FILTER_STOP
	z_index = 200
	set_anchors_preset(Control.PRESET_FULL_RECT)

	var shade := ColorRect.new()
	shade.name = "Shade"
	shade.color = Color(0.01, 0.015, 0.025, 0.88)
	add_child(shade)
	shade.set_anchors_preset(Control.PRESET_FULL_RECT)

	var frame := PanelContainer.new()
	frame.name = "Frame"
	frame.theme_type_variation = "SolidWindow"
	add_child(frame)
	frame.anchor_left = 0.5
	frame.anchor_top = 0.5
	frame.anchor_right = 0.5
	frame.anchor_bottom = 0.5
	frame.offset_left = -280.0
	frame.offset_top = -240.0
	frame.offset_right = 280.0
	frame.offset_bottom = 240.0

	var vbox := VBoxContainer.new()
	vbox.name = "VBox"
	vbox.add_theme_constant_override("separation", 10)
	frame.add_child(vbox)

	var title := Label.new()
	title.name = "Title"
	title.text = "Choose Your Character"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 24)
	title.add_theme_color_override("font_color", UiTheme.GOLD_BRIGHT)
	vbox.add_child(title)

	_rows = VBoxContainer.new()
	_rows.name = "Rows"
	_rows.add_theme_constant_override("separation", 6)
	vbox.add_child(_rows)

	var create_box := HBoxContainer.new()
	create_box.name = "CreateBox"
	create_box.add_theme_constant_override("separation", 8)
	vbox.add_child(create_box)

	_name_edit = LineEdit.new()
	_name_edit.name = "NewName"
	_name_edit.placeholder_text = "New character name"
	_name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_name_edit.text_submitted.connect(func(_text): _on_create_pressed())
	create_box.add_child(_name_edit)

	_create_button = Button.new()
	_create_button.name = "Create"
	_create_button.text = "Create"
	_create_button.pressed.connect(_on_create_pressed)
	create_box.add_child(_create_button)

	_status = Label.new()
	_status.name = "Status"
	_status.text = "Pick a character, or create a new one."
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.add_theme_color_override("font_color", UiTheme.PARCHMENT_DIM)
	vbox.add_child(_status)


func _rebuild_rows() -> void:
	for child in _rows.get_children():
		_rows.remove_child(child)
		child.queue_free()
	for character: Dictionary in _characters:
		_rows.add_child(_build_row(character))
	var full := _characters.size() >= MAX_SLOTS
	_create_button.disabled = full
	_name_edit.editable = not full
	if full:
		_name_edit.placeholder_text = "All %d slots used" % MAX_SLOTS


func _build_row(character: Dictionary) -> HBoxContainer:
	var cid := int(character.get("id", 0))
	var row := HBoxContainer.new()
	row.name = "Row%d" % cid
	row.add_theme_constant_override("separation", 8)

	var label := Label.new()
	label.name = "Who"
	label.text = row_label(character)
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(label)

	var enter := Button.new()
	enter.name = "Enter"
	enter.text = "Enter World"
	enter.pressed.connect(_on_select_pressed.bind(cid))
	row.add_child(enter)

	var delete := Button.new()
	delete.name = "Delete"
	delete.text = "Confirm?" if _pending_delete_id == cid else "Delete"
	delete.pressed.connect(_on_delete_pressed.bind(cid))
	row.add_child(delete)
	return row
