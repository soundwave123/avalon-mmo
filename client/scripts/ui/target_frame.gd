class_name TargetFrame
# T-283/T-462/T-505: the WoW-style target frame — top-left beside player vitals, with name, level,
# and exact health for your
# current target, with the health bar colored by relationship (hostile red, friendly green).
# Hidden when you have no target; cleared when the target dies or leaves the broadcast.
#
# bind()/clear() are a small state model (bound flag, name, hp ratio, color) so the frame
# unit-tests without a scene tree; _render() (guarded on null nodes) draws it when live.

extends Control

# T-736: right-click RELEASE on the frame (without dragging off it) — the owner-specified
# "right-click their name" seam; main-side wiring opens the party context menu for the
# current selection. Press+release both land here (root is MOUSE_FILTER_STOP now).
signal right_clicked(pos: Vector2)

const _W := 260.0
const _CLICK_SLOP_PX := 4.0  # mirrors LocalPlayer.ORBIT_DEADZONE_PX (T-739 click-vs-drag rule)
const _H := 62.0
const _LEFT := 292.0  # 20px margin + 256px vitals + 16px breathing room
const _TOP := 20.0

var _frame_width: float = _W
var _frame_height: float = _H
var _frame_left: float = _LEFT
var _frame_top: float = _TOP
var _bar_top: float = 31.0
var _bar_height: float = 22.0
var _bound: bool = false
var _unit_name: String = ""
var _unit_level: int = 0
var _hp: int = 0
var _max_hp: int = 0
var _ratio: float = 0.0
var _color: Color = Color.WHITE
var _name_label: Label = null
var _level_label: Label = null
var _hp_label: Label = null
var _bar_bg: ColorRect = null
var _bar_fill: ColorRect = null
var _rmb_press: Vector2 = Vector2.INF  # T-736: RMB press anchor for the click-slop rule


func _ready() -> void:
	anchor_left = 0.0
	anchor_right = 0.0
	anchor_top = 0.0
	anchor_bottom = 0.0
	custom_minimum_size = Vector2(_frame_width, _frame_height)
	offset_left = _frame_left
	offset_right = _frame_left + _frame_width
	offset_top = _frame_top
	offset_bottom = _frame_top + _frame_height
	# T-736: STOP (was IGNORE) — the frame is only visible while a target is bound, and it now
	# owns its own right-click affordance. Children stay IGNORE so gui_input lands on the root.
	mouse_filter = Control.MOUSE_FILTER_STOP
	gui_input.connect(_on_gui_input)
	# T-396/T-505 de-boxed idiom: text outline + bar carry legibility; only the shared subtle
	# chat-gradient sits behind them, never a filled/bordered whole-frame Panel.
	var backdrop := UiTheme.gradient_backdrop(0.26, true)
	backdrop.name = "TargetGradient"
	backdrop.anchor_left = 0.0
	backdrop.anchor_top = 0.0
	backdrop.anchor_right = 1.0
	backdrop.anchor_bottom = 1.0
	backdrop.offset_left = 0.0
	backdrop.offset_top = 0.0
	backdrop.offset_right = 0.0
	backdrop.offset_bottom = 0.0
	backdrop.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(backdrop)
	_name_label = Label.new()
	_name_label.position = Vector2(10.0, 3.0)
	_name_label.size = Vector2(_frame_width - 90.0, 22.0)
	_name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_name_label)
	_level_label = Label.new()
	_level_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_level_label.position = Vector2(_frame_width - 88.0, 3.0)
	_level_label.size = Vector2(78.0, 22.0)
	_level_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_level_label)
	_bar_bg = ColorRect.new()
	_bar_bg.color = Color(0.08, 0.07, 0.07, 0.95)
	_bar_bg.position = Vector2(8.0, _bar_top)
	_bar_bg.size = Vector2(_frame_width - 16.0, _bar_height)
	_bar_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_bar_bg)
	_bar_fill = ColorRect.new()
	_bar_fill.position = Vector2(8.0, _bar_top)
	_bar_fill.size = Vector2(_frame_width - 16.0, _bar_height)
	_bar_fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_bar_fill)
	_hp_label = Label.new()
	_hp_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hp_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_hp_label.position = Vector2(8.0, _bar_top)
	_hp_label.size = Vector2(_frame_width - 16.0, _bar_height)
	_hp_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_hp_label)
	hide()


# T-665: configure the secondary target-of-target frame before it enters the tree.
func configure_compact() -> void:
	_frame_width = 190.0
	_frame_height = 48.0
	_frame_left = _LEFT + 70.0
	_frame_top = _TOP + _H + 6.0
	_bar_top = 26.0
	_bar_height = 15.0


# Bind server-fed display state. Level stays optional for player rows that do not carry it yet.
func bind_target(unit_name: String, hp: int, max_hp: int, color: Color, level: int = 0) -> void:
	_bound = true
	_unit_name = unit_name
	_unit_level = maxi(0, level)
	_hp = maxi(0, hp)
	_max_hp = maxi(0, max_hp)
	_ratio = clampf(float(hp) / float(maxi(1, max_hp)), 0.0, 1.0) if max_hp > 0 else 0.0
	_color = color
	_render()


func clear() -> void:
	_bound = false
	_render()


func is_bound() -> bool:
	return _bound


func unit_name() -> String:
	return _unit_name


func unit_level() -> int:
	return _unit_level


func health_text() -> String:
	return "%d / %d" % [_hp, _max_hp] if _max_hp > 0 else "—"


func fill_ratio() -> float:
	return _ratio


func fill_color() -> Color:
	return _color


# T-736: right-click release with at most click-slop travel emits right_clicked (screen pos).
# Tracked locally: a drag that starts on the frame is neither a click nor a mouse-look.
func _on_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT:
		if event.pressed:
			_rmb_press = event.global_position
		elif _rmb_press != Vector2.INF:
			if event.global_position.distance_to(_rmb_press) <= _CLICK_SLOP_PX:
				right_clicked.emit(event.global_position)
			_rmb_press = Vector2.INF


func _render() -> void:
	if _name_label == null:
		return  # headless (unit tests) — state is bound, nothing to draw
	if not _bound:
		hide()
		return
	_name_label.text = _unit_name
	_level_label.text = "Level %d" % _unit_level if _unit_level > 0 else ""
	_hp_label.text = health_text()
	_bar_fill.color = _color
	_bar_fill.size = Vector2((_frame_width - 16.0) * _ratio, _bar_height)
	show()
