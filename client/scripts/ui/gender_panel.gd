class_name GenderPanel
# T-520: one-shot GENDER selection at character creation — shown FIRST, before the T-065 ClassPanel,
# for a brand-new character whose class_kit carries an empty `gender`. Picking a gender sends the
# set_gender INTENT (the server validates + persists + locks — reroll is the only way out); on the
# ack the client hides this panel and shows the class panel. Structure mirrors ClassPanel verbatim:
# a TRUE blocking modal (full-rect, z-topmost, MOUSE_FILTER_STOP, "ui_blocking_modal" group so
# UiInputGate silences every hotkey while it's up) built from real Buttons (hover/press + ↑/↓ focus
# + Enter/Space activate; 1/2 shortcuts). EXPLICIT anchors+offsets — set_anchors_preset is the 4.7
# trap ClassPanel documents (its offset recompute collapses the modal to a top-left stub).

extends Control

signal action_selected(meta: String)

const _GENDERS := [
	{"id": "female", "name": "Female"},
	{"id": "male", "name": "Male"},
]

var _buttons: Array = []


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
	z_index = 200  # above every other HUD panel (matches ClassPanel / gateway_login)
	visible = false
	add_to_group("ui_blocking_modal")
	theme = UiTheme.build()

	# Full-screen dim behind the frame — STOP so background clicks never reach the world.
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

	# SolidWindow frame, centered at a fixed size (the T-396 seam). EXPLICIT anchors, not
	# set_anchors_preset — the preset call ITSELF is the 4.7 trap (collapses containers to stubs).
	var frame := PanelContainer.new()
	frame.name = "Frame"
	frame.theme_type_variation = "SolidWindow"  # T-396: deliberate window = opaque opt-in
	add_child(frame)
	frame.anchor_left = 0.5
	frame.anchor_top = 0.5
	frame.anchor_right = 0.5
	frame.anchor_bottom = 0.5
	frame.offset_left = -280.0
	frame.offset_top = -140.0
	frame.offset_right = 280.0
	frame.offset_bottom = 140.0

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 10)
	frame.add_child(vbox)

	var title := Label.new()
	title.text = "Choose your character's gender (this choice is permanent)."
	title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(title)

	# T-535: the T-526 "both share one body for now" note is gone — the stored gender now visibly
	# drives a distinct hero body (char_hero_<class>_female.glb), so the honesty caveat is obsolete.

	for g: Dictionary in _GENDERS:
		var button := Button.new()
		button.name = "Btn_%s" % g["id"]
		button.text = str(g["name"])
		button.alignment = HORIZONTAL_ALIGNMENT_LEFT
		var meta: String = "set_gender|%s" % g["id"]
		button.pressed.connect(func(): action_selected.emit(meta))
		vbox.add_child(button)
		_buttons.append(button)

	var hint := Label.new()
	hint.text = "Click a choice, use ↑/↓ + Enter, or press 1 / 2."
	hint.modulate = Color(0.7, 0.7, 0.75)
	vbox.add_child(hint)

	visibility_changed.connect(_on_visibility_changed)


# Focus the first button whenever the panel appears — ↑/↓ + Enter work immediately.
# T-718: raise to the top of the sibling order too — GUI mouse picking goes by tree order, not
# z_index (modal_input.gd). Same treatment as ClassPanel: this modal is built early in $HUD.
func _on_visibility_changed() -> void:
	if not visible:
		return
	ModalInput.raise_to_front(self)
	if not _buttons.is_empty():
		(_buttons[0] as Button).grab_focus()


# T-718 (portal #108): the click path routes through `_input` exactly like the 1/2 keys, so a
# later full-rect sibling can never swallow the press (the class panel's live failure; this modal
# is structurally identical and carried the same latent bug).
func _route_mouse(mouse: InputEventMouseButton) -> void:
	if not mouse.pressed or mouse.button_index != MOUSE_BUTTON_LEFT:
		return
	var index := ModalInput.hit_index(_buttons, mouse.position)
	if index < 0:
		return  # a miss falls through: the shade eats it, an illegal overlay stays closable
	(_buttons[index] as Button).pressed.emit()
	get_viewport().set_input_as_handled()  # exactly one dispatch — never also via gui_input


# 1/2 shortcuts while the panel is up. Marks the event handled so nothing underneath fires.
func _input(event: InputEvent) -> void:
	# This IS the blocking modal, so it does NOT gate on UiInputGate (that would self-block).
	# While visible it owns the keyboard: 1/2 pick, Enter/Space activates the focused button,
	# ↑/↓ move focus. Everything else is swallowed so nothing underneath fires.
	if not visible:
		return
	if event is InputEventMouseButton:
		_route_mouse(event as InputEventMouseButton)  # T-718: click == key press
		return
	if not (event is InputEventKey) or not event.is_pressed() or event.is_echo():
		return
	var key := event as InputEventKey
	if key.keycode >= KEY_1 and key.keycode <= KEY_2:
		var index: int = key.keycode - KEY_1
		if index < _buttons.size():
			(_buttons[index] as Button).pressed.emit()
	elif key.keycode in [KEY_ENTER, KEY_KP_ENTER, KEY_SPACE]:
		var focused := get_viewport().gui_get_focus_owner()
		if focused is Button and focused in _buttons:
			(focused as Button).pressed.emit()
		elif not _buttons.is_empty():
			(_buttons[0] as Button).pressed.emit()
	elif key.keycode == KEY_UP or key.keycode == KEY_DOWN:
		return  # let the built-in focus system move between buttons
	get_viewport().set_input_as_handled()


# ---- headless-test accessors ----


func get_buttons() -> Array:
	return _buttons


func get_text() -> String:
	var parts: Array = []
	for b: Button in _buttons:
		parts.append(b.text)
	return "\n".join(parts)
