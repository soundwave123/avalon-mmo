class_name LocalPlayer
extends CharacterBody3D

# T-054: the player you control. WASD moves it locally (client prediction) + sends a request_move
# intent; the server stays authoritative and we reconcile to its position. Owns the third-person
# camera rig (follows because parented). Input/camera are play-test-verified; the predict/reconcile
# math + the apply_server_position remap are unit-tested.
#
# Axis mapping (T-052 convention): the server ground plane is (x, y) with z = height; Godot 3D is
# y-up with the ground on (x, z). So server (sx, sy, sz) -> Godot (sx, sz, sy), and a Godot ground
# move (gx, gz) is sent as the server (x, y) delta.

# T-736: a right-click RELEASE that never travelled past the deadzone (i.e. NOT a mouse-look) —
# main-side wiring ray-picks the position for the party-invite context menu.
signal right_clicked(pos: Vector2)

const MovementPredictor = preload("res://scripts/world/movement_predictor.gd")
const AnimStateMachine = preload("res://scripts/world/anim_state_machine.gd")  # T-123
const PlayerCamera = preload("res://scripts/world/player_camera.gd")  # T-126: camera-feel math
const PlayerMovement = preload("res://scripts/world/player_movement.gd")  # T-321: movement feel
const MountVisuals = preload("res://scripts/world/mount_visuals.gd")  # T-573: mount model registry
const TERRAIN_FIELD := preload("res://scripts/world/terrain_field.gd")  # T-327: shared ground field
const MOVE_SPEED := 6.0  # units/sec on the ground (T-321: run speed; walk toggle = WALK_SPEED)
# T-077: WoW-style mouse-look — hold RIGHT mouse + drag: yaw turns the CHARACTER (movement
# follows facing), vertical drag tilts the camera. Cursor is captured while held.
const MOUSE_SENSITIVITY := 0.0035  # radians per pixel
# T-739: a click is never perfectly still — a mouse reports a pixel or two of drift between press
# and release. The T-321 orbit promoted on the FIRST motion event, so an ordinary target click
# captured the cursor and the release dumped it at screen centre. Require real travel before a
# press becomes a drag; below this a left press stays a click and the cursor is never touched.
const ORBIT_DEADZONE_PX := 4.0  # pixels of travel before a left press becomes a camera orbit
const CAMERA_HEIGHT := 1.6  # ~head height; the rig pivots here
# T-082: WoW spacebar jump — a ~0.62s arc reaching ~1.1m (WoW-like feel). Client-visual
# for now: the server world is flat and ground position stays authoritative; the arc is
# cosmetic height on the local body (multiplayer jump visibility = follow-up).
const JUMP_VELOCITY := 5.6  # m/s up
const GRAVITY := 18.0  # heavier than earth = snappier game feel
const STEP_HEIGHT := 0.45  # T-189: max ledge walked over without jumping (thresholds, plinths)
const MAX_SPEED_PER_TICK := 100.0  # mirror the server's per-tick clamp (ServerConfig)
const SNAP_THRESHOLD := 3.0  # gap beyond which we snap to the server (it corrected us)
const RECONCILE_LERP := 0.25  # smooth small (latency) gaps
# T-698: request_move send cadence. Prediction still moves the body every physics frame; only the
# intent SEND coalesces — displacement deltas are additive, so summing frames into one message lands
# the server on the identical authoritative position while cutting 60 msg/s to 20. The server folds
# moves into its 20 Hz tick and remotes only see the 10 Hz broadcast (multi-client E2E-verified).
const MOVE_SEND_HZ := 20.0

# T-078: the settings menu scales the base look speed (SettingsPanel writes this). Static so the
# value survives across player respawns and is readable the instant a new LocalPlayer is built.
static var sensitivity_mult: float = 1.0

var camera_arm: SpringArm3D = null  # T-126: collision PROBE only (T-187 wall-avoidance mask)
var camera: Camera3D = null  # T-126: positioned manually so the collision pull-out can ease
# T-127: authenticated session username (JWT `sub`, fed by main.gd) — drives the deterministic
# per-username skin/hair/build so we see OURSELF exactly as everyone else resolves us.
var username: String = ""
# T-535: persisted gender (from the class_kit master truth) — "female" swaps the hero body mesh for
# the female sibling; remembered so an era/mount rebuild of BodyVisual keeps the right body.
var gender: String = ""
var _cam_yaw_pivot: Node3D = null  # T-126: carries the follow-lagged camera yaw
var _cam_pitch_pivot: Node3D = null  # T-126: carries pitch + head height; rig hangs off it
var _probe_tip: Node3D = null  # T-126: the SpringArm parks THIS at the collided distance
var _net = null  # ClientNet (request_move)
# T-424: chat-focus gate. main.gd hands us the same `func(): return chat_panel.is_typing()` seam it
# gives the HUD panels. While it returns true the raw-keyboard polls below (WASD in physics_process,
# SPACE in _tick_jump, "/" in _unhandled_input) read NO keys — else typing in chat drove the
# character (owner-reported). Unset = never typing (tests/headless spawn).
var _typing_check: Callable = Callable()
# T-506: presentation-only mirror of the server DEAD/respawn lock. Main injects the death surface
# predicate; unset stays enabled for isolated tests and pre-HUD construction.
var _gameplay_input_check: Callable = Callable()

var _looking: bool = false  # T-077: RIGHT-drag held — turns the CHARACTER (body yaw)
var _look_armed: bool = false  # T-736: right button down but not yet past the deadzone
var _rmb_press_pos: Vector2 = Vector2.ZERO  # T-736/T-739: RMB press anchor (own accumulator —
var _rmb_drag_px: float = 0.0  # the LEFT orbit owns _press_pos/_drag_px; both can be held)
var _orbiting: bool = false  # T-321: LEFT-drag held + moved — orbits the CAMERA only (body kept)
var _orbit_armed: bool = false  # T-321: left button down but not yet dragged (a pending click)
# T-739: every cursor capture/restore goes through this (see mouse_capture.gd for why).
var _mouse_capture := MouseCapture.new()
var _press_pos: Vector2 = Vector2.ZERO  # T-739: where the held button went down (restore anchor)
var _drag_px: float = 0.0  # T-739: pixels travelled since the left press (deadzone accumulator)
var _yaw: float = 0.0
var _cam_orbit_yaw: float = 0.0  # T-321: camera-only yaw offset from left-drag (body _yaw kept)
var _walking: bool = false  # T-321: run/walk toggle state (walk = below the anim run threshold)
var _move_vel: Vector3 = Vector3.ZERO  # T-321: eased ground velocity (accel/decel + turn smooth)
var _cam_yaw: float = 0.0  # T-126: eased toward _yaw + _cam_orbit_yaw (follow-lag on turn/orbit)
var _zoom_target: float = 8.0  # T-126: the user's desired camera distance (wheel sets it)
var _zoom_display: float = 8.0  # T-126: eased toward _zoom_target (smooth wheel zoom)
var _cam_dist: float = 8.0  # T-126: the actual camera distance after collision easing
var _vertical_velocity: float = 0.0
var _airborne: bool = false
var _pitch: float = -0.4363  # radians (-25°) — matches the default arm tilt
var _last_gear: Dictionary = {}  # T-225: survives the apply_class visual swap
# T-697 fix 6: true while the live BodyVisual carries _last_gear's attachments. Replaces the
# per-broadcast recursive find_child("GearSlot_*") probe; every BodyVisual (re)build path leaves
# the visual gear-consistent (make_visual arms the class default, apply_class re-applies), so
# this starts true and only apply_gear/apply_class touch it.
var _gear_applied: bool = true
# T-697 fix 8: cached /root/Main/AudioManager — the footstep hook resolved the string path every
# physics tick.
var _audio_manager: Node = null
var _main: Node = null  # T-737: cached /root/Main (for the T-187 interior gate -> wood footfalls)
var _cadence := FootstepCadence.new()  # T-737: distance-keyed footfall scheduler
var _anim: Dictionary = AnimStateMachine.new_state()  # T-123: locomotion + action state
# T-573: last APPLIED mount state (poll-on-change, not per-frame rebuild) — _tick_mount compares
# the T-572 server-confirmed cache against this and only spawns/frees the MountVisual on a real
# transition. The visual id is remembered so apply_class can re-seat a rebuilt body mid-ride.
var _mounted_shown: bool = false
var _mount_id_shown: String = ""
var _anim_display: String = "idle"  # T-306/T-123: cached so play_state only fires on a real change
var _clock: float = 0.0  # T-123: monotonic seconds fed to the state machine (advances in physics)
var _move_send_accum := Vector2.ZERO  # T-698: unsent server-frame (x, y) displacement sum
var _move_send_timer: float = 0.0  # T-698: seconds since the last request_move flush
# T-327: derive ground height from the shared field (no longer the flat y=0 plane). Untyped on
# purpose — a `TerrainField` annotation needs the global class cache (cold headless parse breaks).
var _terrain = TERRAIN_FIELD.new()


func setup(net) -> void:
	_net = net


# T-424: wire the chat-typing predicate (main.gd passes `func(): return chat_panel.is_typing()`).
func set_typing_check(cb: Callable) -> void:
	_typing_check = cb


func set_gameplay_input_check(cb: Callable) -> void:
	_gameplay_input_check = cb


# T-424: true while the chat input is focused; movement/jump/walk-toggle must read no keys then.
func _is_typing() -> bool:
	return _typing_check.is_valid() and bool(_typing_check.call())


func _is_gameplay_input_disabled() -> bool:
	return is_dead() or (_gameplay_input_check.is_valid() and bool(_gameplay_input_check.call()))


# T-225: bone-attach equipped visuals to the body (no-op until the dict changes).
# T-697 fix 6: Dictionary == is by-value in Godot 4 (no more str(dict) stringify per broadcast),
# and the gear-applied bool replaces the recursive wildcard find_child probe.
func apply_gear(gear: Dictionary) -> void:
	var visual := get_node_or_null("BodyVisual")
	if visual == null:
		return
	if gear == _last_gear and _gear_applied:
		return
	_last_gear = gear
	EntityVisuals.apply_gear(visual, gear)
	_gear_applied = true


# T-351: force a gear re-apply (bypasses the no-change guard) so an era flip re-skins the caster's
# default weapon to / from its Ashmoor focus (EntityVisuals.era selects the default). Cheap: only
# fires on the rare region crossing, not per frame.
func reapply_gear_for_era() -> void:
	var visual := get_node_or_null("BodyVisual")
	if visual != null:
		EntityVisuals.apply_gear(visual, _last_gear)


# T-076: swap the placeholder for the class figure (called by main on class_kit).
# T-535: the class_kit also carries the persisted gender; "female" selects the female body mesh.
func apply_class(char_class: String, char_gender: String = "") -> void:
	if char_gender != "":
		gender = char_gender
	var old_visual := get_node_or_null("BodyVisual")
	if old_visual != null:
		# queue_free is deferred: the corpse still holds the name this frame, so the
		# replacement would get silently renamed (BodyVisual@2) and every later
		# get_node("BodyVisual") — gear, dumps — would miss forever (T-225 bug).
		old_visual.name = "BodyVisualRetired"
		old_visual.queue_free()
	var visual := EntityVisuals.make_visual(
		char_class if char_class != "" else "player", 1.0, gender
	)
	visual.name = "BodyVisual"
	if not _last_gear.is_empty():
		EntityVisuals.apply_gear(visual, _last_gear)  # T-225: gear survives the class swap
	# T-697 fix 6: either branch leaves the fresh rig gear-consistent with _last_gear (an empty
	# dict resolves to the class default weapon inside make_visual), so the applied flag holds.
	_gear_applied = true
	add_child(visual)
	_apply_appearance()  # T-127: re-stamp the per-username skin/hair/build on the fresh rig
	if _mounted_shown:
		_apply_mount_visual()  # T-573: the fresh BodyVisual spawns at ZERO — re-seat a mid-ride rider


# T-127: set the session username (from main.gd, decoded from our JWT) and paint the current body.
func set_username(u: String) -> void:
	username = u
	_apply_appearance()


# T-127: stamp the deterministic per-username look (skin/hair tint + optional hair-atlas swap +
# build/height) onto the live BodyVisual. Idempotent and safe to call before either the username or
# the class figure exists — it no-ops until both are present.
func _apply_appearance() -> void:
	if username == "":
		return
	var visual := get_node_or_null("BodyVisual") as Node3D
	if visual == null:
		return
	var look := AppearanceResolver.resolve_player(username)
	EntityVisuals.apply_appearance(visual, look["tints"], str(look.get("hair_tex", "")))
	visual.scale = Vector3.ONE * float(look.get("scale", 1.0))  # build/height (visual only)


func _ready() -> void:
	_build_body()
	_build_camera()


func _build_body() -> void:
	# T-076: classless placeholder until class_kit arrives (then apply_class swaps it).
	var visual := EntityVisuals.make_visual("player")
	visual.name = "BodyVisual"
	add_child(visual)
	_apply_appearance()  # T-127: paints the per-username look if the username is already known
	var col := CollisionShape3D.new()
	var shape := CapsuleShape3D.new()
	# Owner playtest fix: 1.8m capsule + step-lift exceeded door heads (blocked at the lintel
	# with the feet blocked at the threshold — an unenterable sandwich). Human-proportioned
	# collision: 1.66m tall, 0.35 radius; the visual mesh is unchanged.
	shape.radius = 0.35
	shape.height = 1.66
	col.shape = shape
	col.position = Vector3(0.0, 0.83, 0.0)
	add_child(col)


func _build_camera() -> void:
	# T-126: the rig is a yaw pivot -> pitch pivot -> {spring PROBE, camera}. The camera is a
	# SIBLING of the SpringArm (not its child) so the spring's INSTANT collision snap doesn't
	# reach the camera directly — instead the spring parks `_probe_tip` at the collided distance
	# and _update_camera eases the camera toward it (pull in fast, ease out slow). The SpringArm
	# stays a real, default-mask collision node so T-187's wall-avoidance guarantee holds.
	_cam_yaw_pivot = Node3D.new()
	_cam_yaw_pivot.name = "CamYawPivot"
	add_child(_cam_yaw_pivot)
	_cam_pitch_pivot = Node3D.new()
	_cam_pitch_pivot.name = "CamPitchPivot"
	_cam_pitch_pivot.position = Vector3(0.0, CAMERA_HEIGHT, 0.0)  # ~head height
	_cam_pitch_pivot.rotation.x = _pitch  # T-077: pitch is mouse-look state
	_cam_yaw_pivot.add_child(_cam_pitch_pivot)
	camera_arm = SpringArm3D.new()
	camera_arm.name = "CameraArm"
	camera_arm.spring_length = _zoom_display
	# T-656: explicit (matches the engine default, but this is the ONE place that matters — see
	# remote_entities_layer.gd/npc_world_layer.gd's `collision_layer = 2`). The live root cause of
	# "camera clips into point-blank melee targets" surviving T-636's floor/pitch fix: this rig
	# never turns the player to face its combat target (only an explicit RMB-look sets `_yaw`), so
	# the probe — which always points the SAME direction the camera itself sits, i.e. "behind"
	# whatever `_yaw` currently is — frequently has the mob on ITS side rather than in front of the
	# player. T-636's floor/pitch treated that as "target in front, peek over its shoulder"; live
	# testing (session-24 W6) showed the mob is instead often sitting BETWEEN the render camera and
	# the player it's supposed to be filming, which no distance floor along that same ray clears
	# (screenshot proof: docs/tickets/zone/T-656.md). Layer 1 stays wall/terrain-only; mobs/players/
	# NPCs moved to layer 2 so this mask (unchanged) naturally never treats them as an obstruction.
	camera_arm.collision_mask = 1
	_cam_pitch_pivot.add_child(camera_arm)
	_probe_tip = Node3D.new()  # the spring positions THIS at (0,0,-collided_distance)
	_probe_tip.name = "ProbeTip"
	_probe_tip.position = Vector3(0.0, 0.0, -_zoom_display)  # sane distance before the first cast
	camera_arm.add_child(_probe_tip)
	camera = Camera3D.new()
	# +Z: the camera hangs BEHIND the pivot (SpringArm3D convention — it parks children at +Z),
	# so its -Z view axis faces the player and negative pitch lifts it above the head. T-126's
	# sibling rebuild wrote -Z here, which hung the camera under the ground in FRONT of the body
	# looking away (owner: "characters start underneath the ground").
	camera.position = Vector3(0.0, 0.0, _cam_dist)
	_cam_pitch_pivot.add_child(camera)
	camera.current = true  # take over from the WorldView preview camera


# T-077: hold-RMB mouse-look (WoW). _unhandled_input so clicks the UI consumed never start
# a look, and releasing always restores the cursor.
func _unhandled_input(event: InputEvent) -> void:
	# T-321: run/walk toggle (WoW default "/" ToggleRun). Walk feeds the T-123 anim run threshold
	# honestly (WALK_SPEED < RUN_THRESHOLD_MPS) — server-legal without a flag (slower than max).
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_SLASH:
		if _is_typing() or _is_gameplay_input_disabled():
			return  # T-424: "/" is a chat command prefix while typing — never the walk toggle
		_walking = PlayerMovement.toggled_walk(_walking)
		return
	if event is InputEventMouseButton and event.pressed and camera_arm != null:
		# T-126: wheel zoom (WoW camera distance) — set the DESIRED distance; _update_camera
		# eases the camera toward it (smooth lerp), instead of hard-snapping spring_length.
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_zoom_target = PlayerCamera.zoom_after_steps(_zoom_target, 1)  # +steps = zoom IN
			return
		if event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_zoom_target = PlayerCamera.zoom_after_steps(_zoom_target, -1)  # -steps = zoom OUT
			return
	# T-321: LEFT-drag = camera-only orbit (character keeps its heading). A left CLICK (press with
	# no drag) is left alone so main.gd's targeting/deselect and the entity pickers still work — we
	# only arm on press, commit to an orbit on the first drag motion, and consume the release only
	# if an orbit actually happened (so a plain click still falls through to deselect).
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_orbit_armed = true
			_press_pos = event.position  # T-739: restore anchor if this press becomes a drag
			_drag_px = 0.0
		else:
			if _orbiting:
				get_viewport().set_input_as_handled()  # eat the release so it isn't a deselect
			_orbit_armed = false
			_orbiting = false
			# T-739: no-op unless an orbit actually captured. The old unconditional
			# set_mouse_mode(VISIBLE) here fired on EVERY left release — including target clicks.
			_mouse_capture.release()
		return
	# T-736: the right button now mirrors the T-739 left-button deadzone — capture is DEFERRED
	# until real travel, so a still press/release is a CLICK (context-menu affordance on the
	# hovered entity) and only a real drag becomes mouse-look. Below the deadzone nothing swings
	# and the cursor is never touched (exactly the left-orbit promotion rule).
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT:
		if event.pressed:
			_look_armed = true
			_rmb_press_pos = event.position  # capture anchor if this press becomes a look
			_rmb_drag_px = 0.0
		else:
			if _looking:
				_mouse_capture.release()  # T-739: cursor returns to where mouse-look began
			elif _look_armed and not _is_gameplay_input_disabled():
				right_clicked.emit(event.position)  # T-736: a still RMB release is a click
			_look_armed = false
			_looking = false
	elif event is InputEventMouseMotion and _look_armed and not _looking:
		_rmb_drag_px += event.relative.length()
		if _rmb_drag_px >= ORBIT_DEADZONE_PX:
			_looking = true
			_cam_orbit_yaw = 0.0  # WoW: right-drag re-centres the camera behind the character
			_mouse_capture.capture(_rmb_press_pos)  # T-739: anchor the restore at the PRESS
	elif event is InputEventMouseMotion and _looking:
		var sens := MOUSE_SENSITIVITY * sensitivity_mult  # T-078: user sensitivity
		_yaw -= event.relative.x * sens
		_pitch = PlayerCamera.clamp_pitch(_pitch - event.relative.y * sens)  # T-126: pitch band
		rotation.y = _yaw  # the character turns with the camera (WoW right-drag)
	elif event is InputEventMouseMotion and (_orbiting or _orbit_armed):
		# T-739: drag motion promotes the armed press to an orbit only once it clears the deadzone
		# — a click's inevitable pixel of drift stays a click, so the cursor is never captured and
		# never re-centred. Below the threshold we also swing nothing (no camera creep on a click).
		if not _orbiting:
			_drag_px += event.relative.length()
			if _drag_px < ORBIT_DEADZONE_PX:
				return
			_orbiting = true
			_mouse_capture.capture(_press_pos)  # anchor at the PRESS, not the drifted position
		var sens := MOUSE_SENSITIVITY * sensitivity_mult  # T-078: user sensitivity
		_cam_orbit_yaw -= event.relative.x * sens  # camera swings; _yaw (body heading) UNCHANGED
		_pitch = PlayerCamera.clamp_pitch(_pitch - event.relative.y * sens)  # T-126: pitch band


# WASD → ground move relative to FACING (T-077); client-side predict + intent send.
func _physics_process(delta: float) -> void:
	_clock += delta  # T-123: the state machine's own clock (independent of any engine time source)
	_tick_jump(delta)
	_update_camera(delta)  # T-126: runs every tick (before the no-input early-return below)
	_tick_mount()  # T-573: before the early-returns below, so a dead/typing rider still (dis)mounts
	# T-698: before the early-returns below, so the LAST partial window of a move that just ended
	# (or was cut off by death/typing) still reaches the server instead of sticking in the accum.
	_flush_move_intent(delta)
	if _is_gameplay_input_disabled():
		_move_vel = Vector3.ZERO
		_tick_anim(0.0)
		return
	# T-424: while the chat input is focused, read NO movement keys — leave dir at ZERO so the eased
	# velocity below decelerates to a stop (no hard teleport). This raw poll bypasses the LineEdit's
	# key capture, which is exactly why unguarded WASD leaked into movement while typing.
	var dir := Vector3.ZERO
	if not _is_typing():
		if Input.is_key_pressed(KEY_W):
			dir.z -= 1.0
		if Input.is_key_pressed(KEY_S):
			dir.z += 1.0
		if Input.is_key_pressed(KEY_A):
			dir.x -= 1.0
		if Input.is_key_pressed(KEY_D):
			dir.x += 1.0
	# T-321: accel/decel + turn smoothing. Ease the ground velocity toward the desired velocity
	# (WASD rotated by facing, at run OR walk speed) instead of snapping to it — so momentum ramps
	# up crisply and, crucially, keeps DECELERATING for a few frames after input releases (the old
	# zero-input early-return snapped straight to a stop). WALK_SPEED is below the T-123 run
	# threshold, so the walk toggle yields both walk-speed motion and the walk clip.
	# T-572: mounting was a no-op — this always called target_speed(_walking) alone, so the M-key
	# toggle never changed how fast the player actually moved. _net.is_mounted() mirrors only the
	# server's last confirmed mount_state (never asserted locally).
	var move_speed := PlayerMovement.target_speed(_walking, _net != null and _net._is_mounted())
	var target_vel := PlayerMovement.desired_velocity(dir, _yaw, move_speed)
	_move_vel = PlayerMovement.ease_velocity(
		_move_vel, target_vel, PlayerMovement.ACCEL_SMOOTHING, PlayerMovement.DECEL_SMOOTHING, delta
	)
	if dir == Vector3.ZERO and _move_vel.length() < PlayerMovement.STOP_EPS:
		_move_vel = Vector3.ZERO  # settled to rest — stand still, no foot-slide, no drift
		_tick_anim(0.0)  # T-306/T-123
		return
	var move := _move_vel * delta  # eased ground velocity -> this tick's displacement
	var height := global_position.y  # T-082: predictor owns ground (x,z); we keep the arc
	# T-189: walls actually block. Direct position writes bypassed physics entirely, so the
	# T-164 prop collision never applied to the player. Collide-and-slide the horizontal
	# motion instead, then send the ACTUAL displacement as the move intent so the server's
	# authoritative position matches what the walls allowed (reconcile stays consistent).
	var motion := Vector3(move.x, 0.0, move.z).limit_length(MAX_SPEED_PER_TICK)
	var before := global_position
	# Two-phase step (owner playtest: the always-lift version made every doorway effectively
	# STEP_HEIGHT shorter — lintels blocked entry). Phase 1: move flat. If a wall stopped
	# most of the motion, phase 2 retries from the start with a STEP_HEIGHT lift so genuine
	# steps (thresholds, stoops, plinth floors) still climb — but door heads stay passable.
	var col := move_and_collide(motion)
	if col != null:
		move_and_collide(col.get_remainder().slide(col.get_normal()))
	var flat_travel := (global_position - before).length()
	var stepping := false
	if flat_travel < motion.length() * 0.35:
		global_position = before
		global_position.y = height + STEP_HEIGHT
		var col2 := move_and_collide(motion)
		if col2 != null:
			move_and_collide(col2.get_remainder().slide(col2.get_normal()))
		stepping = true
	if _airborne:
		global_position.y = height
	else:
		# Support = the HIGHER of the floor under the capsule center and under the leading
		# foot. Center-only snapping drops the body the tick after a step-climb (the center
		# is still behind the step edge), slamming it back into the step face (owner:
		# "floor lip" — no building was enterable). Leading-foot-aware support also climbs
		# approaching steps smoothly. Walking off a real ledge still falls: both rays low.
		# The probe must reach PAST the capsule radius (0.35): on a stoop mid-climb the
		# capsule front already overlaps the next step while the 0.3m probe still saw the
		# stoop, sinking the body into the step face (owner: house B unenterable).
		var gh := _ground_height(Vector3.ZERO)
		if motion.length() > 0.001:
			gh = maxf(gh, _ground_height(motion.normalized() * 0.45))
		global_position.y = gh
	var actual := global_position - before
	actual.y = 0.0
	# T-123: drive locomotion from ACTUAL displacement speed (mirrors remote_entities_layer.gd's
	# interpolated-speed rule) so a wall-blocked push (input held, motion eaten by collision) reads
	# as idle, not a foot-sliding jog. MOVE_SPEED (6.0) is the player's only speed and sits above
	# AnimStateMachine.RUN_THRESHOLD_MPS, so unblocked movement always resolves to "run".
	var speed := actual.length() / delta if delta > 0.0 else 0.0
	_tick_anim(speed)
	# T-698: coalesce — sum this frame's ACTUAL displacement; _flush_move_intent sends at 20 Hz.
	_move_send_accum += Vector2(actual.x, actual.z)  # Godot ground (x, z) -> server (x, y)
	_tick_footsteps(delta, speed)


# T-737: your own footfalls. Keyed to DISTANCE travelled off the same measured-displacement speed
# that drives the animation above — so a wall-blocked push stays silent, and slowing down thins
# the footfalls out smoothly instead of stepping between two fixed rates. Replaces the T-111
# `footstep_if_due(340ms)` hook, which fired one sample at one rate at one volume forever.
func _tick_footsteps(delta: float, speed: float) -> void:
	# T-697 fix 8: resolve the AudioManager once and reuse it (the absolute-path get_node walk
	# ran every moving physics tick); revalidated in case the manager is ever rebuilt.
	if _audio_manager == null or not is_instance_valid(_audio_manager):
		_audio_manager = get_node_or_null("/root/Main/AudioManager")
	if _audio_manager == null:
		return
	if _main == null or not is_instance_valid(_main):
		_main = get_node_or_null("/root/Main")
	# T-187's interior tracker doubles as the wood-floor cue: indoors overrides the terrain paint.
	var gate = _main.get("interior_gate") if _main != null else null
	var indoors: bool = gate != null and bool(gate.is_indoors())
	var surface := TerrainSurface.surface_at(global_position.x, global_position.z, indoors)
	var events := _cadence.tick(delta, speed, _mounted_shown, surface, _airborne)
	LocomotionAudio.play_own_steps(_audio_manager, events)


# T-698: the request_move coalescer — accumulate per-frame displacement, send at MOVE_SEND_HZ.
# Runs unconditionally from _physics_process (before its early-returns) so a residual sum always
# flushes within one window even after input stops. Zero-displacement windows send nothing.
func _flush_move_intent(delta: float) -> void:
	_move_send_timer += delta
	if _move_send_timer < 1.0 / MOVE_SEND_HZ:
		return
	_move_send_timer = 0.0
	if _move_send_accum == Vector2.ZERO or _net == null:
		return
	_net.request_move(_move_send_accum.x, _move_send_accum.y)
	_move_send_accum = Vector2.ZERO


# T-189/T-327: the walkable ground under the player — raycast down to prop floors (raised interior
# plank/stone floors, thresholds), with the shared TerrainField as the floor (was a flat y=0 plane).
# On the protected-flat walked pockets TerrainField reads 0.0, so this is a strict no-op today; on a
# hill/hollow the player follows the surface. The raycast still wins where a prop floor stands ABOVE
# the terrain (interior planks, stoops), so terrain never sinks a body through a real floor.
func _ground_height(probe := Vector3.ZERO) -> float:
	var terrain: float = _terrain.height(global_position.x + probe.x, global_position.z + probe.z)
	var space := get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(
		global_position + probe + Vector3(0.0, STEP_HEIGHT + 0.1, 0.0),
		global_position + probe + Vector3(0.0, -2.0, 0.0)
	)
	q.exclude = [get_rid()]
	var hit := space.intersect_ray(q)
	if hit.is_empty():
		return terrain
	return maxf(terrain, (hit["position"] as Vector3).y)


# T-082: spacebar jump — start the arc from the ground; integrate gravity; land on the
# floor underfoot (T-189: was a hard-coded y=0, which broke raised interior floors).
func _tick_jump(delta: float) -> void:
	# T-424: no jump while typing in chat (the same raw-poll bypass as WASD).
	if (
		not _airborne
		and not _is_typing()
		and not _is_gameplay_input_disabled()
		and Input.is_key_pressed(KEY_SPACE)
	):
		_airborne = true
		_vertical_velocity = JUMP_VELOCITY
	if not _airborne:
		return
	_vertical_velocity -= GRAVITY * delta
	var floor_y := _ground_height()
	global_position.y = maxf(floor_y, global_position.y + _vertical_velocity * delta)
	if global_position.y <= floor_y and _vertical_velocity < 0.0:
		global_position.y = floor_y
		_airborne = false
		_vertical_velocity = 0.0


# T-126: WoW-parity camera feel, every physics tick. Follow-lag eases the camera yaw toward the
# body's facing; the wheel-set desired distance eases toward the display distance (smooth zoom);
# the SpringArm probe (parked at _probe_tip) gives the collided distance, which the camera eases
# toward — pulling IN fast (never clip a wall) and easing OUT slowly (no pop when it clears). All
# scalar, no per-frame allocation (T-210). The pure math lives in PlayerCamera; this only wires
# the rig transforms. The subjective "does it feel right" tuning is deferred to the feel pass.
func _update_camera(delta: float) -> void:
	if camera_arm == null:
		return
	# T-321: the camera follows the body yaw PLUS any left-drag orbit offset (body heading stays
	# _yaw; only the camera swings). smooth_yaw stays the single source of yaw-easing math (no
	# duplication) — we just hand it the orbit-adjusted target.
	var cam_target := _yaw + _cam_orbit_yaw
	_cam_yaw = PlayerCamera.smooth_yaw(_cam_yaw, cam_target, PlayerCamera.YAW_SMOOTHING, delta)
	# The yaw pivot sits UNDER the body (which already holds _yaw), so cancel _yaw to land the
	# rig at the eased world yaw _cam_yaw (near-rigid by default).
	_cam_yaw_pivot.rotation.y = _cam_yaw - _yaw
	_zoom_display = PlayerCamera.ease_toward(
		_zoom_display, _zoom_target, PlayerCamera.ZOOM_SMOOTHING, delta
	)
	camera_arm.spring_length = _zoom_display
	# _probe_tip is parked by the SpringArm at (0,0,-collided); read the actual assigned distance
	# so we're robust to the hit-length ratio-vs-absolute API detail. T-126b: a single ray can miss
	# the second wall of a tight corner, so hold the camera a standoff margin short of the raw hit
	# (the camera has real volume; the ray doesn't) — a cheap, honest fix that keeps the collision
	# math in PlayerCamera pure-testable instead of widening the SpringArm to a shape probe.
	var raw_collided := PlayerCamera.margin_distance(absf(_probe_tip.position.z))
	# T-636: a point-blank mob pulls raw_collided down toward 0 exactly like a wall corner would;
	# floor the DISTANCE the camera actually eases toward (never flush-hug an entity) and lift the
	# PITCH off the raw, unfloored signal (so the over-the-shoulder rise still tracks how close the
	# obstruction really is, not the clamped floor).
	var collided := PlayerCamera.entity_floor_distance(raw_collided)
	_cam_dist = PlayerCamera.collision_ease(_cam_dist, collided, delta)
	camera.position.z = _cam_dist  # +Z = behind the pivot (see _build_camera)
	_cam_pitch_pivot.rotation.x = PlayerCamera.close_range_pitch(_pitch, raw_collided)


func is_airborne() -> bool:  # T-082: pilot/test accessor
	return _airborne


func is_walking() -> bool:  # T-321: pilot/test accessor — run/walk toggle state
	return _walking


func body_yaw() -> float:  # T-321: test accessor — the character heading (unchanged by orbit)
	return _yaw


func cam_orbit_yaw() -> float:  # T-321: test accessor — the left-drag camera-only yaw offset
	return _cam_orbit_yaw


func mouse_capture() -> MouseCapture:  # T-739: test accessor — the cursor capture/restore log
	return _mouse_capture


func anim_state() -> String:  # T-306/T-123: pilot/test accessor — the currently DISPLAYED state
	return _anim_display


func is_dead() -> bool:  # T-123: pilot/test accessor
	return bool(_anim.get("dead", false))


# T-573: reconcile the mount VISUAL with the T-572 server-confirmed mount cache. Runs every
# physics tick but acts only on an actual state/skin transition (poll-on-change): spawn the
# registry model + lift the rider onto its seat on mount, free it + reseat the rider on dismount.
# A registered-but-not-yet-landed GLB yields no MountVisual and no seat lift (make_mount null) —
# the T-572 "faster, same silhouette" read persists, silently, until the asset drops in.
func _tick_mount() -> void:
	var mounted: bool = _net != null and _net._is_mounted()  # untyped _net -> no := inference
	var visual_id := str(_net._mount_visual_id()) if mounted else ""
	if mounted == _mounted_shown and visual_id == _mount_id_shown:
		return
	_mounted_shown = mounted
	_mount_id_shown = visual_id
	_apply_mount_visual()


# T-573: (re)build the MountVisual child + rider seat offset from the applied mount state. Split
# from _tick_mount so apply_class can re-run it after the BodyVisual swap drops the seat offset.
func _apply_mount_visual() -> void:
	var old := get_node_or_null("MountVisual")
	if old != null:
		# Same rename-before-queue_free discipline as BodyVisual (T-225): the corpse holds the
		# name until end-of-frame, which would auto-rename a same-frame replacement forever.
		old.name = "MountVisualRetired"
		old.queue_free()
	var body := get_node_or_null("BodyVisual") as Node3D
	if body != null:
		# T-728: dismounting restores the on-foot stance — origin AND facing, or a seat with a yaw
		# correction would leave the rider walking around permanently turned in its saddle.
		body.position = Vector3.ZERO
		body.rotation.y = 0.0
	if not _mounted_shown:
		return
	var mount := MountVisuals.make_mount(_mount_id_shown)
	if mount == null:
		return  # asset not landed yet — no visual, no seat lift, no error spam (T-573 contract)
	add_child(mount)
	if body != null:
		# T-728: snap the rider into the saddle the mount's OWN rig defines, not the model origin.
		var seat := MountVisuals.rider_seat(mount)
		body.position = seat.origin
		body.rotation.y = seat.basis.get_euler().y


# T-306/T-124/T-123: recompute locomotion from real speed + airborne, then push the resolved
# display state (locomotion, or an in-flight action if one is still playing) to EntityVisuals only
# on an actual change, so the crossfade doesn't re-trigger every physics tick.
# T-573: the applied mount state rides along so the body freezes to the seated pose while mounted
# (the on-foot run clip must never play under a rider).
func _tick_anim(speed: float) -> void:
	_anim = AnimStateMachine.tick(_anim, speed, _airborne, _mounted_shown)
	_apply_anim_display()


# T-123: combat/death events call this (main.gd routes ability_result/player_death/etc. here for
# the LOCAL player — remote_entities_layer.gd owns the same call for other players/mobs). Priority
# matrix (death > hit > attack/cast > locomotion) and one-shot timing live in AnimStateMachine.
func trigger_action(event: String) -> void:
	_anim = AnimStateMachine.trigger(_anim, event, _clock)
	_apply_anim_display()


# T-123: a respawn clears death + any in-flight action back to a fresh idle state.
func reset_anim() -> void:
	_anim = AnimStateMachine.respawn_reset()
	_apply_anim_display()


func _apply_anim_display() -> void:
	var display := AnimStateMachine.display_state(_anim, _clock)
	if display == _anim_display:
		return
	_anim_display = display
	EntityVisuals.play_state(self, display)


# Reconcile to the server's authoritative position (server x,y,z -> Godot x,z,y).
func apply_server_position(server_pos: Vector3) -> void:
	var godot_auth := Vector3(server_pos.x, server_pos.z, server_pos.y)
	var height := global_position.y  # T-082: the server is flat — never stomp the jump arc
	global_position = MovementPredictor.reconcile(
		global_position, godot_auth, SNAP_THRESHOLD, RECONCILE_LERP
	)
	global_position.y = height
