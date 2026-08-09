extends Node
# T-343 dev harness (AVALON_VFX_GALLERY=1): a self-contained frost-bolt candidate stage. A mage
# figure casts a frost bolt at a Training Dummy on a loop, viewed from a FIXED side-on camera so
# every recorded variant is identical bar the VFX preset (AVALON_VFX_PRESET). Bypasses the whole
# game boot (no server, no login) so recording needs no runtime lease on the shared stack.
#
# HONESTY RULES (round-2 fixes — round 1 over-promised twice):
# - The stage lights/glows at the SHIPPED environment values (world_view.gd: AgX, exposure 1.15,
#   glow 0.12/0.02) — NOT a flattering bloom setup. What the owner votes on is what ships.
# - Run under Godot movie mode (--write-movie X --fixed-fps 24) for the clips: deterministic
#   fixed-dt frames, so the recording is TRUE full-rate motion, never a wall-clock time-lapse.
#   Outside movie mode the harness falls back to self-captured PNGs (quick strip iteration).
#
# Timeline is mode-aware: classic presets keep the round-1 cycle; "lance" presets run the
# Sub-Zero three-act — ~0.9s cast anticipation, fast flight, ~1.4s impact hold (freeze overlay
# on the dummy, passed as the impact target).

const CASTER_POS := Vector3.ZERO
const DUMMY_POS := Vector3(7.0, 0.0, 0.0)
const CLASSIC_CAST_AT := 0.18
const CLASSIC_FLIGHT_GAP := 0.16  # cast -> launch
const CLASSIC_HOLD := 0.6
const LANCE_CAST_AT := 0.3
const LANCE_HOLD := 2.0  # T-343 r3: hold long enough to see the ~1.5s eased body-freeze fade out

var _dir := ""
var _index := 0
var _movie := false
var _lance_mode := false  # T-343 p2: lance presets get the frost SFX; classic keep generic
var _audio: AudioManager = null  # T-343 p2: real SFX bus so movie mode captures a non-silent wav
var _vfx: VfxManager = null
var _caster: Node3D = null
var _dummy: Node3D = null
var _cam: Camera3D = null
var _cast_at := 0.18
var _flight_at := 0.34
var _flight_dur := 0.4
var _cycle := 1.4
var _t := 0.0
var _fired_cast := false
var _fired_proj := false
var _fired_impact := false
var _strip := {}  # phase -> Image


func _ready() -> void:
	# T-343 (owner ruling 2026-07-16): the sibling hit-type STYLE gallery reuses this same
	# AVALON_VFX_GALLERY dispatch (main.gd sits at the 1000-line cap, so no new branch there). When a
	# style hit type is requested, hand off to that harness and skip the frost-bolt stage entirely.
	if OS.get_environment("AVALON_VFX_STYLE_GALLERY") != "":
		var styles: Node = preload("res://scripts/dev/vfx_style_gallery.gd").new()
		styles.name = "VfxStyleGallery"
		add_child(styles)
		return
	_index = VfxPresets.active_index()
	_movie = OS.has_feature("movie")
	_dir = OS.get_environment("AVALON_REVIEW_DIR")
	if _dir == "":
		_dir = "/tmp/avalon-review/t343"
	DirAccess.make_dir_recursive_absolute(_dir)
	DisplayServer.window_set_title(
		"VFX Gallery — preset %d: %s" % [_index, VfxPresets.name_of(_index)]
	)
	Engine.max_fps = 60

	_build_stage()
	_vfx = VfxManager.new()
	_vfx.name = "Vfx"
	add_child(_vfx)
	_vfx.apply_preset(_index)

	# T-343 p2: an AudioManager on the stage so Godot movie mode records the ability SFX to the
	# companion .wav (vfx-gallery.sh muxes it in) — future ballots are no longer silent. The meadow
	# ambience bed is muted so the ballot hears ONLY the ability cue, not the world bed.
	_audio = AudioManager.new()
	_audio.name = "Audio"
	add_child(_audio)
	_audio.set_ambient_volume_db(-80.0)

	var preset := VfxPresets.resolve(_index)
	var speed: float = float(preset["flight"]["speed"])
	_lance_mode = str(preset["mode"]) == "lance"
	if _lance_mode:
		_cast_at = LANCE_CAST_AT
		_flight_at = LANCE_CAST_AT + float(preset["antic"]["buildup"])
		_flight_dur = clampf(CASTER_POS.distance_to(DUMMY_POS) / speed, 0.08, 0.6)
		_cycle = _flight_at + _flight_dur + LANCE_HOLD
	else:
		_cast_at = CLASSIC_CAST_AT
		_flight_at = CLASSIC_CAST_AT + CLASSIC_FLIGHT_GAP
		_flight_dur = clampf(CASTER_POS.distance_to(DUMMY_POS) / speed, 0.12, 0.6)
		_cycle = _flight_at + _flight_dur + CLASSIC_HOLD

	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	await _capture()


func _build_stage() -> void:
	var we := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.30, 0.40, 0.52)  # muted dusk-blue so cold VFX pops
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.55, 0.60, 0.70)
	env.ambient_light_energy = 0.9
	# SHIPPED grade (world_view.gd) — the vote must see what the game shows, not a bloom fantasy.
	env.tonemap_mode = Environment.TONE_MAPPER_AGX
	env.tonemap_exposure = 1.15
	env.glow_enabled = true
	env.glow_intensity = 0.12
	env.glow_bloom = 0.02
	we.environment = env
	add_child(we)

	var key := DirectionalLight3D.new()  # frozen QA-afternoon sun
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
	_caster.rotation.y = -PI / 2.0  # face +X, toward the dummy
	add_child(_caster)

	_dummy = EntityVisuals.make_visual("mob_dummy")
	_dummy.position = DUMMY_POS
	_dummy.rotation.y = PI / 2.0  # face back toward the caster
	add_child(_dummy)

	_cam = Camera3D.new()
	_cam.fov = 52.0
	_cam.current = true
	add_child(_cam)
	# fixed side-on, ~9.6 m off the bolt path (set after entering the tree so look_at is valid)
	_cam.look_at_from_position(Vector3(3.5, 1.7, 9.6), Vector3(3.5, 1.2, 0.0), Vector3.UP)


# Drive the cast -> flight -> impact cycle on the frame clock (fixed-dt under movie mode).
func _process(delta: float) -> void:
	if _vfx == null:
		return
	_t += delta
	if not _fired_cast and _t >= _cast_at:
		_fired_cast = true
		EntityVisuals.play_state(_caster, "cast")
		_vfx.spawn_cast(CASTER_POS)
		if _audio != null:
			_audio.play_sfx("frost_cast" if _lance_mode else "spell_cast", -6.0)
	if not _fired_proj and _t >= _flight_at:
		_fired_proj = true
		EntityVisuals.play_state(_caster, "attack")
		_vfx.spawn_projectile(CASTER_POS, DUMMY_POS)
		if _audio != null and _lance_mode:
			_audio.play_sfx("frost_flight", -8.0)
	if not _fired_impact and _t >= _flight_at + _flight_dur:
		_fired_impact = true
		_vfx.spawn_impact_on(DUMMY_POS, _dummy)
		if _audio != null:
			_audio.play_sfx("frost_impact" if _lance_mode else "hit", -8.0)
	if _t >= _cycle:  # loop
		_t = 0.0
		_fired_cast = false
		_fired_proj = false
		_fired_impact = false


func _capture() -> void:
	var frames := 96
	var env_frames := OS.get_environment("AVALON_VFX_FRAMES")
	if env_frames.is_valid_int():
		frames = clampi(int(env_frames), 24, 240)
	var frame_dir := _dir.path_join("frames_%d" % _index)
	if not _movie:
		DirAccess.make_dir_recursive_absolute(frame_dir)
		var d := DirAccess.open(frame_dir)
		if d != null:
			for f in d.get_files():
				if f.ends_with(".png"):
					d.remove(f)
	# strip sample times: mid-anticipation / first frame after launch (a mid-flight sample can
	# MISS a 0.12s lance entirely at 24fps — the fast variants' strips came back empty) / just
	# after the flash
	var t_cast := _cast_at + (_flight_at - _cast_at) * 0.6
	var t_flight := _flight_at + 0.02
	var t_impact := _flight_at + _flight_dur + 0.16
	var saved := 0
	for i in range(frames):
		await RenderingServer.frame_post_draw
		var in_flight := _t >= t_flight and _t < _flight_at + _flight_dur
		var want_strip := (
			(not _strip.has("cast") and _t >= t_cast and _t < _flight_at)
			or (not _strip.has("flight") and in_flight)
			or (not _strip.has("impact") and _t >= t_impact)
		)
		if not _movie or want_strip:
			var img: Image = get_viewport().get_texture().get_image()
			if img.get_width() > 720:
				img.resize(
					720, int(720.0 * img.get_height() / img.get_width()), Image.INTERPOLATE_BILINEAR
				)
			if not _movie:
				img.save_png(frame_dir.path_join("f_%04d.png" % saved))
				saved += 1
			if not _strip.has("cast") and _t >= t_cast and _t < _flight_at:
				_strip["cast"] = img
			elif not _strip.has("flight") and in_flight:
				_strip["flight"] = img
			elif not _strip.has("impact") and _t >= t_impact:
				_strip["impact"] = img
	for phase in ["cast", "flight", "impact"]:
		if _strip.has(phase):
			(_strip[phase] as Image).save_png(_dir.path_join("strip_%d_%s.png" % [_index, phase]))
	print(
		(
			"[vfx-gallery] preset %d (%s): %d frames (movie=%s) -> %s"
			% [_index, VfxPresets.name_of(_index), frames, str(_movie), _dir]
		)
	)
	get_tree().quit(0)
