extends GutTest

# T-739: the cursor capture/restore contract in isolation. Headless DisplayServer stubs out
# mouse_set_mode/warp_mouse and always reports MOUSE_MODE_VISIBLE, so the transition LOG is the
# honest oracle here — reading Input.get_mouse_mode() back would pass no matter what we did.

const MouseCaptureLib = preload("res://scripts/world/mouse_capture.gd")


func test_release_without_capture_issues_nothing() -> void:
	var mc = MouseCaptureLib.new()
	mc.release()
	assert_eq(mc.ops, [] as Array[Dictionary], "no capture => no mouse-mode call, no warp")
	assert_false(mc.is_captured(), "still uncaptured")


func test_capture_then_release_warps_back_to_the_saved_position() -> void:
	var mc = MouseCaptureLib.new()
	mc.capture(Vector2(812, 344))
	assert_true(mc.is_captured(), "captured")
	assert_eq(mc.anchor(), Vector2(812, 344), "pre-capture position saved")
	mc.release()
	assert_false(mc.is_captured(), "released")
	assert_eq(mc.ops.size(), 2, "one capture, one restore")
	assert_eq(mc.ops[1]["op"], MouseCaptureLib.OP_RESTORE, "the release issues a restore")
	assert_eq(mc.ops[1]["pos"], Vector2(812, 344), "warped back to the SAVED position")


# A gesture that re-arms mid-drag must still return to where the gesture began, not to wherever
# the cursor notionally was on the second capture call.
func test_recapture_while_captured_keeps_the_original_anchor() -> void:
	var mc = MouseCaptureLib.new()
	mc.capture(Vector2(100, 100))
	mc.capture(Vector2(500, 500))
	assert_eq(mc.anchor(), Vector2(100, 100), "the first anchor wins")
	assert_eq(mc.ops.size(), 1, "the redundant capture is not re-issued")
	mc.release()
	assert_eq(mc.ops[1]["pos"], Vector2(100, 100), "restored to where the gesture began")


func test_double_release_does_not_re_issue_a_warp() -> void:
	var mc = MouseCaptureLib.new()
	mc.capture(Vector2(10, 20))
	mc.release()
	mc.release()
	assert_eq(mc.ops.size(), 2, "the second release is a no-op")


# ---- T-747: the content -> window conversion at the warp ----


# UI stretch made InputEvent.position (CONTENT space) and Input.warp_mouse (WINDOW pixels) two
# different spaces. Warping the anchor unconverted would put the cursor at 1/1.5 of the intended
# distance from the top-left on the shipped 1920x1080 window — a silent reintroduction of the exact
# T-739 symptom this module exists to prevent. The `ops` log carries both so this is provable
# headlessly, where the DisplayServer stubs warp_mouse out entirely.
func test_release_warps_in_window_space_not_content_space() -> void:
	UiViewport.normalize_headless(self)
	await get_tree().process_frame
	var scale := UiViewport.content_scale(get_viewport())
	assert_almost_eq(scale, 1.5, 0.001, "the shipped 1920 window over the 1280 base")

	var mc = MouseCaptureLib.new()
	mc.capture(Vector2(400, 300))
	mc.release()
	assert_eq(mc.ops[1]["pos"], Vector2(400, 300), "the anchor stays in the caller's content space")
	assert_almost_eq(
		mc.ops[1]["warp"],
		Vector2(600, 450),
		Vector2(0.01, 0.01),
		"the warp actually sent is the anchor converted to window pixels",
	)


func test_the_warp_is_the_anchor_itself_when_the_two_spaces_coincide() -> void:
	# A window pinned to the base (the pilot's AVALON_PILOT_RESOLUTION=1280x720 default) makes the
	# conversion an identity. Pinned here to document WHY the bug was invisible to pilot testing.
	get_tree().root.size = Vector2i(UiViewport.base_size())
	await get_tree().process_frame
	var mc = MouseCaptureLib.new()
	mc.capture(Vector2(812, 344))
	mc.release()
	assert_almost_eq(mc.ops[1]["warp"], Vector2(812, 344), Vector2(0.01, 0.01))
	get_tree().root.size = UiViewport.window_size()  # restore for the rest of the suite
	await get_tree().process_frame
