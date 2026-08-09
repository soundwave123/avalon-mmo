class_name VitalsFrame
# T-308: the player's always-on vitals — a HEALTH bar (present for every class) with the class
# resource (mana/rage/energy) stacked beneath it, numeric + fill, in a framed iron/gold panel.
# This is the headline of the HUD overhaul: before T-308 the player had NO on-screen HP at all.
#
# Bars are built by hand (framed trough Panel + a fill Panel sized via anchor_right) rather than a
# themed ProgressBar so the fill colour and medieval framing are fully under our control, and so an
# update is a single anchor assignment + label text (no per-frame node allocation — T-210 budget).

extends Control

const _BAR_W := 240.0
const _BAR_H := 22.0

var _hp_fill: Panel = null
var _hp_label: Label = null
var _res_row: Control = null
var _res_fill: Panel = null
var _res_label: Label = null

var _hp: int = 0
var _hp_max: int = 0
var _res: int = 0
var _res_max: int = 0
var _res_kind: String = "none"

# T-697 fix 5: cached fill styleboxes + last-shown snapshots. The 10 Hz vitals broadcast used to
# allocate two fresh StyleBoxFlat and re-trigger a relayout on EVERY _apply, even when nothing
# changed; now the styleboxes are built once and an unchanged update returns before touching the
# controls. The override itself re-fires only when the picked stylebox actually flips.
var _hp_style: StyleBoxFlat = null
var _hp_style_low: StyleBoxFlat = null
var _res_styles: Dictionary = {}  # resource kind -> cached fill StyleBoxFlat
var _shown_hp: int = -1
var _shown_hp_max: int = -1
var _shown_hp_low: int = -1  # -1 unknown, else 0/1 — which hp stylebox is applied
var _shown_res: int = -1
var _shown_res_max: int = -1
var _shown_res_kind: String = "\n"  # impossible kind, forces the first apply
var _applied_res_style: String = ""  # kind whose stylebox is on the fill (may lag while hidden)


func _ready() -> void:
	# T-460: no box on an idle surface (T-396 rule 2/5) — the bars carry their own thin-outlined
	# troughs and the value labels carry the theme's outline+shadow, so the frame needs only a
	# subtle bottom-weighted gradient behind them (the chat treatment), not a filled/bordered panel.
	# T-645: never eat world clicks while idle — set mouse_filter on the root control.
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var backdrop := UiTheme.gradient_backdrop(0.28, true)
	backdrop.name = "VitalsGradient"
	add_child(backdrop)

	var panel := PanelContainer.new()
	panel.name = "VitalsPanel"
	panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	panel.add_theme_stylebox_override("panel", UiTheme.no_box_stylebox(4.0))
	add_child(panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 4)
	panel.add_child(vbox)

	var hp_row := _build_bar("Health")
	_hp_fill = hp_row.get_meta("fill")
	_hp_label = hp_row.get_meta("label")
	vbox.add_child(hp_row)

	_res_row = _build_bar("Resource")
	_res_fill = _res_row.get_meta("fill")
	_res_label = _res_row.get_meta("label")
	vbox.add_child(_res_row)

	custom_minimum_size = Vector2(_BAR_W + 16.0, 0.0)
	_apply()
	# T-651: T-645 only IGNORE'd the root — trough/panel/VitalsPanel (PanelContainer, default STOP)
	# still spanned the visible bars and ate world clicks. Cascade to the whole idle subtree; no
	# child here is ever interactive (no buttons/tooltips).
	UiTheme.set_mouse_filter_deep(self)


# One framed trough with a coloured fill Panel and a centered numeric label on top.
func _build_bar(bar_name: String) -> Control:
	var trough := Panel.new()
	trough.name = bar_name + "Trough"
	# T-460: translucent trough + the 1px bronze hairline — a bar, not a box, over bright grass.
	trough.add_theme_stylebox_override("panel", UiTheme.trough_stylebox(0.55))
	trough.custom_minimum_size = Vector2(_BAR_W, _BAR_H)

	var fill := Panel.new()
	fill.name = "Fill"
	fill.add_theme_stylebox_override("panel", UiTheme.fill_stylebox(UiTheme.HEALTH))
	fill.set_anchors_preset(Control.PRESET_FULL_RECT)
	fill.offset_left = 2.0
	fill.offset_top = 2.0
	fill.offset_bottom = -2.0
	fill.anchor_right = 1.0
	fill.offset_right = -2.0
	fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	trough.add_child(fill)

	var label := Label.new()
	label.name = "Value"
	label.set_anchors_preset(Control.PRESET_FULL_RECT)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	trough.add_child(label)

	trough.set_meta("fill", fill)
	trough.set_meta("label", label)
	return trough


# T-308: HP is always shown. Fed from our own positions-broadcast entry (hp/max_hp).
func update_health(current: int, maximum: int) -> void:
	_hp = current
	_hp_max = maximum
	_apply()


# The class resource beneath HP. kind "none" hides the resource row (still shows HP).
func update_resource(kind: String, current: int, maximum: int) -> void:
	_res_kind = kind
	_res = current
	_res_max = maximum
	_apply()


func _apply() -> void:
	if _hp_fill == null:
		return
	if _hp != _shown_hp or _hp_max != _shown_hp_max:
		_shown_hp = _hp
		_shown_hp_max = _hp_max
		var hp_ratio := _ratio(_hp, _hp_max)
		_hp_fill.anchor_right = hp_ratio
		var low := 1 if hp_ratio <= 0.3 else 0
		if low != _shown_hp_low:
			_shown_hp_low = low
			if _hp_style == null:
				_hp_style = UiTheme.fill_stylebox(UiTheme.HEALTH)
				_hp_style_low = UiTheme.fill_stylebox(UiTheme.HEALTH_LOW)
			_hp_fill.add_theme_stylebox_override("panel", _hp_style_low if low == 1 else _hp_style)
		_hp_label.text = "Health  %d / %d" % [maxi(_hp, 0), maxi(_hp_max, 0)]

	if _res_kind == _shown_res_kind and _res == _shown_res and _res_max == _shown_res_max:
		return
	_shown_res = _res
	_shown_res_max = _res_max
	_shown_res_kind = _res_kind
	if _res_kind == "none" or _res_max <= 0:
		_res_row.visible = false
		return
	_res_row.visible = true
	_res_fill.anchor_right = _ratio(_res, _res_max)
	# The fill stylebox re-fires only when the VISIBLE row's kind differs from the one applied
	# (tracked separately from _shown_res_kind — a kind first seen while hidden still needs it).
	if _res_kind != _applied_res_style:
		_applied_res_style = _res_kind
		if not _res_styles.has(_res_kind):
			_res_styles[_res_kind] = UiTheme.fill_stylebox(_resource_color(_res_kind))
		_res_fill.add_theme_stylebox_override("panel", _res_styles[_res_kind])
	_res_label.text = "%s  %d / %d" % [_res_kind.capitalize(), maxi(_res, 0), maxi(_res_max, 0)]


func _ratio(current: int, maximum: int) -> float:
	if maximum <= 0:
		return 0.0
	return clampf(float(current) / float(maximum), 0.0, 1.0)


func _resource_color(kind: String) -> Color:
	match kind:
		"rage":
			return UiTheme.RAGE
		"energy", "focus":
			return UiTheme.ENERGY
		_:
			return UiTheme.MANA


# ---- headless-test accessors --------------------------------------------
func get_health_ratio() -> float:
	return _hp_fill.anchor_right if _hp_fill != null else 0.0


func get_health_text() -> String:
	return _hp_label.text if _hp_label != null else ""


func is_resource_visible() -> bool:
	return _res_row != null and _res_row.visible


func get_resource_text() -> String:
	return _res_label.text if _res_label != null else ""
