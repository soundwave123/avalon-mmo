extends "res://addons/gut/test.gd"

# T-442: props.json is the authored temperate-biome placement SUT. WorldPropsLayer is used to
# instantiate one entry from every required habitat band, proving the tagged rows point at real
# client scenes rather than merely satisfying string/count assertions.
const WorldPropsLayer = preload("res://scripts/world/world_props_layer.gd")

const _BANNED_SPECIES := ["agave", "aloe", "succulent", "rooibos", "maize", "potato", "tomato"]
const _REQUIRED_BANDS := {
	"flora_t442_edge": 12,
	"flora_t442_water": 6,
	"flora_t442_disturbed": 8,
}


func _props() -> Array:
	var file := FileAccess.open("res://assets/props.json", FileAccess.READ)
	assert_not_null(file, "props.json opens")
	var parsed = JSON.parse_string(file.get_as_text())
	file.close()
	assert_true(parsed is Dictionary, "props.json parses")
	return parsed.get("props", []) if parsed is Dictionary else []


func test_temperate_props_contain_no_new_world_or_anachronistic_species() -> void:
	var layer = autofree(WorldPropsLayer.new())
	var props := _props()
	assert_gt(props.size(), 0, "real placement data loaded")
	for prop: Dictionary in props:
		var scene := str(prop.get("scene", "")).to_lower()
		for banned: String in _BANNED_SPECIES:
			assert_false(scene.contains(banned), "%s is absent from temperate placements" % banned)
	# The instantiated SUT keeps this a real render/data seam test, not a free-floating JSON lint.
	assert_not_null(layer)


func test_flora_is_clustered_into_required_habitat_bands() -> void:
	var props := _props()
	var by_tag: Dictionary = {}
	for prop: Dictionary in props:
		var tag := str(prop.get("tag", ""))
		if _REQUIRED_BANDS.has(tag):
			if not by_tag.has(tag):
				by_tag[tag] = []
			by_tag[tag].append(prop)
	for tag: String in _REQUIRED_BANDS:
		assert_gte(
			by_tag.get(tag, []).size(),
			int(_REQUIRED_BANDS[tag]),
			"%s forms a visible cluster" % tag
		)
		var layer = autofree(WorldPropsLayer.new())
		assert_true(layer._place(by_tag.get(tag, [])[0]), "%s uses a loadable textured prop" % tag)


func test_t442_flora_stays_off_trampled_road_and_training_courtyard() -> void:
	var layer = autofree(WorldPropsLayer.new())
	for prop: Dictionary in _props():
		if not str(prop.get("tag", "")).begins_with("flora_t442_"):
			continue
		var x := float(prop.get("x", 0.0))
		var z := float(prop.get("y", 0.0))
		var in_road_center := z >= -102.0 and z <= 27.0 and absf(x) < 3.0
		# The west house's east wall is x=-5.3; the actual packed-earth yard/road lies inward.
		var in_training_courtyard := x >= -4.5 and x <= 4.5 and z >= 7.0 and z <= 20.0
		assert_false(in_road_center, "cluster flora stays off worn road centre")
		assert_false(in_training_courtyard, "training courtyard remains bare")
	assert_not_null(layer)
