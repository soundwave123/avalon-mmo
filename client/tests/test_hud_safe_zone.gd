extends "res://addons/gut/test.gd"
# T-608/T-634: HudSafeZone is the shared source of truth every offending panel/toast now reads
# from (quest_log_panel.gd, character_sheet_panel.gd, talent_panel.gd, death_presentation.gd via
# performance_recap_panel.gd's centering). These tests pin its rects against the REAL chrome nodes
# so a future edit to player_hud.gd/action_bar.gd/compass_strip.gd can't silently drift the shared
# constants out of sync with what's actually on screen.

const PlayerHudScene = preload("res://scripts/ui/player_hud.gd")
const ActionBarScene = preload("res://scripts/ui/action_bar.gd")
const CompassStripScene = preload("res://scripts/ui/compass_strip.gd")


func test_vitals_rect_matches_the_live_vitals_frame_and_autoattack_pip() -> void:
	var root := Control.new()
	root.size = Vector2(1280, 720)
	add_child_autofree(root)
	var hud = PlayerHudScene.new()
	root.add_child(hud)
	await get_tree().process_frame
	var vitals_rect: Rect2 = hud.vitals.get_global_rect()
	var pip_rect: Rect2 = (hud.autoattack_indicator as Control).get_global_rect()
	var combined := vitals_rect.merge(pip_rect)
	assert_eq(HudSafeZone.VITALS_RECT, combined, "the reserved rect matches the real chrome")


func test_action_bar_rect_matches_the_live_bar_at_max_slots() -> void:
	var root := Control.new()
	root.size = Vector2(1280, 720)
	add_child_autofree(root)
	var bar = ActionBarScene.new()
	root.add_child(bar)
	var kit: Array = []
	for i in range(ActionBar.MAX_SLOTS):
		kit.append({"id": "ability_%d" % i, "name": "Ability %d" % i, "icon": ""})
	bar.set_kit(kit)
	await get_tree().process_frame
	assert_eq(
		HudSafeZone.ACTION_BAR_RECT,
		bar.get_global_rect(),
		"the reserved rect matches the hotbar at its widest (MAX_SLOTS)",
	)


func test_compass_rect_matches_the_live_compass_strip() -> void:
	var root := Control.new()
	root.size = Vector2(1280, 720)
	add_child_autofree(root)
	var compass = CompassStripScene.new()
	root.add_child(compass)
	await get_tree().process_frame
	assert_eq(HudSafeZone.COMPASS_RECT, compass.get_global_rect())


func test_intersects_helpers_agree_with_rect2_intersects() -> void:
	var overlapping := Rect2(0.0, 0.0, 50.0, 50.0)  # overlaps VITALS_RECT's top-left corner
	assert_true(HudSafeZone.intersects_vitals(overlapping))
	var clear := Rect2(0.0, 200.0, 50.0, 50.0)  # well below every reserved rect
	assert_false(HudSafeZone.intersects_vitals(clear))
	assert_false(HudSafeZone.intersects_action_bar(clear))
	assert_false(HudSafeZone.intersects_compass(clear))
