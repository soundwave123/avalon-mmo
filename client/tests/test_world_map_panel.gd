extends GutTest

# T-730: the full-screen world map panel — keybind registration on every surface, the keep-aspect
# fit transform, zone resolution + marker load against the shipped docs, and the observe() hook
# visual QA reads (marker presence without a screenshot, T-559).

const WorldMapPanelT = preload("res://scripts/ui/world_map_panel.gd")
const ControlsReferenceT = preload("res://scripts/ui/controls_reference.gd")
const SettingsPanelT = preload("res://scripts/ui/settings_panel.gd")


func test_world_map_key_registered_on_every_keybind_surface() -> void:
	# T-723 idiom: the F1 handbook derives its label from the same keycode the panel dispatches on.
	var found := false
	for row: Dictionary in ControlsReferenceT.rows():
		if str(row["action"]) == "World map":
			found = true
			assert_eq(str(row["keys_label"]), OS.get_keycode_string(WorldMapPanelT.TOGGLE_KEYCODE))
	assert_true(found, "ControlsReference must list the World map binding")
	# And the Esc->Options keybind list carries the same row.
	var in_settings := false
	for bind: Array in SettingsPanelT.KEYBINDS:
		if str(bind[0]) == "World map":
			in_settings = true
			assert_eq(str(bind[1]), "T")
	assert_true(in_settings, "SettingsPanel.KEYBINDS must list the World map binding")


func test_toggle_key_is_not_taken_by_main_dispatch() -> void:
	# T is free: not an ability slot, and not one of main._input's literal panel keys.
	assert_eq(AbilityKeybinds.slot_for_keycode(WorldMapPanelT.TOGGLE_KEYCODE), -1)
	var taken := [KEY_L, KEY_C, KEY_I, KEY_N, KEY_M, KEY_TAB, KEY_QUOTELEFT, KEY_ESCAPE]
	assert_false(WorldMapPanelT.TOGGLE_KEYCODE in taken)


func test_fit_rect_keeps_aspect_and_centers() -> void:
	# A square zone in a wide viewport: height-bound, horizontally centered.
	var fit: Rect2 = WorldMapPanelT.fit_rect(Vector2(1000.0, 1000.0), Rect2(0.0, 0.0, 800.0, 400.0))
	assert_eq(fit.size, Vector2(400.0, 400.0))
	assert_eq(fit.position, Vector2(200.0, 0.0))
	# A tall zone in the same viewport keeps its aspect too.
	var tall: Rect2 = WorldMapPanelT.fit_rect(Vector2(500.0, 1000.0), Rect2(0.0, 0.0, 800.0, 400.0))
	assert_eq(tall.size, Vector2(200.0, 400.0))


func test_refresh_zone_resolves_frame_and_markers_from_shipped_docs() -> void:
	var panel = add_child_autofree(WorldMapPanelT.new())
	panel.setup(
		{
			"player_pos": func() -> Vector3: return Vector3(0.0, 0.0, 100.0),  # open Heartwold vale
			"player_yaw": func() -> float: return 0.0,
		}
	)
	panel.refresh_zone()
	var obs: Dictionary = panel.observe()
	assert_eq(str(obs["zone"]), "heartwold")
	assert_false(bool(obs["open"]))
	# The T-730 DoD marker classes all present on the frame.
	for kind in ["hub", "dungeon", "flight", "landmark"]:
		assert_gt(int(obs["marker_kinds"].get(kind, 0)), 0, "missing kind on the vale map: " + kind)
	assert_has(obs["marker_names"], "Elmsvale Village")
	# Inside the city walls the SMALLER frame wins (Highkeep is the T-730 DoD city zone).
	panel.setup({"player_pos": func() -> Vector3: return Vector3(0.0, 0.0, -240.0)})
	panel.refresh_zone()
	assert_eq(str(panel.observe()["zone"]), "highkeep")


func test_toggle_reports_open_in_observe() -> void:
	var panel = add_child_autofree(WorldMapPanelT.new())
	panel.setup({"player_pos": func() -> Vector3: return Vector3.ZERO})
	assert_false(panel.visible)
	panel.toggle()
	assert_true(panel.visible)
	assert_true(bool(panel.observe()["open"]))
	panel.toggle()
	assert_false(panel.visible)
