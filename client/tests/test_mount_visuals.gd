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


# ---- T-728: the saddle seat is per-mount DATA resolved against the mount's own rig ----


func test_seat_transform_differs_per_mount_seat_data() -> void:
	# The T-728 contract: two mounts with different seat data must seat their rider differently.
	# Same anchor for both, so any difference is the registry's (offset + fit scale), not the rig's.
	var anchor := Vector3(0.0, 0.5, 0.0)
	var gryphon := MountVisuals.seat_transform("mount_common_gryphon", anchor)
	var drop_in := MountVisuals.seat_transform(STANDIN_MOUNT, anchor)
	assert_ne(
		gryphon.origin,
		drop_in.origin,
		"per-mount seat data (offset + fit scale) moves the rider — not one hardcoded vector"
	)
	# The gryphon rides scale 1.9, so its saddle sits materially higher than the identity-fit one.
	assert_gt(gryphon.origin.y, drop_in.origin.y, "the taller mount seats its rider higher")


func test_seat_transform_lands_the_riders_hips_on_the_saddle() -> void:
	# The bug this ticket exists for: the rider's ROOT was put on the saddle, so it STOOD there.
	# The seat points at the saddle surface and the root sinks by the seated clip's hip height.
	var anchor := Vector3(0.0, 0.5754, 0.0)  # the gryphon's own "chest" rest origin
	var t := MountVisuals.seat_transform("mount_common_gryphon", anchor)
	var saddle_y := (0.5754 + 0.149) * 1.9  # (anchor + offset) * fit, in world metres
	assert_almost_eq(
		t.origin.y + MountVisuals.RIDER_HIP_HEIGHT,
		saddle_y,
		0.001,
		"root + the seated clip's hip height == the saddle surface (hips seated, not feet)"
	)
	assert_lt(t.origin.y, saddle_y, "the rider's root sits BELOW the saddle — it is not standing")


func test_every_shipped_mount_resolves_a_seat() -> void:
	# "Works for all shipped mounts" — enumerated from the mount data, so a new registry row that
	# forgets its seat fails here instead of shipping a surfing rider.
	for id: String in MountVisuals.MOUNTS:
		var seat: Dictionary = MountVisuals.seat_spec(id)
		assert_true(
			str(seat["anchor_bone"]) != "" or (seat["offset"] as Vector3) != Vector3.ZERO,
			"shipped mount '%s' declares a seat (bone anchor and/or offset)" % id
		)
		var t := MountVisuals.seat_transform(id, Vector3(0.0, 0.5754, 0.0))
		assert_gt(t.origin.y, 0.0, "shipped mount '%s' seats its rider above the ground" % id)


func test_seat_anchor_is_read_off_the_real_mount_rig() -> void:
	# The seat's anchor is the mount's OWN skeleton, not a number typed into the registry: the
	# gryphon's barrel bone rests at model y 0.575 and the seat is measured from there.
	var mount := MountVisuals.make_mount("mount_common_gryphon")
	assert_not_null(mount, "the gryphon GLB has landed")
	autofree(mount)
	var model := mount.get_child(0)
	assert_almost_eq(
		MountVisuals.bone_rest_origin(model, "chest").y,
		0.5754,
		0.01,
		"the rig's barrel bone anchors the saddle (model space, before the fit scale)"
	)
	assert_eq(
		MountVisuals.bone_rest_origin(model, "no_such_bone"),
		Vector3.ZERO,
		"a renamed/absent bone degrades to the model origin instead of throwing"
	)


func test_make_mount_stamps_the_resolved_seat_for_both_render_paths() -> void:
	var mount := MountVisuals.make_mount("mount_common_gryphon")
	autofree(mount)
	var seat := MountVisuals.rider_seat(mount)
	var expected := MountVisuals.seat_transform(
		"mount_common_gryphon", MountVisuals.bone_rest_origin(mount.get_child(0), "chest")
	)
	assert_almost_eq(seat.origin.y, expected.origin.y, 0.0001, "the stamped seat is the rig's seat")
	assert_gt(seat.origin.y, 0.0, "the gryphon seats its rider well above the player's feet")
	assert_eq(
		MountVisuals.rider_seat(null),
		Transform3D.IDENTITY,
		"no mount -> identity seat (the rider stays at its own origin)"
	)


func test_cosmetic_skins_share_the_base_mounts_fit_and_seat() -> void:
	# One mesh, one animal: a paint job must not resize the beast or move its saddle (T-728 — the
	# skins carried the default fit scale, which shrank a bought skin to half the base gryphon).
	var base := MountVisuals.seat_transform("mount_common_gryphon", Vector3(0.0, 0.5754, 0.0))
	for skin in ["skin_storm_gryphon", "skin_royal_gryphon"]:
		assert_eq(
			float(MountVisuals.spec_for(skin)["scale"]),
			float(MountVisuals.spec_for("mount_common_gryphon")["scale"]),
			"%s is the same mesh as the base gryphon, so it is the same size" % skin
		)
		assert_eq(
			MountVisuals.seat_transform(skin, Vector3(0.0, 0.5754, 0.0)).origin,
			base.origin,
			"%s seats its rider exactly where the base gryphon does" % skin
		)


func test_legacy_vector3_seat_row_still_resolves() -> void:
	# The T-573 registry shape was a bare Vector3. It normalizes to a bone-less model-space offset
	# rather than silently seating the rider at the origin, so an unmigrated row keeps working.
	var legacy: Dictionary = MountVisuals.normalize_seat(Vector3(0.0, 1.15, 0.0))
	assert_eq(str(legacy["anchor_bone"]), "", "a bare Vector3 carries no rig anchor")
	assert_eq(legacy["offset"], Vector3(0.0, 1.15, 0.0), "and reads as a model-space offset")
	var seat: Dictionary = MountVisuals.seat_spec("mount_never_heard_of")
	assert_eq(str(seat["anchor_bone"]), "chest", "the drop-in default still anchors to the rig")
	assert_eq(seat["offset"], Vector3.ZERO, "and adds no offset of its own")


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
	# T-728: the rider is snapped to the seat the mount's rig defines, not left at the origin.
	var body := p.get_node_or_null("BodyVisual") as Node3D
	assert_eq(
		body.position,
		MountVisuals.rider_seat(mount).origin,
		"the rider snaps to the mount's resolved saddle seat"
	)
	assert_ne(body.position, Vector3.ZERO, "which is NOT the mount's origin (the T-728 bug)")
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
	assert_almost_eq(
		(p.get_node_or_null("BodyVisual") as Node3D).rotation.y,
		0.0,
		0.0001,
		"T-728: dismount restores the on-foot facing too, not just the position"
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
	# T-728: the actual pose fix — the baked seated ride clip wins over the standing idle. This is
	# also the oracle for the bake: if the importer renames the clip, this fails instead of quietly
	# falling through to the idle family and shipping a rider standing on the mount again.
	assert_true(
		clip in ["Ride_Seated", "Driving", "Driving_Loop", "Sitting_Idle"],
		"the rider plays the baked SEATED ride clip, not the standing idle (got '%s')" % clip
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
