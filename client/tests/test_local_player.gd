extends GutTest

# T-054: the local player's reconcile + the server→Godot axis remap are testable headlessly (the
# CharacterBody3D builds in the test tree; no input/rendering needed). The feel is
# play-test-verified.

const LocalPlayer = preload("res://scripts/world/local_player.gd")


func _player():
	var p = LocalPlayer.new()
	add_child_autofree(p)  # _ready builds the capsule + camera rig
	return p


func test_apply_server_position_snaps_far_gap_and_remaps_axes() -> void:
	var p = _player()
	p.global_position = Vector3(100, 0, 100)  # far from the server → forces a snap
	# server (x=5, y=7 ground) → Godot ground (x=5, z=7). T-082: height (Godot y) is
	# CLIENT-owned while the server world is flat — the jump arc must never be stomped
	# by a reconcile.
	p.apply_server_position(Vector3(5, 7, 2))
	assert_eq(p.global_position.x, 5.0, "ground x snapped")
	assert_eq(p.global_position.z, 7.0, "ground z snapped (server y)")
	assert_eq(p.global_position.y, 0.0, "height untouched by reconcile (client-owned arc)")


func test_jump_arc_rises_and_lands() -> void:
	var p = _player()
	Input.parse_input_event(_space(true))
	Input.flush_buffered_events()  # headless: make is_key_pressed see it NOW
	p._physics_process(0.05)  # launch frame
	Input.parse_input_event(_space(false))
	Input.flush_buffered_events()
	assert_true(p.is_airborne(), "space starts the jump")
	assert_gt(p.global_position.y, 0.0, "rising")
	var peak := 0.0
	for i in range(40):  # 2 simulated seconds — far beyond the arc
		p._physics_process(0.05)
		peak = maxf(peak, p.global_position.y)
	assert_almost_eq(p.global_position.y, 0.0, 0.001, "lands back on the ground")
	assert_false(p.is_airborne(), "landed state cleared")
	assert_between(peak, 0.6, 1.4, "WoW-ish apex (~1m)")


func _space(pressed: bool) -> InputEventKey:
	var ev := InputEventKey.new()
	ev.keycode = KEY_SPACE
	ev.physical_keycode = KEY_SPACE
	ev.pressed = pressed
	return ev


# T-306: the local player never drove EntityVisuals.play_state, so it foot-slid in a frozen
# idle pose while translating (remote_entities_layer.gd already did this for other entities).
# Headless: no AnimationPlayer on the placeholder visual, so play_state() itself no-ops — this
# only asserts the cached _anim_display transitions idle -> run -> idle off real displacement.
# T-123: MOVE_SPEED (6.0 m/s) is above AnimStateMachine.RUN_THRESHOLD_MPS (4.0) — a player has no
# separate walk speed, so unblocked movement reads as RUN, not walk (was "walk" pre-T-123).
# T-321: movement now ACCELERATES — a player ramps from rest through walk speed into run over a few
# ticks (and decelerates back through walk to idle on release) instead of snapping. So this drives
# a short ramp before asserting run, and a longer glide-down before asserting idle.
func test_anim_state_switches_run_then_idle_with_movement() -> void:
	var p = _player()
	assert_eq(p.anim_state(), "idle", "idle decided before any input (zero speed)")
	Input.parse_input_event(_w(true))
	Input.flush_buffered_events()
	for _i in range(8):  # ramp up past the run threshold (accel, not an instant snap)
		p._physics_process(0.05)
	assert_eq(p.anim_state(), "run", "sustained W ramps up to full run speed")
	Input.parse_input_event(_w(false))
	Input.flush_buffered_events()
	for _i in range(20):  # glide to a stop (deceleration), then idle
		p._physics_process(0.05)
	assert_eq(p.anim_state(), "idle", "releasing all input decelerates to idle")


# T-321: the run/walk toggle. Toggling walk on and holding W must produce BOTH walk-speed movement
# AND the walk clip (the honest half of the ticket — WALK_SPEED sits below the anim run threshold).
func test_walk_toggle_produces_walk_speed_and_walk_clip() -> void:
	var p = _player()
	assert_false(p.is_walking(), "starts in run mode")
	Input.parse_input_event(_slash())  # "/" ToggleRun
	Input.flush_buffered_events()
	Input.parse_input_event(_w(true))
	Input.flush_buffered_events()
	assert_true(p.is_walking(), "the / key toggled walk mode on")
	var before: Vector3 = p.global_position
	for _i in range(12):  # reach walk steady-state
		p._physics_process(0.05)
	assert_eq(p.anim_state(), "walk", "walk-speed movement resolves to the WALK clip, not run")
	var travelled: float = (p.global_position - before).length()
	var avg_speed: float = travelled / (12 * 0.05)
	assert_lt(avg_speed, 4.0, "average speed stayed below the run threshold (genuinely walking)")
	assert_gt(avg_speed, 0.5, "but the character is actually moving")
	Input.parse_input_event(_w(false))  # release W — global key state leaks into later tests
	Input.flush_buffered_events()


# T-321: LEFT-drag orbits the CAMERA without changing the character heading; RIGHT-drag still turns
# the body as before. Asserted through the input path (accessors expose body yaw vs orbit offset).
func test_left_drag_orbits_camera_without_turning_character() -> void:
	var p = _player()
	var yaw0: float = p.body_yaw()
	# Left press then a drag motion = orbit. Body yaw must not move; the camera orbit offset must.
	p._unhandled_input(_mouse_button(MOUSE_BUTTON_LEFT, true))
	p._unhandled_input(_mouse_motion(Vector2(120, 0)))
	assert_almost_eq(p.body_yaw(), yaw0, 0.0001, "left-drag leaves the CHARACTER heading unchanged")
	assert_ne(p.cam_orbit_yaw(), 0.0, "left-drag DID swing the camera (orbit offset changed)")
	p._unhandled_input(_mouse_button(MOUSE_BUTTON_LEFT, false))


func test_right_drag_still_turns_the_character() -> void:
	var p = _player()
	var yaw0: float = p.body_yaw()
	p._unhandled_input(_mouse_button(MOUSE_BUTTON_RIGHT, true))
	# T-736: the FIRST motion past the deadzone promotes press->look (and, like the left orbit's
	# promotion event, swings nothing itself); subsequent motion turns the character as always.
	p._unhandled_input(_mouse_motion(Vector2(120, 0)))
	p._unhandled_input(_mouse_motion(Vector2(120, 0)))
	assert_ne(p.body_yaw(), yaw0, "right-drag turns the character heading (unchanged from today)")
	p._unhandled_input(_mouse_button(MOUSE_BUTTON_RIGHT, false))


# T-739: a left click that SELECTS something (NPC / gather node / monster) must leave the OS cursor
# exactly where it landed. The regression was in the transition handler, not the pickers: the left
# release called set_mouse_mode(VISIBLE) unconditionally and the orbit captured on the first motion
# event, so a click with a pixel of hand drift went CAPTURED -> VISIBLE and Godot re-centred the
# cursor. Assert the handler issues NO mouse-mode transition at all for a plain click.
func test_left_click_select_never_changes_the_mouse_mode() -> void:
	var p = _player()
	var click := Vector2(812, 344)  # somewhere off-centre — where the target was clicked
	p._unhandled_input(_mouse_button(MOUSE_BUTTON_LEFT, true, click))
	p._unhandled_input(_mouse_motion(Vector2(1, -1)))  # real mice drift between press and release
	p._unhandled_input(_mouse_button(MOUSE_BUTTON_LEFT, false, click))
	assert_eq(
		p.mouse_capture().ops, [] as Array[Dictionary], "a plain click issues NO cursor transition"
	)
	assert_false(p.mouse_capture().is_captured(), "a plain click never captures the cursor")
	assert_eq(p.cam_orbit_yaw(), 0.0, "sub-deadzone drift does not swing the camera either")


# T-739 / T-077 / T-736: mouse-look captures once right-drag clears the deadzone (T-736 moved the
# capture off the press so a still right-CLICK can be the context-menu affordance) — and the
# release warps the cursor back to the PRESS position, exactly the left-orbit anchor rule.
func test_right_drag_capture_release_restores_the_pre_capture_cursor() -> void:
	var p = _player()
	var press := Vector2(640, 360)
	p._unhandled_input(_mouse_button(MOUSE_BUTTON_RIGHT, true, press))
	assert_false(p.mouse_capture().is_captured(), "a still press captures nothing yet (T-736)")
	p._unhandled_input(_mouse_motion(Vector2(120, 0)))  # past the deadzone -> look begins
	assert_true(p.mouse_capture().is_captured(), "real drag travel captures the cursor (T-077)")
	assert_eq(p.mouse_capture().anchor(), press, "the pre-capture position is saved")
	p._unhandled_input(_mouse_button(MOUSE_BUTTON_RIGHT, false, Vector2(9999, 9999)))
	assert_false(p.mouse_capture().is_captured(), "right-release frees the cursor")
	var ops: Array[Dictionary] = p.mouse_capture().ops
	assert_eq(ops.size(), 2, "exactly one capture and one restore")
	assert_eq(ops[0]["op"], MouseCapture.OP_CAPTURE, "captured on promotion")
	assert_eq(ops[1]["op"], MouseCapture.OP_RESTORE, "restored on release")
	assert_eq(ops[1]["pos"], press, "the restore warp targets the SAVED pre-capture position")


# T-739: a real left DRAG (past the deadzone) still orbits, and its release restores the cursor to
# the press point — not to the drifted end of the drag and not to screen centre.
func test_left_drag_past_the_deadzone_captures_then_restores_to_the_press_point() -> void:
	var p = _player()
	var press := Vector2(300, 200)
	p._unhandled_input(_mouse_button(MOUSE_BUTTON_LEFT, true, press))
	p._unhandled_input(_mouse_motion(Vector2(120, 0)))
	assert_true(p.mouse_capture().is_captured(), "a genuine drag still captures (T-321 orbit)")
	p._unhandled_input(_mouse_button(MOUSE_BUTTON_LEFT, false, Vector2(420, 200)))
	var ops: Array[Dictionary] = p.mouse_capture().ops
	assert_eq(ops.size(), 2, "exactly one capture and one restore")
	assert_eq(ops[1]["op"], MouseCapture.OP_RESTORE, "restored on release")
	assert_eq(ops[1]["pos"], press, "cursor returns to where the drag STARTED")


func _slash() -> InputEventKey:
	var ev := InputEventKey.new()
	ev.keycode = KEY_SLASH
	ev.physical_keycode = KEY_SLASH
	ev.pressed = true
	return ev


func _mouse_button(button: int, pressed: bool, pos := Vector2.ZERO) -> InputEventMouseButton:
	var ev := InputEventMouseButton.new()
	ev.button_index = button
	ev.pressed = pressed
	ev.position = pos  # T-739: the cursor-restore anchor rides the press event
	return ev


func _mouse_motion(relative: Vector2) -> InputEventMouseMotion:
	var ev := InputEventMouseMotion.new()
	ev.relative = relative
	return ev


# T-123: attack/cast/hit are one-shots that hold, then release back to whatever locomotion is
# current; death is terminal until reset_anim() (respawn).
func test_trigger_action_hit_then_releases_to_idle() -> void:
	var p = _player()
	p._physics_process(0.05)  # establish the clock + idle locomotion
	p.trigger_action("hit")
	assert_eq(p.anim_state(), "hit", "hit plays immediately")
	for i in range(20):  # advance the clock well past the hit's ~0.37s hold
		p._physics_process(0.05)
	assert_eq(p.anim_state(), "idle", "hit released back to locomotion")
	assert_false(p.is_dead())


func test_trigger_action_death_sticks_until_reset() -> void:
	var p = _player()
	p._physics_process(0.05)
	p.trigger_action("death")
	assert_true(p.is_dead())
	assert_eq(p.anim_state(), "death")
	for i in range(20):
		p._physics_process(0.05)
	assert_eq(p.anim_state(), "death", "death never releases on its own")
	p.reset_anim()
	assert_false(p.is_dead())
	assert_eq(p.anim_state(), "idle", "respawn resets to idle")


func _w(pressed: bool) -> InputEventKey:
	var ev := InputEventKey.new()
	ev.keycode = KEY_W
	ev.physical_keycode = KEY_W
	ev.pressed = pressed
	return ev


# T-424: while the chat input is focused, the raw-keyboard movement poll must read NO keys — WASD
# leaked into movement because Input.is_key_pressed bypasses the LineEdit's key capture. The typing
# predicate is the same `func(): return chat_panel.is_typing()` seam main.gd hands the HUD panels.
func test_movement_suppressed_while_typing_and_restored_after() -> void:
	var p = _player()
	var typing := [true]  # Array holder so the lambda sees later mutations
	p.set_typing_check(func(): return typing[0])
	Input.parse_input_event(_w(true))
	Input.flush_buffered_events()
	var origin: Vector3 = p.global_position
	for _i in range(10):  # W held, but typing → no movement, no run animation
		p._physics_process(0.05)
	assert_almost_eq(
		p.global_position.x, origin.x, 0.001, "held W does NOT move the body while typing"
	)
	assert_almost_eq(p.global_position.z, origin.z, 0.001, "no z drift while typing")
	assert_eq(p.anim_state(), "idle", "no locomotion animation while typing")
	# Focus returns to movement — the SAME held W now drives the character.
	typing[0] = false
	for _i in range(10):
		p._physics_process(0.05)
	assert_gt(
		(p.global_position - origin).length(), 0.5, "releasing chat focus restores WASD movement"
	)
	assert_eq(p.anim_state(), "run", "movement resumes and reaches run once typing clears")
	Input.parse_input_event(_w(false))  # release — global key state leaks into later tests
	Input.flush_buffered_events()


# T-424: SPACE (jump) is polled the same raw way in _tick_jump — it must not launch while typing.
func test_jump_suppressed_while_typing() -> void:
	var p = _player()
	var typing := [true]
	p.set_typing_check(func(): return typing[0])
	Input.parse_input_event(_space(true))
	Input.flush_buffered_events()
	p._physics_process(0.05)
	assert_false(p.is_airborne(), "space does NOT start a jump while typing")
	assert_almost_eq(p.global_position.y, 0.0, 0.001, "no vertical launch while typing")
	# Clears once focus returns.
	typing[0] = false
	p._physics_process(0.05)
	assert_true(p.is_airborne(), "space jumps again once typing clears")
	Input.parse_input_event(_space(false))
	Input.flush_buffered_events()


# T-424: the "/" walk toggle is a gameplay key too — while typing it's a chat command prefix and
# must NOT flip the run/walk state.
func test_walk_toggle_suppressed_while_typing() -> void:
	var p = _player()
	p.set_typing_check(func(): return true)
	assert_false(p.is_walking(), "starts in run mode")
	p._unhandled_input(_slash())
	assert_false(p.is_walking(), "'/' does not toggle walk while typing (it's a chat prefix)")


# T-506: presentation lock mirrors the server's DEAD rejection locally, so held movement does not
# coast/send while dead or during the respawn fade; releasing the presentation restores control.
func test_movement_suppressed_during_death_presentation_then_restored() -> void:
	var p = _player()
	var blocked := [true]
	p.set_gameplay_input_check(func(): return blocked[0])
	Input.parse_input_event(_w(true))
	Input.flush_buffered_events()
	var origin: Vector3 = p.global_position
	for _i in range(10):
		p._physics_process(0.05)
	assert_eq(p.global_position, origin, "held W cannot move during death/respawn presentation")
	blocked[0] = false
	for _i in range(10):
		p._physics_process(0.05)
	assert_gt((p.global_position - origin).length(), 0.5, "movement returns after presentation")
	Input.parse_input_event(_w(false))
	Input.flush_buffered_events()


func test_apply_server_position_lerps_small_gap() -> void:
	var p = _player()
	p.global_position = Vector3.ZERO
	# server ground (1,0,0) → Godot (1,0,0); gap 1 < snap threshold → lerp by RECONCILE_LERP (0.25).
	p.apply_server_position(Vector3(1, 0, 0))
	assert_almost_eq(
		p.global_position.x, 0.25, 0.001, "lerps 25% toward the server (no rubber-band)"
	)


# T-187 (camera-indoors correctness check — the feel pass stays T-126): the third-person camera
# rig is a SpringArm3D, which is inherently collision-aware (it shape/ray-casts toward its
# camera and pulls in on a hit) — so "doesn't clip through walls indoors" falls out of NOT
# breaking that default, rather than needing new indoor-specific code. This asserts nobody
# accidentally zeroed the collision mask or pointed the arm at a non-default physics layer,
# which would silently defeat wall avoidance both indoors and out. Building interiors use the
# SAME default StaticBody3D layer (T-164's create_trimesh_collision has no layer override — see
# world_props_layer.gd), so mask bit 1 is exactly what's needed to catch them.
func test_camera_arm_keeps_default_collision_mask_for_wall_avoidance() -> void:
	var p = _player()
	assert_not_null(p.camera_arm, "camera rig built in _ready")
	assert_true(
		(p.camera_arm.collision_mask & 1) != 0,
		"camera arm still tests against the default physics layer (buildings/ground/props)"
	)


# T-656: the root cause the T-636 floor/pitch fix missed — this rig never turns the player to
# FACE its combat target, so the probe (which points wherever the camera itself sits, "behind"
# whatever `_yaw` currently is) frequently has a point-blank mob on ITS side rather than in front
# of the player, sitting directly between the render camera and the character it films. No
# distance floor along that same ray clears that. The actual fix: mobs/players/NPCs moved off
# layer 1 (remote_entities_layer.gd / npc_world_layer.gd), so this mask — bit 1 only — never
# treats them as an obstruction in the first place. This locks the OTHER half of that contract:
# the mask must not have grown to also catch layer 2 (which would silently re-break it).
func test_camera_arm_mask_excludes_the_entity_physics_layer() -> void:
	var p = _player()
	assert_not_null(p.camera_arm, "camera rig built in _ready")
	assert_eq(
		p.camera_arm.collision_mask & 2,
		0,
		"camera arm must NOT test layer 2 (mobs/players/NPCs) — T-656"
	)


# T-535: apply_class carries the class_kit gender; "female" is persisted (drives the female body
# mesh) and the class figure rebuilds. A later class swap with no gender keeps the persisted one
# (mirrors the T-597 server rule that a resend never blanks a chosen gender).
func test_apply_class_persists_gender_and_rebuilds_the_body() -> void:
	var p = _player()
	p.apply_class("warrior", "female")
	assert_eq(p.gender, "female", "the class_kit gender is persisted on the local player")
	assert_not_null(p.get_node_or_null("BodyVisual"), "the class figure body is (re)built")
	p.apply_class("mage", "")
	assert_eq(p.gender, "female", "an empty follow-up gender keeps the persisted female")
	p.apply_class("priest", "male")
	assert_eq(p.gender, "male", "an explicit later gender still updates it")


# ---- T-697 fix 6: gear delta via Dictionary == + the gear-applied bool ----------------------


func test_apply_gear_with_equal_dict_is_a_no_op_and_change_rebuilds() -> void:
	var p = _player()
	p.apply_gear({"weapon": "itm_iron_sword"})
	var skel := p.get_node("BodyVisual").find_child("Skeleton3D", true, false)
	if skel == null:
		pass_test("placeholder rig without a skeleton — gear attach not applicable here")
		return
	var socket := skel.find_child("GearSlot_weapon", false, false)
	assert_not_null(socket, "gear applied on the first call")
	assert_true(p._gear_applied, "the applied flag is set")
	p.apply_gear({"weapon": "itm_iron_sword"})  # a FRESH but value-equal dict (broadcast echo)
	assert_true(
		is_same(skel.find_child("GearSlot_weapon", false, false), socket),
		"a value-equal broadcast leaves the existing socket untouched (no rebuild)"
	)
	p.apply_gear({"weapon": "itm_iron_axe"})
	var rebuilt := skel.find_child("GearSlot_weapon", false, false)
	assert_false(is_same(rebuilt, socket), "a REAL gear change still rebuilds the attachment")


# ---- T-736: right-click vs mouse-look (the T-739 deadzone, mirrored onto RMB) ------------


func _rmb(pressed: bool, pos: Vector2) -> InputEventMouseButton:
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_RIGHT
	ev.pressed = pressed
	ev.position = pos
	return ev


func _rmb_motion(relative: Vector2) -> InputEventMouseMotion:
	var ev := InputEventMouseMotion.new()
	ev.relative = relative
	return ev


func test_still_right_click_emits_right_clicked_and_never_captures() -> void:
	var p = _player()
	watch_signals(p)
	p._unhandled_input(_rmb(true, Vector2(100, 100)))
	p._unhandled_input(_rmb_motion(Vector2(1, 1)))  # a click's inevitable pixel of drift
	p._unhandled_input(_rmb(false, Vector2(101, 101)))
	assert_signal_emitted(p, "right_clicked", "a still RMB release is a click")
	assert_false(p._looking, "no mouse-look was entered")
	assert_eq(p._mouse_capture.ops, [], "the cursor was never captured (T-739 rule)")


func test_right_drag_past_deadzone_is_mouse_look_not_a_click() -> void:
	var p = _player()
	watch_signals(p)
	var yaw_before: float = p.rotation.y
	p._unhandled_input(_rmb(true, Vector2(100, 100)))
	p._unhandled_input(_rmb_motion(Vector2(30, 0)))  # well past ORBIT_DEADZONE_PX
	assert_true(p._looking, "real travel promotes the press to mouse-look")
	p._unhandled_input(_rmb_motion(Vector2(30, 0)))
	assert_ne(p.rotation.y, yaw_before, "mouse-look turns the character")
	p._unhandled_input(_rmb(false, Vector2(160, 100)))
	assert_signal_not_emitted(p, "right_clicked", "a look release is NOT a click")
	assert_eq(p._mouse_capture.ops.size(), 2, "captured on promotion, released on release")
	assert_eq(str(p._mouse_capture.ops[0].get("op", "")), "capture")
	assert_eq(str(p._mouse_capture.ops[1].get("op", "")), "restore")


func test_sub_deadzone_travel_swings_no_camera() -> void:
	var p = _player()
	var yaw_before: float = p.rotation.y
	p._unhandled_input(_rmb(true, Vector2(100, 100)))
	p._unhandled_input(_rmb_motion(Vector2(2, 0)))  # below the 4 px deadzone
	assert_false(p._looking)
	assert_eq(p.rotation.y, yaw_before, "no camera/body creep below the deadzone")
	p._unhandled_input(_rmb(false, Vector2(102, 100)))
