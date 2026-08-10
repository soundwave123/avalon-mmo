extends "res://addons/gut/test.gd"
# T-645 set mouse_filter=IGNORE on the OUTERMOST root of VitalsFrame/CompassStrip/XpBar only.
# T-651 (session-23 live-verify, portal #92) proved the inner Panel/PanelContainer/ProgressBar art
# underneath still defaulted to MOUSE_FILTER_STOP and physically ate world clicks — 3 of the 4
# surfaces T-645 claimed were fixed still swallowed a click at idle; only ChatPanel's history
# actually worked. The T-645 tests that used to live here only grepped the source TEXT for
# "mouse_filter = Control.MOUSE_FILTER_IGNORE" appearing ANYWHERE in the file — trivially satisfied
# by setting just the root, which is exactly how the incomplete fix shipped "DONE" undetected.
#
# These instantiate the REAL node tree (same add_child_autofree pattern test_vitals_frame.gd uses)
# and walk every descendant, so a future child silently added with (or defaulting to) STOP/PASS
# fails the test instead of quietly eating clicks again.

const VitalsFrame = preload("res://scripts/ui/vitals_frame.gd")
const CompassStrip = preload("res://scripts/ui/compass_strip.gd")
const XpBar = preload("res://scripts/ui/xp_bar.gd")


# Every Control anywhere under `root` (root included) that is NOT MOUSE_FILTER_IGNORE, by path —
# so a failure names the exact offending node rather than just "something failed".
func _stop_filtered_paths(root: Node) -> Array[String]:
	var bad: Array[String] = []
	if root is Control and (root as Control).mouse_filter != Control.MOUSE_FILTER_IGNORE:
		bad.append(str(root.get_path()))
	for child in root.get_children():
		bad.append_array(_stop_filtered_paths(child))
	return bad


func test_vitals_frame_every_control_is_click_through() -> void:
	var v := VitalsFrame.new()
	add_child_autofree(v)  # runs _ready -> builds the bars + T-651's deep IGNORE cascade
	var bad := _stop_filtered_paths(v)
	assert_eq(bad, [], "every Control under VitalsFrame must be click-through: %s" % [bad])


func test_compass_strip_every_control_is_click_through() -> void:
	var c := CompassStrip.new()
	add_child_autofree(c)
	var bad := _stop_filtered_paths(c)
	assert_eq(bad, [], "every Control under CompassStrip must be click-through: %s" % [bad])


func test_xp_bar_every_control_is_click_through() -> void:
	var x := XpBar.new()
	add_child_autofree(x)
	var bad := _stop_filtered_paths(x)
	assert_eq(bad, [], "every Control under XpBar must be click-through: %s" % [bad])


# ---- ChatPanel: deliberately dynamic filtering, not a static-IGNORE surface --------------------
# ChatPanel is the ONE surface that actually worked. Its idle history/tabs toggle IGNORE<->STOP
# with focus/hover (T-396's typing-summoned interactivity), so the static tree-walk used above
# (which would only ever observe the idle snapshot) doesn't fit; this drives the transition.
#
# T-756: this was a source-text grep — it opened chat_panel.gd and asserted the file CONTAINED
# the string `_tab_row.mouse_filter = mf`. That is the exact anti-pattern this file's own header
# condemns: it passes if the line exists inside an `if false:` block, if _apply_presence is never
# called, or if _tab_row is never built; and it fails the day someone renames a local variable
# while the behaviour is perfectly correct. It tested our source formatting, not our HUD.
# ChatPanel really is dynamic, so drive the transition instead of walking a static snapshot.
func test_chat_panel_updates_tab_row_mouse_filter() -> void:
	var panel := ChatPanel.new()
	add_child_autofree(panel)
	await get_tree().process_frame

	assert_not_null(panel._tab_row, "the tab row exists to be filtered")
	assert_false(panel.presence().is_interactive(), "a fresh panel starts idle")
	assert_eq(
		panel._tab_row.mouse_filter,
		Control.MOUSE_FILTER_IGNORE,
		"idle tabs never eat a world click (T-645)"
	)

	panel._on_input_focus_entered()
	assert_eq(
		panel._tab_row.mouse_filter,
		Control.MOUSE_FILTER_STOP,
		"summoning the input row makes the tabs clickable (T-645)"
	)

	panel._on_input_focus_exited()
	assert_eq(
		panel._tab_row.mouse_filter,
		Control.MOUSE_FILTER_IGNORE,
		"dismissing typing returns the tabs to click-through (T-645)"
	)


# ---- T-748: the sweep (audit item 3 / findings 4d-4g) -------------------------------------------
#
# Judged per surface, NOT blanket-applied: a WINDOW the player deliberately opened may keep a
# STOP root — blocking clicks over its own bounded rect is what a window IS (achievements, guild,
# cosmetic shop, character sheet, pvp, recipe, wardrobe, weekly all stay as they are). The three
# below are the surfaces that block input the player never asked them to block.

const PerformanceRecapPanel = preload("res://scripts/ui/performance_recap_panel.gd")
const ActionBar = preload("res://scripts/ui/action_bar.gd")
const LoadingScreen = preload("res://scripts/ui/loading_screen.gd")


# The recap AUTO-POPS after a kill, centred on screen, 480x280 opaque. Nothing in it is clickable,
# so it must not take the player's clicks — except the breakdown scroll, which keeps the wheel.
func test_performance_recap_only_its_scroll_takes_the_mouse() -> void:
	var p := PerformanceRecapPanel.new()
	add_child_autofree(p)
	var bad := _stop_filtered_paths(p)
	assert_eq(bad.size(), 1, "only ONE node in the recap may take a pick, got: %s" % [bad])
	var scroll: ScrollContainer = null
	for node in p.find_children("*", "ScrollContainer", true, false):
		scroll = node as ScrollContainer
	assert_not_null(scroll, "the ability breakdown scrolls")
	assert_eq(str(scroll.get_path()), bad[0], "the scroll is the one node that keeps STOP")


# The action bar's root band is stamped a few px wider than the slot row; the slots own the clicks.
func test_action_bar_root_band_is_click_through() -> void:
	var bar := ActionBar.new()
	add_child_autofree(bar)
	assert_eq(
		bar.mouse_filter,
		Control.MOUSE_FILTER_IGNORE,
		"the band behind/around the slots must not eat clicks"
	)


# The dismiss used to flip the root only, leaving the opaque full-rect Backdrop eating every click
# for the whole 0.45s fade — after the world was already playable.
func test_loading_screen_dismiss_makes_the_whole_overlay_click_through() -> void:
	var screen := LoadingScreen.new()
	add_child_autofree(screen)
	await get_tree().process_frame
	var before := _stop_filtered_paths(screen)
	assert_true(before.size() > 0, "while loading, the overlay legitimately blocks everything")
	screen._dismiss(false)  # save=false: never touch the real calibration file from a test
	var after := _stop_filtered_paths(screen)
	assert_eq(after, [], "mid-fade the overlay blocks nothing: %s" % [after])


# The other eight from the sweep are deliberately-summoned windows: a STOP root is CORRECT for them
# — but ONLY because each is a bounded box. A full-rect window root is the controls_card trap
# (T-748 fix 3) reappearing under another name, so pin the property that makes STOP defensible.
func test_summoned_windows_are_bounded_boxes_not_full_screen() -> void:
	var paths := [
		"res://scripts/ui/achievements_panel.gd",
		"res://scripts/ui/guild_panel.gd",
		"res://scripts/ui/cosmetic_shop_panel.gd",
		"res://scripts/ui/character_sheet_panel.gd",
		"res://scripts/ui/pvp_panel.gd",
		"res://scripts/ui/recipe_panel.gd",
		"res://scripts/ui/wardrobe_panel.gd",
		"res://scripts/ui/weekly_panel.gd",
	]
	for path: String in paths:
		var panel: Control = (load(path) as GDScript).new()
		add_child_autofree(panel)
		assert_false(panel.visible, "%s opens only when the player asks for it" % path)
		var full_rect := (
			panel.anchor_left == 0.0
			and panel.anchor_top == 0.0
			and panel.anchor_right == 1.0
			and panel.anchor_bottom == 1.0
			and panel.offset_left <= 0.0
			and panel.offset_top <= 0.0
			and panel.offset_right >= 0.0
			and panel.offset_bottom >= 0.0
		)
		assert_false(full_rect, "%s must block clicks over its own box, not the screen" % path)
