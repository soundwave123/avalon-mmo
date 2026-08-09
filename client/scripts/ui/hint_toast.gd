class_name HintToast
# T-426: the non-modal, one-line contextual hint surface. Renders each hint as outlined parchment
# text over the chat-gradient idiom (UiTheme.gradient_backdrop + no_box_stylebox, T-460) — never a
# forged-iron box, never modal, never blocks input outside its own strip. One hint at a time;
# later hints queue. Auto-fades after SHOW_SECS; a click on the strip dismisses it early.
#
# show_hint/tick/dismiss form a pure state machine (queue -> showing -> idle) so it unit-tests
# headless; _render() (guarded on null nodes) is the only tree-touching part — the cast-bar idiom.

extends Control

signal hint_dismissed

const UiTheme = preload("res://scripts/ui/ui_theme.gd")

const SHOW_SECS := 9.0

var _queue: Array = []
var _current := ""
var _remaining := 0.0
var _label: Label = null
var _panel: PanelContainer = null


func _ready() -> void:
	# T-580 (portal #37): the daily-reward "return reason" cue fires from main.gd's Esc handler in
	# the SAME beat that opens the Options menu (_handle_escape -> settings_panel.toggle() then
	# _onboarding.show_return_reason()), and HintToast is parented under $HUD well after SettingsPanel
	# (onboarding_controller.setup() runs late in main.gd's build order), so plain tree order drew the
	# toast text ON TOP of the Options panel's Style header. Every genuine modal in this codebase
	# (ClassPanel, GenderPanel, CharacterSelect, MaintenanceBanner) already opts INTO a high z_index to
	# sit above the default-z_index=0 HUD; the toast is the mirror case — it should never be the thing
	# that wins that fight. A negative z_index is order-independent (unlike move_child), so it stays
	# behind every ordinary panel (Options, quest log, bags, ...) regardless of add_child sequencing.
	z_index = -1
	# A slim strip below the target-frame band. Explicit anchors (the 4.7 HUD-blank trap).
	anchor_left = 0.5
	anchor_right = 0.5
	anchor_top = 0.0
	anchor_bottom = 0.0
	offset_left = -320.0
	offset_right = 320.0
	offset_top = 132.0
	offset_bottom = 166.0
	mouse_filter = Control.MOUSE_FILTER_IGNORE  # only the strip itself catches the dismiss click

	var backdrop := UiTheme.gradient_backdrop(0.26, false)
	backdrop.name = "HintGradient"
	add_child(backdrop)

	_panel = PanelContainer.new()
	_panel.name = "HintPanel"
	_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	_panel.add_theme_stylebox_override("panel", UiTheme.no_box_stylebox(4.0))
	_panel.gui_input.connect(_on_gui_input)  # click-to-dismiss
	add_child(_panel)

	_label = Label.new()
	_label.name = "HintLine"
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_label.add_theme_color_override("font_color", UiTheme.GOLD_BRIGHT)
	_panel.add_child(_label)
	_render()


func _process(delta: float) -> void:
	tick(delta)


# ---- the pure state machine (headless-testable) ----


# Enqueue a hint line; shows immediately when idle, otherwise waits its turn.
func show_hint(text: String) -> void:
	if text.strip_edges() == "":
		return
	if _current == "":
		_begin(text)
	else:
		_queue.append(text)
	_render()


# Advance time: expire the current hint after SHOW_SECS, then pull the next queued one.
func tick(dt: float) -> void:
	if _current == "":
		return
	_remaining -= dt
	if _remaining <= 0.0:
		_advance()
	_render()


# Player clicked the strip (or the handbook closed over it): drop the current hint early.
func dismiss() -> void:
	if _current == "":
		return
	_advance()
	_render()


func _begin(text: String) -> void:
	_current = text
	_remaining = SHOW_SECS


func _advance() -> void:
	hint_dismissed.emit()
	if _queue.is_empty():
		_current = ""
		_remaining = 0.0
	else:
		_begin(_queue.pop_front())


# ---- accessors (tests + the controller) ----


func is_showing() -> bool:
	return _current != ""


func current_text() -> String:
	return _current


func queued_count() -> int:
	return _queue.size()


# ---- tree-touching only below ----


func _on_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		dismiss()


func _render() -> void:
	if _label == null:
		return  # headless unit tests — state above is the truth
	_label.text = _current
	visible = _current != ""
