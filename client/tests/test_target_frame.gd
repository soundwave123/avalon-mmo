extends GutTest
# T-283: the target frame's bind/clear model — name, hp fraction, and relationship color.
# The render path guards on null nodes, so the state model tests with no scene tree.

const TargetFrame = preload("res://scripts/ui/target_frame.gd")
const PlayerHud = preload("res://scripts/ui/player_hud.gd")
const HintToast = preload("res://scripts/ui/hint_toast.gd")
const Rel = preload("res://scripts/world/relationship.gd")


func test_binds_name_and_hp_fraction() -> void:
	var f: TargetFrame = TargetFrame.new()
	f.bind_target("Wolf", 30, 120, Rel.HOSTILE_PLATE, 7)
	assert_true(f.is_bound())
	assert_eq(f.unit_name(), "Wolf")
	assert_eq(f.unit_level(), 7, "server-reported target level is retained for the frame")
	assert_almost_eq(f.fill_ratio(), 0.25, 0.01, "hp fraction is 30/120")
	assert_eq(f.health_text(), "30 / 120", "exact current/max health stays glanceable")


func test_hostile_color_is_red() -> void:
	var f: TargetFrame = TargetFrame.new()
	f.bind_target("Wolf", 100, 100, Rel.plate_color(Rel.Rel.HOSTILE))
	assert_true(f.fill_color().r > f.fill_color().g, "a hostile target's bar is red")


func test_friendly_color_is_green() -> void:
	var f: TargetFrame = TargetFrame.new()
	f.bind_target("Ally", 100, 100, Rel.plate_color(Rel.Rel.FRIENDLY))
	assert_true(f.fill_color().g > f.fill_color().r, "a friendly target's bar is green")


func test_clear_unbinds() -> void:
	var f: TargetFrame = TargetFrame.new()
	f.bind_target("Wolf", 30, 120, Rel.HOSTILE_PLATE)
	f.clear()
	assert_false(f.is_bound(), "clear() unbinds the frame (hidden when live)")


func test_zero_max_hp_is_empty_not_a_crash() -> void:
	var f: TargetFrame = TargetFrame.new()
	f.bind_target("Unknown", 0, 0, Rel.HOSTILE_PLATE)
	assert_true(f.is_bound(), "still bound (name shows) even with no resources")
	assert_almost_eq(f.fill_ratio(), 0.0, 0.01, "no max_hp -> empty bar, no divide-by-zero")


func test_player_hud_tracks_server_mob_snapshot_health_and_level() -> void:
	var viewport_root := Control.new()
	viewport_root.size = Vector2(1280, 720)
	add_child_autofree(viewport_root)
	var hud: PlayerHud = PlayerHud.new()
	viewport_root.add_child(hud)
	await get_tree().process_frame
	var snapshot := {
		"players": [],
		"mobs":
		[
			{
				"mob_id": 1001,
				"kind": "mob_wolf",
				"name": "Gray Wolf",
				"level": 7,
				"hp": 80,
				"max_hp": 100,
			}
		],
	}
	assert_true(hud.update_target(1001, 99, snapshot))
	assert_eq(hud.target_frame.unit_name(), "Gray Wolf")
	assert_eq(hud.target_frame.unit_level(), 7)
	assert_almost_eq(hud.target_frame.fill_ratio(), 0.8, 0.001)
	await get_tree().process_frame  # Control layout resolves after the hidden frame is shown.
	var gradient := hud.target_frame.get_node("TargetGradient") as TextureRect
	assert_eq(gradient.size, Vector2(260, 62), "de-boxed gradient fills the frame under Godot 4.7")
	assert_lt(
		hud.target_frame.position.x, hud.compass.position.x, "target status is left of compass"
	)
	snapshot["mobs"][0]["hp"] = 25
	assert_true(hud.update_target(1001, 99, snapshot))
	assert_almost_eq(
		hud.target_frame.fill_ratio(), 0.25, 0.001, "later server HP visibly shrinks fill"
	)


func test_player_hud_shows_and_hides_target_of_target_from_server_snapshot() -> void:
	var viewport_root := Control.new()
	viewport_root.size = Vector2(1280, 720)
	add_child_autofree(viewport_root)
	var hud: PlayerHud = PlayerHud.new()
	viewport_root.add_child(hud)
	await get_tree().process_frame
	var snapshot := {
		"players":
		[
			{
				"peer_id": 99,
				"username": "Tank",
				"level": 8,
				"hp": 70,
				"max_hp": 120,
			}
		],
		"mobs":
		[
			{
				"mob_id": 1001,
				"name": "Gray Wolf",
				"hp": 80,
				"max_hp": 100,
				"target_id": 99,
			}
		],
	}
	assert_true(hud.update_target(1001, 99, snapshot))
	assert_true(hud.target_of_target_frame.is_bound(), "mob target_id binds the compact frame")
	assert_eq(hud.target_of_target_frame.unit_name(), "Tank")
	assert_eq(hud.target_of_target_frame.health_text(), "70 / 120")
	assert_lt(
		hud.target_of_target_frame.size.x,
		hud.target_frame.size.x,
		"target-of-target is the smaller secondary frame"
	)

	snapshot["mobs"][0].erase("target_id")
	assert_true(hud.update_target(1001, 99, snapshot))
	assert_false(
		hud.target_of_target_frame.is_bound(), "missing target_id clears and hides target-of-target"
	)


func test_hint_toast_does_not_overlap_target_frame_on_lock() -> void:
	var viewport_root := Control.new()
	viewport_root.size = Vector2(1280, 720)
	add_child_autofree(viewport_root)
	var hud: PlayerHud = PlayerHud.new()
	viewport_root.add_child(hud)
	var toast := HintToast.new()
	viewport_root.add_child(toast)
	await get_tree().process_frame

	hud.target_frame.bind_target("Gray Wolf", 80, 80, Rel.HOSTILE_PLATE, 1)
	toast.show_hint("Target locked -- press 1-4 to use an ability, or `1` to auto-attack.")
	await get_tree().process_frame

	assert_false(
		hud.target_frame.get_global_rect().intersects(toast.get_global_rect()),
		"target-lock hint must not cover the target frame name/level row"
	)


# T-505: player + target frames form the conventional top-left status cluster. The target stays
# de-boxed: its bar and outlined text provide legibility, not a filled Panel behind the whole frame.
func test_player_and_target_frames_form_deboxed_top_left_cluster() -> void:
	var viewport_root := Control.new()
	viewport_root.size = Vector2(1920, 1080)
	add_child_autofree(viewport_root)
	var hud: PlayerHud = PlayerHud.new()
	viewport_root.add_child(hud)
	await get_tree().process_frame

	var vitals_rect := hud.vitals.get_global_rect()
	var target_rect := hud.target_frame.get_global_rect()
	assert_lt(vitals_rect.position.y, 100.0, "player vitals move into the conventional top-left")
	assert_lt(target_rect.position.y, 100.0, "target status shares the top-left band")
	assert_gt(
		target_rect.position.x, vitals_rect.end.x, "target frame sits adjacent to player vitals"
	)
	assert_lt(
		absf(target_rect.position.y - vitals_rect.position.y),
		8.0,
		"player and target frames align as one glanceable cluster"
	)
	for child in hud.target_frame.get_children():
		assert_false(child is Panel, "target frame has no filled whole-surface panel")


# ---- T-736: the frame's right-click affordance -------------------------------------------


func _tf_rmb(pressed: bool, global_pos: Vector2) -> InputEventMouseButton:
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_RIGHT
	ev.pressed = pressed
	ev.global_position = global_pos
	return ev


func test_frame_root_stops_mouse_for_its_own_right_click() -> void:
	var f: TargetFrame = TargetFrame.new()
	add_child_autofree(f)  # _ready applies the filter + connects gui_input
	assert_eq(f.mouse_filter, Control.MOUSE_FILTER_STOP, "root owns clicks now (T-736)")


func test_right_click_release_on_frame_emits_with_screen_pos() -> void:
	var f: TargetFrame = TargetFrame.new()
	add_child_autofree(f)
	watch_signals(f)
	f._on_gui_input(_tf_rmb(true, Vector2(300, 40)))
	f._on_gui_input(_tf_rmb(false, Vector2(302, 41)))  # within click slop
	assert_signal_emitted(f, "right_clicked")


func test_right_drag_off_the_frame_is_not_a_click() -> void:
	var f: TargetFrame = TargetFrame.new()
	add_child_autofree(f)
	watch_signals(f)
	f._on_gui_input(_tf_rmb(true, Vector2(300, 40)))
	f._on_gui_input(_tf_rmb(false, Vector2(340, 60)))  # dragged well past the slop
	assert_signal_not_emitted(f, "right_clicked", "a drag is neither click nor look")
	f._on_gui_input(_tf_rmb(false, Vector2(340, 60)))  # stray release with no press: no-op
	assert_signal_not_emitted(f, "right_clicked")
