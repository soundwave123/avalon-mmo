extends GutTest

# T-727: remote entities must FACE the way they travel — the "everyone else runs backwards"
# regression the 2026-08-08 duo playtest found (reciprocal on both clients: each saw the other
# running backwards while the runner saw themselves running forwards).
#
# The convention: every silhouette EntityVisuals builds is normalised onto the game's forward =
# body-local -Z (creature GLBs bake yaw_deg 0 already facing -Z; the +Z-in-file T-118 hero rigs
# carry yaw_deg 180). CombatMotion lunges along that same -Z, and the LOCAL player travels along it
# (W = dir.z -= 1 rotated by the body yaw) — which is why the local player never looked wrong. The
# shipped bug was RemoteEntitiesLayer deriving its body yaw as atan2(dir.x, dir.z), which points
# body-local +Z at the travel direction (correct only for NpcWorldLayer, whose models strip the 180
# flip). Applied to an EntityVisuals rig it was a flat 180: the body translated forward while the
# run clip faced backwards, i.e. dot(forward, velocity) == -1.
#
# These drive the real layer's _process(0.1) directly: at delta 0.1 the facing lerp factor
# minf(10 * delta, 1) == 1, so one tick snaps the body exactly onto its heading — deterministic,
# no dependence on real frame time. Lives in its own file so test_remote_entities.gd stays under
# the 1000-line cap. The live two-client half of the DoD is the AVALON_OBSERVE harness
# (scripts/test-remote-entities-loop.sh + client/scripts/dev/observe_probe.gd), which scores the
# same dot on a real remote player running in front of a real observer client.

const RemoteEntitiesLayer = preload("res://scripts/world/remote_entities_layer.gd")


func _layer():
	var l = RemoteEntitiesLayer.new()
	add_child_autofree(l)
	return l


# Run one remote player from the origin to `dest` (wire x/y ground coords) and return the world
# planar forward its body ended up facing. Snapshot timestamps are pushed into the past so the
# buffer clamps to the newest sample (render_t sits RENDER_DELAY_MS behind) — the node really moves.
func _travel_forward(l, dest: Vector2) -> Vector3:
	var t := Time.get_ticks_msec()
	l.ingest({"players": [{"peer_id": 1, "x": 0, "y": 0, "z": 0}], "mobs": []}, 99, t - 2000)
	l._process(0.1)  # settle at the origin
	l.ingest(
		{"players": [{"peer_id": 1, "x": dest.x, "y": dest.y, "z": 0}], "mobs": []}, 99, t - 1000
	)
	l._process(0.1)  # one tick of travel; the lerp factor is 1, so the yaw snaps onto the heading
	var node: Node3D = l.node_for("player_1")
	var forward := -node.global_transform.basis.z
	forward.y = 0.0
	return forward.normalized()


func test_remote_player_faces_its_travel_direction() -> void:
	# The wire's (x, y) ground pair maps to Godot (x, z), so a heading reads the same in both frames.
	for dest: Vector2 in [
		Vector2(10, 0), Vector2(-10, 0), Vector2(0, 10), Vector2(0, -10), Vector2(7, 7)
	]:
		var l = _layer()
		var forward := _travel_forward(l, dest)
		var velocity := Vector3(dest.x, 0.0, dest.y).normalized()
		assert_almost_eq(
			forward.dot(velocity),
			1.0,
			0.01,
			"a remote player running to %s faces that way (dot(forward, velocity) ~ +1)" % dest
		)


func test_remote_player_never_faces_opposite_its_travel() -> void:
	# The T-727 signature itself: a 180 inversion scores dot == -1. This is the DoD's sign assert, so
	# any future convention drift on either side of the atan2 fails loudly instead of subtly.
	var l = _layer()
	var forward := _travel_forward(l, Vector2(6, -6))
	var velocity := Vector3(6.0, 0.0, -6.0).normalized()
	assert_gt(forward.dot(velocity), 0.0, "dot(facing, velocity) > 0 while running (not inverted)")


func test_player_facings_reports_the_rendered_forward() -> void:
	# The accessor the AVALON_OBSERVE harness scores: it must report the SAME forward the body node
	# renders (not a re-derived guess), so the live guard can't pass while the visual is wrong.
	var l = _layer()
	var forward := _travel_forward(l, Vector2(0, 12))
	var facings: Dictionary = l.player_facings()
	assert_true(facings.has("player_1"), "the running remote player is reported")
	var entry: Dictionary = facings["player_1"]
	assert_almost_eq(
		(entry["forward"] as Vector3).dot(forward),
		1.0,
		0.001,
		"reported forward == rendered forward"
	)
	assert_almost_eq(
		(entry["pos"] as Vector3).z,
		12.0,
		0.01,
		"reported position is the interpolated world position"
	)


func test_stationary_combat_facing_points_at_the_target() -> void:
	# Same convention on the T-125 stationary path: a standing actor's forward must point AT its
	# target (it aimed its back at the target before the fix — the same single inversion).
	var l = _layer()
	l.ingest(
		{
			"players": [],
			"mobs": [{"mob_id": 1, "x": 0, "y": 0, "z": 0}, {"mob_id": 2, "x": 10, "y": 0, "z": 0}]
		},
		99,
		Time.get_ticks_msec()
	)
	l._process(0.1)  # settle both onto their positions
	l.face_target(1, 2)
	l._process(0.1)  # stationary → the combat goal snaps the actor around (lerp factor 1)
	var node: Node3D = l.node_for("mob_1")
	var forward := -node.global_transform.basis.z
	var to_target := node.global_position.direction_to(l.node_for("mob_2").global_position)
	assert_almost_eq(forward.dot(to_target), 1.0, 0.01, "the actor squares up FACING its target")
