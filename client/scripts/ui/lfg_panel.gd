class_name LfgPanel
# T-625: the LFG-lite board panel (toggle U) — the deferred client half of T-334. The server brain
# (lfg_logic.gd + the lfg_flag/lfg_unflag/lfg_list intents + the lfg_board reply) already ships and
# is unit-tested; this is the missing player-facing surface. Server-fed and intent-only: every board
# row it shows came back from a lfg_board reply, and it emits nothing but DESIRES — a flag/unflag of
# itself, and the normal T-280 party_invite off a row (a leader forms the party; the server
# re-validates every verb). Code-built on the shared T-308 theme, mirroring SocialPanel/GuildPanel.
#
# Keybind: U. J is WoW's Group-Finder-ish convention, but J is already taken here by the T-480
# weekly vault (weekly_panel.gd); U is unbound (O=friends, G=guild, Y=achievements, P=pvp, K=recipe,
# B=spellbook, V=wardrobe, H=cosmetics, J=weekly are the taken panel keys — verified this session).

extends Control

var _send_fn: Callable = Callable()
var _is_typing_fn: Callable = Callable()  # chat focus gate — U must not fire while typing
var _level_fn: Callable = Callable()  # player level: an honest display HINT for lfg_flag
var _body: RichTextLabel = null
var _status: Label = null
var _flag_btn: Button = null
var _board: Array = []
var _flagged := false  # local mirror of "am I on the board", reconciled from each lfg_board ack


func _ready() -> void:
	visible = false
	# T-606: idle click-through — the transparent margin around the window never eats a world click.
	# The SolidWindow frame below keeps its default STOP, so the OPEN window still catches its own
	# clicks (Godot hit-tests children independently of an IGNORE parent); only the padding is porous.
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	# T-608: anchored center-right like SocialPanel/GuildPanel — this rect (x 940..1260, y 160..560 at
	# the 1280x720 base) clears every HudSafeZone reserved band: Vitals (top-left), Compass (top-
	# center), and the ActionBar hotbar (bottom-center). test_lfg_panel asserts the non-collision.
	set_anchors_preset(Control.PRESET_CENTER_RIGHT)
	custom_minimum_size = Vector2(320, 360)
	offset_left = -340.0
	offset_right = -20.0
	offset_top = -180.0
	offset_bottom = 180.0
	var frame := PanelContainer.new()
	frame.name = "LfgFrame"
	frame.theme_type_variation = "SolidWindow"  # T-396: deliberate window = opaque opt-in
	frame.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(frame)
	var col := VBoxContainer.new()
	frame.add_child(col)
	# Title bar — label left, close [X] right (the T-513 lesson: a panel needs a visible close
	# affordance, not only its toggle key). Close just hides, same as pressing U again.
	var header := HBoxContainer.new()
	col.add_child(header)
	var title := Label.new()
	title.text = "Find Group  (U)"
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	var close_btn := Button.new()
	close_btn.name = "LfgClose"
	close_btn.text = "X"
	close_btn.focus_mode = Control.FOCUS_NONE
	close_btn.pressed.connect(func(): visible = false)
	header.add_child(close_btn)
	var row := HBoxContainer.new()
	col.add_child(row)
	_flag_btn = _btn("Flag as LFG", _toggle_flag)
	_flag_btn.name = "LfgFlagToggle"
	row.add_child(_flag_btn)
	row.add_child(_btn("Refresh", func(): _emit({"type": "lfg_list"})))
	_body = RichTextLabel.new()
	_body.name = "LfgBody"
	_body.bbcode_enabled = true
	_body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_body.meta_clicked.connect(_on_meta)
	col.add_child(_body)
	_status = Label.new()
	_status.name = "LfgStatus"
	col.add_child(_status)
	_render()


func setup(
	send_fn: Callable, is_typing_fn: Callable = Callable(), level_fn: Callable = Callable()
) -> void:
	_send_fn = send_fn
	_is_typing_fn = is_typing_fn
	_level_fn = level_fn


func _input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.is_pressed() or event.is_echo():
		return
	if KeyRegistry.event_code(event as InputEventKey) != KEY_U:
		return
	if UiInputGate.is_text_input_focused(get_viewport()):
		return
	if _is_typing_fn.is_valid() and bool(_is_typing_fn.call()):
		return  # chat holds the keyboard
	toggle()
	get_viewport().set_input_as_handled()


func toggle() -> void:
	visible = not visible
	if visible:
		_emit({"type": "lfg_list"})  # refresh the board from the server on open


# Server reply: {type:lfg_board, intent, ok, reason, board:[{peer,name,level,role}]}. `intent` names
# the op that produced it, so a flag/unflag ack flips the local toggle without a second round-trip.
func receive(data: Dictionary) -> void:
	if str(data.get("type", "")) != "lfg_board":
		return
	_board = data.get("board", [])
	var intent := str(data.get("intent", ""))
	var ok := bool(data.get("ok", false))
	if ok and intent == "lfg_flag":
		_flagged = true
	elif ok and intent == "lfg_unflag":
		_flagged = false
	_status.text = "" if ok else "LFG: %s" % str(data.get("reason", "error"))
	_render()


func _toggle_flag() -> void:
	if _flagged:
		_emit({"type": "lfg_unflag"})
	else:
		# The level is a display hint only — the server derives the trusted role from the session
		# class and never trusts a client-supplied role (lfg_logic.role_for_class).
		var lvl := int(_level_fn.call()) if _level_fn.is_valid() else 1
		_emit({"type": "lfg_flag", "level": lvl})


func _render() -> void:
	if _flag_btn != null:
		_flag_btn.text = "Unflag" if _flagged else "Flag as LFG"
	if _body == null:
		return
	var lines: Array[String] = []
	lines.append("[b]Looking for Group[/b]")
	for r: Dictionary in _board:
		var rname := str(r.get("name", ""))
		# T-755: bbcode_enabled + meta_clicked -> party_invite. Display is escaped, payload stripped.
		lines.append(
			(
				"  [url=invite|%s]%s[/url]  L%d  %s"
				% [
					BBCode.escape_meta(rname),
					BBCode.escape(rname),
					int(r.get("level", 1)),
					BBCode.escape(str(r.get("role", "")))
				]
			)
		)
	if _board.is_empty():
		lines.append("  [color=#808080](nobody flagged yet — be the first)[/color]")
	_body.text = "\n".join(lines)


func _on_meta(meta: Variant) -> void:
	var p := str(meta).split("|")
	if p.size() < 2:
		return
	if p[0] == "invite":
		_emit({"type": "party_invite", "target": p[1]})  # T-280: the normal party invite path


func _emit(msg: Dictionary) -> void:
	if _send_fn.is_valid():
		_send_fn.call(msg)


func _btn(label: String, fn: Callable) -> Button:
	var b := Button.new()
	b.name = label.replace(" ", "")
	b.text = label
	b.focus_mode = Control.FOCUS_NONE
	b.pressed.connect(fn)
	return b


# test/introspection helpers
func body_text() -> String:
	return _body.text if _body != null else ""


func is_flagged() -> bool:
	return _flagged
