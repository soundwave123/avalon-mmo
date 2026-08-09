class_name MouseCapture
extends RefCounted

# T-739: the ONE place the game is allowed to move the OS cursor.
#
# Godot's MOUSE_MODE_CAPTURED hides the cursor and pins it to the window centre; leaving CAPTURED
# hands the cursor back AT THAT CENTRE, not where the user left it. Every capture site therefore
# owes the player a restore: remember where the cursor was before the capture and warp_mouse()
# back to it on release. local_player.gd had two capture sites (T-077 right-drag mouse-look and
# T-321 left-drag camera orbit) and neither restored, so any interaction that passed through
# CAPTURED — including a target click that drifted a pixel between press and release — dumped the
# cursor at screen centre (owner playtest: clicking NPCs / gather nodes / monsters).
#
# Two rules, both enforced here so no caller can get them subtly wrong:
#   1. release() is a NO-OP unless this module actually captured. A plain click that never
#      captured must not touch the mouse mode at all — the old code called set_mouse_mode(VISIBLE)
#      unconditionally on every left-button release.
#   2. Every capture -> visible transition warps the cursor back to the anchor recorded at capture
#      time (the press position: exactly where the click landed).
#
# Positions are VIEWPORT-local (InputEvent.position / Input.warp_mouse share that space) — never
# mix in DisplayServer.mouse_get_position(), which is screen-global.
#
# `ops` records every transition so the behaviour is unit-testable headlessly: the headless
# DisplayServer stubs mouse_set_mode/warp_mouse out and always reports MOUSE_MODE_VISIBLE, so
# reading Input.get_mouse_mode() back in a test proves nothing.

const OP_CAPTURE := "capture"
const OP_RESTORE := "restore"  # visible again + cursor warped back to the anchor

var ops: Array[Dictionary] = []  # transition log, newest last (tests + debug only)

var _captured: bool = false
var _anchor: Vector2 = Vector2.ZERO


# True while this module holds the cursor captured.
func is_captured() -> bool:
	return _captured


# The cursor position recorded at capture time — the position release() warps back to.
func anchor() -> Vector2:
	return _anchor


# Capture the cursor for a drag-look/orbit, anchoring the restore at `anchor_pos` (viewport-local,
# normally the button-press event's position). Re-capturing while already captured keeps the
# ORIGINAL anchor: a drag that re-arms mid-gesture must still return to where the gesture began.
func capture(anchor_pos: Vector2) -> void:
	if _captured:
		return
	_captured = true
	_anchor = anchor_pos
	ops.append({"op": OP_CAPTURE, "pos": anchor_pos})
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)


# Hand the cursor back where it was. No-op (and NO mouse-mode call) if we never captured — that is
# what keeps a plain left-click select from disturbing the cursor at all.
func release() -> void:
	if not _captured:
		return
	_captured = false
	# Order matters: go VISIBLE first (that is the transition that re-centres), then warp back.
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	Input.warp_mouse(_anchor)
	ops.append({"op": OP_RESTORE, "pos": _anchor})
