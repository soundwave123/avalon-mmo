extends GutTest

# T-427: data-only discovery definitions + pure edge query. Runtime movement supplies both points;
# this module never accepts a client assertion that a landmark was reached.

const DiscoveryNodes = preload("res://scripts/discovery_nodes.gd")


func test_shipped_data_has_hamlet_and_ashmoor_sets() -> void:
	var loaded := DiscoveryNodes.load_file("res://data/discovery_nodes.json")
	assert_eq(loaded["errors"], [])
	var zones: Array = loaded["nodes"].map(func(n): return n["zone"])
	assert_true(zones.has("era_1_hamlet"), "Era-1 hamlet landmarks authored")
	assert_true(zones.has("ashmoor"), "Ashmoor landmarks authored")
	assert_true(loaded["nodes"].size() >= 4, "both areas contain a useful authored set")


func test_entered_returns_only_newly_crossed_nodes() -> void:
	var nodes := [
		{"id": "well", "x": 42.0, "y": -13.0, "radius": 3.0},
		{"id": "far", "x": -420.0, "y": -7.0, "radius": 3.0},
	]
	var entered := DiscoveryNodes.entered(nodes, Vector3.ZERO, Vector3(42.0, -13.0, 0.0))
	assert_eq(entered.map(func(n): return n["id"]), ["well"])
	assert_eq(
		DiscoveryNodes.entered(nodes, Vector3(42, -13, 0), Vector3(43, -13, 0)),
		[],
		"moving within a radius is not a second entry"
	)


func test_validation_rejects_duplicate_ids_and_bad_rewards() -> void:
	var result := (
		DiscoveryNodes
		. validate(
			[
				{
					"id": "same",
					"name": "A",
					"zone": "z",
					"x": 0,
					"y": 0,
					"radius": 2,
					"level": 1,
					"xp": 1
				},
				{
					"id": "same",
					"name": "B",
					"zone": "z",
					"x": 5,
					"y": 0,
					"radius": 0,
					"level": 0,
					"xp": -1
				},
			]
		)
	)
	assert_true(result.size() >= 4, "duplicate/radius/level/xp all fail loud")
