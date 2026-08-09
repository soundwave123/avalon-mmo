extends GutTest
# T-505: focused prominence regressions live outside test_remote_entities.gd, which sits near the
# 1000-line cap. The SUT is the shipped T-255/T-463 pooled FCT + overhead plate layer.

const RemoteEntitiesLayer = preload("res://scripts/world/remote_entities_layer.gd")


func _damaged_mob_layer():
	var layer = RemoteEntitiesLayer.new()
	add_child_autofree(layer)
	(
		layer
		. ingest(
			{
				"players": [],
				"mobs":
				[
					{
						"mob_id": 1001,
						"x": 10,
						"y": 10,
						"z": 0,
						"hp": 60,
						"max_hp": 100,
					}
				],
			},
			99,
			1000
		)
	)
	return layer


# Ordinary hits need enough type weight for a first-time player to read the number during combat,
# and consecutive hits must not occupy the same world-space point.
func test_damage_floats_are_large_outlined_and_spread() -> void:
	var layer = _damaged_mob_layer()
	layer.spawn_damage_number(1001, 12, "hit")
	layer.spawn_damage_number(1001, 13, "hit")
	var hits: Array[Label3D] = []
	for child in layer.get_children():
		if child is Label3D and (child as Label3D).visible:
			hits.append(child as Label3D)
	assert_eq(hits.size(), 2, "two rapid server hit events occupy two pooled labels")
	for hit in hits:
		assert_gte(hit.font_size, 84, "ordinary damage is large enough at 1080p/1440p")
		assert_gte(hit.outline_size, 12, "a strong outline keeps damage readable over the world")
	assert_gt(
		hits[0].global_position.distance_to(hits[1].global_position),
		0.35,
		"consecutive hits fan apart instead of stacking unreadably"
	)


func test_damaged_and_targeted_mob_plates_gain_prominence() -> void:
	var layer = _damaged_mob_layer()
	var bar: Node3D = layer.hp_bar_for("mob_1001")
	var bg := bar.get_node("hp_bg") as MeshInstance3D
	var bg_quad := bg.mesh as QuadMesh
	var bg_mat := bg.material_override as StandardMaterial3D
	assert_gt(bg_quad.size.x, 1.0, "combat health bar is wider than the old T-463 strip")
	assert_lt(bg_mat.albedo_color.r, 0.05, "dark backdrop gives the health fill strong contrast")
	assert_gt(bar.scale.x, 1.0, "a damaged mob is promoted above an untouched hostile")
	layer.set_target(1001)
	assert_gte(bar.scale.x, 1.4, "the current target receives the strongest overhead emphasis")
