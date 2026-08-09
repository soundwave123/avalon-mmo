extends SceneTree

# Headless terrain-height oracle for scripts/world-audit.py and tools/reseat_props.py. As of T-309
# the formula is NOT mirrored here — it loads the SAME TerrainField the rendered ground uses, so
# the audit/reseat grade and the mesh can never disagree.

const TERRAIN_FIELD := preload("res://scripts/world/terrain_field.gd")


func _init() -> void:
	var points = JSON.parse_string(OS.get_environment("AVALON_TERRAIN_POINTS"))
	if not (points is Array):
		printerr("TERRAIN_HEIGHTS_ERROR: missing AVALON_TERRAIN_POINTS array")
		quit(2)
		return
	var field := TERRAIN_FIELD.new()
	var heights: Array[float] = []
	for point in points:
		if not (point is Array) or point.size() != 2:
			printerr("TERRAIN_HEIGHTS_ERROR: each point must be [x, z]")
			quit(2)
			return
		heights.append(field.height(float(point[0]), float(point[1])))
	print("TERRAIN_HEIGHTS:" + JSON.stringify(heights))
	quit()
