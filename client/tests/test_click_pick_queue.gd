extends GutTest

# T-753: the buffered click pick.
#
# These run against a REAL physics space — an actual StaticBody3D, an actual Camera3D, and
# TargetSelection's actual intersect_ray — because the bug being fixed is a phase bug, and a mocked
# space state cannot have the wrong phase. The click positions come from
# Camera3D.unproject_position, which is the same CONTENT-space coordinate an InputEventMouseButton
# delivers to _unhandled_input (see ui_viewport.gd for why that is not window space), so these
# exercise the coordinates the real click path uses rather than invented pixels.

const MOB_TARGET_ID := 1001


class FakeEntities:
	extends Node
	var _entities: Dictionary = {}


class FakeMain:
	extends Node3D
	var remote_entities = null
	var npc_world = null
	var click_picks = null
	var picks: Array = []  # target ids routed to _on_entity_clicked
	var cleared: int = 0  # _clear_target calls

	func _on_entity_clicked(target_id: int) -> void:
		picks.append(target_id)

	func _clear_target() -> void:
		cleared += 1


# A camera at +Z looking down its own -Z at the origin, and a 2 m box body sitting on the origin.
# Returns the fixture parts; the caller must await two physics frames before casting so the body is
# actually registered in the broadphase.
func _world() -> Dictionary:
	UiViewport.normalize_headless(self)
	var main := FakeMain.new()
	add_child_autofree(main)
	var entities := FakeEntities.new()
	main.add_child(entities)
	main.remote_entities = entities

	var body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(2, 2, 2)
	shape.shape = box
	body.add_child(shape)
	main.add_child(body)
	body.global_position = Vector3.ZERO
	entities._entities["mob_1001"] = {"node": body, "target_id": MOB_TARGET_ID, "hp": 10}

	var cam := Camera3D.new()
	main.add_child(cam)
	cam.global_position = Vector3(0, 0, 10)
	cam.current = true

	var q := ClickPickQueue.mount(main)
	main.click_picks = q
	return {"main": main, "queue": q, "cam": cam, "body": body}


func _on_mob(f: Dictionary) -> Vector2:
	return (f["cam"] as Camera3D).unproject_position((f["body"] as Node3D).global_position)


func _on_sky(f: Dictionary) -> Vector2:
	# Straight up, far outside the box — the ray leaves the scene and hits nothing.
	return (f["cam"] as Camera3D).unproject_position(Vector3(0, 400, 0))


# ---- the phase itself ----


func test_the_ray_is_not_cast_in_the_input_callback() -> void:
	var f := _world()
	await get_tree().physics_frame
	await get_tree().physics_frame
	var got: Array = []
	f["queue"].submit(_on_mob(f), func(id: int) -> void: got.append(id))
	assert_eq(got.size(), 0, "submit() must not resolve inline — that is the locked-space window")
	assert_eq(f["queue"].pending(), 1, "the click is buffered instead")
	f["queue"].drain()
	assert_eq(got, [MOB_TARGET_ID], "it resolves on the physics drain")
	assert_eq(f["queue"].pending(), 0, "and leaves the buffer empty")


func test_a_hit_and_a_miss_resolve_to_their_own_answers() -> void:
	var f := _world()
	await get_tree().physics_frame
	await get_tree().physics_frame
	var got: Array = []
	var sink := func(id: int) -> void: got.append(id)
	f["queue"].submit(_on_mob(f), sink)
	f["queue"].submit(_on_sky(f), sink)
	f["queue"].drain()
	assert_eq(got, [MOB_TARGET_ID, -1], "the mob click picks the mob, the sky click picks nothing")


# ---- the DoD: a click storm drops nothing ----


func test_click_storm_in_one_frame_resolves_every_pick_in_order() -> void:
	var f := _world()
	await get_tree().physics_frame
	await get_tree().physics_frame
	var storm := 24
	var got: Array = []
	var expected: Array = []
	for i in storm:
		var on_mob := i % 2 == 0
		f["queue"].submit(
			_on_mob(f) if on_mob else _on_sky(f), func(id: int) -> void: got.append(id)
		)
		expected.append(MOB_TARGET_ID if on_mob else -1)
	assert_eq(f["queue"].pending(), storm, "all %d clicks buffered" % storm)
	f["queue"].drain()
	assert_eq(got.size(), storm, "every one of the %d clicks resolved — none coalesced" % storm)
	assert_eq(got, expected, "and each resolved to its own pick, in submission order")


func test_click_storm_across_frames_resolves_every_pick_via_physics_process() -> void:
	var f := _world()
	await get_tree().physics_frame
	await get_tree().physics_frame
	# Three clicks per frame for eight frames: an uncapped render loop really can outrun the 60 Hz
	# physics tick several-to-one, so more than one click per tick is the normal case, not the edge.
	var frames := 8
	var per_frame := 3
	var got: Array = []
	for _frame in frames:
		for _i in per_frame:
			f["queue"].submit(_on_mob(f), func(id: int) -> void: got.append(id))
		await get_tree().physics_frame
		await get_tree().physics_frame  # the drain runs on the callback, not on the yield itself
	assert_eq(
		got.size(),
		frames * per_frame,
		"all %d clicks resolved through the engine's own physics callback" % (frames * per_frame)
	)
	assert_eq(got.count(MOB_TARGET_ID), frames * per_frame, "and every one of them found the mob")
	assert_eq(f["queue"].pending(), 0, "nothing left stranded in the buffer")


# ---- dispatch safety ----


func test_a_sink_that_submits_waits_for_the_next_drain_instead_of_spinning() -> void:
	var f := _world()
	await get_tree().physics_frame
	await get_tree().physics_frame
	var pos := _on_mob(f)
	var got: Array = []
	var resubmit := func(id: int) -> void:
		got.append(id)
		if got.size() == 1:
			f["queue"].submit(pos, func(id2: int) -> void: got.append(id2))
	f["queue"].submit(pos, resubmit)
	f["queue"].drain()
	assert_eq(got.size(), 1, "the click submitted DURING the drain is not swept into that drain")
	assert_eq(f["queue"].pending(), 1, "it is queued for the following tick")
	f["queue"].drain()
	assert_eq(got.size(), 2, "and resolves there")


func test_a_sink_whose_object_died_between_click_and_tick_is_skipped() -> void:
	var f := _world()
	await get_tree().physics_frame
	await get_tree().physics_frame
	var doomed := Node.new()
	f["queue"].submit(_on_mob(f), Callable(doomed, "queue_free"))
	var got: Array = []
	f["queue"].submit(_on_mob(f), func(id: int) -> void: got.append(id))
	doomed.free()
	f["queue"].drain()
	assert_eq(got, [MOB_TARGET_ID], "a dead sink is skipped; the clicks behind it still resolve")


# ---- main's left-click policy, which lives on the queue (main.gd is at its line cap) ----


func test_submit_target_click_targets_a_mob_and_deselects_on_empty_ground() -> void:
	var f := _world()
	await get_tree().physics_frame
	await get_tree().physics_frame
	var main: FakeMain = f["main"]
	f["queue"].submit_target_click(_on_mob(f))
	f["queue"].drain()
	assert_eq(main.picks, [MOB_TARGET_ID], "clicking the mob selects it")
	assert_eq(main.cleared, 0, "and does not clear")
	f["queue"].submit_target_click(_on_sky(f))
	f["queue"].drain()
	assert_eq(main.picks, [MOB_TARGET_ID], "the empty-ground click selects nothing new")
	assert_eq(main.cleared, 1, "T-057: it deselects instead")


func test_an_npc_body_click_leaves_the_combat_target_alone() -> void:
	var f := _world()
	var main: FakeMain = f["main"]
	var npc_world := Node3D.new()
	main.add_child(npc_world)
	main.npc_world = npc_world
	# Reparent the collider under npc_world and drop its entity row: TargetSelection then reports
	# NPC_CLICK, the sentinel that hands the click to the talk handler.
	var body: StaticBody3D = f["body"]
	main.remote_entities._entities.clear()
	main.remove_child(body)
	npc_world.add_child(body)
	body.global_position = Vector3.ZERO
	await get_tree().physics_frame
	await get_tree().physics_frame
	f["queue"].submit_target_click(_on_mob(f))
	f["queue"].drain()
	assert_eq(main.picks, [], "an NPC click never sets a combat target")
	assert_eq(main.cleared, 0, "and never clears one either")
