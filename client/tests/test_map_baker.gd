extends GutTest

# T-730: the runtime terrain-map baker — classification against the shipped analytics (lake,
# river, King's Road, Highkeep streets, heightfield), the ramp, and bake determinism. All
# headless: the baker samples the same TerrainField/WorldView code the world renders from.

const MapTerrainBakerT = preload("res://scripts/ui/map_terrain_baker.gd")


func test_classify_hits_the_shipped_features() -> void:
	var baker = MapTerrainBakerT.new()
	# Crystal Lake center (TerrainField.LAKE_CENTER) reads water.
	assert_eq(baker.classify(18.0, 22.0), "water")
	# A RIVER_PTS vertex sits in the carved channel.
	assert_eq(baker.classify(19.0, -140.0), "water")
	# The King's Road at its own centerline is road.
	assert_eq(baker.classify(WorldView.road_center_x(-50.0), -50.0), "road")
	# Open meadow far from every feature.
	assert_eq(baker.classify(300.0, 300.0), "land")


func test_height_ramp_orders_lowland_rock_snow() -> void:
	var lowland: Color = MapTerrainBakerT.color_for_height(0.2)
	var rock: Color = MapTerrainBakerT.color_for_height(30.0)
	var snow: Color = MapTerrainBakerT.color_for_height(200.0)
	assert_ne(lowland, rock)
	# The high stops brighten (the mountain rim reads pale against the vale).
	assert_gt(snow.r + snow.g + snow.b, lowland.r + lowland.g + lowland.b)
	# Above the last stop the ramp clamps.
	assert_eq(snow, MapTerrainBakerT.color_for_height(500.0))


func test_bake_paints_water_and_road_pixels() -> void:
	var baker = MapTerrainBakerT.new()
	# A tight frame over the village: lake (18,22), the King's Road corridor and meadow all
	# inside, at 1.25 m/px so pixel centers land on every feature class.
	var img: Image = baker.bake(Rect2(-20.0, -60.0, 40.0, 100.0), 48)
	var found := {"water": 0, "road": 0, "land": 0}
	for py in img.get_height():
		for px in img.get_width():
			var c := img.get_pixel(px, py)
			# RGB8 storage quantizes to 8 bits — compare with a 1/255-scale tolerance.
			if _close(c, MapTerrainBakerT.WATER):
				found["water"] += 1
			elif _close(c, MapTerrainBakerT.ROAD):
				found["road"] += 1
			else:
				found["land"] += 1
	assert_gt(int(found["water"]), 0, "no lake/river pixels in the village frame")
	assert_gt(int(found["road"]), 0, "no King's Road pixels in the village frame")
	assert_gt(int(found["land"]), 0, "no land pixels in the village frame")


func _close(a: Color, b: Color) -> bool:
	return absf(a.r - b.r) < 0.01 and absf(a.g - b.g) < 0.01 and absf(a.b - b.b) < 0.01


func test_bake_rows_is_incremental_and_deterministic() -> void:
	var baker = MapTerrainBakerT.new()
	var rect := Rect2(-100.0, -100.0, 200.0, 200.0)
	var whole: Image = baker.bake(rect, 32)
	# The same frame baked in 8-row chunks (the MapUi schedule) is byte-identical.
	var chunked := Image.create(32, 32, false, Image.FORMAT_RGB8)
	chunked.fill(MapTerrainBakerT.BASE)
	var row := 0
	while row < 32:
		baker.bake_rows(chunked, rect, row, 8)
		row += 8
	assert_eq(whole.get_data(), chunked.get_data())
	# And a second full bake matches too (no hidden state).
	assert_eq((baker.bake(rect, 32) as Image).get_data(), whole.get_data())
