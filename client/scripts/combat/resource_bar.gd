class_name ResourceBar
# T-062: the local player's class-resource HUD bar (rage red / mana blue), fed by the positions
# broadcast. Mirrors HealthBar's ProgressBar + theme-color pattern (no art assets pre-M7); a future
# TextureProgressBar swap is a pure visual upgrade later. Hidden when the class has no resource.
#
# Direct value set (not a Tween): the positions broadcast arrives ~10 Hz, so per-update tweens would
# stack/overlap; a hard set tracks the server value cleanly. (Tween smoothing is an easy polish.)

extends Control

const RAGE_COLOR := Color(0.78, 0.22, 0.22)  # red — Warrior rage
const MANA_COLOR := Color(0.25, 0.45, 0.95)  # blue — caster mana

var _label: Label = null
var _bar: ProgressBar = null


func _ready() -> void:
	var vbox := VBoxContainer.new()
	vbox.name = "ResourceVBox"
	vbox.add_theme_constant_override("separation", 2)
	add_child(vbox)

	_label = Label.new()
	_label.name = "ResourceLabel"
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(_label)

	_bar = ProgressBar.new()
	_bar.name = "ResourceProgress"
	_bar.min_value = 0
	_bar.max_value = 100
	_bar.value = 0
	_bar.show_percentage = false
	_bar.custom_minimum_size = Vector2(200, 20)
	vbox.add_child(_bar)


# Feed from the broadcast. kind = "rage" | "mana" | "none". Hidden (no class resource) for "none".
func update_resource(kind: String, current: int, maximum: int) -> void:
	if _bar == null or _label == null:
		return
	if kind == "none" or maximum <= 0:
		visible = false
		return
	visible = true
	_bar.max_value = float(maximum)
	_bar.value = float(clampi(current, 0, maximum))
	_bar.add_theme_color_override("fill_color", RAGE_COLOR if kind == "rage" else MANA_COLOR)
	_label.text = "%s: %d/%d" % [kind.capitalize(), current, maximum]


# Test/inspection accessors.
func get_value() -> int:
	return int(_bar.value) if _bar != null else 0


func get_max() -> int:
	return int(_bar.max_value) if _bar != null else 0
