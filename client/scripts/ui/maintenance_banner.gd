class_name MaintenanceBanner
extends Control

# T-511: important, de-boxed maintenance countdown. This is deliberately only outlined amber text
# (no panel, toast card, or ColorRect) so it cannot be confused with the low-priority hint system.
const AMBER := Color(1.0, 0.67, 0.20)

var _label: Label
var _active := false


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	z_index = 190
	set_anchors_preset(Control.PRESET_CENTER_TOP)
	offset_left = -360.0
	offset_top = 28.0
	offset_right = 360.0
	offset_bottom = 72.0
	_label = Label.new()
	_label.name = "Text"
	_label.set_anchors_preset(Control.PRESET_FULL_RECT)
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_label.add_theme_font_size_override("font_size", 22)
	_label.add_theme_color_override("font_color", AMBER)
	_label.add_theme_color_override("font_outline_color", Color(0.05, 0.025, 0.0, 0.96))
	_label.add_theme_constant_override("outline_size", 5)
	_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.85))
	_label.add_theme_constant_override("shadow_offset_y", 2)
	add_child(_label)
	visible = false


func display(notice: Dictionary) -> void:
	if _label == null:
		return
	_label.text = str(notice.get("text", "Server maintenance — %s" % notice.get("reason", "")))
	_active = true
	visible = true


func clear_notice() -> void:
	_active = false
	visible = false
	if _label != null:
		_label.text = ""


func is_active() -> bool:
	return _active


func banner_text() -> String:
	return _label.text if _label != null else ""
