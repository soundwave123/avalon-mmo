class_name SocialPanel
# T-361 item 2: the friends/ignore panel (toggle O, WoW's social key). Server-fed: every list it
# shows came back from a social_list reply; the panel only emits desires (add/remove/trade).
# Friends carry a live online flag (world presence); an online friend offers a [trade] link —
# the natural entry point into the T-363 trade window. Code-built on the shared theme.

extends Control

var _send_fn: Callable = Callable()
var _is_typing_fn: Callable = Callable()  # chat focus gate — O must not fire while typing
var _body: RichTextLabel = null
var _name_box: LineEdit = null
var _friends: Array = []
var _ignored: Array = []


func _ready() -> void:
	visible = false
	set_anchors_preset(Control.PRESET_CENTER_RIGHT)
	custom_minimum_size = Vector2(300, 360)
	offset_left = -320.0
	offset_right = -20.0
	offset_top = -180.0
	offset_bottom = 180.0
	var frame := PanelContainer.new()
	frame.name = "SocialFrame"
	frame.theme_type_variation = "SolidWindow"  # T-396: deliberate window = opaque opt-in
	frame.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(frame)
	var col := VBoxContainer.new()
	frame.add_child(col)
	# T-513: title bar — label left, close [X] right (playtest: the window had no close affordance,
	# only the O toggle, which non-MMO testers didn't discover). Close just hides, same as O.
	var header := HBoxContainer.new()
	col.add_child(header)
	var title := Label.new()
	title.text = "Friends  (O)"
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	var close_btn := Button.new()
	close_btn.name = "SocialClose"
	close_btn.text = "X"
	close_btn.focus_mode = Control.FOCUS_NONE
	close_btn.pressed.connect(func(): visible = false)
	header.add_child(close_btn)
	_body = RichTextLabel.new()
	_body.name = "SocialBody"
	_body.bbcode_enabled = true
	_body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_body.meta_clicked.connect(_on_meta)
	col.add_child(_body)
	_name_box = LineEdit.new()
	_name_box.name = "SocialName"
	_name_box.placeholder_text = "character name"
	col.add_child(_name_box)
	var row := HBoxContainer.new()
	col.add_child(row)
	row.add_child(_btn("Add Friend", func(): _named("social_add_friend")))
	row.add_child(_btn("Ignore", func(): _named("social_add_ignore")))
	_render()


func setup(send_fn: Callable, is_typing_fn: Callable = Callable()) -> void:
	_send_fn = send_fn
	_is_typing_fn = is_typing_fn


func _input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.is_pressed() or event.is_echo():
		return
	if (event as InputEventKey).keycode != KEY_O:
		return
	if UiInputGate.is_text_input_focused(get_viewport()):
		return
	if _is_typing_fn.is_valid() and bool(_is_typing_fn.call()):
		return  # chat (or our own name box) holds the keyboard
	visible = not visible
	if visible:
		_emit({"type": "social_list"})  # refresh from the server on open
	get_viewport().set_input_as_handled()


# Server reply: the authoritative lists (+ online flags decorated by the world).
func receive(data: Dictionary) -> void:
	if str(data.get("type", "")) != "social_list":
		return
	_friends = data.get("friends", [])
	_ignored = data.get("ignored", [])
	_render()


func _render() -> void:
	if _body == null:
		return
	var lines: Array[String] = []
	lines.append("[b]Friends[/b]")
	for f: Dictionary in _friends:
		var fname := str(f.get("name", ""))
		var online := bool(f.get("online", false))
		(
			lines
			. append(
				(
					"  [color=#%s]%s[/color] %s%s [url=unfriend|%s]\\[x\\][/url]"
					% [
						"7fff7f" if online else "808080",
						fname,
						"(online)" if online else "(offline)",
						" [url=trade|%s]\\[trade\\][/url]" % fname if online else "",
						fname,
					]
				)
			)
		)
	if _friends.is_empty():
		lines.append("  [color=#808080](none)[/color]")
	lines.append("[b]Ignored[/b]")
	for iname in _ignored:
		lines.append("  %s [url=unignore|%s]\\[x\\][/url]" % [str(iname), str(iname)])
	if _ignored.is_empty():
		lines.append("  [color=#808080](none)[/color]")
	_body.text = "\n".join(lines)


func _on_meta(meta: Variant) -> void:
	var p := str(meta).split("|")
	if p.size() < 2:
		return
	match p[0]:
		"unfriend":
			_emit({"type": "social_remove_friend", "name": p[1]})
		"unignore":
			_emit({"type": "social_remove_ignore", "name": p[1]})
		"trade":
			_emit({"type": "trade_request", "target": p[1]})


func _named(intent: String) -> void:
	var n := _name_box.text.strip_edges() if _name_box != null else ""
	if n != "":
		_emit({"type": intent, "name": n})
		_name_box.clear()


func _emit(msg: Dictionary) -> void:
	if _send_fn.is_valid():
		_send_fn.call(msg)


func _btn(label: String, fn: Callable) -> Button:
	var b := Button.new()
	b.text = label
	b.focus_mode = Control.FOCUS_NONE
	b.pressed.connect(fn)
	return b


# test/introspection helpers
func body_text() -> String:
	return _body.text if _body != null else ""
