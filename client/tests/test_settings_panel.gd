extends GutTest

# T-078: the settings/options menu is built in code, so its wiring is headlessly unit-testable
# (add_child_autofree → _ready builds the controls + loads any saved config). These prove the panel
# structure, toggle(), a config save→load round-trip, and that a quality preset actually moves the
# WorldView environment knobs. The live rendering/audio effect is play-test-verified.

const SettingsPanel = preload("res://scripts/ui/settings_panel.gd")
const WorldView = preload("res://scripts/world/world_view.gd")
const WorldPropsLayer = preload("res://scripts/world/world_props_layer.gd")
const LodPolicy = preload("res://scripts/world/lod_policy.gd")
const TMP_CFG := "user://test_settings_roundtrip.cfg"
const ROCK := "res://assets/models/prop_rock_a.glb"  # tiny manifest for the WorldProps push test


func _panel():
	var p = SettingsPanel.new()
	add_child_autofree(p)  # _ready builds the controls + loads any saved config
	return p


# T-756: this suite used to clobber the developer's REAL user://settings.cfg. Two routes:
# _ready() calls load_settings() on the default path, and — the destructive one — assigning
# a control's value directly (`_vsync_check.button_pressed = false`) emits its changed signal,
# which runs the panel's handler, which calls save() with the DEFAULT path. Every round-trip
# test overwrote the real file with test values. Snapshot it and put it back byte-for-byte.
var _real_cfg_existed := false
var _real_cfg_backup := ""


func before_each() -> void:
	_real_cfg_existed = FileAccess.file_exists(SettingsPanel.CONFIG_PATH)
	_real_cfg_backup = ""
	if _real_cfg_existed:
		_real_cfg_backup = FileAccess.get_file_as_string(SettingsPanel.CONFIG_PATH)


func after_each() -> void:
	if FileAccess.file_exists(TMP_CFG):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(TMP_CFG))
	LocalPlayer.sensitivity_mult = 1.0  # restore the shared default touched by the sensitivity test
	if _real_cfg_existed:
		var f := FileAccess.open(SettingsPanel.CONFIG_PATH, FileAccess.WRITE)
		if f != null:
			f.store_string(_real_cfg_backup)
			f.close()
	elif FileAccess.file_exists(SettingsPanel.CONFIG_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(SettingsPanel.CONFIG_PATH))


func test_panel_builds_all_controls() -> void:
	var p = _panel()
	assert_not_null(p._window_opt, "window mode dropdown")
	assert_not_null(p._vsync_check, "vsync toggle")
	assert_not_null(p._scale_slider, "render scale slider")
	assert_not_null(p._quality_opt, "quality preset dropdown")
	assert_not_null(p._master_slider, "master volume slider")
	assert_not_null(p._ambience_slider, "ambience volume slider")
	assert_not_null(p._sfx_slider, "sfx volume slider")
	assert_not_null(p._sens_slider, "mouse sensitivity slider")
	assert_eq(p._quality_opt.item_count, 4, "Low/Medium/High/Ultra presets")
	assert_eq(p._window_opt.item_count, 2, "windowed / fullscreen")


func test_toggle_shows_and_hides() -> void:
	var p = _panel()
	assert_false(p.visible, "starts hidden (opened with Esc)")
	p.toggle()
	assert_true(p.visible, "toggle opens it")
	p.toggle()
	assert_false(p.visible, "toggle closes it")


func test_settings_round_trip() -> void:
	var p = _panel()
	# T-756: no_signal setters. A plain `.value =` / `.button_pressed =` fires the control's
	# changed signal, which runs the panel's handler, which calls save() on the DEFAULT path —
	# so this round-trip test used to write the real settings.cfg as a side effect. This test is
	# about save(TMP_CFG) → load_settings(TMP_CFG); the handlers are not part of that claim and
	# are covered separately by the apply tests below.
	p._window_opt.selected = 1  # OptionButton.selected does not emit item_selected
	p._vsync_check.set_pressed_no_signal(false)
	p._scale_slider.set_value_no_signal(0.75)
	p._quality_opt.selected = 1
	p._master_slider.set_value_no_signal(42.0)
	p._ambience_slider.set_value_no_signal(30.0)
	p._sfx_slider.set_value_no_signal(66.0)
	p._sens_slider.set_value_no_signal(2.5)
	p.save(TMP_CFG)

	var q = _panel()
	q.load_settings(TMP_CFG)
	assert_eq(q._window_opt.selected, 1, "window mode round-trips")
	assert_false(q._vsync_check.button_pressed, "vsync round-trips")
	assert_almost_eq(q._scale_slider.value, 0.75, 0.001, "render scale round-trips")
	assert_eq(q._quality_opt.selected, 1, "quality round-trips")
	assert_almost_eq(q._master_slider.value, 42.0, 0.001, "master round-trips")
	assert_almost_eq(q._ambience_slider.value, 30.0, 0.001, "ambience round-trips")
	assert_almost_eq(q._sfx_slider.value, 66.0, 0.001, "sfx round-trips")
	assert_almost_eq(q._sens_slider.value, 2.5, 0.001, "sensitivity round-trips")


func test_quality_preset_changes_environment() -> void:
	var p = _panel()
	var wv = WorldView.new()
	add_child_autofree(wv)  # builds the env + sun
	p.setup(wv, null)  # null audio → the audio setters are safely skipped
	var env: Environment = wv.world_environment.environment

	p._quality_opt.selected = 3  # Ultra
	p._apply_quality()
	assert_true(env.ssao_enabled, "ultra: ssao on")
	assert_true(env.sdfgi_enabled, "ultra: sdfgi on")
	assert_true(env.ssr_enabled, "ultra: ssr on")
	assert_true(
		env.volumetric_fog_enabled,
		"ultra: volumetric fog on (AAA-spec pass; T-170 disable retired)"
	)

	p._quality_opt.selected = 0  # Low
	p._apply_quality()
	assert_false(env.ssao_enabled, "low: ssao off (changed from ultra)")
	assert_false(env.sdfgi_enabled, "low: sdfgi off (changed from ultra)")
	assert_false(env.ssr_enabled, "low: ssr off (changed from ultra)")
	assert_false(env.volumetric_fog_enabled, "low: volumetric fog off (perf tier)")


# ---- T-692 Part B: asset-loading preset knobs ----


func test_presets_resolve_the_full_asset_loading_knob_set() -> void:
	var flora_density := [0.5, 0.75, 1.0, 1.0]
	var lod_mult := [0.55, 0.8, 1.0, 1.25]
	var flora_ring := [190.0, 275.0, 340.0, 425.0]
	var mesh_lod := [4.0, 2.0, 1.0, 1.0]
	var splits := [
		DirectionalLight3D.SHADOW_ORTHOGONAL,
		DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS,
		DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS,
		DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS,
	]
	var atlas := [2048, 4096, 4096, 8192]
	for t in 4:
		var p: Dictionary = SettingsPanel.QUALITY_PRESETS[t]
		assert_almost_eq(float(p["flora_density"]), flora_density[t], 0.001, "density tier %d" % t)
		assert_almost_eq(float(p["lod_mult"]), lod_mult[t], 0.001, "lod_mult tier %d" % t)
		assert_almost_eq(float(p["flora_ring"]), flora_ring[t], 0.001, "flora_ring tier %d" % t)
		assert_almost_eq(
			float(p["building_ring"]), 900.0, 0.001, "building ring pinned at 900 on tier %d" % t
		)
		assert_almost_eq(
			float(p["mesh_lod_threshold"]), mesh_lod[t], 0.001, "mesh LOD threshold tier %d" % t
		)
		assert_eq(int(p["shadow_splits"]), splits[t], "shadow split count tier %d" % t)
		assert_eq(int(p["shadow_atlas"]), atlas[t], "shadow atlas size tier %d" % t)


func test_flora_ring_stays_ahead_of_the_scaled_tree_cull_at_every_tier() -> void:
	# The T-594 zero-pop-in invariant per tier: stream-out must sit beyond the longest scaled
	# cull distance (trees, 320 x lod_mult), so nothing visible ever streams out.
	for t in 4:
		var p: Dictionary = SettingsPanel.QUALITY_PRESETS[t]
		var cull := LodPolicy.cull_distance("prop_oak_real.glb", float(p["lod_mult"]))
		assert_gt(
			float(p["flora_ring"]), cull, "tier %d flora ring exceeds the scaled tree cull" % t
		)


func test_default_quality_is_high_and_auto_detect_tiers_by_adapter_type() -> void:
	assert_eq(SettingsPanel.DEFAULT_QUALITY, 2, "the default tier is High — Ultra is an opt-up")
	assert_eq(
		SettingsPanel.tier_for_adapter(RenderingDevice.DEVICE_TYPE_DISCRETE_GPU),
		2,
		"discrete GPU -> High"
	)
	assert_eq(
		SettingsPanel.tier_for_adapter(RenderingDevice.DEVICE_TYPE_INTEGRATED_GPU),
		1,
		"integrated GPU -> Medium"
	)
	assert_eq(
		SettingsPanel.tier_for_adapter(RenderingDevice.DEVICE_TYPE_VIRTUAL_GPU), 0, "virtual -> Low"
	)
	assert_eq(SettingsPanel.tier_for_adapter(RenderingDevice.DEVICE_TYPE_CPU), 0, "cpu -> Low")
	assert_eq(
		SettingsPanel.tier_for_adapter(RenderingDevice.DEVICE_TYPE_OTHER), 0, "unknown -> Low"
	)


func test_quality_preset_pushes_asset_cfg_to_the_props_layer() -> void:
	var p = _panel()
	var wv = WorldView.new()
	add_child_autofree(wv)
	var props := WorldPropsLayer.new()
	props.name = "WorldProps"
	props._batching = false
	props.load_manifest([{"scene": ROCK, "x": 0.0, "y": 0.0}])
	wv.add_child(props)  # freed with the autofreed WorldView
	p.setup(wv, null)
	p._quality_opt.selected = 0  # Low
	p._apply_quality()
	assert_almost_eq(float(props._cfg["flora_ring"]), 190.0, 0.001, "Low pulls the flora ring in")
	assert_almost_eq(float(props._cfg["flora_density"]), 0.5, 0.001, "Low thins the carpet")
	assert_almost_eq(float(props._cfg["lod_mult"]), 0.55, 0.001, "Low scales the cull distances")
	assert_almost_eq(
		float(props._cfg["building_ring"]), 900.0, 0.001, "the building ring never drops"
	)
	p._quality_opt.selected = 3  # Ultra
	p._apply_quality()
	assert_almost_eq(float(props._cfg["flora_ring"]), 425.0, 0.001, "Ultra pushes the ring out")
	assert_almost_eq(float(props._cfg["flora_density"]), 1.0, 0.001, "Ultra restores full density")


func test_quality_preset_drives_shadow_splits_and_distance() -> void:
	var p = _panel()
	var wv = WorldView.new()
	add_child_autofree(wv)
	p.setup(wv, null)
	p._quality_opt.selected = 0  # Low
	p._apply_quality()
	assert_eq(
		wv.sun.directional_shadow_mode,
		DirectionalLight3D.SHADOW_ORTHOGONAL,
		"Low: a single shadow split"
	)
	assert_almost_eq(wv.sun.directional_shadow_max_distance, 60.0, 0.01, "Low: 60 m shadows")
	p._quality_opt.selected = 3  # Ultra
	p._apply_quality()
	assert_eq(
		wv.sun.directional_shadow_mode,
		DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS,
		"Ultra: the authored 4-split baseline"
	)
	assert_almost_eq(wv.sun.directional_shadow_max_distance, 220.0, 0.01, "Ultra: authored 220 m")


func test_theme_applied() -> void:
	# T-308: the panel carries the shared UiTheme so it reads as one HUD (parchment/iron/gold),
	# and that theme propagates the forged-iron PanelContainer stylebox.
	var p = _panel()
	assert_not_null(p.theme, "UiTheme applied to the panel root")
	assert_true(
		p.theme.has_stylebox("panel", "PanelContainer"), "theme carries the framed panel stylebox"
	)


func test_keybind_reference_present() -> void:
	# T-078 Controls display: a read-only core-bind list ships now (remapping deferred).
	var p = _panel()
	assert_true(p.KEYBINDS.size() >= 6, "core keybinds listed")


func test_sensitivity_applies_to_local_player() -> void:
	var p = _panel()
	p._sens_slider.value = 2.0
	p._apply_sensitivity()
	assert_almost_eq(LocalPlayer.sensitivity_mult, 2.0, 0.001, "sensitivity feeds the mouse-look")


# T-400: the options window scrolls internally and never overflows the viewport (judge flag: it ran
# off the top AND bottom at 720p). The content lives inside a ScrollContainer (NOT a RichTextLabel,
# which collapses to zero size in that combo), and its height caps at ~viewport*0.9.
func test_options_has_internal_scroll() -> void:
	var p = _panel()
	await get_tree().process_frame
	assert_not_null(p._scroll, "internal ScrollContainer wraps the content")
	assert_eq(p._box.get_parent(), p._scroll, "the content column lives inside the scroll")


func test_options_height_capped_to_viewport() -> void:
	var p = _panel()
	await get_tree().process_frame
	# Inject a short viewport: the tall options column must cap below it (90%), leaving margin.
	p._apply_height_cap(300.0)
	var h: float = p._scroll.custom_minimum_size.y
	assert_gt(h, 0.0, "scroll has a measured, non-zero height (not the zero-size RTL trap)")
	assert_lte(h, 270.5, "window height capped at ~viewport*0.9 so it never overflows 720p")


func test_options_keeps_screen_edge_margin() -> void:
	var p = _panel()
	await get_tree().process_frame
	assert_gt(p.offset_left, 0.0, "options overlay has a left screen margin")
	assert_gt(p.offset_top, 0.0, "options overlay has a top screen margin")
