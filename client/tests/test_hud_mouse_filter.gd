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
# Unchanged from T-645 — ChatPanel is the ONE surface that actually worked. Its idle history/tabs
# toggle IGNORE<->STOP with focus/hover (T-396's typing-summoned interactivity), so a static
# tree-walk (which would only ever observe the idle snapshot) doesn't fit; this checks the dynamic
# wiring is still present instead.
func test_chat_panel_updates_tab_row_mouse_filter() -> void:
	var path := "res://scripts/ui/chat_panel.gd"
	var file := FileAccess.open(path, FileAccess.READ)
	assert_true(file != null, "ChatPanel file should exist")
	var content := file.get_as_text()
	assert_true(
		content.contains("_tab_row.mouse_filter = mf") and content.contains("T-645"),
		"ChatPanel._apply_presence should update _tab_row.mouse_filter (T-645)"
	)
