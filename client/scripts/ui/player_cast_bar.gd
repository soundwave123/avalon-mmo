class_name PlayerCastBar
# T-265 (M7 System D): the centered cast bar under your HUD while YOU cast. Driven by the
# broadcast cast truth (main._own_cast: {ability_id, remaining_s, total_s}, refreshed ~1Hz
# by T-264) and interpolated locally each frame for a smooth fill between updates. Distinct
# from the T-027 combat/cast_bar.gd, which is an event-driven cosmetic bar for ability use.
#
# update_cast(own_cast, dt) is a pure state machine (empty -> casting -> done | cancelled):
# it mutates state and query accessors only, so it unit-tests with no scene tree; _render()
# (guarded on null nodes) is the only tree-touching part. Cancel flash: if the cast dict
# vanishes with meaningful time left (interrupt/move), the bar flashes red briefly.

extends Control

# T-426: fired when a cast vanishes early (the red-flash read) — the teaching seam for the
# "moving cancels casting" contextual hint. Purely observational; the flash behavior is unchanged.
signal interrupted

# Vanishing with more than this remaining reads as an interrupt (flash), not a completion.
const CANCEL_MIN_REMAINING := 0.3
const FLASH_TIME := 0.3
const _BAR_W := 320.0
const _BAR_H := 22.0

var _names: Dictionary = {}  # ability_id -> display name (from the class kit)
var _active: bool = false
var _ability_id: int = -1
var _total: float = 0.0
var _remaining: float = 0.0
var _last_bcast: float = -1.0  # last broadcast remaining_s (fresh tick vs. stale repeat)
var _flash: float = 0.0
var _name_label: Label = null
var _bar: ProgressBar = null


func _ready() -> void:
	# Center-bottom, sitting above the action bar.
	# Explicit anchors (4.7-proof — see the HUD-judge anchor regression, 2026-07-13).
	anchor_left = 0.5
	anchor_right = 0.5
	anchor_top = 1.0
	anchor_bottom = 1.0
	custom_minimum_size = Vector2(_BAR_W, _BAR_H)
	offset_left = -_BAR_W / 2.0
	offset_right = _BAR_W / 2.0
	offset_top = -140.0
	offset_bottom = -140.0 + _BAR_H
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_bar = ProgressBar.new()
	_bar.min_value = 0.0
	_bar.max_value = 1.0
	_bar.show_percentage = false
	_bar.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_bar)
	_name_label = Label.new()
	_name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_name_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_name_label.set_anchors_preset(Control.PRESET_FULL_RECT)
	_name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_name_label)
	hide()


# ability_id -> display name, sourced from main's class kit (id/name entries).
func set_ability_names(names: Dictionary) -> void:
	_names = names


# The state machine. own_cast is main._own_cast for this frame ({} when not casting); dt is
# seconds since the last call. Interpolates remaining downward between ~1Hz broadcasts and
# resyncs to server truth whenever a fresh broadcast lowers remaining_s.
func update_cast(own_cast: Dictionary, dt: float) -> void:
	if _flash > 0.0:
		_flash = maxf(0.0, _flash - dt)
	if own_cast.is_empty():
		if _active:
			if _remaining > CANCEL_MIN_REMAINING:
				_flash = FLASH_TIME  # vanished early -> interrupted
				interrupted.emit()  # T-426: the "moving cancels casting" teaching moment
			_active = false
			_ability_id = -1
			_last_bcast = -1.0
		_render()
		return
	var aid := int(own_cast.get("ability_id", -1))
	var b_remain := float(own_cast.get("remaining_s", 0.0))
	var b_total := float(own_cast.get("total_s", 0.0))
	if not _active or aid != _ability_id or b_remain > _last_bcast + 0.05:
		# a new cast: fresh, a different ability, or the same ability restarted (remaining jumped up)
		_active = true
		_ability_id = aid
		_total = b_total
		_remaining = b_remain
		_flash = 0.0
	elif b_remain < _last_bcast - 0.001:
		_remaining = b_remain  # fresh broadcast tick -> snap to server truth
	else:
		_remaining = maxf(0.0, _remaining - dt)  # same broadcast -> interpolate locally
	_last_bcast = b_remain
	_render()


func fill_ratio() -> float:
	if _total <= 0.0:
		return 0.0
	return clampf((_total - _remaining) / _total, 0.0, 1.0)


func is_active() -> bool:
	return _active


func is_flashing() -> bool:
	return _flash > 0.0


func ability_id() -> int:
	return _ability_id


func remaining() -> float:
	return _remaining


func _render() -> void:
	if _bar == null or _name_label == null:
		return  # headless (unit tests) — state is updated, nothing to draw
	if _active:
		_name_label.text = str(_names.get(_ability_id, "Casting"))
		_bar.value = fill_ratio()
		modulate = Color(1, 1, 1, 1)
		show()
	elif _flash > 0.0:
		_name_label.text = "Interrupted"
		_bar.value = 1.0
		modulate = Color(1.0, 0.3, 0.3, 1.0)
		show()
	else:
		hide()
