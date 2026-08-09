class_name PaperdollPreview
extends Panel

# T-640: the character window's live 3D paperdoll. A SubViewport holds the player's OWN hero rig
# with the T-224/T-420 worn-armor attach applied via `EntityVisuals.apply_gear` — the EXACT same
# call the world model uses (local_player.gd/entity_visuals.gd) — so the preview can never diverge
# from what everyone else sees you wearing. Idle turntable by default; hold + drag to spin manually.
#
# HEADLESS-SAFE: tests and the pilot run without a display (DisplayServer.get_name() == "headless",
# the established idiom — main.gd/pilot.gd/connection_recovery.gd all gate on it). The whole
# SubViewport/3D subtree is skipped there; this degrades to the ORIGINAL T-422 framed placeholder
# (the same gold-bordered panel + "Character" hint) instead of faking a render.

const IDLE_SPIN_DEG_PER_SEC := 12.0  # slow turntable (WoW reference feel, not a spin-cycle)
const DRAG_DEG_PER_PX := 0.35
# T-421-style first-guess framing: a bust-to-knee 3-quarter view. The hero rigs are real-world scale
# (~1.8 m), same as ARMOR_FIT's own "first-guess, pilot-tuning is a follow-up" caveat.
const _CAM_POS := Vector3(0.0, 1.15, 2.5)
const _CAM_PITCH_DEG := -6.0
const _CAM_FOV := 30.0

var _headless: bool = DisplayServer.get_name() == "headless"
var _viewport: SubViewport = null
var _model_root: Node3D = null  # rotates for the turntable/drag; holds the current Body child
var _dragging: bool = false
var _spin_deg: float = 0.0
var _manual_yaw_deg: float = 0.0
var _char_class: String = ""
var _username: String = ""
var _last_gear: Dictionary = {}  # headless-test-visible even with no real model


func _ready() -> void:
	custom_minimum_size = Vector2(120.0, 168.0)
	mouse_filter = Control.MOUSE_FILTER_STOP  # catches the manual-rotate drag
	add_theme_stylebox_override("panel", _frame_stylebox())
	if _headless:
		_build_placeholder_hint()
		return
	_build_viewport()
	set_process(true)


# T-422 fallback: the original portrait frame's centered hint label, unchanged look.
func _build_placeholder_hint() -> void:
	var hint := Label.new()
	hint.name = "Hint"
	hint.text = "Character"
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	hint.add_theme_color_override("font_color", Color(0.55, 0.51, 0.42, 0.85))
	hint.anchor_right = 1.0
	hint.anchor_bottom = 1.0
	hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(hint)


func _build_viewport() -> void:
	var container := SubViewportContainer.new()
	container.name = "ViewportContainer"
	container.stretch = true
	container.mouse_filter = Control.MOUSE_FILTER_IGNORE  # the Panel above handles drag input
	container.anchor_right = 1.0
	container.anchor_bottom = 1.0
	add_child(container)
	_viewport = SubViewport.new()
	_viewport.name = "Viewport"
	_viewport.size = Vector2i(240, 336)
	_viewport.own_world_3d = true  # isolated scene — never collides with the real world's lighting
	_viewport.transparent_bg = true
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	container.add_child(_viewport)
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.0, 0.0, 0.0, 0.0)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.75, 0.76, 0.80)
	env.ambient_light_energy = 1.2
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	var we := WorldEnvironment.new()
	we.environment = env
	_viewport.add_child(we)
	var key := DirectionalLight3D.new()
	key.rotation_degrees = Vector3(-35.0, -35.0, 0.0)
	key.light_energy = 1.4
	_viewport.add_child(key)
	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-15.0, 150.0, 0.0)
	fill.light_energy = 0.4
	_viewport.add_child(fill)
	var camera := Camera3D.new()
	camera.position = _CAM_POS
	camera.rotation_degrees = Vector3(_CAM_PITCH_DEG, 0.0, 0.0)
	camera.fov = _CAM_FOV
	camera.current = true
	_viewport.add_child(camera)
	_model_root = Node3D.new()
	_model_root.name = "ModelRoot"
	_viewport.add_child(_model_root)


func _process(delta: float) -> void:
	if _model_root == null:
		return
	if not _dragging:
		_spin_deg += IDLE_SPIN_DEG_PER_SEC * delta
	_model_root.rotation_degrees.y = _spin_deg + _manual_yaw_deg


# Drag-to-rotate: press+drag spins the model; the idle turntable resumes from wherever you left it.
func _gui_input(event: InputEvent) -> void:
	if _headless:
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_dragging = true
		elif _dragging:
			_dragging = false
			_spin_deg += _manual_yaw_deg  # fold the manual offset in so release doesn't snap back
			_manual_yaw_deg = 0.0
	elif event is InputEventMouseMotion and _dragging:
		_manual_yaw_deg += event.relative.x * DRAG_DEG_PER_PX


# T-640: fed the SAME positions-broadcast player row (main.gd's `p`, T-225) that drives the world
# model — never a separately-decided visual, so the preview and what everyone else sees can't drift.
# {char_class, gear, username, ...}; unknown/missing keys keep the previous value.
func update_preview(p: Dictionary) -> void:
	_char_class = str(p.get("char_class", _char_class))
	_username = str(p.get("username", _username))
	var gear: Dictionary = p.get("gear", {})
	# T-697 fix 6: Dictionary == compares by value in Godot 4 — no per-broadcast str() stringify.
	var gear_changed := gear != _last_gear
	_last_gear = gear
	if _headless or _model_root == null:
		return  # nothing to render — the placeholder hint stays up
	var kind := _char_class if _char_class != "" else "player"
	if _model_root.get_child_count() == 0 or str(_model_root.get_meta("kind", "")) != kind:
		for c in _model_root.get_children():
			c.queue_free()
		var visual := EntityVisuals.make_visual(kind)
		visual.name = "Body"
		_model_root.add_child(visual)
		_model_root.set_meta("kind", kind)
		gear_changed = true  # a fresh rig always needs its gear (re)applied
	if not gear_changed:
		return
	var body := _model_root.get_node_or_null("Body") as Node3D
	if body == null:
		return
	EntityVisuals.apply_gear(body, gear)
	if _username != "":
		var look := AppearanceResolver.resolve_player(_username)
		EntityVisuals.apply_appearance(body, look["tints"], str(look.get("hair_tex", "")))


func _frame_stylebox() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.08, 0.07, 0.06, 0.85)
	sb.border_color = UiTheme.GOLD
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(4)
	return sb


# ---- headless-test accessors ----


func is_headless() -> bool:
	return _headless


func has_model() -> bool:
	return not _headless and _model_root != null and _model_root.get_child_count() > 0


func get_model_class() -> String:
	return _char_class


func get_last_gear() -> Dictionary:
	return _last_gear
