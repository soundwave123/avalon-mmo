extends GutTest

# T-573: the client mount-rendering seam. The mount GLB itself is generated in a separate lane, so
# these tests exercise the WIRING with what exists today: the registry's drop-in default path
# (res://assets/models/<id>.glb) lets the wolf GLB stand in as a loadable "mount", while the
# registered-but-not-landed gryphon proves the graceful missing-asset contract (no node, no seat
# lift, no error spam). Dropping mount_common_gryphon.glb into assets/models makes the real mount
# live with zero code edits — exactly what this seam is for.

const LocalPlayer = preload("res://scripts/world/local_player.gd")
const RemoteEntitiesLayer = preload("res://scripts/world/remote_entities_layer.gd")
const MountVisuals = preload("res://scripts/world/mount_visuals.gd")
const AnimStateMachine = preload("res://scripts/world/anim_state_machine.gd")

# A GLB that actually exists in the repo (the wolf) — resolved via the drop-in default path, it
# stands in for the gryphon until the mount asset lands.
const STANDIN_MOUNT := "mob_wolf"
# Registered in MountVisuals.MOUNTS but its GLB has NOT landed yet (asset lane in flight).
# A mount id whose GLB does not exist (falls to the drop-in default path and misses) — exercises
# the silent-fallback seam. mount_common_gryphon graduated out of this role when its GLB landed.
const PENDING_MOUNT := "mount_test_unlanded"


# T-572 seam stub: LocalPlayer reads the server-confirmed mount cache off its injected net object
# (never asserts state itself), so the stub only has to answer the same two underscored reads.
class NetStub:
	extends RefCounted

	var mounted := false
	var visual := ""

	func _is_mounted() -> bool:
		return mounted

	func _mount_visual_id() -> String:
		return visual

	func request_move(_x: float, _z: float) -> void:
		pass


func _player_with_net(net: NetStub):
	var p = LocalPlayer.new()
	add_child_autofree(p)  # _ready builds BodyVisual + camera rig
	p.setup(net)
	return p


func _layer():
	var l = RemoteEntitiesLayer.new()
	add_child_autofree(l)
	return l


func _w(pressed: bool) -> InputEventKey:
	var ev := InputEventKey.new()
	ev.keycode = KEY_W
	ev.physical_keycode = KEY_W
	ev.pressed = pressed
	return ev


# ---- the registry/loader itself ----


func test_make_mount_missing_glb_or_empty_id_returns_null() -> void:
	assert_null(MountVisuals.make_mount(""), "empty id -> no visual")
	assert_null(
		MountVisuals.make_mount(PENDING_MOUNT),
		"registered mount whose GLB has not landed -> null (silent), not an error or placeholder"
	)
	assert_null(MountVisuals.make_mount("mount_never_heard_of"), "unknown id -> null (silent)")


func test_make_mount_builds_from_the_drop_in_default_path() -> void:
	var mount := MountVisuals.make_mount(STANDIN_MOUNT)
	assert_not_null(
		mount, "an id whose assets/models/<id>.glb exists resolves with no registry row"
	)
	autofree(mount)
	assert_eq(mount.name, "MountVisual", "the attach node carries the contract name")
	assert_gt(mount.get_child_count(), 0, "the GLB model is instanced under the attach node")


func test_seat_offset_rides_the_registry_not_code() -> void:
	assert_eq(
		MountVisuals.seat_offset("mount_common_gryphon"),
		Vector3(0.0, 1.15, 0.0),
		"the rider attach transform is registry data (asset re-fits are data edits)"
	)
	assert_eq(
		MountVisuals.seat_offset("mount_never_heard_of"),
		Vector3.ZERO,
		"an unregistered mount has no seat lift"
	)


# ---- local player: mount-state transition toggles the MountVisual (poll on change) ----


func test_local_mount_transition_spawns_then_dismount_hides() -> void:
	var net := NetStub.new()
	net.visual = STANDIN_MOUNT
	var p = _player_with_net(net)
	p._physics_process(0.05)
	assert_null(p.get_node_or_null("MountVisual"), "no mount visual while dismounted")
	net.mounted = true
	p._physics_process(0.05)
	var mount = p.get_node_or_null("MountVisual")
	assert_not_null(mount, "the server-confirmed mount transition spawns the MountVisual child")
	p._physics_process(0.05)
	assert_eq(
		p.get_node_or_null("MountVisual"),
		mount,
		"steady mounted state keeps the SAME node (poll-on-change, no per-frame rebuild)"
	)
	net.mounted = false
	p._physics_process(0.05)
	assert_null(p.get_node_or_null("MountVisual"), "dismounting frees the mount visual")
	assert_eq(
		(p.get_node_or_null("BodyVisual") as Node3D).position,
		Vector3.ZERO,
		"the rider reseats at ZERO after dismount"
	)


func test_local_mount_with_unlanded_glb_is_silent() -> void:
	var net := NetStub.new()
	net.visual = PENDING_MOUNT  # registered, GLB not landed (the shipping state today)
	net.mounted = true
	var p = _player_with_net(net)
	p._physics_process(0.05)
	assert_null(
		p.get_node_or_null("MountVisual"), "missing GLB -> no visual at all (and no error spam)"
	)
	assert_eq(
		(p.get_node_or_null("BodyVisual") as Node3D).position,
		Vector3.ZERO,
		"no seat lift without a mount under the rider (no floating-rider read)"
	)


func test_local_mounted_anim_is_seated_never_the_run_clip() -> void:
	var net := NetStub.new()
	net.visual = STANDIN_MOUNT
	net.mounted = true
	var p = _player_with_net(net)
	Input.parse_input_event(_w(true))
	Input.flush_buffered_events()
	for _i in range(8):  # ramp past the run threshold (mounted speed is ~1.6x run — T-572)
		p._physics_process(0.05)
	assert_eq(p.anim_state(), "mounted", "full-speed mounted movement shows the seated state")
	assert_ne(p.anim_state(), "run", "the on-foot run clip never plays while mounted")
	net.mounted = false
	for _i in range(8):  # still holding W after the dismount
		p._physics_process(0.05)
	assert_eq(p.anim_state(), "run", "dismounting mid-move releases back to the honest run read")
	Input.parse_input_event(_w(false))  # release — global key state leaks into later tests
	Input.flush_buffered_events()


# ---- remote players: the broadcast mounted/mount_visual fields drive the same visual ----


func _ingest_player(l, mounted: bool, visual_id: String) -> void:
	var p := {"peer_id": 1, "x": 0, "y": 0, "z": 0}
	p["mounted"] = mounted
	if mounted:
		p["mount_visual"] = visual_id
	l.ingest({"players": [p], "mobs": []}, 99, Time.get_ticks_msec())


func test_remote_mounted_player_gets_mount_visual_and_loses_it_on_dismount() -> void:
	var l = _layer()
	_ingest_player(l, true, STANDIN_MOUNT)
	assert_not_null(
		l._mount_for("player_1"), "the broadcast mounted/mount_visual fields attach the mount"
	)
	_ingest_player(l, true, STANDIN_MOUNT)
	assert_not_null(
		l._mount_for("player_1"), "an unchanged broadcast keeps the mount (delta idiom)"
	)
	_ingest_player(l, false, "")
	assert_null(l._mount_for("player_1"), "mounted=false detaches the mount visual")


func test_remote_mounted_with_unlanded_glb_is_silent() -> void:
	var l = _layer()
	_ingest_player(l, true, PENDING_MOUNT)
	assert_null(l._mount_for("player_1"), "missing GLB -> no visual on the remote rider either")
	_ingest_player(l, false, "")  # dismount must not crash on the never-attached mount
	assert_null(l._mount_for("player_1"))


func test_remote_mounted_body_holds_seated_idle_not_the_run_clip() -> void:
	var l = _layer()
	_ingest_player(l, true, STANDIN_MOUNT)
	l._process(0.1)
	var e: Dictionary = l.get("_entities")["player_1"]
	assert_eq(
		str(e.get("anim_display", "")), "mounted", "the broadcast flag drove the mounted display"
	)
	var ap := (l.node_for("player_1") as Node3D).find_child("AnimationPlayer", true, false)
	assert_not_null(ap, "the hero rig carries an AnimationPlayer")
	var clip: String = (ap as AnimationPlayer).current_animation
	assert_true(
		clip in EntityVisuals.STATE_CLIPS["mounted"],
		"a mounted rider resolves the seated state (Ride_Seated when baked, idle family today)"
	)
	assert_false(
		clip in ["run", "Jog_Fwd_Loop", "Jog_Fwd", "Sprint_Loop", "Sprint", "Running_A"],
		"never the on-foot run clip under a rider"
	)


# ---- the pure state machine: mounted display state ----


func test_anim_state_machine_mounted_wins_over_run_speed_and_releases() -> void:
	var s := AnimStateMachine.tick(AnimStateMachine.new_state(), 9.6, false, true)
	assert_eq(
		AnimStateMachine.display_state(s, 0.0),
		"mounted",
		"is_mounted freezes the display to the seated state even at mounted-run speed"
	)
	s = AnimStateMachine.tick(s, 6.0, false, false)  # dismounted, still moving at run speed
	assert_eq(AnimStateMachine.display_state(s, 0.0), "run", "dismounting releases straight to run")


func test_mounted_state_clips_carry_no_run_synonym() -> void:
	# The resolver guarantee behind "the run clip never plays": whatever clip set a rig carries,
	# the mounted state can only ever resolve to a ride/idle-family clip.
	for clip: String in EntityVisuals.STATE_CLIPS["mounted"]:
		assert_false(
			clip in EntityVisuals.STATE_CLIPS["run"],
			"mounted candidate '%s' must not be a run-state synonym" % clip
		)
