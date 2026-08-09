class_name MapTerrainBaker
extends RefCounted

# T-730: bakes a stylized top-down zone image from the SAME analytic terrain data the client
# already ships — TerrainField (heightfield), WorldView's road/street functions and the
# TerrainField river polyline / lake constants. There is NO committed heightmap anywhere in the
# repo (terrain is 100% code, byte-identical client/server via the sync gate), so an offline
# tools/mapgen bake would shell headless Godot to sample the very code the client carries and then
# commit an image that drifts whenever terrain_field.gd changes. Baking at runtime keeps ONE source
# of truth, needs no drift oracle and no large committed asset. Cost: RESOLUTION^2 noise samples,
# spread across frames by MapUi (ROWS_PER_FRAME) so no hitch lands on the frame budget.
#
# The T-738 minimap crops THIS SAME image (MapUi caches one bake per zone) — the tickets' shared
# terrain contract.

const WATER := Color(0.20, 0.34, 0.42)
const ROAD := Color(0.52, 0.44, 0.31)
const BASE := Color(0.24, 0.28, 0.20)  # pre-bake fill — reads as unlit parchment-dark land
# Height ramp stops: [up_to_h, color] — lowland grass -> upland olive -> rock -> the rim/snow.
const RAMP: Array = [
	[0.5, Color(0.29, 0.40, 0.23)],
	[4.0, Color(0.35, 0.42, 0.23)],
	[12.0, Color(0.44, 0.42, 0.27)],
	[40.0, Color(0.45, 0.40, 0.34)],
	[120.0, Color(0.70, 0.70, 0.68)],
]
# river_view.gd's channel half width; the polyline itself comes from TerrainField.RIVER_PTS (the
# T-342 multi-way synced source) — no new geometry list here.
const RIVER_HALF_W := 3.6
# Hillshade: west-neighbor slope tilts brightness so relief reads without extra height samples.
const SHADE_GAIN := 0.10
const SHADE_MIN := 0.80
const SHADE_MAX := 1.18

# Untyped: a TerrainField annotation breaks the cold headless parse (T-309 lesson).
var _field = preload("res://scripts/world/terrain_field.gd").new()


# What covers the ground at (x, z): "water" / "road" / "land". Pure given the shipped analytics.
func classify(x: float, z: float) -> String:
	if Vector2(x, z).distance_to(TerrainField.LAKE_CENTER) <= TerrainField.LAKE_RADIUS:
		return "water"
	if _river_dist(x, z) <= RIVER_HALF_W:
		return "water"
	var on_kings_road := (
		z >= TerrainSurface.ROAD_Z_MIN
		and z <= TerrainSurface.ROAD_Z_MAX
		and absf(x - WorldView.road_center_x(z)) <= TerrainSurface.ROAD_HALF_W
	)
	if on_kings_road:
		return "road"
	if WorldView.hk_in_city(x, z) and WorldView.hk_street_dist(x, z) <= 0.0:
		return "road"
	return "land"


# The land ramp color for a terrain height (static -> directly unit-testable).
static func color_for_height(h: float) -> Color:
	var prev_h := -10.0
	var prev_c: Color = RAMP[0][1]
	for stop: Array in RAMP:
		var stop_h := float(stop[0])
		var stop_c: Color = stop[1]
		if h <= stop_h:
			var t := clampf((h - prev_h) / maxf(stop_h - prev_h, 0.001), 0.0, 1.0)
			return prev_c.lerp(stop_c, t)
		prev_h = stop_h
		prev_c = stop_c
	return RAMP[RAMP.size() - 1][1]


# Full bake (tests + one-shot callers). Production goes through bake_rows via MapUi's chunking.
func bake(rect: Rect2, resolution: int) -> Image:
	var img := Image.create(resolution, resolution, false, Image.FORMAT_RGB8)
	img.fill(BASE)
	bake_rows(img, rect, 0, resolution)
	return img


# Bake image rows [row0, row0+count) — the incremental unit MapUi schedules per frame.
func bake_rows(img: Image, rect: Rect2, row0: int, count: int) -> void:
	var res_x := img.get_width()
	var res_y := img.get_height()
	var step_x := rect.size.x / float(res_x)
	var step_z := rect.size.y / float(res_y)
	for py in range(row0, mini(row0 + count, res_y)):
		var z := rect.position.y + (float(py) + 0.5) * step_z
		var prev_h := INF
		for px in res_x:
			var x := rect.position.x + (float(px) + 0.5) * step_x
			match classify(x, z):
				"water":
					img.set_pixel(px, py, WATER)
					prev_h = INF
				"road":
					img.set_pixel(px, py, ROAD)
					prev_h = INF
				_:
					var h := float(_field.height(x, z))
					var c := color_for_height(h)
					if prev_h != INF:  # west-neighbor hillshade (no extra field samples)
						var shade := clampf(1.0 + (h - prev_h) * SHADE_GAIN, SHADE_MIN, SHADE_MAX)
						c = Color(c.r * shade, c.g * shade, c.b * shade)
					img.set_pixel(px, py, c)
					prev_h = h


# Distance to the river centerline (TerrainField.RIVER_PTS — the shipped polyline, not a copy).
func _river_dist(x: float, z: float) -> float:
	var p := Vector2(x, z)
	var best := 1e9
	var pts: Array = TerrainField.RIVER_PTS
	for i in range(pts.size() - 1):
		var a := Vector2(float(pts[i][0]), float(pts[i][1]))
		var ab := Vector2(float(pts[i + 1][0]), float(pts[i + 1][1])) - a
		var t: float = clampf((p - a).dot(ab) / ab.dot(ab), 0.0, 1.0)
		best = minf(best, p.distance_to(a + ab * t))
	return best
