class_name ClassPanel
# T-065: one-shot class selection at character creation. Shown when the server's class_kit
# carries class_locked=false; picking a class sends the set_class INTENT (server validates
# and locks — reroll is the only way out, no respec).
#
# Real Buttons (play-test finding 2026-07-02: the first cut used RichTextLabel text links —
# they render as plain text, give no click affordance, and have no keyboard focus, so the
# panel read as unclickable). Buttons give hover/press states, ↑/↓ focus navigation, and
# Enter/Space activation for free; 1/2/3 are shortcuts.

extends Control

signal action_selected(meta: String)

const _CLASSES := [
	{"id": "warrior", "name": "Warrior", "blurb": "Front-line rage melee — takes and holds hits."},
	{"id": "mage", "name": "Mage", "blurb": "Ranged mana caster — fire and frost damage."},
	{"id": "priest", "name": "Priest", "blurb": "Mana healer — mends allies, smites foes."},
]

var _buttons: Array = []


func _ready() -> void:
	# T-512: a TRUE modal. Playtest finding: as a small centered Control buried among later HUD
	# CanvasLayer children, the panel's buttons sat UNDER other panels (clicks did nothing) and its
	# keys leaked to chat/hotkeys ("Enter opened chat"). Fix: full-screen, z-topmost, a shade that
	# eats off-button clicks, and the "ui_blocking_modal" group so UiInputGate silences every other
	# key listener while it's up (mirrors the working gateway_login modal).
	# EXPLICIT full-rect anchors+offsets — set_anchors_preset is the 4.7 trap this file already
	# documents (its offset recompute collapses the node; the pilot caught it rendering top-left).
	anchor_left = 0.0
	anchor_top = 0.0
	anchor_right = 1.0
	anchor_bottom = 1.0
	offset_left = 0.0
	offset_top = 0.0
	offset_right = 0.0
	offset_bottom = 0.0
	mouse_filter = Control.MOUSE_FILTER_STOP  # eat any click that misses the frame (no world leak)
	z_index = 200  # above every other HUD panel (gateway_login uses the same)
	visible = false
	add_to_group("ui_blocking_modal")
	theme = UiTheme.build()

	# Full-screen dim behind the frame — also STOP so background clicks never reach the world.
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

	# T-400: SolidWindow frame, centered at a fixed size (the T-396 seam). PanelContainer supplies
	# content margins so the VBox needs no manual offsets.
	var frame := PanelContainer.new()
	frame.name = "Frame"
	frame.theme_type_variation = "SolidWindow"  # T-396: deliberate window = opaque opt-in
	add_child(frame)
	# EXPLICIT anchors, not set_anchors_preset — the preset call ITSELF is the 4.7 trap
	# (a32d538: its offset recompute collapses containers; the judge caught these five as
	# 17x16 stubs). Center the frame at a fixed 560x320 over the full-rect shade.
	frame.anchor_left = 0.5
	frame.anchor_top = 0.5
	frame.anchor_right = 0.5
	frame.anchor_bottom = 0.5
	frame.offset_left = -280.0
	frame.offset_top = -160.0
	frame.offset_right = 280.0
	frame.offset_bottom = 160.0

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 10)
	frame.add_child(vbox)

	var title := Label.new()
	title.text = "Choose your class — this choice is permanent (reroll to change)."
	title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(title)

	for c: Dictionary in _CLASSES:
		var button := Button.new()
		button.name = "Btn_%s" % c["id"]
		button.text = "%s  —  %s" % [c["name"], c["blurb"]]
		button.alignment = HORIZONTAL_ALIGNMENT_LEFT
		var meta: String = "set_class|%s" % c["id"]
		button.pressed.connect(func(): action_selected.emit(meta))
		vbox.add_child(button)
		_buttons.append(button)

	var hint := Label.new()
	hint.text = "Click a class, use ↑/↓ + Enter, or press 1 / 2 / 3."
	hint.modulate = Color(0.7, 0.7, 0.75)
	vbox.add_child(hint)

	visibility_changed.connect(_on_visibility_changed)


# Focus the first button whenever the panel appears — ↑/↓ + Enter work immediately.
# T-718: also raise the panel to the top of its sibling order — z_index only wins the DRAW, GUI
# mouse picking goes by tree order (see modal_input.gd), and this modal is built early in $HUD.
func _on_visibility_changed() -> void:
	if not visible:
		return
	ModalInput.raise_to_front(self)
	if not _buttons.is_empty():
		(_buttons[0] as Button).grab_focus()


# T-718 (portal #108): a CLICK on a class row must do exactly what pressing 1/2/3 does. It used to
# depend on GUI mouse picking, which resolves by tree order and ignores z_index — a later, visible,
# full-rect sibling ate the press, so no set_class intent was ever sent and the panel stayed up
# (a following key press was what actually completed creation). Routing the click here, at the same
# `_input` stage the keys already own, makes the two paths identical and overlay-proof: the same
# Button.pressed signal is emitted, and the event is marked handled so the underlying Button never
# double-fires it via gui_input.
# A miss is deliberately NOT swallowed: the shade's MOUSE_FILTER_STOP still eats off-button clicks
# through the normal GUI path when this modal wins the pick, and letting a miss through keeps an
# illegally-stacked surface above us (the s25 Handbook overlap) closable by mouse.
func _route_mouse(mouse: InputEventMouseButton) -> void:
	if not mouse.pressed or mouse.button_index != MOUSE_BUTTON_LEFT:
		return
	var index := ModalInput.hit_index(_buttons, mouse.position)
	if index < 0:
		return
	(_buttons[index] as Button).pressed.emit()
	get_viewport().set_input_as_handled()  # exactly one dispatch — never also via gui_input


# 1/2/3 shortcuts while the panel is up. Marks the event handled so the ability bar
# (main's 1-4 keys) never fires underneath the selection.
func _input(event: InputEvent) -> void:
	# T-512: this IS the blocking modal, so it does NOT gate on UiInputGate (that would self-block).
	# While visible it owns the keyboard: 1/2/3 pick, Enter/Space activates the focused class,
	# ↑/↓ move focus. Everything else is swallowed so nothing underneath fires.
	if not visible:
		return
	if event is InputEventMouseButton:
		_route_mouse(event as InputEventMouseButton)  # T-718: click == key press
		return
	if not (event is InputEventKey) or not event.is_pressed() or event.is_echo():
		return
	var key := event as InputEventKey
	if key.keycode >= KEY_1 and key.keycode <= KEY_3:
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
