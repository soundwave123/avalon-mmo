class_name HealthBar
# T-027: Entity health bar UI component.
#
# Node structure: Container → [HPLabel, HPBar] (created in _ready).
# Call `update_hp(current, max)` to update bar fill and label text.
# Color transitions from green (full) → yellow (mid) → red (low).

extends Control

const LOW_THRESHOLD: float = 0.3
const MID_THRESHOLD: float = 0.6

var _entity_id: int = -1
var _entity_name: String = ""
var _hp_label: Label = null
var _hp_bar: ProgressBar = null
var _ratio: float = 1.0


func _ready() -> void:
	_hp_label = Label.new()
	_hp_label.name = "HPLabel"
	_hp_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	add_child(_hp_label)

	_hp_bar = ProgressBar.new()
	_hp_bar.name = "HPBar"
	_hp_bar.min_value = 0
	_hp_bar.max_value = 100
	_hp_bar.value = 100
	_hp_bar.show_percentage = false
	add_child(_hp_bar)


func set_entity(entity_id: int, entity_name: String) -> void:
	_entity_id = entity_id
	_entity_name = entity_name


func update_hp(current_hp: int, max_hp: int) -> void:
	if _hp_label == null or _hp_bar == null:
		return

	_hp_bar.max_value = float(max_hp)
	_hp_bar.value = float(current_hp)

	var ratio: float = 0.0
	if max_hp > 0:
		ratio = float(current_hp) / float(max_hp)

	_ratio = ratio
	_hp_bar.add_theme_color_override("fill_color", get_bar_color(ratio))
	_hp_label.text = "%s: %d/%d" % [_entity_name, current_hp, max_hp]


func get_entity_id() -> int:
	return _entity_id


func get_ratio() -> float:
	return _ratio


func get_bar_color(ratio: float) -> Color:
	if ratio <= LOW_THRESHOLD:
		return Color(1.0, 0.2, 0.2)  # red
	if ratio <= MID_THRESHOLD:
		return Color(1.0, 0.8, 0.2)  # yellow
	return Color(0.2, 1.0, 0.2)  # green
