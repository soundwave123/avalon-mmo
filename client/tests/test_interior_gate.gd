extends GutTest

# T-187: InteriorGate is the live per-frame wrapper main.gd polls; these tests exercise the
# transition bookkeeping (changed-flag, is_indoors/volume_id) that the pure InteriorZones math
# is wrapped in. See test_interior_zones.gd for the underlying geometry/hysteresis coverage.

const InteriorGate = preload("res://scripts/world/interior_gate.gd")


func _house(id := "house") -> Dictionary:
	return {
		"id": id,
		"center": Vector3(0.0, 0.0, 0.0),
		"half_extents": Vector2(2.0, 2.0),
		"height": 3.0,
		"rot_y": 0.0,
	}


func test_starts_outdoors() -> void:
	var gate := InteriorGate.new()
	assert_false(gate.is_indoors())
	assert_eq(gate.volume_id(), "")


func test_update_position_reports_changed_on_entry() -> void:
	var gate := InteriorGate.new()
	var changed := gate.update_position(Vector3.ZERO, [_house()])
	assert_true(changed, "outdoors -> indoors is a change")
	assert_true(gate.is_indoors())
	assert_eq(gate.volume_id(), "house")


func test_update_position_reports_no_change_while_staying_indoors() -> void:
	var gate := InteriorGate.new()
	gate.update_position(Vector3.ZERO, [_house()])
	var changed := gate.update_position(Vector3(0.2, 0.0, 0.0), [_house()])
	assert_false(changed, "still well inside the same volume")
	assert_true(gate.is_indoors())


func test_update_position_reports_changed_on_exit() -> void:
	var gate := InteriorGate.new()
	gate.update_position(Vector3.ZERO, [_house()])
	var changed := gate.update_position(Vector3(50.0, 0.0, 50.0), [_house()])
	assert_true(changed, "far outside now — exits")
	assert_false(gate.is_indoors())
	assert_eq(gate.volume_id(), "")


func test_update_position_no_volumes_stays_outdoors() -> void:
	var gate := InteriorGate.new()
	var changed := gate.update_position(Vector3.ZERO, [])
	assert_false(changed)
	assert_false(gate.is_indoors())
