extends "res://addons/gut/test.gd"
# #79: HostileProximity.has_live_hostile_nearby — pure predicate, plain Dictionary rows so no live
# RemoteEntitiesLayer/scene tree is needed (the TargetSelection idiom).

const HostileProximity = preload("res://scripts/world/hostile_proximity.gd")


func _mob_node(pos: Vector3) -> Node3D:
	var n := Node3D.new()
	add_child_autofree(n)  # global_position only resolves once inside the tree
	n.global_position = pos
	return n


func test_true_for_a_close_alive_mob() -> void:
	var entities := {"mob_1": {"is_player": false, "hp": 50, "node": _mob_node(Vector3(2, 0, 2))}}
	assert_true(HostileProximity.has_live_hostile_nearby(entities, Vector3.ZERO, 20.0))


func test_false_when_the_only_mob_is_dead() -> void:
	var entities := {"mob_1": {"is_player": false, "hp": 0, "node": _mob_node(Vector3(2, 0, 2))}}
	assert_false(
		HostileProximity.has_live_hostile_nearby(entities, Vector3.ZERO, 20.0),
		"a dead mob is not still a threat"
	)


func test_false_when_out_of_range() -> void:
	var entities := {
		"mob_1": {"is_player": false, "hp": 50, "node": _mob_node(Vector3(500, 0, 500))}
	}
	assert_false(
		HostileProximity.has_live_hostile_nearby(entities, Vector3.ZERO, 20.0),
		"far outside the pull radius"
	)


func test_ignores_other_players() -> void:
	var entities := {"player_1": {"is_player": true, "hp": 50, "node": _mob_node(Vector3(2, 0, 2))}}
	assert_false(
		HostileProximity.has_live_hostile_nearby(entities, Vector3.ZERO, 20.0),
		"a nearby PLAYER is not a hostile"
	)


func test_false_with_no_entities() -> void:
	assert_false(HostileProximity.has_live_hostile_nearby({}, Vector3.ZERO, 20.0))


func test_true_when_one_of_several_mobs_is_still_alive_and_close() -> void:
	var entities := {
		"mob_1": {"is_player": false, "hp": 0, "node": _mob_node(Vector3(1, 0, 1))},  # just died
		"mob_2": {"is_player": false, "hp": 30, "node": _mob_node(Vector3(3, 0, 3))},  # still fighting
	}
	assert_true(
		HostileProximity.has_live_hostile_nearby(entities, Vector3.ZERO, 20.0),
		"the second, still-alive hostile keeps the encounter 'live'"
	)
