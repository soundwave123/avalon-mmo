extends Node
# Dev prop showroom (AVALON_SHOWROOM=1): lays the village-prop candidates out in a row at
# believable real-world scale (TRELLIS GLBs come out ~1 m normalized, so each is scaled to a
# target size), each on the ground with a name label, next to a 1.8 m human reference so scale
# reads. Captures an in-engine lineup + a gameplay-distance shot of each into AVALON_REVIEW_DIR,
# then quits — the quick "see them together, in-game" judge surface.

# name -> target real-world longest-dimension in metres (a barrel is ~0.9 m, a stall ~2.6 m).
const PROPS := {
	"prop_market_stall": 2.6,
	"prop_crate": 0.7,
	"prop_barrel": 0.95,
	"prop_sack": 0.6,
	"prop_handcart": 2.2,
	"prop_well_v2": 2.2,
}
# AVALON_SHOWROOM_PROPS (comma-separated names) overrides which props show; default = all below.
const SPACING := 3.2  # metres between prop centres
const ORDER := [
	"prop_market_stall", "prop_crate", "prop_barrel", "prop_sack", "prop_handcart", "prop_well_v2"
]

const MOVE_SPEED := 6.0  # metres/sec free-fly
const LOOK_SENS := 0.003

var _cam: Camera3D = null
var _dir := ""
var _placed: Array = []  # [{name, x, height}] for the per-prop camera passes
var _order: Array = ORDER
var _live := false  # AVALON_SHOWROOM_LIVE=1 -> stay open + walk around instead of capture+quit
var _yaw := 0.0
var _pitch := 0.0


func _ready() -> void:
	_dir = OS.get_environment("AVALON_REVIEW_DIR")
	if _dir == "":
		_dir = "/tmp/avalon-review/showroom"
	DirAccess.make_dir_recursive_absolute(_dir)

	var we := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.55, 0.62, 0.70)  # soft sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.72, 0.74, 0.78)
	env.ambient_light_energy = 1.1
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	we.environment = env
	add_child(we)
	var key := DirectionalLight3D.new()
	key.rotation_degrees = Vector3(-42.0, -40.0, 0.0)
	key.light_energy = 1.6
	key.shadow_enabled = true
	add_child(key)
	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-18.0, 135.0, 0.0)
	fill.light_energy = 0.5
	add_child(fill)

	var ground := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(80.0, 80.0)
	ground.mesh = pm
	var gm := StandardMaterial3D.new()
	gm.albedo_color = Color(0.34, 0.40, 0.32)  # grass-ish
	ground.material_override = gm
	add_child(ground)

	var sel := OS.get_environment("AVALON_SHOWROOM_PROPS")
	if sel != "":
		_order = sel.split(",", false)
	var n := _order.size()
	var x0 := -SPACING * (n - 1) / 2.0
	for i in range(n):
		var name: String = str(_order[i])
		var x := x0 + i * SPACING
		var h: float = await _place_prop(name, x)
		_placed.append({"name": name, "x": x, "height": h})

	_place_human_reference(x0 + n * SPACING)  # a 1.8 m figure at the end for scale

	_cam = Camera3D.new()
	_cam.fov = 68.0
	_cam.current = true
	add_child(_cam)
	await get_tree().process_frame
	await RenderingServer.frame_post_draw

	_live = OS.get_environment("AVALON_SHOWROOM_LIVE") != ""
	if _live:
		# Walk-around mode: start in front of the row, mouse-look + WASD, Esc to close.
		_cam.position = Vector3(0.0, 1.7, SPACING * _order.size() * 0.55)
		Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
		set_process(true)
		print("[showroom] LIVE — WASD/QE move, mouse look, Esc to close")
	else:
		await _capture()


func _unhandled_input(event: InputEvent) -> void:
	if not _live:
		return
	if event is InputEventMouseMotion:
		_yaw -= event.relative.x * LOOK_SENS
		_pitch = clampf(_pitch - event.relative.y * LOOK_SENS, -1.4, 1.4)
		_cam.rotation = Vector3(_pitch, _yaw, 0.0)
	elif event is InputEventKey and event.pressed and event.physical_keycode == KEY_ESCAPE:
		get_tree().quit(0)


func _process(delta: float) -> void:
	if not _live:
		return
	var dir := Vector3.ZERO
	var b := _cam.global_transform.basis
	if Input.is_physical_key_pressed(KEY_W):
		dir -= b.z
	if Input.is_physical_key_pressed(KEY_S):
		dir += b.z
	if Input.is_physical_key_pressed(KEY_A):
		dir -= b.x
	if Input.is_physical_key_pressed(KEY_D):
		dir += b.x
	if Input.is_physical_key_pressed(KEY_E) or Input.is_physical_key_pressed(KEY_SPACE):
		dir += Vector3.UP
	if Input.is_physical_key_pressed(KEY_Q):
		dir += Vector3.DOWN
	if dir != Vector3.ZERO:
		_cam.global_position += dir.normalized() * MOVE_SPEED * delta


# Load one prop GLB, scale it to its target real size, sit it on the ground, label it.
# Returns the placed height (metres) for the camera passes.
func _place_prop(name: String, x: float) -> float:
	var path := "res://assets/models/%s.glb" % name
	if not ResourceLoader.exists(path):
		return 1.0
	var model := (load(path) as PackedScene).instantiate()
	add_child(model)
	await get_tree().process_frame
	var box := _aabb(model)
	var longest := maxf(box.size.x, maxf(box.size.y, box.size.z))
	var scale: float = (float(PROPS.get(name, 1.5)) / longest) if longest > 0.001 else 1.0
	model.scale = Vector3.ONE * scale
	# sit the base on the ground (y=0) after scaling
	model.position = Vector3(x, -box.position.y * scale, 0.0)
	_add_label(name.replace("prop_", ""), Vector3(x, box.size.y * scale + 0.5, 0.0))
	return box.size.y * scale


func _place_human_reference(x: float) -> void:
	var body := MeshInstance3D.new()
	var cap := CapsuleMesh.new()
	cap.height = 1.8
	cap.radius = 0.3
	body.mesh = cap
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.45, 0.5, 0.6)
	body.material_override = m
	body.position = Vector3(x, 0.9, 0.0)
	add_child(body)
	_add_label("~1.8m human", Vector3(x, 2.3, 0.0))


func _add_label(text: String, pos: Vector3) -> void:
	var l := Label3D.new()
	l.text = text
	l.position = pos
	l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	l.font_size = 48
	l.outline_size = 10
	l.pixel_size = 0.004
	l.modulate = Color(1, 1, 0.9)
	add_child(l)


func _aabb(model: Node) -> AABB:
	var box := AABB()
	var first := true
	for node in model.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		var a := mi.global_transform * mi.get_aabb()
		if first:
			box = a
			first = false
		else:
			box = box.merge(a)
	return box


func _capture() -> void:
	var n := _order.size()
	var span := SPACING * n
	# lineup: front + a three-quarter overview of the whole row
	await _shot("lineup_front", Vector3(0.0, 1.9, span * 0.85), Vector3(0.0, 1.0, 0.0))
	await _shot("lineup_threeq", Vector3(span * 0.45, 3.0, span * 0.7), Vector3(0.0, 0.8, 0.0))
	# per-prop gameplay-distance shot (eye height 1.6 m, ~4 m back)
	for p in _placed:
		var x: float = p["x"]
		var h: float = p["height"]
		await _shot(
			str(p["name"]), Vector3(x + 1.4, 1.6, 4.2), Vector3(x, maxf(h * 0.45, 0.4), 0.0)
		)
	print("[showroom] captured -> %s" % _dir)
	get_tree().quit(0)


func _shot(name: String, eye: Vector3, target: Vector3) -> void:
	_cam.global_position = eye
	_cam.look_at(target, Vector3.UP)
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(_dir.path_join(name + ".png"))
