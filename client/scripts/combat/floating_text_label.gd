class_name FloatingTextLabel
# T-027: Single animated floating damage number / label.
#
# Node structure: Label + Tween (created in _ready).
# Call `show_text(value, color)` to start the animation.
# Emits `finished` signal when the label fades out and returns to pool.

extends Control

signal finished

var _tween: Tween = null
var _is_animating: bool = false


func _ready() -> void:
	modulate = Color(1, 1, 1, 1)
	anchor_left = 0.5
	anchor_top = 0.0
	anchor_right = 0.5
	anchor_bottom = 1.0
	offset_top = -20
	offset_bottom = 20
	hide()


func show_text(text: String, color: Color) -> void:
	"""Start a float-up + fade-out animation. Emits finished when done."""
	if _is_animating:
		return

	var label: Label = _get_label()
	if label == null:
		return

	label.text = text
	label.modulate = color
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	pivot_offset = Vector2(0, 0)

	show()
	_is_animating = true
	offset_top = -10.0
	offset_bottom = 10.0
	modulate = Color(color.r, color.g, color.b, 1.0)
	scale = Vector2(1.2, 1.2)

	_tween = create_tween()
	_tween.set_parallel(true)

	_tween.tween_property(self, "offset_top", -60.0, 1.0)
	_tween.tween_property(self, "offset_bottom", -40.0, 1.0)
	_tween.tween_property(self, "modulate:a", 0.0, 1.0)
	_tween.tween_property(self, "scale", Vector2(1.0, 1.0), 0.3)

	_tween.tween_interval(0.7)
	_tween.connect("finished", _on_tween_finished)


func is_animating() -> bool:
	return _is_animating


func _on_tween_finished() -> void:
	_is_animating = false
	hide()
	finished.emit()


func _get_label() -> Label:
	for child in get_children():
		if child is Label:
			return child as Label
	var label := Label.new()
	label.name = "Label"
	add_child(label)
	return label
