class_name ScreenFlash
# T-027 §5: Full-screen damage-received flash.
#
# A ColorRect overlaying the viewport. flash() sets it to peak alpha then tweens to 0.
# Triggered only when the local player is the damage target (the orchestrator decides);
# no flash on miss. Purely cosmetic.
#
# Testable headlessly: is_flashing(), get_alpha().

extends Control

signal flash_started

const DEFAULT_COLOR: Color = Color(1.0, 0.0, 0.0)  # red
const DEFAULT_PEAK_ALPHA: float = 0.2
const DEFAULT_DURATION: float = 0.2

var _rect: ColorRect = null
var _is_flashing: bool = false
var _tween: Tween = null


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	_rect = ColorRect.new()
	_rect.name = "FlashRect"
	_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	_rect.color = Color(DEFAULT_COLOR.r, DEFAULT_COLOR.g, DEFAULT_COLOR.b, 0.0)
	_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_rect)


func flash(
	color: Color = DEFAULT_COLOR,
	peak_alpha: float = DEFAULT_PEAK_ALPHA,
	duration: float = DEFAULT_DURATION
) -> void:
	"""Flash the overlay to peak_alpha, then fade to 0 over duration."""
	if _rect == null:
		return
	_is_flashing = true
	_rect.color = Color(color.r, color.g, color.b, peak_alpha)

	_kill_tween()
	_tween = create_tween()
	_tween.tween_property(_rect, "color:a", 0.0, duration)
	_tween.finished.connect(_on_fade_complete)

	flash_started.emit()


func _on_fade_complete() -> void:
	_is_flashing = false
	_kill_tween()


func _kill_tween() -> void:
	if _tween != null and _tween.is_valid():
		_tween.kill()
	_tween = null


func is_flashing() -> bool:
	return _is_flashing


func get_alpha() -> float:
	return _rect.color.a if _rect != null else 0.0
