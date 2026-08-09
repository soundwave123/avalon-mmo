extends SceneTree

# T-324: Headless navmesh-bake walk-in audit. Replaces the live-pilot walk loop (30+ min, dead-
# client hangs, stoop/jamb false negatives — T-323) with the industry-standard test: bake a
# NavigationMesh at the real agent radius (0.4m) over each enterable building + a door approach
# apron, then ask NavigationServer3D whether a walkable path exists from the outside approach point
# THROUGH the door to the building's interior centre. A door wide enough for the agent leaves a
# connected navmesh throat; a blocked/too-narrow door (or an obstructed interior) leaves the centre
# unreachable. Deterministic geometry — no live world, no NPC traffic, no goto-queue lag — in ms.
#
# Driven by scripts/walkin-audit.py (bake mode = default). Emits one WALKIN_RESULT:<json> line per
# door and a final WALKIN_DONE:<json> summary; the Python wrapper parses those.
#
# Reuses WorldPropsLayer's door discovery + interior-volume derivation (socket_door / legacy "door"
# node -> InteriorZones oriented footprint box), so a village-layout change moves the test for free.
#
# Geometry model (learned the hard way, T-324): buildings sit on TERRAIN and many rely on the raised
# floor + stoop in their own mesh (the inn) while others use the ground itself as their floor. So we
# lay ONLY an exterior apron at grade running outward from each door (never a slab UNDER the
# footprint — that fragments the navmesh where it meets a raised interior floor and gave the inn a
# false BLOCKED) and let the building's own trimesh carry the interior floor/stoop. The interior
# floor height is found by a downward physics ray at the footprint centre (the same trimesh the
# player collides with, T-164), so the goal snaps onto the real floor whatever its height.

const WorldPropsLayer = preload("res://scripts/world/world_props_layer.gd")

# Agent capsule that must fit the door: matches the player controller (T-164 capsule r=0.4). The
# 0.3m climb clears the modest door stoops (T-301) the wedged live capsule tripped on (T-323).
const AGENT_RADIUS := 0.4
const AGENT_HEIGHT := 1.8
const AGENT_MAX_CLIMB := 0.45  # matches LocalPlayer.STEP_HEIGHT — the ledge/threshold/plinth-floor
# rise the real capsule climbs (thresholds, stoops, raised village floors); 0.3 falsely blocked them
const AGENT_MAX_SLOPE := 50.0
const CELL_SIZE := 0.08  # fine enough to resolve a 1.2m door throat after 0.4m radius erosion
const CELL_HEIGHT := 0.08
const APRON := 6.0  # metres of walkable ground baked outward from each door (approach room)
const APPROACH_OUT := 5.0  # start the path this far OUTSIDE the door, on the apron
const REACH_FRACTION := 0.6  # PASS = path gets at least this far along door->centre (past the door)

# Hand fallback door table (name -> [local s along the face, half-depth to the door plane]). Every
# committed enterable building actually carries a socket_door/legacy node, so this is a safety net
# for a future pre-socket asset — mirrors scripts/walkin-audit.py DOORS.
const DOORS := {
	"prop_tavern_v2": [0.0, 4.0],
	"prop_cottage_v2": [-1.2, 2.2],
	"prop_church_v2": [0.0, 4.28],
	"prop_house_a_v2": [0.0, 3.48],
	"prop_house_b_v2": [0.0, 4.08],
	"prop_smithy_v2": [0.0, 4.18],
	"prop_windmill_v2": [0.0, 2.65],
}


func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	var filt := OS.get_environment("AVALON_WALKIN_FILTER")
	var filters: Array = []
	if filt != "":
		for token in filt.split(","):
			if token.strip_edges() != "":
				filters.append(token.strip_edges())

	var file := FileAccess.open("res://assets/props.json", FileAccess.READ)
	if file == null:
		printerr("WALKIN_ERROR: cannot open res://assets/props.json")
		quit(2)
		return
	var data = JSON.parse_string(file.get_as_text())
	file.close()
	if not (data is Dictionary) or not data.has("props"):
		printerr("WALKIN_ERROR: props.json malformed")
		quit(2)
		return

	# A throwaway WorldPropsLayer instance is the canonical door/interior-volume oracle. It is NOT
	# added to the tree, so its _ready() (which would reload every prop) never fires — the tests use
	# this exact pattern (test_world_props.gd calls _place on a bare .new()).
	var oracle := WorldPropsLayer.new()

	var buildings := 0
	var doors_total := 0
	var fails: Array = []
	for p in data["props"]:
		if not (p is Dictionary) or not p.has("scene"):
			continue
		var base := str(p["scene"]).get_file().replace(".glb", "")
		if not filters.is_empty():
			var matched := false
			for f in filters:
				if f in base:
					matched = true
					break
			if not matched:
				continue
		var res := await _audit_building(oracle, p, base)
		if res.is_empty():
			continue  # not enterable (no door marker) — silently skipped, same as the layer
		buildings += 1
		doors_total += int(res["doors"])
		for f in res["fails"]:
			fails.append(f)

	oracle.free()
	var summary := {"buildings": buildings, "doors": doors_total, "fails": fails}
	print("WALKIN_DONE:" + JSON.stringify(summary))
	quit(1 if not fails.is_empty() else 0)


# Bakes one placed building + its door aprons and path-tests every door. Returns {} if the building
# carries no door marker (decorative silhouette), else {doors:int, fails:Array}.
func _audit_building(oracle: WorldPropsLayer, p: Dictionary, base: String) -> Dictionary:
	var scene := load(str(p["scene"])) as PackedScene
	if scene == null:
		return {}
	var node := scene.instantiate()
	if not (node is Node3D):
		node.free()
		return {}
	if not oracle._has_door_marker(node):
		node.free()
		return {}

	# Everything for this building lives under a throwaway root so neighbours never bleed into the
	# bake and cleanup is a single free().
	var bake_root := Node3D.new()
	get_root().add_child(bake_root)
	bake_root.add_child(node)
	var n3d := node as Node3D
	var base_y := float(p.get("terrain_y", 0.0))
	n3d.position = Vector3(float(p.get("x", 0.0)), base_y, float(p.get("y", 0.0)))
	n3d.rotation.y = deg_to_rad(float(p.get("rot_deg", 0.0)))
	n3d.scale = Vector3.ONE * float(p.get("scale", 1.0))

	var vol := oracle._build_interior_volume(node, n3d, base)
	if vol.is_empty():
		bake_root.queue_free()
		return {}
	var center: Vector3 = vol["center"]

	# Interior floor height: cast a ray straight down at the footprint centre against the building's
	# own trimesh (the very surface the player stands on, T-164). Start below the door lintel so the
	# ray skips the ceiling/loft and lands on the floor; no hit -> the interior floor IS the terrain,
	# so use grade.
	for child in node.find_children("*", "MeshInstance3D", true, false):
		(child as MeshInstance3D).create_trimesh_collision()
	await physics_frame
	var floor_y := base_y
	var space := get_root().world_3d.direct_space_state
	var ray := PhysicsRayQueryParameters3D.create(
		Vector3(center.x, base_y + 1.5, center.z), Vector3(center.x, base_y - 1.0, center.z)
	)
	var hit := space.intersect_ray(ray)
	if not hit.is_empty():
		floor_y = float(hit["position"].y)

	# Door world points + an exterior apron running outward from each (at grade, never under the
	# footprint). The apron is rotated to face along the door's outward normal.
	var doors := _door_world_points(node, n3d, base)
	if doors.is_empty():
		bake_root.queue_free()
		return {}
	var starts: Array = []
	for door_pos in doors:
		var out_dir := Vector3(door_pos.x - center.x, 0.0, door_pos.z - center.z)
		if out_dir.length() < 0.01:
			out_dir = Vector3(0.0, 0.0, 1.0)
		out_dir = out_dir.normalized()
		var apron := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(4.0, 0.2, APRON + 1.0)
		apron.mesh = bm
		apron.position = Vector3(
			door_pos.x + out_dir.x * (APRON * 0.5),
			base_y - 0.1,
			door_pos.z + out_dir.z * (APRON * 0.5)
		)
		apron.rotation.y = atan2(out_dir.x, out_dir.z)  # local +Z aligns to the outward normal
		bake_root.add_child(apron)
		starts.append(
			Vector3(
				door_pos.x + out_dir.x * APPROACH_OUT,
				base_y + 0.2,
				door_pos.z + out_dir.z * APPROACH_OUT
			)
		)

	# Bake the navmesh over {building meshes + door aprons}.
	var nav := NavigationMesh.new()
	nav.cell_size = CELL_SIZE
	nav.cell_height = CELL_HEIGHT
	nav.agent_radius = AGENT_RADIUS
	nav.agent_height = AGENT_HEIGHT
	nav.agent_max_climb = AGENT_MAX_CLIMB
	nav.agent_max_slope = AGENT_MAX_SLOPE
	nav.geometry_parsed_geometry_type = NavigationMesh.PARSED_GEOMETRY_MESH_INSTANCES
	nav.geometry_source_geometry_mode = NavigationMesh.SOURCE_GEOMETRY_ROOT_NODE_CHILDREN
	var src := NavigationMeshSourceGeometryData3D.new()
	NavigationServer3D.parse_source_geometry_data(nav, src, bake_root)
	NavigationServer3D.bake_from_source_geometry_data(nav, src)

	var map := NavigationServer3D.map_create()
	NavigationServer3D.map_set_cell_size(map, CELL_SIZE)
	NavigationServer3D.map_set_cell_height(map, CELL_HEIGHT)
	NavigationServer3D.map_set_up(map, Vector3.UP)
	NavigationServer3D.map_set_active(map, true)
	var region := NavigationServer3D.region_create()
	NavigationServer3D.region_set_map(region, map)
	NavigationServer3D.region_set_navigation_mesh(region, nav)
	NavigationServer3D.region_set_enabled(region, true)
	# Wait until the server has folded the region into the map. A fixed frame count races (some
	# buildings query an empty map); poll on a point that's ALWAYS on the mesh — the first door's
	# apron start — until it snaps close.
	var synced := false
	for _i in range(60):
		await physics_frame
		if starts[0].distance_to(NavigationServer3D.map_get_closest_point(map, starts[0])) < 0.6:
			synced = true
			break
	if not synced:
		printerr("WALKIN_ERROR: navmesh map never synced for %s" % base)

	var goal := Vector3(center.x, floor_y + 0.2, center.z)
	var fails: Array = []
	for i in doors.size():
		var door_pos: Vector3 = doors[i]
		var start: Vector3 = starts[i]
		var inward := Vector3(center.x - door_pos.x, 0.0, center.z - door_pos.z).normalized()
		var door_to_center: float = (
			(center.x - door_pos.x) * inward.x + (center.z - door_pos.z) * inward.z
		)
		var need := maxf(REACH_FRACTION * door_to_center, 0.8)
		var path := NavigationServer3D.map_get_path(map, start, goal, true)
		var depth := -1e9
		if path.size() > 0:
			var last: Vector3 = path[path.size() - 1]
			depth = (last.x - door_pos.x) * inward.x + (last.z - door_pos.z) * inward.z
		var status := "ENTERED" if depth >= need else "BLOCKED"
		var rec := {
			"name": base,
			"door": [snappedf(door_pos.x, 0.1), snappedf(door_pos.z, 0.1)],
			"depth": snappedf(depth, 0.01),
			"need": snappedf(need, 0.01),
			"status": status,
		}
		print("WALKIN_RESULT:" + JSON.stringify(rec))
		if status == "BLOCKED":
			fails.append(
				(
					(
						"%s: navmesh has no walkable path from the %.0fm approach into the "
						% [base, APPROACH_OUT]
					)
					+ ("interior (reached %.2fm past the door, need %.2fm)" % [depth, need])
				)
			)

	NavigationServer3D.region_set_map(region, RID())
	NavigationServer3D.free_rid(region)
	NavigationServer3D.map_set_active(map, false)
	NavigationServer3D.free_rid(map)
	bake_root.queue_free()
	return {"doors": doors.size(), "fails": fails}


# World-space door points for a placed building. Primary source = socket_door* empties (their
# global_position IS the door once the placement transform is applied) and the legacy "door" node;
# the DOORS hand table is the fallback for a future pre-socket asset (unused by the committed set).
func _door_world_points(node: Node, n3d: Node3D, base: String) -> Array:
	var pts: Array = []
	for sock in node.find_children("socket_door*", "Node3D", true, false):
		pts.append((sock as Node3D).global_position)
	if pts.is_empty():
		var legacy := node.find_child("door", true, false)
		if legacy is Node3D:
			pts.append((legacy as Node3D).global_position)
	if pts.is_empty() and DOORS.has(base):
		var s: float = DOORS[base][0]
		var hd: float = DOORS[base][1]
		var th := n3d.rotation.y
		var c := cos(th)
		var sn := sin(th)
		pts.append(
			Vector3(
				n3d.position.x + (s * c + hd * sn),
				n3d.position.y,
				n3d.position.z + (-s * sn + hd * c)
			)
		)
	return pts
