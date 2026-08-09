class_name DeathPresentation
# T-506: renders the pure death timeline as a full-screen grayscale ramp, de-boxed death copy,
# covered respawn reveal, and one quiet durability consequence. It never decides death or respawn.
extends Control

const DeathState = preload("res://scripts/ui/death_presentation_state.gd")
const _DURABILITY_LINE := "Your gear was damaged."
const _DURABILITY_TOAST := "Your gear was damaged"
# T-533: the T-429 Performance Recap auto-surfaces on death, centered (offset +/-160 from screen
# centre after T-634's trim). The "You died." headline and durability toast were both parked at
# screen centre too, so the headline rendered *inside* the recap's rectangle. Compose the death
# frame as one stack: headline above the recap, recap centred, toast + respawn cue below, so nothing
# shares the recap's band at any supported resolution. Keep _RECAP_HALF_HEIGHT in sync with
# performance_recap_panel.gd's centre offset.
# T-554: the ±200 band (down from ±260) keeps the headline clear of the top compass at 1280x720 — a
# taller band pinned the headline into the compass "N / 0°" at short heights (the reported overlap).
# T-634: trimmed again to ±140 — the toast+cue stack below the recap landed on top of the ActionBar
# hotbar (y=580..632) because the old ±200 band + gaps only left 20px of clearance above it for two
# lines of text. _TOAST_HEIGHT/_CUE_HEIGHT are set to the labels' REAL rendered minimum height at
# their font sizes (Godot expands an anchored Control's rect to its content minimum regardless of
# a smaller requested offset span — a smaller constant here just silently under-budgets the next
# element's gap). HudSafeZone.ACTION_BAR_RECT (hud_safe_zone.gd) is the shared reference for the
# hotbar top edge; see the regression test in test_death_presentation.gd.
const _RECAP_HALF_HEIGHT := 140.0
const _COMPOSE_GAP := 6.0
const _DEATH_LABEL_HEIGHT := 84.0
const _TOAST_HEIGHT := 26.0
const _CUE_HEIGHT := 28.0
const _RESPAWN_CUE := "Respawning…"
const _GRAYSCALE_SHADER := """
shader_type canvas_item;
uniform sampler2D screen_texture : hint_screen_texture, repeat_disable, filter_linear;
uniform float amount : hint_range(0.0, 1.0) = 0.0;
void fragment() {
	vec4 source = texture(screen_texture, SCREEN_UV);
	float luminance = dot(source.rgb, vec3(0.2126, 0.7152, 0.0722));
	COLOR = vec4(mix(source.rgb, vec3(luminance), amount), source.a);
}
"""

var _state: Dictionary = DeathState.new_state()
var _combat_log = null
var _grayscale: ColorRect = null
var _grayscale_material: ShaderMaterial = null
var _fade: ColorRect = null
var _death_label: Label = null
var _toast: Label = null
var _respawn_cue: Label = null  # T-554: the "Respawning…" release affordance during the dead hold


func _ready() -> void:
	anchor_left = 0.0
	anchor_top = 0.0
	anchor_right = 1.0
	anchor_bottom = 1.0
	offset_left = 0.0
	offset_top = 0.0
	offset_right = 0.0
	offset_bottom = 0.0
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	z_index = 100

	_grayscale = _full_rect("Grayscale", Color.WHITE)
	var shader := Shader.new()
	shader.code = _GRAYSCALE_SHADER
	_grayscale_material = ShaderMaterial.new()
	_grayscale_material.shader = shader
	_grayscale.material = _grayscale_material
	add_child(_grayscale)

	_fade = _full_rect("RespawnFade", Color(0.0, 0.0, 0.0, 0.0))
	add_child(_fade)

	_death_label = Label.new()
	_death_label.name = "DeathLabel"
	_death_label.text = "You died."
	_death_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_death_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_death_label.add_theme_font_size_override("font_size", 44)
	_death_label.add_theme_color_override("font_color", Color(0.88, 0.88, 0.88))
	_death_label.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 0.96))
	_death_label.add_theme_constant_override("outline_size", 6)
	# Seat the headline directly above the recap panel's top edge (recap top = centre - 260).
	var death_bottom := -(_RECAP_HALF_HEIGHT + _COMPOSE_GAP)
	_center_rect(
		_death_label,
		Vector2(-220.0, death_bottom - _DEATH_LABEL_HEIGHT),
		Vector2(220.0, death_bottom)
	)
	add_child(_death_label)

	_toast = Label.new()
	_toast.name = "DurabilityToast"
	_toast.text = _DURABILITY_TOAST
	_toast.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_toast.add_theme_font_size_override("font_size", 18)
	_toast.add_theme_color_override("font_color", Color(0.72, 0.69, 0.64))
	_toast.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 0.9))
	_toast.add_theme_constant_override("outline_size", 3)
	# Seat the durability toast just below the recap panel's bottom edge (recap bottom = centre + 260).
	var toast_top := _RECAP_HALF_HEIGHT + _COMPOSE_GAP
	_center_rect(_toast, Vector2(-180.0, toast_top), Vector2(180.0, toast_top + _TOAST_HEIGHT))
	add_child(_toast)

	# T-554: the release/respawn affordance. Death runs straight to an auto-respawn after the fade;
	# without a cue the screen was a flash of the headline. This "Respawning…" line, seated below the
	# durability toast, tells the player what is happening; it rides the headline alpha, so it holds
	# through the dead phase and clears the instant begin_respawn() zeroes death_text_alpha.
	_respawn_cue = Label.new()
	_respawn_cue.name = "RespawnCue"
	_respawn_cue.text = _RESPAWN_CUE
	_respawn_cue.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_respawn_cue.add_theme_font_size_override("font_size", 20)
	_respawn_cue.add_theme_color_override("font_color", Color(0.82, 0.80, 0.76))
	_respawn_cue.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 0.9))
	_respawn_cue.add_theme_constant_override("outline_size", 4)
	var cue_top := toast_top + _TOAST_HEIGHT + _COMPOSE_GAP
	_center_rect(_respawn_cue, Vector2(-180.0, cue_top), Vector2(180.0, cue_top + _CUE_HEIGHT))
	add_child(_respawn_cue)
	_render()


func setup(combat_log) -> void:
	_combat_log = combat_log


func begin_death() -> void:
	var was_alive := int(_state.get("phase", DeathState.Phase.ALIVE)) == DeathState.Phase.ALIVE
	_state = DeathState.begin_death(_state)
	if was_alive and _combat_log != null:
		_combat_log.add_entry(_DURABILITY_LINE, Color(0.72, 0.69, 0.64))
	set_process(true)
	_render()


func begin_respawn() -> void:
	_state = DeathState.begin_respawn(_state)
	set_process(true)
	_render()
	# T-522: dismiss the death-only surfaces (the Defeat performance recap) on the local respawn, so
	# they can't linger until the player finds a toggle (playtest #9). This runs only on OUR respawn.
	get_tree().call_group("hide_on_local_respawn", "hide")


func is_input_disabled() -> bool:
	return bool(_state.get("input_disabled", false))


func toast_text() -> String:
	return _toast.text if _toast != null else _DURABILITY_TOAST


func toast_alpha() -> float:
	return float(_state.get("toast_alpha", 0.0))


func _process(delta: float) -> void:
	_state = DeathState.advance(_state, delta)
	_render()
	if int(_state["phase"]) == DeathState.Phase.ALIVE:
		set_process(false)


func _render() -> void:
	if _grayscale == null:
		return
	var grayscale := float(_state.get("grayscale", 0.0))
	_grayscale.visible = int(_state["phase"]) != DeathState.Phase.ALIVE
	_grayscale_material.set_shader_parameter("amount", grayscale)
	_fade.color.a = float(_state.get("fade", 0.0))
	_death_label.modulate.a = float(_state.get("death_text_alpha", 0.0))
	_toast.modulate.a = float(_state.get("toast_alpha", 0.0))
	if _respawn_cue != null:  # T-554: the release cue rides the headline (holds through the dead hold)
		_respawn_cue.modulate.a = float(_state.get("death_text_alpha", 0.0))


func _full_rect(node_name: String, color: Color) -> ColorRect:
	var rect := ColorRect.new()
	rect.name = node_name
	rect.color = color
	rect.anchor_left = 0.0
	rect.anchor_top = 0.0
	rect.anchor_right = 1.0
	rect.anchor_bottom = 1.0
	rect.offset_left = 0.0
	rect.offset_top = 0.0
	rect.offset_right = 0.0
	rect.offset_bottom = 0.0
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return rect


func _center_rect(control: Control, top_left: Vector2, bottom_right: Vector2) -> void:
	control.anchor_left = 0.5
	control.anchor_top = 0.5
	control.anchor_right = 0.5
	control.anchor_bottom = 0.5
	control.offset_left = top_left.x
	control.offset_top = top_left.y
	control.offset_right = bottom_right.x
	control.offset_bottom = bottom_right.y
	control.mouse_filter = Control.MOUSE_FILTER_IGNORE
