class_name ControlsCard
# T-376: the onboarding controls card — the first thing a brand-new adventurer sees on entering the
# world, so they learn to move, look, fight and interact instead of being stranded at the class
# panel. Built in CODE (no .tscn) on the shared UiTheme so it reads as the same forged-iron HUD.
# Rows come from ControlsReference (labels derived from the live keycodes — never hand-typed).
# Dismissible (Close button or Esc via main's panel precedence) and re-openable any time with F1;
# main.gd persists "seen" per-user so a returning player is never shown it again unbidden.
#
# T-426 grows it into the full help/glossary surface (GameFlow "no manual needed"): the SolidWindow
# chrome (a deliberately-summoned window, T-396), a GLOSSARY of the core verbs/concepts, the list
# of contextual hints for review after they fired, and the "Show hints" suppression switch.

extends Control

signal dismissed
# T-426: the "Show hints" switch flipped (OnboardingController persists it per user).
signal hints_toggled(enabled: bool)

const UiTheme = preload("res://scripts/ui/ui_theme.gd")
const ControlsReference = preload("res://scripts/ui/controls_reference.gd")
const HintReference = preload("res://scripts/ui/hint_reference.gd")

const _COMPACT_SCROLL_H := 92.0  # T-717: three rows + breathing room
const _SCROLL_MAX_H := 430.0  # keep the window inside 720p (the T-400 settings-panel lesson)

var _rows_box: VBoxContainer = null
var _body: PanelContainer = null  # T-748: the bounded card rect — the only click-blocking surface
var _full_only: Array = []  # T-717: nodes shown only in the full (F1) handbook
var _compact_footer: Label = null
var _full_footer: Label = null
var _scroll: ScrollContainer = null
var _glossary_box: VBoxContainer = null
var _hints_box: VBoxContainer = null
var _hints_check: CheckButton = null


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	offset_left = 16.0
	offset_top = 16.0
	offset_right = -16.0
	offset_bottom = -16.0
	theme = UiTheme.build()
	visible = false
	# T-748: the handbook is a WINDOW, not a modal, but it was a full-screen default-STOP overlay
	# added LAST to $HUD — and GUI picking goes by reverse child order and ignores z_index, so while
	# it was up it won EVERY click on screen, over panels and over the z=200 creation modals alike
	# (the s25 trap modal_input.gd documents). Recipe (c) in ui_theme.gd — the porous overlay: the
	# full-rect CHROME (root, dim, centering) never takes a pick; only the bounded card BODY does.
	# So the handbook blocks clicks over itself and nowhere else.
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	var dim := ColorRect.new()
	dim.name = "Dim"
	dim.color = Color(0.0, 0.0, 0.0, 0.55)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE  # a scrim you can see through AND click through
	add_child(dim)

	var center := CenterContainer.new()
	center.name = "CardCenter"
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE  # full-rect centering chrome, not a surface
	add_child(center)

	var panel := PanelContainer.new()
	panel.name = "CardBody"
	panel.theme_type_variation = "SolidWindow"  # T-396: deliberate window = opaque opt-in
	panel.mouse_filter = Control.MOUSE_FILTER_STOP  # the ONE blocking rect: the card itself
	_body = panel
	center.add_child(panel)
	var box := VBoxContainer.new()
	box.custom_minimum_size = Vector2(560.0, 0.0)
	box.add_theme_constant_override("separation", 8)
	panel.add_child(box)

	var title := Label.new()
	title.text = "The Adventurer's Handbook"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 24)
	title.add_theme_color_override("font_color", UiTheme.GOLD_BRIGHT)
	box.add_child(title)

	var lede := Label.new()
	lede.text = "Welcome, traveller. Learn the ways of hand and eye:"
	lede.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lede.add_theme_color_override("font_color", UiTheme.PARCHMENT_DIM)
	box.add_child(lede)

	# T-426: controls + glossary + hints can outgrow 720p — scroll inside, window stays put.
	var scroll := ScrollContainer.new()
	_scroll = scroll
	scroll.custom_minimum_size = Vector2(560.0, _SCROLL_MAX_H)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	box.add_child(scroll)
	var content := VBoxContainer.new()
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.add_theme_constant_override("separation", 8)
	scroll.add_child(content)

	_rows_box = VBoxContainer.new()
	_rows_box.add_theme_constant_override("separation", 3)
	content.add_child(_rows_box)
	_build_rows()

	_full_only.append(_section_label("The ways of the world"))
	content.add_child(_full_only[-1])
	_glossary_box = VBoxContainer.new()
	_glossary_box.add_theme_constant_override("separation", 3)
	content.add_child(_glossary_box)
	_build_glossary()

	_full_only.append(_section_label("Whispers of guidance"))
	content.add_child(_full_only[-1])
	_hints_box = VBoxContainer.new()
	_hints_box.add_theme_constant_override("separation", 3)
	content.add_child(_hints_box)
	_build_hints()

	_hints_check = CheckButton.new()
	_hints_check.name = "ShowHints"
	_hints_check.text = "Show first-time hints"
	_hints_check.button_pressed = true
	_hints_check.toggled.connect(func(on: bool): hints_toggled.emit(on))
	box.add_child(_hints_check)

	_full_footer = Label.new()
	_full_footer.text = "Press F1 (or the ? by the compass) to open this handbook at any time."
	_full_footer.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_full_footer.add_theme_color_override("font_color", UiTheme.PARCHMENT_DIM)
	box.add_child(_full_footer)

	_compact_footer = Label.new()
	_compact_footer.name = "CompactFooter"
	_compact_footer.text = "That is enough to begin. Press F1 for everything else."
	_compact_footer.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_compact_footer.add_theme_color_override("font_color", UiTheme.PARCHMENT_DIM)
	box.add_child(_compact_footer)

	var close := Button.new()
	close.name = "ControlsClose"
	close.text = "Got it (Esc)"
	close.pressed.connect(close_card)
	box.add_child(close)


# One parchment row per control: the key/mouse label (gold) beside its plain-language action.
func _build_rows(compact: bool = false) -> void:
	for child in _rows_box.get_children():
		child.queue_free()
		_rows_box.remove_child(child)  # free is deferred; unparent now so the rebuild is clean
	var source: Array = ControlsReference.essential_rows() if compact else ControlsReference.rows()
	for r: Dictionary in source:
		_rows_box.add_child(_pair_row(str(r["keys_label"]), str(r["action"])))


# T-426: one glossary row per core verb/concept — term (gold) beside its one-line explanation.
func _build_glossary() -> void:
	for g: Dictionary in ControlsReference.glossary_rows():
		_glossary_box.add_child(_pair_row(str(g["term"]), str(g["tip"])))


# T-426: the contextual hints, reviewable here forever after their one live firing.
func _build_hints() -> void:
	for id in HintReference.ids():
		var lbl := Label.new()
		lbl.text = "•  " + HintReference.text_for(str(id))
		lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_hints_box.add_child(lbl)


func _section_label(text: String) -> Label:
	var lbl := Label.new()
	lbl.text = text
	lbl.add_theme_font_size_override("font_size", 18)
	lbl.add_theme_color_override("font_color", UiTheme.GOLD)
	return lbl


func _pair_row(left: String, right: String) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	var key := Label.new()
	key.text = left
	key.custom_minimum_size = Vector2(200.0, 0.0)
	key.add_theme_color_override("font_color", UiTheme.GOLD_BRIGHT)
	row.add_child(key)
	var val := Label.new()
	val.text = right
	val.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	val.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(val)
	return row


# T-426: reflect the persisted "show hints" setting without re-emitting the toggle.
func set_hints_checked(on: bool) -> void:
	if _hints_check != null:
		_hints_check.set_pressed_no_signal(on)


# T-717: `compact` is the auto-shown first impression — 3 rows, no glossary/hints, a pointer at F1.
# Every later open (F1 / the ? button) is the full reference. Rebuilds the row list each time so the
# labels stay derived from the live bindings in both modes.
func open(compact: bool = false) -> void:
	_build_rows(compact)
	for node: Control in _full_only:
		node.visible = not compact
	_glossary_box.visible = not compact
	_hints_box.visible = not compact
	if _hints_check != null:
		_hints_check.visible = not compact
	if _compact_footer != null:
		_compact_footer.visible = compact
	if _full_footer != null:
		_full_footer.visible = not compact  # one footer at a time — they say the same thing
	if _scroll != null:
		# compact holds exactly 3 rows; reserving the full reference height leaves a dead grey
		# field below them, and shrinking to 0 collapses the scroll and hides them entirely.
		var h := _COMPACT_SCROLL_H if compact else _SCROLL_MAX_H
		_scroll.custom_minimum_size = Vector2(560.0, h)
	visible = true


func close_card() -> void:
	visible = false
	dismissed.emit()


func toggle() -> void:
	if visible:
		close_card()
	else:
		open()


# ---- headless-test accessors ----


# T-748: the bounded card rect (the porous overlay's one blocking surface) — lets a test click
# inside it and outside it and assert which control the viewport actually picked.
func card_body() -> PanelContainer:
	return _body


func row_count() -> int:
	return _rows_box.get_child_count() if _rows_box != null else 0


func glossary_count() -> int:
	return _glossary_box.get_child_count() if _glossary_box != null else 0


func hint_count() -> int:
	return _hints_box.get_child_count() if _hints_box != null else 0


func hints_checked() -> bool:
	return _hints_check != null and _hints_check.button_pressed


func get_text() -> String:
	var parts: Array = []
	for row in _rows_box.get_children():
		var segs: Array = []
		for lbl in row.get_children():
			segs.append((lbl as Label).text)
		parts.append("  ".join(segs))
	return "\n".join(parts)


# T-426: all glossary text (term + tip per line) — the "can I look X up in-game?" oracle.
func glossary_text() -> String:
	var parts: Array = []
	for row in _glossary_box.get_children():
		var segs: Array = []
		for lbl in row.get_children():
			segs.append((lbl as Label).text)
		parts.append("  ".join(segs))
	return "\n".join(parts)
