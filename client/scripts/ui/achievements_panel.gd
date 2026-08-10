class_name AchievementsPanel
extends Control

# T-367: the achievements / collections panel (toggle Y, WoW's achievement key). Server-fed: every
# row it shows came back from an achievement_list reply (the server owns progress + the earned set);
# the panel only READS — its one intent is the read-only refresh on open. Code-built on the shared
# T-308 theme, mirroring SocialPanel.

var _send_fn: Callable = Callable()
var _is_typing_fn: Callable = Callable()  # chat/name-box focus gate — Y must not fire while typing
var _body: RichTextLabel = null
var _summary: Label = null
var _rows: Array = []
var _renown_rows: Array = []  # T-678: server-fed hub standing ({hub,name,points,rank,...})


func _ready() -> void:
	visible = false
	set_anchors_preset(Control.PRESET_CENTER)
	custom_minimum_size = Vector2(360, 400)
	offset_left = -180.0
	offset_right = 180.0
	offset_top = -200.0
	offset_bottom = 200.0
	var frame := PanelContainer.new()
	frame.name = "AchievementsFrame"
	frame.theme_type_variation = "SolidWindow"  # T-396: deliberate window = opaque opt-in
	frame.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(frame)
	var col := VBoxContainer.new()
	frame.add_child(col)
	var title := Label.new()
	title.text = "Achievements  (Y)"
	col.add_child(title)
	_summary = Label.new()
	_summary.name = "AchievementsSummary"
	col.add_child(_summary)
	_body = RichTextLabel.new()
	_body.name = "AchievementsBody"
	_body.bbcode_enabled = true
	_body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_child(_body)
	_render()


func setup(send_fn: Callable, is_typing_fn: Callable = Callable()) -> void:
	_send_fn = send_fn
	_is_typing_fn = is_typing_fn


func _input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.is_pressed() or event.is_echo():
		return
	if KeyRegistry.event_code(event as InputEventKey) != KEY_Y:
		return
	if UiInputGate.is_text_input_focused(get_viewport()):
		return
	if _is_typing_fn.is_valid() and bool(_is_typing_fn.call()):
		return  # chat holds the keyboard
	toggle()
	get_viewport().set_input_as_handled()


func toggle() -> void:
	visible = not visible
	if visible and _send_fn.is_valid():
		_send_fn.call({"type": "achievement_list"})  # refresh from the server on open
		_send_fn.call({"type": "renown_list"})  # T-678: hub standing rides the same open refresh


# Server reply: the authoritative achievement list ({id,name,desc,earned,fraction,reward,...}).
func render(rows: Array) -> void:
	_rows = rows
	_render()


# T-678: the renown_list reply — one row per hub, rendered as a standing header above the
# achievement list. The panel only READS; every number came from the master's renown_op.
func render_renown(rows: Array) -> void:
	_renown_rows = rows
	_render()


func _render() -> void:
	if _body == null:
		return
	var earned_count := 0
	var lines: Array[String] = []
	for r: Dictionary in _renown_rows:
		var pts := int(r.get("points", 0))
		var nxt := int(r.get("next_points", -1))
		var bar := ("%d / %d" % [pts, nxt]) if nxt >= 0 else ("%d (max)" % pts)
		lines.append(
			(
				"[color=#7fc7ff]%s — %s (Rank %d) · %s renown[/color]"
				% [
					str(r.get("name", r.get("hub", ""))),
					str(r.get("rank_name", "")),
					int(r.get("rank", 0)),
					bar
				]
			)
		)
	if not _renown_rows.is_empty():
		lines.append("")
	for a: Dictionary in _rows:
		var name_txt := str(a.get("name", a.get("id", "")))
		var desc := str(a.get("desc", ""))
		if bool(a.get("earned", false)):
			earned_count += 1
			lines.append("[color=#ffd24a]★ %s[/color] — %s" % [name_txt, desc])
		else:
			var pct := int(round(float(a.get("fraction", 0.0)) * 100.0))
			lines.append("[color=#9aa0a6]☆ %s — %s (%d%%)[/color]" % [name_txt, desc, pct])
	if _rows.is_empty():
		lines.append("[color=#808080](no achievements defined)[/color]")
	_body.text = "\n".join(lines)
	if _summary != null:
		_summary.text = "%d / %d earned" % [earned_count, _rows.size()]
