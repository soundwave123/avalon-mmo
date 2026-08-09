extends Node
# T-343 style-gallery harness (AVALON_VFX_STYLE_GALLERY=1). Renders ONE candidate style for ONE
# hit type on a loop, from a fixed side-on camera at the SHIPPED grade (world_view.gd: AgX,
# exposure 1.15, glow 0.12/0.02) so the owner votes on the honest look. Selection comes from
# AVALON_VFX_STYLE_TYPE (impact|cast|heal|projectile) + AVALON_VFX_STYLE_INDEX. Self-contained: no
# server, no login, no runtime lease (returns before the game boot). Mirrors vfx_gallery.gd's
# honesty rules; runs under Godot movie mode for the clip, else self-captures the strip PNGs.
#
# Every style is cheap: 1-2 pooled one-shot GPUParticles3D + at most one lightweight extra (an
# additive ground ring, a light column, an OmniLight pulse, or a travelling core mesh). No
# per-frame allocation — nodes are built once and repositioned/restarted per cycle.

const CASTER_POS := Vector3.ZERO
const DUMMY_POS := Vector3(7.0, 0.0, 0.0)
const FIRE_AT := 0.15
const SETTLE := 0.75

var _dir := ""
var _type := "impact"
var _index := 0
var _movie := false
var _style: Dictionary = {}
var _caster: Node3D = null
var _dummy: Node3D = null
var _cam: Camera3D = null
var _emitters: Array[GPUParticles3D] = []
var _ring: MeshInstance3D = null
var _column: MeshInstance3D = null
var _light: OmniLight3D = null
var _orb: MeshInstance3D = null  # projectile core
var _anchor := Vector3.ZERO
var _speed := 22.0
var _travel_dur := 0.4
var _cycle := 1.6
var _t := 0.0
var _fired := false
var _strip := {}  # phase -> Image


func _ready() -> void:
	_type = VfxStyles.active_type()
	_index = VfxStyles.active_index()
	_style = VfxStyles.resolve(_type, _index)
	_movie = OS.has_feature("movie")
	_dir = OS.get_environment("AVALON_REVIEW_DIR")
	if _dir == "":
		_dir = "/tmp/avalon-review/t343-gallery"
	DirAccess.make_dir_recursive_absolute(_dir)
	DisplayServer.window_set_title(
		"VFX Styles — %s #%d: %s" % [_type, _index, VfxStyles.name_of(_type, _index)]
	)
	Engine.max_fps = 60
	_build_stage()
	_build_style()
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	await _capture()


func _build_stage() -> void:
	var we := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.30, 0.40, 0.52)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.55, 0.60, 0.70)
	env.ambient_light_energy = 0.9
	env.tonemap_mode = Environment.TONE_MAPPER_AGX  # SHIPPED grade — vote on what ships
	env.tonemap_exposure = 1.15
	env.glow_enabled = true
	env.glow_intensity = 0.12
	env.glow_bloom = 0.02
	we.environment = env
	add_child(we)
	var key := DirectionalLight3D.new()
	key.rotation_degrees = Vector3(-42.0, -40.0, 0.0)
	key.light_energy = 1.4
	key.shadow_enabled = true
	add_child(key)
	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-18.0, 135.0, 0.0)
	fill.light_energy = 0.4
	add_child(fill)
	var ground := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(60.0, 60.0)
	ground.mesh = pm
	var gm := StandardMaterial3D.new()
	gm.albedo_color = Color(0.26, 0.30, 0.26)
	ground.material_override = gm
	ground.position = Vector3(3.5, 0.0, 0.0)
	add_child(ground)
	_caster = EntityVisuals.make_visual("mage")
	_caster.position = CASTER_POS
	_caster.rotation.y = -PI / 2.0
	add_child(_caster)
	_dummy = EntityVisuals.make_visual("mob_dummy")
	_dummy.position = DUMMY_POS
	_dummy.rotation.y = PI / 2.0
	add_child(_dummy)
	_cam = Camera3D.new()
	_cam.fov = 52.0
	_cam.current = true
	add_child(_cam)
	# impact/heal/projectile read best framed on the target; a pure cast frames on the caster
	var focus := 4.5 if _type != "cast" else 1.6
	_cam.look_at_from_position(Vector3(focus, 1.7, 9.6), Vector3(focus, 1.2, 0.0), Vector3.UP)


func _build_style() -> void:
	# Where the effect plays: cast at the caster's hand, everything else on the target.
	match _type:
		"cast":
			_anchor = CASTER_POS + Vector3(0.35, 1.1, 0.0)
		"heal":
			_anchor = DUMMY_POS + Vector3(0.0, 0.6, 0.0)
		"projectile":
			_anchor = CASTER_POS + Vector3(0.0, 1.2, 0.0)
		_:
			_anchor = DUMMY_POS + Vector3(0.0, 1.1, 0.0)
	for cfg in _style.get("emitters", []):
		_emitters.append(_make_emitter(cfg))
	if _style.has("ring"):
		_ring = _make_disc(_style["ring"])
	if _style.has("column"):
		_column = _make_column(_style["column"])
	if _style.has("light"):
		var l: Dictionary = _style["light"]
		_light = OmniLight3D.new()
		_light.light_color = l["color"]
		_light.light_energy = 0.0
		_light.omni_range = float(l.get("range", 4.0))
		_light.shadow_enabled = false
		add_child(_light)
	if _type == "projectile":
		_speed = float(_style.get("speed", 22.0))
		_travel_dur = clampf(CASTER_POS.distance_to(DUMMY_POS) / _speed, 0.12, 0.6)
		if _style.has("core"):
			_orb = _make_orb(_style["core"])
	_cycle = FIRE_AT + (_travel_dur if _type == "projectile" else 0.0) + SETTLE + 0.4


func _make_emitter(cfg: Dictionary) -> GPUParticles3D:
	var p := GPUParticles3D.new()
	p.one_shot = true
	p.explosiveness = 1.0
	p.emitting = false
	p.lifetime = float(cfg.get("life", 0.5))
	p.amount = maxi(1, int(cfg.get("amount", 20)))
	p.local_coords = _type != "projectile"  # projectile trail lives in world space behind the orb
	p.draw_pass_1 = _quad(float(cfg["size"]), cfg["color"], float(cfg["energy"]))
	p.visibility_aabb = AABB(Vector3(-40, -10, -40), Vector3(80, 40, 80))
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var m := ParticleProcessMaterial.new()
	m.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	m.emission_sphere_radius = float(cfg["emis_r"])
	m.direction = cfg["dir"]
	m.spread = float(cfg["spread"])
	m.initial_velocity_min = float(cfg["vmin"])
	m.initial_velocity_max = float(cfg["vmax"])
	m.gravity = cfg["grav"]
	m.scale_min = float(cfg["smin"])
	m.scale_max = float(cfg["smax"])
	m.color_ramp = _ramp(cfg["ramp"][0], cfg["ramp"][1])
	p.process_material = m
	add_child(p)
	return p


func _quad(size: float, color: Color, energy: float) -> QuadMesh:
	var q := QuadMesh.new()
	q.size = Vector2(size, size)
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	m.billboard_keep_scale = true
	m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	m.vertex_color_use_as_albedo = true
	m.albedo_color = color
	m.emission_enabled = true
	m.emission = Color(color.r, color.g, color.b)
	m.emission_energy_multiplier = energy
	q.material = m
	return q


func _make_disc(cfg: Dictionary) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 1.0
	cyl.bottom_radius = 1.0
	cyl.height = 0.04
	cyl.radial_segments = 40
	mi.mesh = cyl
	mi.material_override = _additive_mat(cfg["color"], float(cfg["energy"]))
	mi.visible = false
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
	return mi


func _make_column(cfg: Dictionary) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = float(cfg["radius"]) * 0.7
	cyl.bottom_radius = float(cfg["radius"])
	cyl.height = float(cfg["height"])
	cyl.radial_segments = 24
	mi.mesh = cyl
	mi.material_override = _additive_mat(cfg["color"], float(cfg["energy"]))
	mi.visible = false
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
	return mi


func _make_orb(cfg: Dictionary) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = float(cfg["radius"])
	sm.height = float(cfg["radius"]) * 2.0
	sm.radial_segments = 8
	sm.rings = 5
	mi.mesh = sm
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = cfg["color"]
	m.emission_enabled = true
	m.emission = cfg["color"]
	m.emission_energy_multiplier = float(cfg["energy"])
	mi.material_override = m
	mi.visible = false
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
	if not _emitters.is_empty():  # parent the trail to the orb so it streams in world space
		var tr := _emitters[0]
		if tr.get_parent() != null:
			tr.reparent(mi)
		else:
			mi.add_child(tr)
	return mi


func _additive_mat(color: Color, energy: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.albedo_color = color
	m.emission_enabled = true
	m.emission = Color(color.r, color.g, color.b)
	m.emission_energy_multiplier = energy
	return m


func _ramp(a: Color, b: Color) -> GradientTexture1D:
	var g := Gradient.new()
	g.set_offsets(PackedFloat32Array([0.0, 1.0]))
	g.set_colors(PackedColorArray([a, b]))
	var t := GradientTexture1D.new()
	t.gradient = g
	return t


func _fire() -> void:
	for p in _emitters:
		if _type != "projectile":
			p.global_position = _anchor
		p.restart()
	if _ring != null:
		_ring.global_position = Vector3(_anchor.x, 0.03, _anchor.z)
		_ring.visible = true
	if _column != null:
		_column.global_position = Vector3(
			_anchor.x, float(_style["column"]["height"]) * 0.5, _anchor.z
		)
		_column.visible = true
	if _light != null:
		_light.global_position = _anchor
	if _orb != null:
		_orb.global_position = _anchor
		_orb.visible = true


func _process(delta: float) -> void:
	_t += delta
	if not _fired and _t >= FIRE_AT:
		_fired = true
		if _type == "cast":
			EntityVisuals.play_state(_caster, "cast")
		elif _type == "projectile":
			EntityVisuals.play_state(_caster, "attack")
		_fire()
	if _fired:
		_animate(_t - FIRE_AT)
	if _t >= _cycle:
		_t = 0.0
		_fired = false
		if _orb != null:
			_orb.visible = false
		if _ring != null:
			_ring.visible = false
		if _column != null:
			_column.visible = false


# Drive the lightweight extras off elapsed-since-fire (deterministic under fixed-dt movie mode).
func _animate(e: float) -> void:
	if _ring != null:
		var life := float(_style["ring"]["life"])
		var p := clampf(e / life, 0.0, 1.0)
		var r := lerpf(0.2, float(_style["ring"]["radius"]), p)
		_ring.scale = Vector3(r, 1.0, r)
		_set_alpha(
			_ring,
			(
				(1.0 - p)
				* float(_style["ring"]["color"].a if _style["ring"]["color"] is Color else 1.0)
			)
		)
	if _column != null:
		var clife := float(_style["column"]["life"])
		var cp := clampf(e / clife, 0.0, 1.0)
		var a := sin(cp * PI)  # rise then fall
		_set_alpha(_column, a * float((_style["column"]["color"] as Color).a))
	if _light != null:
		var llife := float(_style["light"]["life"])
		var lp := clampf(e / llife, 0.0, 1.0)
		_light.light_energy = (1.0 - lp) * float(_style["light"]["energy"])
	if _orb != null and _type == "projectile":
		var tp := clampf(e / _travel_dur, 0.0, 1.0)
		_orb.global_position = _anchor.lerp(DUMMY_POS + Vector3(0.0, 1.1, 0.0), tp)
		if tp >= 1.0:
			_orb.visible = false
			for pr in _emitters:
				pr.emitting = false


func _set_alpha(mi: MeshInstance3D, a: float) -> void:
	var m: StandardMaterial3D = mi.material_override
	if m != null:
		m.albedo_color.a = clampf(a, 0.0, 1.0)


func _capture() -> void:
	var launch := FIRE_AT
	var t_a := launch + 0.05
	var t_b := launch + (_travel_dur * 0.5 if _type == "projectile" else 0.26)
	var t_c := launch + (_travel_dur + 0.12 if _type == "projectile" else 0.68)
	var frames := 120
	var env_frames := OS.get_environment("AVALON_VFX_FRAMES")
	if env_frames.is_valid_int():
		frames = clampi(int(env_frames), 24, 240)
	for i in range(frames):
		await RenderingServer.frame_post_draw
		if not _strip.has("a") and _t >= t_a and _t < t_b:
			_strip["a"] = _shot()
		elif not _strip.has("b") and _t >= t_b and _t < t_c:
			_strip["b"] = _shot()
		elif not _strip.has("c") and _t >= t_c:
			_strip["c"] = _shot()
	for phase in ["a", "b", "c"]:
		if _strip.has(phase):
			(_strip[phase] as Image).save_png(
				_dir.path_join("style_%s_%d_%s.png" % [_type, _index, phase])
			)
	print(
		(
			"[vfx-style-gallery] %s #%d (%s): %d frames movie=%s -> %s"
			% [_type, _index, VfxStyles.style_id(_type, _index), frames, str(_movie), _dir]
		)
	)
	get_tree().quit(0)


func _shot() -> Image:
	var img: Image = get_viewport().get_texture().get_image()
	if img.get_width() > 720:
		img.resize(720, int(720.0 * img.get_height() / img.get_width()), Image.INTERPOLATE_BILINEAR)
	return img
