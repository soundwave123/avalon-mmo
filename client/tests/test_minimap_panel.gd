extends GutTest

# T-738: the corner minimap — settings persistence round-trip through SettingsPanel (the one
# settings.cfg writer), zoom-step behavior, edge-of-zone window clamping, and the DoD assertion
# that BOTH map surfaces read the same marker pipeline (no duplicated POI lists).

const MinimapPanelT = preload("res://scripts/ui/minimap_panel.gd")
const WorldMapPanelT = preload("res://scripts/ui/world_map_panel.gd")
const SettingsPanelT = preload("res://scripts/ui/settings_panel.gd")
const TMP_CFG := "user://test_minimap_settings.cfg"


func after_each() -> void:
	if FileAccess.file_exists(TMP_CFG):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(TMP_CFG))


func test_both_map_surfaces_share_one_marker_pipeline() -> void:
	# The T-738 DoD: assert no duplicated POI pipeline — both panels' MARKER_SOURCE is the SAME
	# script object (map_markers.gd), so a marker can only ever be derived one way.
	assert_true(
		MinimapPanelT.MARKER_SOURCE == WorldMapPanelT.MARKER_SOURCE,
		"world map and minimap must read the same MapMarkers pipeline"
	)


func test_apply_settings_round_trip_and_zoom_clamp() -> void:
	var mm = add_child_autofree(MinimapPanelT.new())
	mm.apply_settings(false, true, 2)
	assert_false(mm.visible)
	assert_true(mm.rotate_mode)
	assert_eq(mm.zoom_idx, 2)
	# Out-of-range zoom steps clamp to the table.
	mm.apply_settings(true, false, 99)
	assert_eq(mm.zoom_idx, MinimapPanelT.ZOOM_RADII.size() - 1)
	mm.apply_settings(true, false, -5)
	assert_eq(mm.zoom_idx, 0)


func test_zoom_change_fires_the_persistence_callback() -> void:
	var mm = add_child_autofree(MinimapPanelT.new())
	var seen := []
	mm.setup({}, func(idx: int) -> void: seen.append(idx))
	mm.apply_settings(true, false, 1)
	mm._set_zoom(0)
	assert_eq(seen, [0])
	mm._set_zoom(0)  # unchanged -> no duplicate persistence write
	assert_eq(seen, [0])


func test_window_center_clamps_inside_the_zone_frame() -> void:
	var mm = add_child_autofree(MinimapPanelT.new())
	mm._zone = {"id": "vale", "rect": Rect2(-500.0, -500.0, 1000.0, 1000.0)}
	# Mid-zone: the window centers on the player.
	assert_eq(mm._window_center(Vector3(10.0, 0.0, 20.0), 40.0), Vector2(10.0, 20.0))
	# At the west edge: the window clamps so the crop never samples off the baked frame
	# (radius 40 * OVERSIZE 1.5 = 60 m of margin).
	var clamped: Vector2 = mm._window_center(Vector3(-495.0, 0.0, 0.0), 40.0)
	assert_eq(clamped, Vector2(-440.0, 0.0))


func test_settings_panel_persists_minimap_state_round_trip() -> void:
	var panel_a = add_child_autofree(SettingsPanelT.new())
	panel_a._minimap_visible_check.button_pressed = false
	panel_a._minimap_rotate_check.button_pressed = true
	panel_a._minimap_zoom = 2
	panel_a.save(TMP_CFG)
	var panel_b = add_child_autofree(SettingsPanelT.new())
	panel_b.load_settings(TMP_CFG)
	assert_false(panel_b._minimap_visible_check.button_pressed)
	assert_true(panel_b._minimap_rotate_check.button_pressed)
	assert_eq(panel_b._minimap_zoom, 2)


func test_bound_minimap_receives_restored_settings() -> void:
	var panel_a = add_child_autofree(SettingsPanelT.new())
	panel_a._minimap_visible_check.button_pressed = false
	panel_a._minimap_rotate_check.button_pressed = true
	panel_a._minimap_zoom = 0
	panel_a.save(TMP_CFG)
	var panel_b = add_child_autofree(SettingsPanelT.new())
	var mm = add_child_autofree(MinimapPanelT.new())
	panel_b.bind_minimap(mm)
	panel_b.load_settings(TMP_CFG)
	assert_false(mm.visible)
	assert_true(mm.rotate_mode)
	assert_eq(mm.zoom_idx, 0)
	# The wheel path: MinimapPanel._set_zoom -> the persistence callback (proven above) -> the
	# panel's _minimap_zoom -> save/load (proven by the round-trip test). Here: the field updates
	# and re-saving to the TEMP path carries it (never the real user config from a test).
	panel_b._minimap_zoom = 2
	panel_b.save(TMP_CFG)
	var panel_d = add_child_autofree(SettingsPanelT.new())
	panel_d.load_settings(TMP_CFG)
	assert_eq(panel_d._minimap_zoom, 2)


func test_observe_reports_mode_zoom_and_zone() -> void:
	var mm = add_child_autofree(MinimapPanelT.new())
	mm.apply_settings(true, true, 0)
	mm._zone = {"id": "vale", "rect": Rect2(-500.0, -500.0, 1000.0, 1000.0)}
	var obs: Dictionary = mm.observe()
	assert_true(bool(obs["visible"]))
	assert_true(bool(obs["rotate"]))
	assert_eq(int(obs["zoom"]), 0)
	assert_eq(float(obs["radius_m"]), float(MinimapPanelT.ZOOM_RADII[0]))
	assert_eq(str(obs["zone"]), "vale")
