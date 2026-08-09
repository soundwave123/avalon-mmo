extends GutTest

# T-656: "camera clips into point-blank melee targets" (T-636's fix tested green but didn't take
# live). Split out of test_remote_entities.gd, which was already near gdlint's 1000-line file cap
# (T-636's own test_player_camera_t636.gd precedent). Two independent parts of the real fix:
#   1. mob/player collision bodies moved off layer 1 (the follow camera's SpringArm3D probe never
#      treats a point-blank entity as a wall to avoid).
#   2. nameplate near-camera clamp (NameplateLod.near_clamp_scale) — the actual live root cause:
#      the camera was legitimately avoiding a WALL near the training dummy, and a mob's Label3D
#      nameplate has unbounded perspective scaling, so it blew up to fill the frame once
#      wall-avoidance forced the camera down to MIN_ENTITY_DISTANCE.

const RemoteEntitiesLayer = preload("res://scripts/world/remote_entities_layer.gd")
const NameplateLod = preload("res://scripts/ui/nameplate_lod.gd")
# T-697: the mob carries full hp so its plate is VISIBLE (hostile-in-range rule, base scale 1.0)
# — the per-frame near-clamp now skips invisible plates, and a live point-blank mob always has hp.
const _MOB_PAYLOAD := {
	"players": [], "mobs": [{"mob_id": 1001, "x": 10, "y": 10, "z": 0, "hp": 100, "max_hp": 100}]
}


func _layer():
	var l = RemoteEntitiesLayer.new()
	add_child_autofree(l)
	return l


# T-656: one _process frame after the FIRST ingest samples the SnapshotBuffer at a render_t
# still before the only snapshot (RENDER_DELAY_MS lag), leaving the node at its pre-broadcast
# spawn position — the same staleness test_distance_cull_hides_far_damaged_entity works around.
# Re-ingest (matching the entity's real position again) after that frame so the node has actually
# landed at (10, y, 10) before a caller measures distance to it.
func _layer_with_mob():
	var l = _layer()
	l.ingest(_MOB_PAYLOAD, 99, Time.get_ticks_msec())
	await get_tree().process_frame
	l.ingest(_MOB_PAYLOAD, 99, Time.get_ticks_msec())
	return l


func test_mob_and_player_bodies_are_off_the_default_physics_layer() -> void:
	var l = _layer()
	(
		l
		. ingest(
			{
				"players": [{"peer_id": 1, "x": 5, "y": 6, "z": 0}],
				"mobs": [{"mob_id": 1001, "x": 10, "y": 10, "z": 0}],
			},
			99,
			1000
		)
	)
	assert_eq(l.node_for("mob_1001").collision_layer, 2, "mob body off layer 1")
	assert_eq(l.node_for("player_1").collision_layer, 2, "remote player body off layer 1")


func test_plate_shrinks_when_the_camera_is_forced_very_close() -> void:
	var l = await _layer_with_mob()  # mob_1001 settled at (10, y, 10)
	# T-656: distance to the PLATE (~2.1 m above the body root — see _make_hp_bar), not the body
	# root — placing the camera relative to the entity's ground position undercounts the real
	# gap and can land just OUTSIDE NEAR_CLAMP_M. Read the plate's actual position first.
	var bar_pos: Vector3 = l.hp_bar_for("mob_1001").global_position
	var cam := Camera3D.new()
	add_child_autofree(cam)
	cam.current = true
	cam.global_position = bar_pos + Vector3(0.0, 0.0, 1.0)  # well inside NEAR_CLAMP_M (2.5 m)
	await get_tree().process_frame
	assert_true(
		l.hp_bar_for("mob_1001").scale.x < 1.0,
		"camera well inside NEAR_CLAMP_M — the plate must be shrunk, not full perspective size"
	)


func test_plate_is_full_size_at_a_normal_combat_distance() -> void:
	var l = await _layer_with_mob()
	var bar_pos: Vector3 = l.hp_bar_for("mob_1001").global_position
	var cam := Camera3D.new()
	add_child_autofree(cam)
	cam.current = true
	cam.global_position = bar_pos + Vector3(0.0, 0.0, 8.0)  # the default zoom distance
	await get_tree().process_frame
	assert_almost_eq(
		l.hp_bar_for("mob_1001").scale.x,
		1.0,
		0.001,
		"normal combat range — near-clamp must not touch the ordinary base scale"
	)
