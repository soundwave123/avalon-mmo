class_name VfxManager
extends Node3D

# T-110: spell & combat VFX — short one-shot GPUParticles3D bursts that give combat visual punch
# (pairs with the T-111 combat SFX): a caster shimmer when an ability fires, an impact spark when a
# hit lands, and green sparkles on a heal. Small pre-built pools are repositioned + restarted per
# event (no per-frame allocation). Built in code so the STRUCTURE is headlessly unit-testable.
#
# T-343: the cast / projectile-core / trail / impact look is PRESET-DRIVEN (VfxPresets) under the
# gallery harness (AVALON_VFX_PRESET pins a candidate and re-skins the whole path by swapping one
# index). PHASE 3 (live default): with no such env, the non-frost pools render the owner-chosen
# HOUSE styles per hit type — data-driven from vfx_styles.json's "default" block (impact grounded,
# cast handglow, heal motes, projectile comet), by _build_house(). Retargeting the house look is a
# JSON edit, not code. The frost bolt keeps its ability-routed Ice Lance in either path.

# T-343 phase 2: the SHIPPED default. The owner picked preset 13 (Ice Lance) as the frost bolt's
# look, but the kit-wide restyle is phase 3 — so the lance is ability-aware, not the global
# default. In normal play the burst pools stay the generic look for every other ability and a
# DEDICATED lance (built from FROST_PRESET, regardless of AVALON_VFX_PRESET) serves the frost
# bolt only. FROST_ABILITY_ID mirrors server/world/data/abilities/frostbolt.json ("id": 204).
const FROST_PRESET := 13
const FROST_ABILITY_ID := 204
# T-350: the "satisfying shot" flash/tracer colours (see the gun pools built in _build_gun).
const GUN_FLASH := Color(1.0, 0.82, 0.45)
const GUN_TRACER := Color(1.0, 0.95, 0.7)

# T-351: the §11 per-era ABILITY re-skin — region -> era preset set (the T-343 preset system IS the
# vehicle; NO new VFX modules). Era 1 keeps the SHIPPED Ice Lance (13); inside the Ashmoor district
# the frost bolt resolves to the Gaslight Lance (19) — same three-act / speed / freeze, only a
# gaslight-azure + soot re-costume, so the era-invariant feel bar (§11.5) is preserved. main.gd
# flips the era from WorldView.in_ashmoor_district(); era 1 (the whole existing world) is unchanged.
const ERA_FROST_PRESET := {0: 13, 1: 19}
# T-351/T-343 p3: the priest heal is the house "Warm Rising Motes" style (owner-chosen default for
# the heal hit type), re-tinted per era — era-1 warm gold (the motes palette), era-2 a distinct warm
# variant. The heal MOTION (rise/spread/gravity) is sourced from vfx_styles.json's `motes` emitter;
# ERA_HEAL only overrides the tint. Each entry is [color, ramp_a (bright), ramp_b (faded-out)] as
# [r,g,b(,a)] literals (era-0 mirrors the motes palette so the const stays the per-era tint source).
const ERA_HEAL := {
	0:
	{"color": [1.0, 0.9, 0.6], "ramp_a": [1.0, 0.96, 0.72, 1.0], "ramp_b": [0.86, 0.7, 0.42, 0.0]},
	1:
	{
		"color": [0.98, 0.9, 0.62],
		"ramp_a": [1.0, 0.96, 0.72, 1.0],
		"ramp_b": [0.86, 0.7, 0.42, 0.0]
	},
}

var _cast: Array[GPUParticles3D] = []
var _impact: Array[GPUParticles3D] = []
var _heal: Array[GPUParticles3D] = []
var _proj: Array = []  # [{orb: MeshInstance3D, trail: GPUParticles3D, spin: Vector3}]
var _ci := 0
var _ii := 0
var _hi := 0
var _pi := 0
var _preset: Dictionary = {}
var _spinning := false  # any projectile core spins -> tick _process; else stay idle (T-210)
var _lance: FrostLanceVfx = null  # T-343 r2: preset mode "lance" delegates the whole path
var _frost_lance: FrostLanceVfx = null
var _era := 0  # T-351: 0 = era 1 (default world), 1 = Ashmoor/era 2; drives the ability re-skin
var _proj_speed := 20.0  # flight speed of the active projectile look (house comet or preset)
# T-343 p3: the house cast style's optional hand-glow light (a shared OmniLight pulsed per cast).
var _cast_light: OmniLight3D = null
var _cast_light_energy := 0.0
var _cast_light_life := 0.6

# T-350: the "satisfying shot" pools (ashmoor-direction §7). Preset-independent (a gunshot is not a
# spell), so built ONCE in _ready and never touched by apply_preset. Muzzle flash burst + a short
# OmniLight pulse (delivery punch), a hitscan tracer streak, and the impact reuses spawn_impact.
var _gun_muzzle: Array[GPUParticles3D] = []
var _gun_tracers: Array[MeshInstance3D] = []
var _gun_light: OmniLight3D = null
var _gmi := 0
var _gti := 0


func _ready() -> void:
	# T-343 phase 3: the LIVE default renders the owner-chosen house styles per hit type (data-driven
	# from vfx_styles.json "default": impact grounded, cast handglow, heal motes, projectile comet);
	# the frost bolt keeps its ability-routed Ice Lance. The preset-driven build (T-110 baseline +
	# candidate bank) is only used when the gallery harness pins a preset via AVALON_VFX_PRESET.
	if OS.has_environment("AVALON_VFX_PRESET"):
		_preset = VfxPresets.resolve(VfxPresets.active_index())
		_build()
	else:
		_build_house()
	_build_gun()


# T-343 phase 3: build the live non-frost pools from the canonical house-style selection
# (VfxStyles.resolve_default per hit type). The frost bolt still gets its dedicated ability-routed
# lance; every other cast/impact/heal/projectile now renders the chosen house language. Pool slots
# stay pooled one-shot GPUParticles3D (a multi-emitter style rides its extra emitters as children of
# the primary, restarted together in _fire) — no per-frame allocation.
func _build_house() -> void:
	_frost_lance = FrostLanceVfx.new()
	_frost_lance.name = "FrostLance"
	add_child(_frost_lance)
	_frost_lance.setup(VfxPresets.resolve(_frost_preset()))
	_spinning = false
	set_process(false)
	var cast_style := VfxStyles.resolve_default("cast")
	var impact_style := VfxStyles.resolve_default("impact")
	for i in range(5):
		_cast.append(_make_style_slot(cast_style["emitters"]))
	for i in range(6):
		_impact.append(_make_style_slot(impact_style["emitters"]))
	_build_cast_light(cast_style)
	_build_heal()
	var proj_style := VfxStyles.resolve_default("projectile")
	_proj_speed = float(proj_style.get("speed", 22.0))
	for i in range(4):
		_proj.append(_make_house_projectile(proj_style))


# T-343: rebuild every pool from another preset (used by the gallery harness to record variants).
func apply_preset(index: int) -> void:
	for p in _cast + _impact + _heal:
		p.queue_free()
	for pr in _proj:
		(pr["orb"] as Node).queue_free()
	if _lance != null:
		_lance.queue_free()
		_lance = null
	if _frost_lance != null:
		_frost_lance.queue_free()
		_frost_lance = null
	if _cast_light != null:
		_cast_light.queue_free()
		_cast_light = null
	_cast.clear()
	_impact.clear()
	_heal.clear()
	_proj.clear()
	_ci = 0
	_ii = 0
	_hi = 0
	_pi = 0
	_preset = VfxPresets.resolve(index)
	_build()


# Which lance (if any) serves this ability. Global lance mode (gallery) routes EVERY ability to
# _lance; otherwise only the frost bolt gets its dedicated _frost_lance and all else stays generic.
func _lance_for(ability_id: int) -> FrostLanceVfx:
	if _lance != null:
		return _lance
	if ability_id == FROST_ABILITY_ID:
		return _frost_lance
	return null


# T-343 r2: impact with a known victim — lance mode flash-freezes the target (material_overlay,
# ~1.5s eased). Non-lance abilities fall back to the plain burst; callers without a node pass null.
func spawn_impact_on(pos: Vector3, target: Node3D, ability_id := -1) -> void:
	var lance := _lance_for(ability_id)
	if lance != null:
		lance.impact(pos, target)
		return
	spawn_impact(pos)


func _build() -> void:
	if str(_preset.get("mode", "burst")) == "lance":
		_lance = FrostLanceVfx.new()
		_lance.name = "FrostLance"
		add_child(_lance)
		_lance.setup(_preset)
		# heal keeps its own pool even in lance mode (out of frost-bolt scope)
		_build_heal()
		set_process(false)
		return
	# T-343 phase 2: outside global lance mode, the frost bolt still gets its shipped lance look — a
	# dedicated FrostLanceVfx built from FROST_PRESET, routed by ability id. Every other ability keeps
	# the generic burst pools below (kit-wide restyle is phase 3).
	_frost_lance = FrostLanceVfx.new()
	_frost_lance.name = "FrostLance"
	add_child(_frost_lance)
	_frost_lance.setup(VfxPresets.resolve(_frost_preset()))
	var cast: Dictionary = _preset["cast"]
	var impact: Dictionary = _preset["impact"]
	_spinning = (_preset["core"] as Dictionary).get("spin", Vector3.ZERO) != Vector3.ZERO
	set_process(_spinning)
	for i in range(5):
		_cast.append(
			_make(
				_burst_proc(cast),
				_bb(cast["size"], cast["color"], str(cast["tex"]), float(cast["energy"])),
				float(cast["lifetime"]),
				int(cast["amount"])
			)
		)
	for i in range(6):
		_impact.append(
			_make(
				_burst_proc(impact),
				_bb(impact["size"], impact["color"], str(impact["tex"]), float(impact["energy"])),
				float(impact["lifetime"]),
				int(impact["amount"])
			)
		)
	_build_heal()
	_proj_speed = float((_preset["flight"] as Dictionary)["speed"])
	for i in range(4):
		_proj.append(_make_projectile())


# T-351: the frost preset for the current era (Ashmoor -> Gaslight Lance 19, else Ice Lance 13).
func _frost_preset() -> int:
	return int(ERA_FROST_PRESET.get(_era, FROST_PRESET))


# T-351/T-343 p3: build the heal pool from the house "motes" style (rise/spread/gravity motion),
# re-tinted with the current era's colour + ramp (ERA_HEAL). Motion is data-driven from vfx_styles;
# only the tint is per-era.
func _build_heal() -> void:
	var e: Dictionary = (VfxStyles.resolve_default("heal")["emitters"] as Array)[0]
	var h: Dictionary = ERA_HEAL.get(_era, ERA_HEAL[0])
	var hc: Array = h["color"]
	var ra: Array = h["ramp_a"]
	var rb: Array = h["ramp_b"]
	var tint := Color(hc[0], hc[1], hc[2])
	for i in range(4):
		var proc := _burst_proc(e)
		proc.color_ramp = _ramp(
			Color(ra[0], ra[1], ra[2], ra[3]), Color(rb[0], rb[1], rb[2], rb[3])
		)
		_heal.append(
			_make(
				proc,
				_bb(float(e["size"]), tint, "", float(e["energy"])),
				float(e["life"]),
				int(e["amount"])
			)
		)


# T-351: swap the ability re-skin to `era` (0 = default world, 1 = Ashmoor). Rebuilds the priest
# heal pool + the ability-aware frost lance from the era's preset; a no-op if the era is unchanged
# (main.gd calls this every throttled position tick). The GLOBAL gallery lance (_lance) is never
# region-driven — only the shipped ability-routed path (_frost_lance) and the heal re-skin.
func set_era(era: int) -> void:
	if era == _era:
		return
	_era = era
	for p in _heal:
		p.queue_free()
	_heal.clear()
	_hi = 0
	_build_heal()
	if _lance == null and _frost_lance != null:
		_frost_lance.queue_free()
		_frost_lance = FrostLanceVfx.new()
		_frost_lance.name = "FrostLance"
		add_child(_frost_lance)
		_frost_lance.setup(VfxPresets.resolve(_frost_preset()))


func _process(_delta: float) -> void:
	if not _spinning:
		return
	for p in _proj:
		var orb: MeshInstance3D = p["orb"]
		if orb.visible:
			orb.rotation += (p["spin"] as Vector3) * _delta


# A glowing orb that tweens from `from` to `to` (a ranged spell bolt) trailing motes; the impact at
# the target is left to the server-confirmed ability_result (spawn_impact), so no double flash.
func spawn_projectile(from: Vector3, to: Vector3, ability_id := -1) -> void:
	var lance := _lance_for(ability_id)
	if lance != null:
		lance.launch(from, to)
		return
	if _proj.is_empty():
		return
	var p: Dictionary = _proj[_pi]
	_pi = (_pi + 1) % _proj.size()
	var orb: MeshInstance3D = p["orb"]
	var trail: GPUParticles3D = p["trail"]
	orb.global_position = from + Vector3(0.0, 1.2, 0.0)
	orb.visible = true
	trail.emitting = true
	var dur := clampf(from.distance_to(to) / _proj_speed, 0.12, 0.6)
	var tw := create_tween()
	tw.tween_property(orb, "global_position", to + Vector3(0.0, 1.1, 0.0), dur)
	tw.tween_callback(
		func():
			orb.visible = false
			trail.emitting = false
	)


func _make_projectile() -> Dictionary:
	var core: Dictionary = _preset["core"]
	var trail_cfg: Dictionary = _preset["trail"]
	var orb := MeshInstance3D.new()
	var kind := str(core["kind"])
	var tex := str(core["tex"])
	var loaded_tex: Texture2D = _load_tex(tex)
	if kind != "none":
		orb.mesh = _core_mesh(kind, float(core["radius"]), loaded_tex)
		orb.material_override = _core_material(core, loaded_tex)
	orb.visible = false
	orb.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(orb)
	var trail := GPUParticles3D.new()
	trail.amount = int(trail_cfg["amount"])
	trail.lifetime = float(trail_cfg["lifetime"])
	trail.local_coords = false  # leave the trail in world space behind the moving orb
	trail.emitting = false
	trail.draw_pass_1 = _bb(
		trail_cfg["size"], trail_cfg["color"], str(trail_cfg["tex"]), float(trail_cfg["energy"])
	)
	var tp := ParticleProcessMaterial.new()
	tp.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	tp.emission_sphere_radius = float(trail_cfg["emis_r"])
	tp.initial_velocity_min = float(trail_cfg["vmin"])
	tp.initial_velocity_max = float(trail_cfg["vmax"])
	tp.gravity = trail_cfg["grav"]
	tp.scale_min = float(trail_cfg["smin"])
	tp.scale_max = float(trail_cfg["smax"])
	tp.color_ramp = _ramp(trail_cfg["ramp"][0], trail_cfg["ramp"][1])
	trail.process_material = tp
	trail.visibility_aabb = AABB(Vector3(-40, -10, -40), Vector3(80, 40, 80))
	orb.add_child(trail)
	return {"orb": orb, "trail": trail, "spin": core.get("spin", Vector3.ZERO)}


func _core_mesh(kind: String, radius: float, tex: Texture2D) -> Mesh:
	# A sourced glow/spark sprite reads best as a flat billboard, not a lit solid.
	if tex != null:
		var q := QuadMesh.new()
		q.size = Vector2(radius * 2.4, radius * 2.4)
		return q
	match kind:
		"box":
			var b := BoxMesh.new()
			b.size = Vector3(radius, radius, radius) * 1.7
			return b
		"prism":
			var pr := PrismMesh.new()
			pr.size = Vector3(radius * 1.8, radius * 2.4, radius * 1.8)
			return pr
		_:
			var sm := SphereMesh.new()
			sm.radius = radius
			sm.height = radius * 2.0
			sm.radial_segments = 8
			sm.rings = 5
			return sm


func _core_material(core: Dictionary, tex: Texture2D) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = core["albedo"]
	mat.emission_enabled = true
	mat.emission = core["emission"]
	mat.emission_energy_multiplier = float(core["energy"])
	if tex != null:  # sourced sprite core: additive billboard so the glow reads
		mat.albedo_texture = tex
		mat.emission_texture = tex
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
		mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
		mat.billboard_keep_scale = true
	return mat


func spawn_cast(pos: Vector3, ability_id := -1) -> void:
	var lance := _lance_for(ability_id)
	if lance != null:
		lance.begin_cast(pos)
		return
	var at := pos + Vector3(0.0, 1.0, 0.0)
	_fire(_cast, at, func(): _ci = (_ci + 1) % _cast.size(), _ci)
	if _cast_light != null:  # house hand-glow windup: a brief warm pulse at the hand
		_cast_light.global_position = at
		_cast_light.light_energy = _cast_light_energy
		var tw := create_tween()
		tw.tween_property(_cast_light, "light_energy", 0.0, _cast_light_life)


func spawn_impact(pos: Vector3) -> void:
	if _lance != null:
		_lance.impact(pos, null)
		return
	_fire(_impact, pos + Vector3(0.0, 1.1, 0.0), func(): _ii = (_ii + 1) % _impact.size(), _ii)


# T-350: the satisfying shot (ashmoor-direction §7). `shooter` = the firing entity's node (its
# muzzle is derived — chest height + a step forward along the flat aim line, so the tracer leaves
# the barrel not the feet), `target_pos` = the hit entity's base. Fires the delivery punch
# (muzzle-flash burst + a short OmniLight pulse), an instant hitscan TRACER streak (the lance's
# path-streak idiom at gun speed — must read in 2-3 frames), and the impact puff at the hit point.
# Server-confirmed: only ever called off an ability_result, so the tracer lands where the hit did.
func spawn_gunshot(shooter: Node3D, target_pos: Vector3) -> void:
	var hit := target_pos + Vector3(0.0, 1.1, 0.0)
	var from := hit
	if shooter != null:
		var cpos: Vector3 = shooter.global_position
		var flat := Vector3(target_pos.x - cpos.x, 0.0, target_pos.z - cpos.z)
		var fwd := flat.normalized() if flat.length() > 0.01 else Vector3.FORWARD
		from = cpos + Vector3(0.0, 1.3, 0.0) + fwd * 0.5
	if not _gun_muzzle.is_empty():
		_fire(_gun_muzzle, from, func(): _gmi = (_gmi + 1) % _gun_muzzle.size(), _gmi)
	if _gun_light != null:
		_gun_light.global_position = from
		_gun_light.light_energy = 6.0
		var tw := create_tween()
		tw.tween_property(_gun_light, "light_energy", 0.0, 0.09)
	_fire_tracer(from, hit)
	spawn_impact(hit)


func _fire_tracer(from: Vector3, to: Vector3) -> void:
	if _gun_tracers.is_empty():
		return
	var length := from.distance_to(to)
	if length < 0.05:
		return
	var tr: MeshInstance3D = _gun_tracers[_gti]
	_gti = (_gti + 1) % _gun_tracers.size()
	var mid := (from + to) * 0.5
	tr.global_position = mid
	tr.look_at(to, Vector3.UP)  # local -Z now points at the target
	tr.scale = Vector3(1.0, 1.0, length)  # the base box is 1m along Z; span from..to
	tr.visible = true
	var tw := create_tween()  # a 2-3 frame streak, then gone
	tw.tween_interval(0.06)
	tw.tween_callback(func(): tr.visible = false)


func _build_gun() -> void:
	for i in range(4):
		var proc := ParticleProcessMaterial.new()
		proc.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
		proc.emission_sphere_radius = 0.05
		proc.direction = Vector3(0.0, 0.2, 1.0)  # spray forward-ish off the muzzle
		proc.spread = 35.0
		proc.initial_velocity_min = 1.5
		proc.initial_velocity_max = 4.0
		proc.gravity = Vector3.ZERO
		proc.scale_min = 0.7
		proc.scale_max = 1.4
		proc.color_ramp = _ramp(Color(1.0, 0.95, 0.7, 1.0), Color(1.0, 0.5, 0.15, 0.0))
		_gun_muzzle.append(_make(proc, _bb(0.28, GUN_FLASH, "", 5.0), 0.12, 10))
	for i in range(4):
		var box := BoxMesh.new()
		box.size = Vector3(0.035, 0.035, 1.0)  # long along Z; _fire_tracer scales Z to the shot length
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
		mat.albedo_color = GUN_TRACER
		mat.emission_enabled = true
		mat.emission = GUN_TRACER
		mat.emission_energy_multiplier = 4.0
		var tr := MeshInstance3D.new()
		tr.mesh = box
		tr.material_override = mat
		tr.visible = false
		tr.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(tr)
		_gun_tracers.append(tr)
	_gun_light = OmniLight3D.new()
	_gun_light.light_color = GUN_FLASH
	_gun_light.light_energy = 0.0
	_gun_light.omni_range = 4.0
	_gun_light.shadow_enabled = false
	add_child(_gun_light)


func spawn_heal(pos: Vector3) -> void:
	_fire(_heal, pos + Vector3(0.0, 0.6, 0.0), func(): _hi = (_hi + 1) % _heal.size(), _hi)


# --- internals --------------------------------------------------------------
func _fire(pool: Array, pos: Vector3, advance: Callable, idx: int) -> void:
	if pool.is_empty():
		return
	var p: GPUParticles3D = pool[idx]
	p.global_position = pos
	p.restart()  # one_shot: re-emits the burst
	for ch in p.get_children():  # a multi-emitter house style rides its extras on the primary
		if ch is GPUParticles3D:
			(ch as GPUParticles3D).restart()
	advance.call()


func _make(
	proc: ParticleProcessMaterial, mesh: Mesh, lifetime: float, amount: int
) -> GPUParticles3D:
	var p := GPUParticles3D.new()
	p.process_material = proc
	p.draw_pass_1 = mesh
	p.lifetime = lifetime
	p.amount = maxi(1, amount)
	p.one_shot = true
	p.explosiveness = 1.0  # a single burst, not a stream
	p.emitting = false
	p.visibility_aabb = AABB(Vector3(-3, -3, -3), Vector3(6, 6, 6))
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(p)
	return p


func _load_tex(path: String) -> Texture2D:
	if path == "" or not ResourceLoader.exists(path):
		return null
	return load(path) as Texture2D


func _bb(size: float, color: Color, tex: String, energy: float) -> QuadMesh:
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
	var loaded := _load_tex(tex)
	if loaded != null:  # sourced particle sprite (Kenney/CC0) — texture the additive quad
		m.albedo_texture = loaded
		m.emission_texture = loaded
	q.material = m
	return q


func _ramp(a: Color, b: Color) -> GradientTexture1D:
	var g := Gradient.new()
	g.set_offsets(PackedFloat32Array([0.0, 1.0]))
	g.set_colors(PackedColorArray([a, b]))
	var t := GradientTexture1D.new()
	t.gradient = g
	return t


# Build a one-shot burst ParticleProcessMaterial from a preset cast/impact sub-dict.
func _burst_proc(cfg: Dictionary) -> ParticleProcessMaterial:
	var p := ParticleProcessMaterial.new()
	p.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	p.emission_sphere_radius = float(cfg["emis_r"])
	p.direction = cfg["dir"]
	p.spread = float(cfg["spread"])
	p.initial_velocity_min = float(cfg["vmin"])
	p.initial_velocity_max = float(cfg["vmax"])
	p.gravity = cfg["grav"]
	p.scale_min = float(cfg["smin"])
	p.scale_max = float(cfg["smax"])
	p.color_ramp = _ramp(cfg["ramp"][0], cfg["ramp"][1])
	return p


# --- T-343 phase 3: house-style builders ------------------------------------
# One pooled slot for a house style: the primary emitter is a direct child (repositioned/restarted
# per event); any additional emitters ride as children of the primary so a multi-emitter style
# (e.g. impact "grounded" = embers + dust) fires as one unit (see _fire).
func _make_style_slot(emitters: Array) -> GPUParticles3D:
	var primary := _make_style_emitter(emitters[0])
	add_child(primary)
	for i in range(1, emitters.size()):
		primary.add_child(_make_style_emitter(emitters[i]))
	return primary


func _make_style_emitter(cfg: Dictionary) -> GPUParticles3D:
	var p := GPUParticles3D.new()
	p.process_material = _burst_proc(cfg)
	p.draw_pass_1 = _bb(float(cfg["size"]), cfg["color"], "", float(cfg["energy"]))
	p.lifetime = float(cfg.get("life", 0.5))
	p.amount = maxi(1, int(cfg.get("amount", 20)))
	p.one_shot = true
	p.explosiveness = 1.0
	p.emitting = false
	p.visibility_aabb = AABB(Vector3(-3, -3, -3), Vector3(6, 6, 6))
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return p


# The house cast style's optional hand-glow: one shared OmniLight pulsed at the caster's hand per
# cast (guarded null when the active cast style declares no light).
func _build_cast_light(style: Dictionary) -> void:
	if not style.has("light"):
		_cast_light = null
		return
	var l: Dictionary = style["light"]
	_cast_light = OmniLight3D.new()
	_cast_light.light_color = l["color"]
	_cast_light.light_energy = 0.0
	_cast_light.omni_range = float(l.get("range", 3.0))
	_cast_light.shadow_enabled = false
	add_child(_cast_light)
	_cast_light_energy = float(l.get("energy", 2.0))
	_cast_light_life = float(l.get("life", 0.6))


# A house projectile: a small emissive core mesh + a world-space trail emitter, both hidden until a
# shot tweens the orb from caster to target (spawn_projectile). Mirrors the {orb,trail,spin} shape
# of the preset _make_projectile so the spawn path is identical.
func _make_house_projectile(style: Dictionary) -> Dictionary:
	var core: Dictionary = style["core"]
	var orb := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = float(core["radius"])
	sm.height = float(core["radius"]) * 2.0
	sm.radial_segments = 8
	sm.rings = 5
	orb.mesh = sm
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = core["color"]
	m.emission_enabled = true
	m.emission = core["color"]
	m.emission_energy_multiplier = float(core["energy"])
	orb.material_override = m
	orb.visible = false
	orb.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(orb)
	var trail := GPUParticles3D.new()
	var tc: Dictionary = (style["emitters"] as Array)[0]
	trail.amount = int(tc["amount"])
	trail.lifetime = float(tc["life"])
	trail.local_coords = false  # leave the trail in world space behind the moving orb
	trail.emitting = false
	trail.draw_pass_1 = _bb(float(tc["size"]), tc["color"], "", float(tc["energy"]))
	trail.process_material = _burst_proc(tc)
	trail.visibility_aabb = AABB(Vector3(-40, -10, -40), Vector3(80, 40, 80))
	orb.add_child(trail)
	return {"orb": orb, "trail": trail, "spin": Vector3.ZERO}
