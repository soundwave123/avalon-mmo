extends "res://addons/gut/test.gd"
# T-608/T-634: HudSafeZone is the shared source of truth every offending panel/toast now reads
# from (quest_log_panel.gd, character_sheet_panel.gd, talent_panel.gd, death_presentation.gd via
# performance_recap_panel.gd's centering). These tests pin its rects against the REAL chrome nodes
# so a future edit to player_hud.gd/action_bar.gd/compass_strip.gd can't silently drift the shared
# constants out of sync with what's actually on screen.
#
# T-747 UNPINNED. Every test here used to build a harness root sized to a LITERAL Vector2(1280,720)
# — a resolution the shipped client never ran at, since project.godot declared a 1920x1080 viewport
# with no stretch keys at all. So the suite proved the constants were self-consistent with each
# other; it could not prove they were TRUE, and in fact they were wrong at every real resolution.
#
# The base is real now (canvas_items stretch at a 1280x720 content base), so the harness root is
# sized from the LIVE content rect instead of a literal. That inverts what a base change costs: it
# now fails these tests loudly rather than silently invalidating every reserved rect on screen.

const PlayerHudScene = preload("res://scripts/ui/player_hud.gd")
const ActionBarScene = preload("res://scripts/ui/action_bar.gd")
const CompassStripScene = preload("res://scripts/ui/compass_strip.gd")


# A harness root at the REAL content base. normalize_headless matters: a headless window boots
# 64x64, and under `expand` that resolves the content rect to the window's aspect (1280x1280), not
# the authored base.
func _base_root() -> Control:
	UiViewport.normalize_headless(self)
	await get_tree().process_frame
	var root := Control.new()
	root.size = get_tree().root.get_visible_rect().size
	add_child_autofree(root)
	return root


func test_the_live_content_base_is_what_these_constants_were_authored_against() -> void:
	# The assertion the old fake root made impossible. If project.godot's base ever moves, every
	# rect below is wrong by construction — so fail here first, with a message that says why.
	UiViewport.normalize_headless(self)
	await get_tree().process_frame
	assert_eq(
		get_tree().root.get_visible_rect().size,
		Vector2(HudSafeZone.BASE_WIDTH, HudSafeZone.BASE_HEIGHT),
		"the client's content base IS the base every reserved rect is measured in",
	)


func test_vitals_rect_matches_the_live_vitals_frame_and_autoattack_pip() -> void:
	var root := await _base_root()
	var hud = PlayerHudScene.new()
	root.add_child(hud)
	await get_tree().process_frame
	var vitals_rect: Rect2 = hud.vitals.get_global_rect()
	var pip_rect: Rect2 = (hud.autoattack_indicator as Control).get_global_rect()
	var combined := vitals_rect.merge(pip_rect)
	assert_eq(HudSafeZone.VITALS_RECT, combined, "the reserved rect matches the real chrome")


func test_action_bar_rect_matches_the_live_bar_at_max_slots() -> void:
	var root := await _base_root()
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
	var root := await _base_root()
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


# ---- T-738: the minimap corner reservation ----


func test_minimap_rect_matches_the_live_minimap_panel() -> void:
	var root := await _base_root()
	var minimap = preload("res://scripts/ui/minimap_panel.gd").new()
	root.add_child(minimap)
	await get_tree().process_frame
	assert_eq(HudSafeZone.MINIMAP_RECT, minimap.get_global_rect())


func test_minimap_rect_clears_every_other_reserved_rect() -> void:
	var mm := HudSafeZone.MINIMAP_RECT
	assert_false(HudSafeZone.intersects_vitals(mm))
	assert_false(HudSafeZone.intersects_action_bar(mm))
	assert_false(HudSafeZone.intersects_compass(mm))
	# And it sits inside the 1280x720 base frame.
	assert_true(Rect2(0.0, 0.0, HudSafeZone.BASE_WIDTH, HudSafeZone.BASE_HEIGHT).encloses(mm))
	assert_true(HudSafeZone.intersects_minimap(mm.grow(-2.0)))


# ---- T-747: the `expand` caveat — only the base HEIGHT is guaranteed ----


# The constants above are a 16:9 snapshot. On an ultrawide the content rect grows sideways and the
# centre- and right-anchored chrome slides with it, so the bare constants stop describing the real
# chrome. This asserts the width-aware accessors against the LIVE nodes at a 21:9 content width —
# i.e. it proves the adjustment, not just that the arithmetic is self-consistent.
func test_width_aware_rects_track_the_live_chrome_on_an_ultrawide() -> void:
	var ultrawide := 1706.0  # 21:9 at a 720 base height
	var root := Control.new()
	root.size = Vector2(ultrawide, HudSafeZone.BASE_HEIGHT)
	add_child_autofree(root)
	var bar = ActionBarScene.new()
	root.add_child(bar)
	var kit: Array = []
	for i in range(ActionBar.MAX_SLOTS):
		kit.append({"id": "ability_%d" % i, "name": "Ability %d" % i, "icon": ""})
	bar.set_kit(kit)
	var compass = CompassStripScene.new()
	root.add_child(compass)
	var minimap = preload("res://scripts/ui/minimap_panel.gd").new()
	root.add_child(minimap)
	var hud = PlayerHudScene.new()
	root.add_child(hud)
	await get_tree().process_frame

	assert_eq(HudSafeZone.action_bar_rect(ultrawide), bar.get_global_rect(), "centre-anchored bar")
	assert_eq(HudSafeZone.compass_rect(ultrawide), compass.get_global_rect(), "centre-anchored")
	assert_eq(HudSafeZone.minimap_rect(ultrawide), minimap.get_global_rect(), "right-anchored")
	assert_eq(
		HudSafeZone.vitals_rect(ultrawide),
		hud.vitals.get_global_rect().merge((hud.autoattack_indicator as Control).get_global_rect()),
		"left-anchored vitals genuinely does not move",
	)
	# And the bare constants would have been wrong here — that is the whole point.
	assert_ne(HudSafeZone.minimap_rect(ultrawide), HudSafeZone.MINIMAP_RECT)


func test_omitting_the_width_gives_the_shipped_16_9_case() -> void:
	assert_eq(HudSafeZone.action_bar_rect(), HudSafeZone.ACTION_BAR_RECT)
	assert_eq(HudSafeZone.compass_rect(), HudSafeZone.COMPASS_RECT)
	assert_eq(HudSafeZone.minimap_rect(), HudSafeZone.MINIMAP_RECT)
	assert_eq(HudSafeZone.vitals_rect(), HudSafeZone.VITALS_RECT)
