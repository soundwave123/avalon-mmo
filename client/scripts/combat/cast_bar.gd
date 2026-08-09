class_name CastBar
# T-027 §6: Cosmetic cast bar driven by server cast_started / cast_cancelled events.
#
# A ProgressBar that fills from 0 → 1 over the cast duration (cast_ticks * tick seconds).
# Purely cosmetic — it does NOT predict when the cast fires. It is shown on cast_started
# and hidden on cast_cancelled or when the ability_result (spell fired) arrives.
#
# Testable headlessly: is_casting(), get_ability_id(), get_progress().

extends Control

signal cast_shown(ability_id: int, cast_ticks: int)
signal cast_hidden

# Server runs at ServerConfig.TICK_RATE_HZ; mirror it client-side for the fill duration.
# Only affects how long the cosmetic bar animates — server remains authoritative on timing.
const TICK_SECONDS: float = 0.05  # 20 Hz

var _bar: ProgressBar = null
var _is_casting: bool = false
var _ability_id: int = -1
var _tween: Tween = null


func _ready() -> void:
	_bar = ProgressBar.new()
	_bar.name = "CastProgress"
	_bar.min_value = 0.0
	_bar.max_value = 1.0
	_bar.value = 0.0
	_bar.show_percentage = false
	add_child(_bar)
	hide()


func start_cast(ability_id: int, cast_ticks: int, tick_seconds: float = TICK_SECONDS) -> void:
	"""Show the bar and fill it over the cast duration."""
	_ability_id = ability_id
	_is_casting = true
	_bar.value = 0.0
	show()

	var duration: float = maxf(0.01, float(cast_ticks) * tick_seconds)
	_kill_tween()
	_tween = create_tween()
	_tween.tween_property(_bar, "value", 1.0, duration)
	_tween.finished.connect(_on_fill_complete)

	cast_shown.emit(ability_id, cast_ticks)


func cancel() -> void:
	"""Hide the bar (cast cancelled or the ability fired)."""
	if not _is_casting:
		return
	_stop()


func _on_fill_complete() -> void:
	# The bar finished filling; the real fire is driven by the server's ability_result,
	# but if that hasn't arrived we still hide the completed cosmetic bar.
	_stop()


func _stop() -> void:
	_is_casting = false
	_kill_tween()
	hide()
	cast_hidden.emit()


func _kill_tween() -> void:
	if _tween != null and _tween.is_valid():
		_tween.kill()
	_tween = null


func is_casting() -> bool:
	return _is_casting


func get_ability_id() -> int:
	return _ability_id


func get_progress() -> float:
	return _bar.value if _bar != null else 0.0
