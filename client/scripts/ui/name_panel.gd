class_name NamePanel
# T-716: the NAME step of character creation — the third and last creation modal, shown after the
# T-065 class panel and before the Handbook (gender -> class -> NAME -> tutorial offer -> handbook).
# Until this shipped, a fresh account's character was silently named after the ACCOUNT
# (character_manager.ensure_character), which is the cheapest identity investment in the genre being
# thrown away.
#
# Structure mirrors ClassPanel/GenderPanel — a TRUE blocking modal (full-rect, z-topmost,
# MOUSE_FILTER_STOP shade, "ui_blocking_modal" so UiInputGate silences every world hotkey while it
# is up) with EXPLICIT anchors+offsets (set_anchors_preset is the 4.7 trap ClassPanel documents).
#
# It differs from its two siblings in exactly one way, and it is the important one: this modal is a
# FREE-TYPE field, so it must NOT swallow keys in _input the way they do — the player is typing.
# Hotkey safety comes from the group membership instead (T-513/T-504: UiInputGate makes main.gd and
# every panel listener stand down while a blocking modal is visible), and the s15 GuildPanel
# focus-trap lesson is honoured explicitly: hiding the panel RELEASES the LineEdit's focus, because
# a LineEdit left focused keeps UiInputGate.is_text_input_focused true and kills every hotkey
# client-wide with no way out but a relog.

extends Control

signal action_selected(meta: String)  # "set_name|<name>" — main dispatches the set_name intent

# T-716: shared module — preloaded, never class_name (its copies would collide).
const CharacterName = preload("res://scripts/ui/character_name.gd")
const _FIELD_MAX := CharacterName.MAX_LENGTH

var _field: LineEdit = null
var _error: Label = null
var _confirm: Button = null
var _suggestion_applied := false  # the account-name default is offered ONCE, never over typing


func _ready() -> void:
	anchor_left = 0.0
	anchor_top = 0.0
	anchor_right = 1.0
	anchor_bottom = 1.0
	offset_left = 0.0
	offset_top = 0.0
	offset_right = 0.0
	offset_bottom = 0.0
	mouse_filter = Control.MOUSE_FILTER_STOP  # eat any click that misses the frame (no world leak)
	z_index = 200  # above every other HUD panel (matches ClassPanel / GenderPanel)
	visible = false
	add_to_group("ui_blocking_modal")
	theme = UiTheme.build()

	var shade := ColorRect.new()
	shade.name = "Shade"
	shade.color = Color(0.0, 0.0, 0.0, 0.55)
	shade.anchor_left = 0.0
	shade.anchor_top = 0.0
	shade.anchor_right = 1.0
	shade.anchor_bottom = 1.0
	shade.offset_left = 0.0
	shade.offset_top = 0.0
	shade.offset_right = 0.0
	shade.offset_bottom = 0.0
	shade.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(shade)

	var frame := PanelContainer.new()
	frame.name = "Frame"
	frame.theme_type_variation = "SolidWindow"  # T-396: deliberate window = opaque opt-in
	add_child(frame)
	frame.anchor_left = 0.5
	frame.anchor_top = 0.5
	frame.anchor_right = 0.5
	frame.anchor_bottom = 0.5
	frame.offset_left = -280.0
	frame.offset_top = -150.0
	frame.offset_right = 280.0
	frame.offset_bottom = 150.0

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 10)
	frame.add_child(vbox)

	var title := Label.new()
	title.text = "Name your character — this is the name other adventurers will see."
	title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(title)

	_field = LineEdit.new()
	_field.name = "NameField"
	_field.max_length = _FIELD_MAX
	_field.placeholder_text = "Your character's name"
	_field.text_submitted.connect(func(_t): _submit())  # Enter confirms, like the class panel's
	vbox.add_child(_field)

	_error = Label.new()
	_error.name = "NameError"
	_error.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_error.add_theme_color_override("font_color", Color(1.0, 0.45, 0.4))
	_error.visible = false
	vbox.add_child(_error)

	_confirm = Button.new()
	_confirm.name = "Btn_confirm"
	_confirm.text = "Confirm name"
	_confirm.pressed.connect(_submit)
	vbox.add_child(_confirm)

	var hint := Label.new()
	hint.text = (
		"%d-%d characters: letters, numbers, - and _ (capitals become lowercase). Enter confirms."
		% [CharacterName.MIN_LENGTH, CharacterName.MAX_LENGTH]
	)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.modulate = Color(0.7, 0.7, 0.75)
	vbox.add_child(hint)

	visibility_changed.connect(_on_visibility_changed)


# The default the server suggests (the account name). Offered ONCE and never over something the
# player already typed — a class_kit/player_stats resend must not wipe a half-typed name.
func set_suggestion(name: String) -> void:
	if _suggestion_applied or _field == null or _field.text != "":
		return
	var suggestion := CharacterName.normalize(name)
	if suggestion == "":
		return
	_suggestion_applied = true
	_field.text = suggestion


# T-716: server truth for the name attempt. ok -> the flow hides us (and _on_visibility_changed
# releases focus); a rejection shows the PLAIN-ENGLISH reason and hands the field back, selected,
# so "try another" is one keystroke away.
func on_result(data: Dictionary) -> void:
	if bool(data.get("ok", false)):
		return
	show_error(CharacterName.plain_english(str(data.get("reason", ""))))


func show_error(text: String) -> void:
	if _error == null:
		return
	_error.text = text
	_error.visible = text != ""
	if _field != null and visible:
		_field.grab_focus()
		_field.select_all()


# Local pre-flight ONLY — the server re-validates everything and owns uniqueness (which the client
# cannot know). This exists so an obviously-bad name answers instantly instead of after a round
# trip; anything it lets through is still the server's call.
func _submit() -> void:
	if _field == null:
		return
	var name := CharacterName.normalize(_field.text)
	var reason := CharacterName.reject_reason(name)
	if reason != "":
		show_error(CharacterName.plain_english(reason))
		return
	show_error("")
	action_selected.emit("set_name|%s" % name)


# Shown: raise above later siblings (T-718 — GUI picking goes by tree order, not z_index, so the
# field and button would otherwise be un-clickable under a later full-rect panel) and take the
# caret. Hidden: RELEASE focus — see the s15 focus-trap note in the header.
func _on_visibility_changed() -> void:
	if _field == null:
		return
	if visible:
		ModalInput.raise_to_front(self)
		_field.grab_focus()
		_field.caret_column = _field.text.length()
		return
	_field.release_focus()
	release_focus()


# T-718: the Confirm button's click is routed at the `_input` stage so no overlay can eat it.
# Deliberately narrow — every other mouse event falls through, because a free-type modal needs the
# normal GUI path for the LineEdit (caret placement, drag-select, focus).
func _input(event: InputEvent) -> void:
	if not visible or not (event is InputEventMouseButton):
		return
	var mouse := event as InputEventMouseButton
	if not mouse.pressed or mouse.button_index != MOUSE_BUTTON_LEFT:
		return
	if ModalInput.hit_index([_confirm], mouse.position) < 0:
		return
	_submit()
	get_viewport().set_input_as_handled()  # exactly one dispatch — never also via gui_input


# ---- headless-test accessors ----


func get_field() -> LineEdit:
	return _field


func get_error_text() -> String:
	return _error.text if _error != null and _error.visible else ""


func get_confirm_button() -> Button:
	return _confirm
