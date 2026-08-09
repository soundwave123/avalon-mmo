class_name FrostLanceVfx
extends Node3D

# T-343 round 2: the Sub-Zero frost-lance VFX family (preset mode "lance"). Owner verdict on
# round 1 killed the ball paradigm — this module renders the three-stage power language:
#   1. CAST ANTICIPATION — a coiling hand-frost aura + cold vapor pouring off + a frost-creep
#      disc growing at the caster's feet (streaming emitters, run for the buildup window).
#   2. FLIGHT — a fast elongated crystalline lance: REAL SurfaceTool shard meshes (the
#      grass-blade runtime-mesh idiom, world_view.gd precedent), white-hot inner spear inside a
#      deep-blue jagged sheath, roll spin, a violent world-space vapor stream + glint sparkle.
#   3. IMPACT WITH CONSEQUENCES — a hard white flash frame (light pulse + additive quad), a
#      radial explosion of MESH shards (GPUParticles3D draw_pass_1 crystals), an expanding
#      ground frost ring, and the victim FLASH-FREEZING for ~0.5s via material_overlay (the
#      T-290 moss pattern, world_props_layer.gd — overlay second pass, tangent-less skipped).
# Everything is pooled at build time and repositioned/restarted per event (T-210: no per-frame
# allocation); _process runs ONLY while a lance is in flight (roll spin).

var _antic: Array = []  # [{aura, vapor, creep, tween}]
var _lances: Array = []  # [{root, mesh, trail, glint}]
var _impacts: Array = []  # [{flash, light, shards, ring, vapor}]
var _ai := 0
var _li := 0
var _ii := 0
var _flying := 0
var _p: Dictionary = {}


func setup(preset: Dictionary) -> void:
	_p = preset
	var antic: Dictionary = _p["antic"]
	var lance: Dictionary = _p["lance"]
	var burst: Dictionary = _p["burst"]
	for i in range(2):
		_antic.append(_make_antic(antic))
	for i in range(4):
		_lances.append(_make_lance(lance, i))
	for i in range(4):
		_impacts.append(_make_impact(burst, i))
	set_process(false)


func _process(delta: float) -> void:
	var spin: float = float((_p["lance"] as Dictionary)["spin"])
	for l in _lances:
		var root: Node3D = l["root"]
		if root.visible:
			root.rotate_object_local(Vector3(0, 0, 1), spin * delta)


# --- stage 1: cast anticipation ---------------------------------------------------------------
func begin_cast(pos: Vector3) -> void:
	var antic: Dictionary = _p["antic"]
	var kit: Dictionary = _antic[_ai]
	_ai = (_ai + 1) % _antic.size()
	var buildup: float = float(antic["buildup"])
	var aura: GPUParticles3D = kit["aura"]
	var vapor: GPUParticles3D = kit["vapor"]
	var creep: MeshInstance3D = kit["creep"]
	aura.global_position = pos + Vector3(0.0, 1.15, 0.0)
	vapor.global_position = pos + Vector3(0.0, 1.0, 0.0)
	creep.global_position = pos + Vector3(0.0, 0.04, 0.0)
	aura.emitting = true
	vapor.emitting = true
	creep.visible = true
	creep.scale = Vector3.ONE * 0.05
	creep.transparency = 0.0
	var tw := create_tween()
	tw.set_parallel(false)
	tw.tween_property(creep, "scale", Vector3.ONE, buildup * 0.8)
	tw.tween_property(creep, "transparency", 1.0, buildup * 0.6)
	tw.tween_callback(
		func():
			aura.emitting = false
			vapor.emitting = false
			creep.visible = false
	)


# --- stage 2: the lance ------------------------------------------------------------------------
func launch(from: Vector3, to: Vector3) -> void:
	var lance: Dictionary = _lances[_li]
	_li = (_li + 1) % _lances.size()
	var root: Node3D = lance["root"]
	var trail: GPUParticles3D = lance["trail"]
	var glint: GPUParticles3D = lance["glint"]
	var src := from + Vector3(0.0, 1.35, 0.0)
	var dst := to + Vector3(0.0, 1.15, 0.0)
	root.global_position = src
	root.look_at(dst, Vector3.UP)
	root.visible = true
	trail.emitting = true
	glint.emitting = true
	# lay the hanging vapor line along the full path
	var streak: GPUParticles3D = lance["streak"]
	streak.global_position = (src + dst) * 0.5
	streak.look_at(dst, Vector3.UP)
	var sp := streak.process_material as ParticleProcessMaterial
	sp.emission_box_extents = Vector3(0.15, 0.15, src.distance_to(dst) * 0.5)
	streak.restart()
	_flying += 1
	set_process(true)
	var speed: float = float((_p["flight"] as Dictionary)["speed"])
	var dur := clampf(src.distance_to(dst) / speed, 0.08, 0.6)
	var tw := create_tween()
	tw.tween_property(root, "global_position", dst, dur)
	tw.tween_callback(
		func():
			root.visible = false
			trail.emitting = false
			glint.emitting = false
			_flying = maxi(0, _flying - 1)
			if _flying == 0:
				set_process(false)
	)


# --- stage 3: impact with consequences ---------------------------------------------------------
# `pos` = the victim's base position (same convention as VfxManager.spawn_impact); `target` is
# the victim's visual root for the flash-freeze overlay (null = no freeze, e.g. missed lookup).
func impact(pos: Vector3, target: Node3D = null) -> void:
	var burst: Dictionary = _p["burst"]
	var kit: Dictionary = _impacts[_ii]
	_ii = (_ii + 1) % _impacts.size()
	var flash: MeshInstance3D = kit["flash"]
	var light: OmniLight3D = kit["light"]
	var shards: GPUParticles3D = kit["shards"]
	var ring: MeshInstance3D = kit["ring"]
	var vapor: GPUParticles3D = kit["vapor"]
	var hit := pos + Vector3(0.0, 1.15, 0.0)
	shards.global_position = hit
	vapor.global_position = hit
	flash.global_position = hit
	light.global_position = hit + Vector3(0.0, 0.4, 0.0)
	ring.global_position = pos + Vector3(0.0, 0.05, 0.0)
	shards.restart()
	vapor.restart()
	# hard white flash frame: 2-3 frames of a big additive quad + a light pulse
	flash.visible = true
	flash.transparency = 0.0
	flash.scale = Vector3.ONE
	light.light_energy = float(burst["flash_energy"])
	var tw := create_tween()
	tw.set_parallel(true)
	tw.tween_property(flash, "transparency", 1.0, 0.12)
	tw.tween_property(flash, "scale", Vector3.ONE * 1.6, 0.12)
	tw.tween_property(light, "light_energy", 0.0, 0.18)
	tw.chain().tween_callback(func(): flash.visible = false)
	# T-343 r3: the TARGET-side ground ring is drastically reduced. Round-2 owner note — the big
	# expanding disc under the victim read as a generic decal "stamped under every enemy", the same
	# frost circle the caster gets. It is now a small, brief contact scuff (≤0.35s, ~0.35 of its
	# radius) so ground contact still registers but the CONSEQUENCE moves onto the victim's BODY
	# (flash_freeze). The caster-side creep (begin_cast) is untouched — that beat is anticipation.
	var ring_life := minf(float(burst["ring_life"]), 0.35)
	ring.visible = true
	ring.transparency = 0.0
	ring.scale = Vector3.ONE * 0.12
	var rtw := create_tween()
	rtw.set_parallel(true)
	rtw.tween_property(ring, "scale", Vector3.ONE * 0.35, ring_life)
	rtw.tween_property(ring, "transparency", 1.0, ring_life)
	rtw.chain().tween_callback(func(): ring.visible = false)
	if target != null:
		flash_freeze(target, burst)


# The victim flash-freezes: an icy-blue glaze drawn as a second pass over every mesh
# (material_overlay, the T-290 moss pattern — the base look is never modified). T-343 r3 makes
# this the STAR consequence (owner: "the enemy should look slightly blue from being hit"):
#   - a bright freeze SNAP for ~0.15s (the hit lands), easing down to
#   - a held, tasteful blue body TINT that fades out over ~1.5s (up from a flat 0.5s pop).
# CRITICAL FIX vs r2: the overlay uses BLEND_MODE_MIX, not ADD. Adding blue to a near-white body
# only washes it brighter (channels clamp at white) — it never reads BLUE, which was exactly the
# round-2 defect. MIX composites the blue over the body so the enemy actually shifts blue. A low
# icy emission rides on top for a frozen sheen (kept dim so it does not re-whitewash the tint);
# UNSHADED so the tint reads uniformly even on the shadow side. Tangent-less surfaces are skipped
# (godotengine/godot#106276 per-frame warning).
func flash_freeze(target: Node3D, burst: Dictionary) -> void:
	var fc: Color = burst["freeze_color"]
	var tint := Color(fc.r * 0.7, fc.g * 0.82, fc.b)  # push saturated so MIX reads clearly blue
	var base_e: float = float(burst["freeze_energy"])
	var dur := maxf(float(burst["freeze_dur"]), 1.5)  # eased body tint, not a 0.5s flat pop
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_MIX
	mat.albedo_color = Color(tint.r, tint.g, tint.b, 0.72)  # start on the bright SNAP
	mat.emission_enabled = true
	mat.emission = Color(fc.r, fc.g, fc.b)  # dim icy sheen; kept blue, not white
	mat.emission_energy_multiplier = base_e * 0.5
	var frozen: Array = []
	for child in target.find_children("*", "MeshInstance3D", true, false):
		var mi := child as MeshInstance3D
		if mi.mesh == null or _tangentless(mi.mesh):
			continue
		mi.material_overlay = mat
		frozen.append(mi)
	# SNAP (bright freeze frame) -> settle to a held tint -> long eased fade-out.
	var tw := create_tween()
	tw.tween_property(mat, "albedo_color", Color(tint.r, tint.g, tint.b, 0.55), 0.15)
	tw.parallel().tween_property(mat, "emission_energy_multiplier", base_e * 0.25, 0.15)
	# EASE_IN: hold the blue tint through the freeze, then fall away in the last ~third — a slow
	# early departure keeps the enemy visibly blue for most of the ~1.5s instead of a quick decay.
	(
		tw
		. chain()
		. tween_property(mat, "albedo_color", Color(tint.r, tint.g, tint.b, 0.0), dur)
		. set_ease(Tween.EASE_IN)
		. set_trans(Tween.TRANS_CUBIC)
	)
	tw.parallel().tween_property(mat, "emission_energy_multiplier", 0.0, dur).set_ease(
		Tween.EASE_IN
	)
	tw.chain().tween_callback(
		func():
			for mi in frozen:
				if is_instance_valid(mi) and mi.material_overlay == mat:
					mi.material_overlay = null
	)


static func _tangentless(mesh: Mesh) -> bool:
	for s in mesh.get_surface_count():
		var arrays: Array = mesh.surface_get_arrays(s)
		if arrays.size() > Mesh.ARRAY_TANGENT and arrays[Mesh.ARRAY_TANGENT] == null:
			return true
	return false


# --- builders: anticipation --------------------------------------------------------------------
func _make_antic(antic: Dictionary) -> Dictionary:
	# coiling hand aura: orbiting particles rising off the cast hands
	var aura := GPUParticles3D.new()
	aura.amount = int(antic["aura_amount"])
	aura.lifetime = 0.7
	aura.emitting = false
	aura.local_coords = false
	aura.draw_pass_1 = FrostLanceLib.quad(0.14, antic["aura_core"], float(antic["aura_energy"]))
	var ap := ParticleProcessMaterial.new()
	ap.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_RING
	ap.emission_ring_radius = 0.32
	ap.emission_ring_inner_radius = 0.18
	ap.emission_ring_height = 0.25
	ap.emission_ring_axis = Vector3(0, 1, 0)
	ap.orbit_velocity_min = 0.9  # the COIL — particles spiral around the hands
	ap.orbit_velocity_max = 1.6
	ap.direction = Vector3(0, 1, 0)
	ap.spread = 12.0
	ap.initial_velocity_min = 0.3
	ap.initial_velocity_max = 0.8
	ap.gravity = Vector3(0, 0.9, 0)
	ap.scale_min = 0.5
	ap.scale_max = 1.2
	ap.color_ramp = FrostLanceLib.ramp2(antic["aura_core"], antic["aura_color"])
	aura.process_material = ap
	aura.visibility_aabb = AABB(Vector3(-3, -3, -3), Vector3(6, 6, 6))
	add_child(aura)
	# cold vapor pouring DOWN off the hands (dense, soft, sinking — liquid-nitrogen read)
	var vapor := GPUParticles3D.new()
	vapor.amount = int(antic["vapor_amount"])
	vapor.lifetime = 1.0
	vapor.emitting = false
	vapor.local_coords = false
	vapor.draw_pass_1 = FrostLanceLib.quad(0.4, antic["vapor_color"], 1.1)
	var vp := ParticleProcessMaterial.new()
	vp.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	vp.emission_sphere_radius = 0.3
	vp.direction = Vector3(0, -1, 0)
	vp.spread = 30.0
	vp.initial_velocity_min = 0.4
	vp.initial_velocity_max = 0.9
	vp.gravity = Vector3(0, -0.8, 0)
	vp.scale_min = 0.8
	vp.scale_max = 1.8
	var vc: Color = antic["vapor_color"]
	vp.color_ramp = FrostLanceLib.ramp(Color(vc.r, vc.g, vc.b, 0.4), Color(vc.r, vc.g, vc.b, 0.0))
	vapor.process_material = vp
	vapor.visibility_aabb = AABB(Vector3(-3, -3, -3), Vector3(6, 6, 6))
	add_child(vapor)
	# frost creeping across the ground at the caster's feet
	var creep := MeshInstance3D.new()
	creep.mesh = FrostLanceLib.disc_mesh(float(antic["creep_radius"]), 28)
	creep.material_override = FrostLanceLib.radial_mat(
		antic["creep_color"], float(antic["creep_energy"])
	)
	creep.visible = false
	creep.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(creep)
	return {"aura": aura, "vapor": vapor, "creep": creep}


# --- builders: the lance -----------------------------------------------------------------------
func _make_lance(lance: Dictionary, index: int) -> Dictionary:
	var root := Node3D.new()
	root.visible = false
	add_child(root)
	var mesh := MeshInstance3D.new()
	mesh.mesh = _lance_mesh(lance, index)
	mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(mesh)
	# violent trailing vapor stream (world-space so it hangs in the air behind the lance)
	var trail := GPUParticles3D.new()
	trail.amount = int(lance["trail_amount"])
	trail.lifetime = float(lance["trail_life"])
	trail.local_coords = false
	trail.emitting = false
	trail.draw_pass_1 = FrostLanceLib.quad(float(lance["trail_size"]), lance["trail_color"], 1.6)
	var tp := ParticleProcessMaterial.new()
	tp.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	tp.emission_sphere_radius = 0.12
	tp.initial_velocity_min = 0.2
	tp.initial_velocity_max = 1.0
	tp.spread = 180.0
	tp.gravity = Vector3(0, -0.3, 0)
	tp.scale_min = 0.6
	tp.scale_max = 1.6
	var tc: Color = lance["trail_color"]
	tp.color_ramp = FrostLanceLib.ramp(Color(1.0, 1.0, 1.0, 0.85), Color(tc.r, tc.g, tc.b, 0.0))
	trail.process_material = tp
	trail.visibility_aabb = AABB(Vector3(-50, -20, -50), Vector3(100, 40, 100))
	root.add_child(trail)
	# glint sparkle — tiny white-hot points, the refraction read
	var glint := GPUParticles3D.new()
	glint.amount = int(lance["glint_amount"])
	glint.lifetime = 0.22
	glint.local_coords = false
	glint.emitting = false
	glint.draw_pass_1 = FrostLanceLib.quad(0.07, Color(1, 1, 1), float(lance["glint_energy"]))
	var gp := ParticleProcessMaterial.new()
	gp.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	gp.emission_box_extents = Vector3(0.2, 0.2, float(lance["length"]) * 0.45)
	gp.initial_velocity_min = 0.0
	gp.initial_velocity_max = 0.4
	gp.gravity = Vector3.ZERO
	gp.scale_min = 0.4
	gp.scale_max = 1.0
	gp.color_ramp = FrostLanceLib.ramp(Color(1, 1, 1, 1), Color(0.8, 0.95, 1.0, 0.0))
	glint.process_material = gp
	glint.visibility_aabb = AABB(Vector3(-50, -20, -50), Vector3(100, 40, 100))
	root.add_child(glint)
	# path streak: a one-shot vapor LINE laid along the whole flight path at launch. A moving
	# emitter alone clumps particles at 2-3 discrete frame positions at lance speeds (24fps x
	# 45+ u/s), so the continuous jet line is emitted instantly and left hanging to fade.
	var streak := GPUParticles3D.new()
	streak.amount = int(lance["trail_amount"])
	streak.lifetime = maxf(float(lance["trail_life"]), 0.45)
	streak.one_shot = true
	streak.explosiveness = 1.0
	streak.emitting = false
	streak.local_coords = false
	streak.draw_pass_1 = FrostLanceLib.quad(
		float(lance["trail_size"]) * 0.8, lance["trail_color"], 1.4
	)
	var sp := ParticleProcessMaterial.new()
	sp.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	sp.emission_box_extents = Vector3(0.15, 0.15, 3.5)  # re-stretched per launch
	sp.initial_velocity_min = 0.1
	sp.initial_velocity_max = 0.6
	sp.spread = 180.0
	sp.gravity = Vector3(0, -0.2, 0)
	sp.scale_min = 0.5
	sp.scale_max = 1.3
	var stc: Color = lance["trail_color"]
	sp.color_ramp = FrostLanceLib.ramp(Color(1.0, 1.0, 1.0, 0.8), Color(stc.r, stc.g, stc.b, 0.0))
	streak.process_material = sp
	streak.visibility_aabb = AABB(Vector3(-50, -20, -50), Vector3(100, 40, 100))
	add_child(streak)  # NOT under root — it must stay put while the lance flies on
	return {"root": root, "mesh": mesh, "trail": trail, "glint": glint, "streak": streak}


# The lance body: surface 0 = white-hot inner spear, surface 1 = deep-blue jagged crystal sheath
# (satellite shards). Real geometry, faceted crystal normals — never a billboard.
func _lance_mesh(lance: Dictionary, index: int) -> ArrayMesh:
	var rng := RandomNumberGenerator.new()
	rng.seed = 3430 + index  # varied silhouettes across the pool, stable across rebuilds
	var length: float = float(lance["length"])
	var girth: float = float(lance["girth"])
	var mesh := ArrayMesh.new()
	# inner spear: one long spike along -Z (Godot forward), tip 65% ahead of the tail
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_smooth_group(-1)  # flat faceted shading — the crystal read
	FrostLanceLib.add_spike(st, Vector3.ZERO, length, girth * 0.55, 0.65, rng)
	st.generate_normals()
	st.commit(mesh)
	mesh.surface_set_material(
		0, FrostLanceLib.ice_mat(lance["core_color"], float(lance["energy"]), 1.0)
	)
	# sheath: jagged satellite shards ringing the spear, tilted into the flight direction
	var st2 := SurfaceTool.new()
	st2.begin(Mesh.PRIMITIVE_TRIANGLES)
	st2.set_smooth_group(-1)
	var shards := int(lance["shards"])
	var spread: float = float(lance["spread"])
	for k in range(shards):
		var a := float(k) * TAU / float(shards) + rng.randf_range(-0.25, 0.25)
		var r := spread * rng.randf_range(0.75, 1.25)
		var center := Vector3(cos(a) * r, sin(a) * r, rng.randf_range(-0.15, 0.3) * length)
		var slen := length * rng.randf_range(0.3, 0.55)
		FrostLanceLib.add_spike(st2, center, slen, girth * rng.randf_range(0.3, 0.5), 0.6, rng)
	st2.generate_normals()
	st2.commit(mesh)
	mesh.surface_set_material(
		1, FrostLanceLib.ice_mat(lance["edge_color"], float(lance["energy"]) * 0.45, 0.8)
	)
	return mesh


# One elongated crystal spike along -Z: front apex + jittered mid ring + back apex (octahedral,
# 8 faces). `tip_frac` = how far ahead of the ring the front tip sits (0..1 of len).
func _make_impact(burst: Dictionary, index: int) -> Dictionary:
	var flash := MeshInstance3D.new()
	var fq := QuadMesh.new()
	fq.size = Vector2(float(burst["flash_size"]), float(burst["flash_size"]))
	var fm := StandardMaterial3D.new()
	fm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	fm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	fm.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	fm.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	fm.albedo_texture = FrostLanceLib.soft_tex()  # radial burst, not a hard white rectangle
	fm.albedo_color = Color(1, 1, 1, 0.95)
	fm.emission_enabled = true
	fm.emission = Color(1, 1, 1)
	fm.emission_energy_multiplier = 5.0
	fq.material = fm
	flash.mesh = fq
	flash.visible = false
	flash.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(flash)
	var light := OmniLight3D.new()
	light.light_color = burst["freeze_color"]
	light.light_energy = 0.0
	light.omni_range = 9.0
	light.shadow_enabled = false
	add_child(light)
	# radial explosion of REAL crystal shards (mesh draw pass, not billboards)
	var shards := GPUParticles3D.new()
	shards.amount = int(burst["shard_amount"])
	shards.lifetime = 0.75
	shards.one_shot = true
	shards.explosiveness = 1.0
	shards.emitting = false
	shards.draw_pass_1 = _shard_mesh(burst, index)
	var sp := ParticleProcessMaterial.new()
	sp.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	sp.emission_sphere_radius = 0.2
	sp.spread = 180.0
	sp.initial_velocity_min = float(burst["vmin"])
	sp.initial_velocity_max = float(burst["vmax"])
	sp.gravity = Vector3(0, -9.0, 0)
	sp.angular_velocity_min = -360.0
	sp.angular_velocity_max = 360.0
	sp.scale_min = 0.5
	sp.scale_max = 1.3
	var sc: Color = burst["shard_color"]
	sp.color_ramp = FrostLanceLib.ramp(Color(1, 1, 1, 1), Color(sc.r, sc.g, sc.b, 0.0))
	shards.process_material = sp
	shards.visibility_aabb = AABB(Vector3(-8, -8, -8), Vector3(16, 16, 16))
	shards.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(shards)
	# ground frost ring
	var ring := MeshInstance3D.new()
	ring.mesh = FrostLanceLib.disc_mesh(float(burst["ring_radius"]), 32)
	ring.material_override = FrostLanceLib.radial_mat(
		burst["ring_color"], float(burst["ring_energy"])
	)
	ring.visible = false
	ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(ring)
	# cold vapor puff hanging at the impact point
	var vapor := GPUParticles3D.new()
	vapor.amount = int(burst["vapor_amount"])
	vapor.lifetime = 0.9
	vapor.one_shot = true
	vapor.explosiveness = 1.0
	vapor.emitting = false
	vapor.draw_pass_1 = FrostLanceLib.quad(0.5, burst["freeze_color"], 1.2)
	var vp := ParticleProcessMaterial.new()
	vp.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	vp.emission_sphere_radius = 0.35
	vp.spread = 180.0
	vp.initial_velocity_min = 0.6
	vp.initial_velocity_max = 2.0
	vp.gravity = Vector3(0, 0.4, 0)
	vp.scale_min = 1.0
	vp.scale_max = 2.2
	var fc: Color = burst["freeze_color"]
	vp.color_ramp = FrostLanceLib.ramp(Color(fc.r, fc.g, fc.b, 0.45), Color(fc.r, fc.g, fc.b, 0.0))
	vapor.process_material = vp
	vapor.visibility_aabb = AABB(Vector3(-6, -6, -6), Vector3(12, 12, 12))
	add_child(vapor)
	return {"flash": flash, "light": light, "shards": shards, "ring": ring, "vapor": vapor}


# A small jagged crystal for the shard burst draw pass.
func _shard_mesh(burst: Dictionary, index: int) -> ArrayMesh:
	var rng := RandomNumberGenerator.new()
	rng.seed = 7343 + index
	var mesh := ArrayMesh.new()
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_smooth_group(-1)
	var s: float = float(burst["shard_size"])
	FrostLanceLib.add_spike(st, Vector3.ZERO, s * 1.6, s * 0.2, 0.6, rng)  # slivers
	st.generate_normals()
	st.commit(mesh)
	mesh.surface_set_material(
		0, FrostLanceLib.ice_mat(burst["shard_color"], float(burst["shard_energy"]), 0.95)
	)
	return mesh
