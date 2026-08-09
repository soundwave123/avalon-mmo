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
