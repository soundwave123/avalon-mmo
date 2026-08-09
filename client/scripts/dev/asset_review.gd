extends Node
# T-121: asset-review harness. Loads one GLB (res:// path in AVALON_REVIEW_GLB) into a neutral
# studio and captures it from many angles — front, 3/4, side, back, a LOW angle (to judge the
# base/roots), and a close-up — into AVALON_REVIEW_DIR, then quits. Reliable in-engine rendering
# (Blender headless render is broken here). These shots feed the STRUCTURAL quality rubric
# (docs/knowledge/asset-quality-rubric.md): you judge every side before an asset may PASS.

var _cam: Camera3D = null
var _dir := ""


func _ready() -> void:
	_dir = OS.get_environment("AVALON_REVIEW_DIR")
	if _dir == "":
		_dir = "/tmp/avalon-review"
	DirAccess.make_dir_recursive_absolute(_dir)
	var glb := OS.get_environment("AVALON_REVIEW_GLB")

	var we := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.46, 0.52, 0.58)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.72, 0.72, 0.74)
	env.ambient_light_energy = 1.2
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	we.environment = env
	add_child(we)

	var key := DirectionalLight3D.new()
	key.rotation_degrees = Vector3(-40.0, -35.0, 0.0)
	key.light_energy = 1.7
	key.shadow_enabled = true
	add_child(key)
	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-18.0, 140.0, 0.0)
	fill.light_energy = 0.5
	add_child(fill)

	var ground := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(60.0, 60.0)
	ground.mesh = pm
	var gm := StandardMaterial3D.new()
	gm.albedo_color = Color(0.30, 0.34, 0.30)
	ground.material_override = gm
	add_child(ground)

	var model := (load(glb) as PackedScene).instantiate()
	add_child(model)
	_cam = Camera3D.new()
	_cam.current = true
	add_child(_cam)
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	_run(_aabb(model))


# Merged world-space AABB of every mesh in the loaded model.
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


func _run(box: AABB) -> void:
	var center := box.get_center()
	var reach := maxf(box.size.length() * 0.85, 1.5)
	var eye_y := box.size.y * 0.15
	var shots := {
		"front": Vector3(0.0, eye_y, reach),
		"threeq": Vector3(reach * 0.72, eye_y, reach * 0.72),
		"side": Vector3(reach, eye_y, 0.0),
		"back": Vector3(-reach * 0.6, eye_y, -reach * 0.75),
		"base_low": Vector3(reach * 0.6, -box.size.y * 0.32, reach * 0.6),  # roots/base check
		"closeup": Vector3(reach * 0.45, eye_y, reach * 0.45),  # detail
		# JUNCTION checks — tight shots aimed at where parts JOIN (trunk->branches, wall->roof,
		# limb->body). This is where "shapes plopped on shapes" shows; it must read as one merged
		# form. Two heights so both the upper (canopy/roof) and lower (base/hips) joins are seen.
		"junction_hi": Vector3(reach * 0.42, box.size.y * 0.30, reach * 0.42),
		"junction_lo": Vector3(reach * 0.42, box.size.y * 0.05, reach * 0.42),
	}
	for name in shots:
		_cam.global_position = center + (shots[name] as Vector3)
		var target := center
		if name == "junction_hi":
			target = center + Vector3(0.0, box.size.y * 0.26, 0.0)  # aim at the upper joins
		elif name == "junction_lo":
			target = center + Vector3(0.0, -box.size.y * 0.22, 0.0)  # aim at the base joins
		_cam.look_at(target, Vector3.UP)
		await RenderingServer.frame_post_draw
		await RenderingServer.frame_post_draw
		var img := get_viewport().get_texture().get_image()
		img.save_png(_dir.path_join(name + ".png"))
	print("[asset-review] captured views -> %s" % _dir)
	get_tree().quit(0)
