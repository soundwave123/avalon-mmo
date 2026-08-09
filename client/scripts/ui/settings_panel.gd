class_name SettingsPanel
# T-078: the WoW-style Esc options menu — Video / Audio / Controls, built in CODE (no .tscn; the
# QuestLogPanel/TalentPanel idiom) and added under the HUD by main.gd. Every control applies LIVE
# and persists to user://settings.cfg (ConfigFile); setup() re-applies the saved config to the live
# world/audio on boot. Headless-unit-testable: the controls are members, toggle() flips visibility,
# and the config round-trips through save()/load_settings().
#
# DEFERRED (follow-up ticket): key REMAPPING of the core binds (WASD, 1-4, N/L/I, autoattack). It
# needs a rebindable InputMap + a capture widget; local_player.gd/main.gd currently read raw
# keycodes. This menu ships mouse-look sensitivity now; remapping is scoped out of T-078 pass 1.

extends Control

const CONFIG_PATH := "user://settings.cfg"

# Read-only list of the core keybinds (T-078 Controls display; remapping is deferred). One label
# per row so the parchment theme colours them; kept in sync by hand with main.gd's _input map —
# EXCEPT the action-bar range, which T-723 DERIVES from AbilityKeybinds (the same map main._input
# dispatches through and the bar prints on its pips). That row is the one that actually rotted: it
# still advertised "1 - 4" while the bar drew nine slots. _keybind_rows() resolves the token.
const ABILITY_KEYS_TOKEN := "{ability_keys}"
const KEYBINDS := [
	["Move", "W A S D"],
	["Action bar", ABILITY_KEYS_TOKEN],
	["Auto-attack", "` (backtick)"],
	["Quest log", "L"],
	["Bags", "I"],
	["Talents", "N"],
	["Character sheet", "C"],
	["Options / cancel", "Esc"],
]

# Quality preset -> the WorldView environment/sun knobs + (T-692 Part B) the asset-loading knobs:
# flora_density/flora_ring/lod_mult stream to WorldPropsLayer.apply_quality_cfg (budgeted rebuild);
# building_ring is PINNED at 900 on every tier (silhouette = navigation — a P2 lever, not a preset
# one); mesh_lod_threshold/shadow_splits/shadow_atlas apply live below. Index 3 (Ultra) mirrors
# the project.godot/world_view baseline so opting up restores the world exactly as authored
# (atlas 8192, 4-split, mesh_lod 1.0); the DEFAULT tier is High (see _quality_opt + auto-detect —
# Ultra-by-default wastes a large fps fraction on invisible deltas). Volumetric fog ships on
# High/Ultra (AAA-spec pass; the old T-170 all-tier disable is retired). AA applies live via the
# viewport per tier (owner tip: never ProjectSettings at runtime).
const QUALITY_PRESETS := [
	{
		"ssao": false,
		"ssil": false,
		"sdfgi": false,
		"ssr": false,
		"glow": false,
		"shadows": false,
		"shadow_dist": 60.0,
		"volumetric": false,
		"taa": false,
		"msaa": Viewport.MSAA_DISABLED,
		"flora_density": 0.5,
		"lod_mult": 0.55,
		"flora_ring": 190.0,
		"building_ring": 900.0,
		"mesh_lod_threshold": 4.0,
		"shadow_splits": DirectionalLight3D.SHADOW_ORTHOGONAL,
		"shadow_atlas": 2048,
	},
	{
		"ssao": true,
		"ssil": false,
		"sdfgi": false,
		"ssr": false,
		"glow": true,
		"shadows": true,
		"shadow_dist": 120.0,
		"volumetric": false,
		"taa": true,
		"msaa": Viewport.MSAA_DISABLED,
		"flora_density": 0.75,
		"lod_mult": 0.8,
		"flora_ring": 275.0,
		"building_ring": 900.0,
		"mesh_lod_threshold": 2.0,
		"shadow_splits": DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS,
		"shadow_atlas": 4096,
	},
	{
		"ssao": true,
		"ssil": true,
		"sdfgi": true,
		"ssr": false,
		"glow": true,
		"shadows": true,
		"shadow_dist": 180.0,
		"volumetric": true,
		"taa": true,
		"msaa": Viewport.MSAA_2X,
		"flora_density": 1.0,
		"lod_mult": 1.0,
		"flora_ring": 340.0,
		"building_ring": 900.0,
		"mesh_lod_threshold": 1.0,
		"shadow_splits": DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS,
		"shadow_atlas": 4096,
	},
	{
		"ssao": true,
		"ssil": true,
		"sdfgi": true,
		"ssr": true,
		"glow": true,
		"shadows": true,
		"shadow_dist": 220.0,
		"volumetric": true,
		"taa": true,
		"msaa": Viewport.MSAA_8X,
		"flora_density": 1.0,
		"lod_mult": 1.25,
		"flora_ring": 425.0,
		"building_ring": 900.0,
		"mesh_lod_threshold": 1.0,
		"shadow_splits": DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS,
		"shadow_atlas": 8192,
	},
]

# T-692 Part B: the default tier (High). Ultra is an opt-up — the authored-baseline mirror.
const DEFAULT_QUALITY := 2

var _world_view: WorldView = null  # main.gd hands over its 3D world (env + sun knobs) via setup()
var _audio: AudioManager = null  # /root/Main/AudioManager — ambience + sfx volume setters
var _loading := false  # true while load_settings() writes control values (suppresses apply + save)

var _window_opt: OptionButton = null
var _vsync_check: CheckButton = null
var _scale_slider: HSlider = null
var _quality_opt: OptionButton = null
var _master_slider: HSlider = null
var _ambience_slider: HSlider = null
var _music_slider: HSlider = null  # T-416: trims the dedicated "Music" bus (score beds)
var _sfx_slider: HSlider = null
var _sens_slider: HSlider = null
var _class_color_check: CheckButton = null  # T-286: color friendly plates by class
var _scroll: ScrollContainer = null  # T-400: internal scroll so the window can't overflow 720p
var _box: VBoxContainer = null  # T-400: the scrolled content column (height measured for the cap)


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	offset_left = 16.0
	offset_top = 16.0
	offset_right = -16.0
	offset_bottom = -16.0
	visible = false  # opened with Esc (main.gd)
	theme = UiTheme.build()  # T-308: parchment/iron/gold skin, so the menu reads as one HUD
	var dim := ColorRect.new()
	dim.color = Color(0.0, 0.0, 0.0, 0.55)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(dim)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(center)
	var panel := PanelContainer.new()
	panel.theme_type_variation = "SolidWindow"  # T-396: deliberate window = opaque opt-in
	center.add_child(panel)
	# T-400: an internal scroll caps the window to the viewport so it can't overflow 720p top+bottom
	# (judge flag). ScrollContainer wraps a plain VBox — NOT a RichTextLabel, which once collapsed to
	# zero size inside a ScrollContainer (see inventory_panel.gd). Height capped in _apply_height_cap.
	_scroll = ScrollContainer.new()
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	panel.add_child(_scroll)
	var box := VBoxContainer.new()
	box.custom_minimum_size = Vector2(440.0, 0.0)
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_theme_constant_override("separation", 6)
	_scroll.add_child(box)
	_box = box

	_add_title(box, "Options")
	_add_header(box, "Video")
	_window_opt = _add_option(box, "Window Mode", ["Windowed", "Fullscreen"], 0, _on_window_mode)
	# Owner 2026-07-08: PC game, uncapped by default — VSync opt-IN (project.godot vsync_mode=0).
	_vsync_check = _add_check(box, "VSync", false, _on_vsync)
	_scale_slider = _add_slider(box, "Render Scale", 0.5, 1.0, 0.05, 1.0, _on_render_scale)
	_quality_opt = _add_option(
		box, "Quality", ["Low", "Medium", "High", "Ultra"], DEFAULT_QUALITY, _on_quality
	)
	_add_header(box, "Audio")
	_master_slider = _add_slider(box, "Master", 0.0, 100.0, 1.0, 100.0, _on_master)
	_ambience_slider = _add_slider(box, "Ambience", 0.0, 100.0, 1.0, 100.0, _on_ambience)
	_music_slider = _add_slider(box, "Music", 0.0, 100.0, 1.0, 100.0, _on_music)
	_sfx_slider = _add_slider(box, "SFX", 0.0, 100.0, 1.0, 100.0, _on_sfx)
	_add_header(box, "Controls")
	_sens_slider = _add_slider(box, "Mouse Sensitivity", 0.2, 3.0, 0.05, 1.0, _on_sensitivity)
	# Read-only keybind reference. Remapping (rebindable InputMap + capture widget) is the named
	# deferral below; showing the fixed core binds is the honest Controls "display" for now.
	_add_keybind_list(box)
	_add_header(box, "Nameplates")
	# T-286: WoW parity — off = flat green friendly plates; on = friendly plates by class color.
	_class_color_check = _add_check(box, "Class-Color Plates", false, _on_class_colors)

	var close := Button.new()
	close.text = "Close"
	close.pressed.connect(toggle)
	box.add_child(close)

	# Owner request: a fullscreen client had no way out — Esc menu now carries Exit Game.
	var quit := Button.new()
	quit.name = "ExitGameButton"
	quit.text = "Exit Game"
	quit.pressed.connect(func() -> void: get_tree().quit())
	box.add_child(quit)

	load_settings()  # pull the saved config into the controls (guarded — the live apply is setup())
	_autodetect_quality()  # T-692 Part B: first boot only — pick the tier from the adapter type
	call_deferred("_apply_height_cap")  # size the cap once the column has a measured minimum


# main.gd: hand over the live systems + push the loaded config to them (the boot apply).
func setup(world_view: WorldView, audio: AudioManager) -> void:
	_world_view = world_view
	_audio = audio
	_apply_all()


func toggle() -> void:
	visible = not visible
	if visible:
		_apply_height_cap()  # re-cap on open (the viewport may have resized since boot)
		if _has_window():
			Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)  # free the cursor so the menu is clickable


# T-400: clamp the scrolled column to min(content height, viewport*0.9) so the window fits 720p with
# room to spare; the ScrollContainer scrolls anything taller. viewport_h is injectable for tests.
func _apply_height_cap(viewport_h: float = -1.0) -> void:
	if _scroll == null or _box == null:
		return
	var vp_h := viewport_h
	if vp_h <= 0.0:
		vp_h = float(get_viewport_rect().size.y) if is_inside_tree() else 720.0
	var content_h := _box.get_combined_minimum_size().y
	var cap := vp_h * 0.9
	_scroll.custom_minimum_size.y = minf(content_h, cap) if content_h > 0.0 else cap


# ---- apply (each pushes ONE control's current value to the live system) ----


func _apply_all() -> void:
	_apply_window_mode()
	_apply_vsync()
	_apply_render_scale()
	_apply_quality()
	_apply_master()
	_apply_ambience()
	_apply_music()
	_apply_sfx()
	_apply_sensitivity()
	_apply_class_colors()


# T-286: push the class-color-plates toggle to the live remote-entity layer (world_view child).
func _apply_class_colors() -> void:
	if _world_view == null or _class_color_check == null:
		return
	var remote := _world_view.get_node_or_null("RemoteEntities")
	if remote != null:
		remote.set_class_color_plates(_class_color_check.button_pressed)


func _apply_window_mode() -> void:
	if not _has_window():
		return
	var mode := DisplayServer.WINDOW_MODE_WINDOWED
	if _window_opt.selected == 1:
		mode = DisplayServer.WINDOW_MODE_FULLSCREEN
	DisplayServer.window_set_mode(mode)


func _apply_vsync() -> void:
	if not _has_window():
		return
	var mode := DisplayServer.VSYNC_DISABLED
	if _vsync_check.button_pressed:
		mode = DisplayServer.VSYNC_ENABLED
	DisplayServer.window_set_vsync_mode(mode)


func _apply_render_scale() -> void:
	if is_inside_tree():
		get_viewport().scaling_3d_scale = float(_scale_slider.value)


func _apply_quality() -> void:
	if _world_view == null or _world_view.world_environment == null:
		return
	var env: Environment = _world_view.world_environment.environment
	if env == null:
		return
	var p: Dictionary = QUALITY_PRESETS[_quality_opt.selected]
	env.ssao_enabled = p["ssao"]
	env.ssil_enabled = p["ssil"]
	env.sdfgi_enabled = p["sdfgi"]
	env.ssr_enabled = p["ssr"]
	env.glow_enabled = p["glow"]
	# Volumetric fog is part of the realism baseline (AAA-spec pass) on High/Ultra; the old
	# T-170 hard-disable silently killed it at boot (owner tip about runtime settings caught it).
	env.volumetric_fog_enabled = bool(p.get("volumetric", false))
	if _world_view.sun != null:
		_world_view.sun.shadow_enabled = bool(p["shadows"])
		_world_view.sun.directional_shadow_max_distance = float(p["shadow_dist"])
		# T-692 Part B: cascade COUNT is the primary shadow lever (UE curve 1/2/4/4).
		_world_view.sun.directional_shadow_mode = int(
			p.get("shadow_splits", DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS)
		)
	# T-692 Part B: the sun shadow atlas scales per tier — the RUNTIME setter (the project-setting
	# equivalent is the restart trap above); 16_bits=false matches the project.godot baseline.
	RenderingServer.directional_shadow_atlas_set_size(int(p.get("shadow_atlas", 8192)), false)
	# Anti-aliasing per preset, applied LIVE via the viewport (RenderingServer-backed) — never
	# ProjectSettings at runtime, which would need a restart.
	if is_inside_tree():
		var vp := get_viewport()
		vp.use_taa = bool(p.get("taa", false))
		vp.msaa_3d = int(p.get("msaa", Viewport.MSAA_DISABLED))
		# T-692 Part B: higher threshold = coarser auto-LOD everywhere (engine default 1.0 px).
		vp.mesh_lod_threshold = float(p.get("mesh_lod_threshold", 1.0))
	# T-692 Part B: the asset-loading knobs ride the props layer's budgeted rebuild (T-688) — a
	# preset change re-thins density + re-rings streaming live: no relaunch, no one-frame burst.
	var props := _world_view.get_node_or_null("WorldProps")
	if props != null and props.has_method("apply_quality_cfg"):
		props.apply_quality_cfg(props_cfg(_quality_opt.selected))


func _apply_master() -> void:
	var idx := AudioServer.get_bus_index("Master")
	if idx < 0:
		return
	var pct := float(_master_slider.value)
	AudioServer.set_bus_mute(idx, pct <= 0.0)
	AudioServer.set_bus_volume_db(idx, _slider_db(pct))


func _apply_ambience() -> void:
	if _audio != null:
		_audio.set_ambient_volume_db(_slider_db(float(_ambience_slider.value)))


func _apply_music() -> void:
	# T-416: the score sits on its own "Music" bus (created by MusicBedLayer); trim it like Master.
	var idx := AudioServer.get_bus_index(MusicBedLayer.BUS_NAME)
	if idx < 0:
		return
	var pct := float(_music_slider.value)
	AudioServer.set_bus_mute(idx, pct <= 0.0)
	AudioServer.set_bus_volume_db(idx, _slider_db(pct))


func _apply_sfx() -> void:
	if _audio != null:
		_audio.set_sfx_volume_db(_slider_db(float(_sfx_slider.value)))


func _apply_sensitivity() -> void:
	LocalPlayer.sensitivity_mult = float(_sens_slider.value)


# 0..100% -> dB. 100% = 0 dB (design level / no attenuation), 0% = silence. Serves as the Master bus
# level and as the ambience/sfx offsets, so every default (100%) preserves the current mix.
func _slider_db(pct: float) -> float:
	if pct <= 0.0:
		return -60.0
	return lerpf(-40.0, 0.0, clampf(pct, 0.0, 100.0) / 100.0)


# T-692 Part B: the asset-loading slice of a preset — exactly what WorldPropsLayer's
# apply_quality_cfg consumes. Pure/table-driven so the mapping is headlessly testable.
static func props_cfg(tier: int) -> Dictionary:
	var p: Dictionary = QUALITY_PRESETS[tier]
	return {
		"flora_ring": float(p["flora_ring"]),
		"building_ring": float(p["building_ring"]),
		"flora_density": float(p["flora_density"]),
		"lod_mult": float(p["lod_mult"]),
	}


# T-692 Part B: first-run tier heuristic. Godot has no portable total-VRAM query, so the adapter
# TYPE decides: discrete GPU -> High, integrated -> Medium, anything else (virtual/CPU/unknown)
# -> Low. Never Ultra — that stays an explicit opt-up. Pure so the branches unit-test on
# injected values.
static func tier_for_adapter(adapter_type: int) -> int:
	if adapter_type == RenderingDevice.DEVICE_TYPE_DISCRETE_GPU:
		return 2
	if adapter_type == RenderingDevice.DEVICE_TYPE_INTEGRATED_GPU:
		return 1
	return 0


# T-692 Part B: auto-detect runs only on a real display with NO saved config (a saved choice
# always wins). Not persisted here — the first save() records it; until then the deterministic
# re-detect each boot is equivalent, and headless/test boots never touch the user's settings.cfg.
func _autodetect_quality(path := CONFIG_PATH) -> void:
	if FileAccess.file_exists(path) or not _has_window():
		return
	_quality_opt.selected = tier_for_adapter(RenderingServer.get_video_adapter_type())


func _has_window() -> bool:
	return DisplayServer.get_name() != "headless"


# ---- change handlers (apply that control + persist; guarded during load) ----


func _on_window_mode(_index: int) -> void:
	if _loading:
		return
	_apply_window_mode()
	save()


func _on_vsync(_pressed: bool) -> void:
	if _loading:
		return
	_apply_vsync()
	save()


func _on_class_colors(_pressed: bool) -> void:
	if _loading:
		return
	_apply_class_colors()
	save()


func _on_render_scale(_value: float) -> void:
	if _loading:
		return
	_apply_render_scale()
	save()


func _on_quality(_index: int) -> void:
	if _loading:
		return
	_apply_quality()
	save()


func _on_master(_value: float) -> void:
	if _loading:
		return
	_apply_master()
	save()


func _on_ambience(_value: float) -> void:
	if _loading:
		return
	_apply_ambience()
	save()


func _on_music(_value: float) -> void:
	if _loading:
		return
	_apply_music()
	save()


func _on_sfx(_value: float) -> void:
	if _loading:
		return
	_apply_sfx()
	save()


func _on_sensitivity(_value: float) -> void:
	if _loading:
		return
	_apply_sensitivity()
	save()


# ---- persistence (ConfigFile at user://settings.cfg) ----


func save(path := CONFIG_PATH) -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("video", "window_mode", _window_opt.selected)
	cfg.set_value("video", "vsync", _vsync_check.button_pressed)
	cfg.set_value("video", "render_scale", _scale_slider.value)
	cfg.set_value("video", "quality", _quality_opt.selected)
	cfg.set_value("audio", "master", _master_slider.value)
	cfg.set_value("audio", "ambience", _ambience_slider.value)
	cfg.set_value("audio", "music", _music_slider.value)
	cfg.set_value("audio", "sfx", _sfx_slider.value)
	cfg.set_value("controls", "sensitivity", _sens_slider.value)
	cfg.set_value("nameplates", "class_colors", _class_color_check.button_pressed)
	cfg.save(path)


func load_settings(path := CONFIG_PATH) -> void:
	var cfg := ConfigFile.new()
	if cfg.load(path) != OK:
		return  # no saved config yet — the controls keep their (Ultra/default) values
	_loading = true
	_window_opt.selected = int(cfg.get_value("video", "window_mode", _window_opt.selected))
	_vsync_check.button_pressed = bool(cfg.get_value("video", "vsync", _vsync_check.button_pressed))
	_scale_slider.value = float(cfg.get_value("video", "render_scale", _scale_slider.value))
	_quality_opt.selected = int(cfg.get_value("video", "quality", _quality_opt.selected))
	_master_slider.value = float(cfg.get_value("audio", "master", _master_slider.value))
	_ambience_slider.value = float(cfg.get_value("audio", "ambience", _ambience_slider.value))
	_music_slider.value = float(cfg.get_value("audio", "music", _music_slider.value))
	_sfx_slider.value = float(cfg.get_value("audio", "sfx", _sfx_slider.value))
	_sens_slider.value = float(cfg.get_value("controls", "sensitivity", _sens_slider.value))
	_class_color_check.button_pressed = bool(
		cfg.get_value("nameplates", "class_colors", _class_color_check.button_pressed)
	)
	_loading = false


# ---- UI builders ----


func _add_title(box: VBoxContainer, text: String) -> void:
	var lbl := Label.new()
	lbl.text = text
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.add_theme_font_size_override("font_size", 22)
	lbl.add_theme_color_override("font_color", UiTheme.GOLD_BRIGHT)  # T-308 accent
	box.add_child(lbl)


func _add_header(box: VBoxContainer, text: String) -> void:
	var lbl := Label.new()
	lbl.text = text
	lbl.add_theme_color_override("font_color", UiTheme.GOLD)  # T-308 section accent
	box.add_child(lbl)


# T-723: the rows as RENDERED — KEYBINDS with the derived tokens resolved against the live map.
func _keybind_rows() -> Array:
	var out: Array = []
	for bind: Array in KEYBINDS:
		var keys := str(bind[1])
		if keys == ABILITY_KEYS_TOKEN:
			keys = AbilityKeybinds.range_label()
		out.append([str(bind[0]), keys])
	return out


func _add_keybind_list(box: VBoxContainer) -> void:
	for bind: Array in _keybind_rows():
		var row := HBoxContainer.new()
		var action := Label.new()
		action.text = bind[0]
		action.custom_minimum_size = Vector2(150.0, 0.0)
		action.add_theme_color_override("font_color", UiTheme.PARCHMENT_DIM)
		row.add_child(action)
		var keys := Label.new()
		keys.text = bind[1]
		keys.add_theme_color_override("font_color", UiTheme.GOLD_BRIGHT)
		row.add_child(keys)
		box.add_child(row)


func _row(box: VBoxContainer, label_text: String) -> HBoxContainer:
	var row := HBoxContainer.new()
	var lbl := Label.new()
	lbl.text = label_text
	lbl.custom_minimum_size = Vector2(150.0, 0.0)
	row.add_child(lbl)
	box.add_child(row)
	return row


func _add_option(
	box: VBoxContainer, label_text: String, items: Array, default: int, cb: Callable
) -> OptionButton:
	var row := _row(box, label_text)
	var opt := OptionButton.new()
	for item: String in items:
		opt.add_item(item)
	opt.selected = default
	opt.custom_minimum_size = Vector2(200.0, 0.0)
	opt.item_selected.connect(cb)
	row.add_child(opt)
	return opt


func _add_check(box: VBoxContainer, label_text: String, default: bool, cb: Callable) -> CheckButton:
	var row := _row(box, label_text)
	var chk := CheckButton.new()
	chk.button_pressed = default
	chk.toggled.connect(cb)
	row.add_child(chk)
	return chk


func _add_slider(
	box: VBoxContainer,
	label_text: String,
	min_v: float,
	max_v: float,
	step: float,
	default: float,
	cb: Callable
) -> HSlider:
	var row := _row(box, label_text)
	var slider := HSlider.new()
	slider.min_value = min_v
	slider.max_value = max_v
	slider.step = step
	slider.value = default
	slider.custom_minimum_size = Vector2(200.0, 0.0)
	slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	slider.value_changed.connect(cb)
	row.add_child(slider)
	return slider
