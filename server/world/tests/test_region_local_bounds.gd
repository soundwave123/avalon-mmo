extends GutTest

# T-593 region_local_bounds — the BINDING PRECISION GUARD for the continent program. Single-float
# transform error starts biting past the ~8 km third-person envelope (shimmer, shadow acne, contact
# jitter); authoring every zone's terrain + spawns + props + NPC posts within ±4 km of that zone's
# region origin (world_regions.gd) keeps the whole continent single-precision FOREVER — no
# double-precision engine fork (docs/research/2026-07-19-godot-large-zones.md, continent-plan §6.6).
#
# This audit FAILS CLOSED: if any future zone silently drifts its authored content past ±4 km of the
# nearest region origin (i.e. no origin is near enough — it fell into the fuzzy far field), the run
# goes red. It checks two things per binding rule:
#   (1) every region's whole REACHABLE ENVELOPE (its clamp box, which bounds every terrain sample
#       and every movement/spawn landing) sits within ±4 km of that region's origin; and
#   (2) every authored CONTENT point (spawn hub, mob spawn, NPC post, walled-prop footprint) routes
#       to a region origin within ±4 km (the nearest-origin dispatch is the region assignment).

const _WR = preload("res://scripts/world_regions.gd")

const LOCAL_LIMIT := 4000.0  # the ±4 km binding rule (third-person single-precision envelope)


func _nearest_origin_dist(wr, x: float, z: float) -> float:
	# Distance from (x, z) to its nearest region origin — the region the nearest-origin dispatch
	# assigns this point to. Content must live within ±4 km of THAT origin.
	var o: Vector2 = wr.origin_at(x, z)
	return Vector2(x, z).distance_to(o)


func _load_json(path: String) -> Variant:
	if not FileAccess.file_exists(path):
		return null
	return JSON.parse_string(FileAccess.get_file_as_string(path))


# ---- (1) every region's reachable envelope is local to its origin ---------------------------
func test_every_region_clamp_box_is_within_4km_of_its_origin() -> void:
	var wr = _WR.load_default()
	assert_gt(
		wr.region_count(), 0, "the region table must be loaded for the audit to mean anything"
	)
	for i in wr.region_count():
		var o: Vector2 = wr.origin_of(i)
		var box: Dictionary = wr.clamp_box_of(i)
		var mn: Vector2 = box["min"]
		var mx: Vector2 = box["max"]
		# The farthest reachable point from the origin is a box corner (true whether or not the
		# origin lies inside the box), so checking all four corners bounds the whole envelope.
		for corner in [mn, Vector2(mn.x, mx.y), Vector2(mx.x, mn.y), mx]:
			var d := o.distance_to(corner)
			assert_lte(
				d,
				LOCAL_LIMIT,
				(
					"region '%s' corner %s is %.0f m from its origin %s (> ±4 km precision limit)"
					% [wr.region_id_of(i), corner, d, o]
				)
			)
		# Sanity: the origin sits inside its own clamp box (content authored at the origin must be
		# reachable) — a drifted/mis-sized box is caught here before it can strand a zone's content.
		assert_true(
			o.x >= mn.x and o.x <= mx.x and o.y >= mn.y and o.y <= mx.y,
			"region '%s' origin %s is outside its own clamp box" % [wr.region_id_of(i), o]
		)


# ---- (2) every authored content point routes to a local origin ------------------------------
func _assert_points_local(wr, pts: Array, kind: String) -> void:
	for p in pts:
		var d := _nearest_origin_dist(wr, p.x, p.y)
		assert_lte(
			d,
			LOCAL_LIMIT,
			(
				"%s at %s is %.0f m from its nearest region origin (> ±4 km precision limit)"
				% [kind, p, d]
			)
		)


func test_spawn_hubs_are_local_to_a_region() -> void:
	var wr = _WR.load_default()
	var doc: Variant = _load_json("res://data/regions/spawn_points.json")
	assert_typeof(doc, TYPE_DICTIONARY, "spawn_points.json parsed")
	var pts: Array = []
	for h in doc.get("hubs", []):
		if h is Array and (h as Array).size() >= 2:
			pts.append(Vector2(float(h[0]), float(h[1])))
	assert_gt(pts.size(), 0, "at least one spawn hub is audited")
	_assert_points_local(wr, pts, "spawn hub")


func test_mob_spawns_are_local_to_a_region() -> void:
	var wr = _WR.load_default()
	var doc: Variant = _load_json("res://data/mobs/spawns.json")
	assert_typeof(doc, TYPE_DICTIONARY, "spawns.json parsed")
	var pts: Array = []
	for s in doc.get("spawns", []):
		if typeof(s) != TYPE_DICTIONARY:
			continue
		for pos in s.get("positions", []):
			if pos is Array and (pos as Array).size() >= 2:
				pts.append(Vector2(float(pos[0]), float(pos[1])))
	assert_gt(pts.size(), 0, "at least one mob spawn is audited")
	_assert_points_local(wr, pts, "mob spawn")


func test_npc_posts_are_local_to_a_region() -> void:
	var wr = _WR.load_default()
	var doc: Variant = _load_json("res://data/npcs/npcs.json")
	assert_typeof(doc, TYPE_DICTIONARY, "npcs.json parsed")
	var pts: Array = []
	for n in doc.get("npcs", []):
		if typeof(n) == TYPE_DICTIONARY and n.has("x") and n.has("y"):
			pts.append(Vector2(float(n["x"]), float(n["y"])))
	assert_gt(pts.size(), 0, "at least one NPC post is audited")
	_assert_points_local(wr, pts, "NPC post")


func test_prop_footprints_are_local_to_a_region() -> void:
	# npc_obstacles.json is generated from client props.json (the walled-BUILDING footprints), so its
	# rect centres are the server-visible prop anchors — audit them as the prop-placement proxy.
	var wr = _WR.load_default()
	var doc: Variant = _load_json("res://data/regions/npc_obstacles.json")
	assert_typeof(doc, TYPE_DICTIONARY, "npc_obstacles.json parsed")
	var pts: Array = []
	for b in doc.get("barriers", []):
		if typeof(b) == TYPE_DICTIONARY and b.has("center"):
			var c: Variant = b["center"]
			if c is Array and (c as Array).size() >= 2:
				pts.append(Vector2(float(c[0]), float(c[1])))
	assert_gt(pts.size(), 0, "at least one prop footprint is audited")
	_assert_points_local(wr, pts, "prop footprint")
