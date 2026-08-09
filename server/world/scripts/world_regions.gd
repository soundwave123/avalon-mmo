class_name WorldRegions
extends RefCounted

# T-590: the zone-origin / terrain-region table — the plumbing-side source of truth for region
# ORIGINS, EXTENTS, ERAS, per-region RESPAWN anchors and per-region world CLAMP envelopes. Loaded
# once from res://data/regions/regions.json. This is the data the continent program (T-592..596)
# grows; T-590 seeds it with EXACTLY today's world (the Wold + the Ashmoor March) so nothing moves.
#
# Split of concerns: the TERRAIN height dispatch lives in the shared/pure terrain_field.gd (which
# holds a const MIRROR of the origins + sampler names so that byte-identical client/server field has
# no file dependency — the same rule broadcast_builder.gd REGION_ANCHORS follows). THIS module owns
# everything the SERVER plumbing needs (clamp, respawn, era, membership origin) and is server-only,
# so it may load JSON freely. test_world_regions asserts the two tables' origins agree.
#
# region lookup uses the T-371 NEAREST-ORIGIN idiom (broadcast_builder.region_of): a position
# belongs to the region whose origin is nearest. clamp_xz honours a region's own envelope when it
# declares one, else the global fallback — today EVERY region -> the global ±500 box, so movement +
# spawn validation are byte-identical to the pre-T-590 flat clamp. T-593 raises a region's envelope
# by editing its "clamp" block; no code change.

const _DEFAULT_PATH := "res://data/regions/regions.json"

var _regions: Array = []  # each: {id, era, origin:Vector2, extent, respawn:Vector2, clamp}
var _global_min := Vector2(-500.0, -500.0)
var _global_max := Vector2(500.0, 500.0)


# Build from an already-parsed regions document (the test seam — a toy region proves the mechanism
# generalizes without a file). An empty/malformed doc yields an empty table (callers fall back to
# the global clamp), never a crash.
func _init(doc: Dictionary = {}) -> void:
	if doc.is_empty():
		return
	var gc: Dictionary = doc.get("global_clamp", {})
	if gc.has("min") and gc.has("max"):
		_global_min = _v2(gc["min"])
		_global_max = _v2(gc["max"])
	for r in doc.get("regions", []):
		if typeof(r) != TYPE_DICTIONARY:
			continue
		_regions.append(_parse_region(r))


# Live loader: read + parse the shipped table. Returns an empty (global-clamp-only) table if the
# file is missing/malformed, so a boot without the data file degrades to the pre-T-590 flat clamp.
static func load_default() -> WorldRegions:
	return load_from(_DEFAULT_PATH)


static func load_from(path: String) -> WorldRegions:
	if path == "" or not FileAccess.file_exists(path):
		return WorldRegions.new()
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if typeof(parsed) != TYPE_DICTIONARY:
		push_warning("[world_regions] malformed table %s" % path)
		return WorldRegions.new()
	return WorldRegions.new(parsed)


func _parse_region(r: Dictionary) -> Dictionary:
	var clamp_block = null
	var c: Variant = r.get("clamp", null)
	if typeof(c) == TYPE_DICTIONARY and c.has("min") and c.has("max"):
		clamp_block = {"min": _v2(c["min"]), "max": _v2(c["max"])}
	return {
		"id": str(r.get("region_id", "")),
		"era": int(r.get("era", 1)),
		"origin": _v2(r.get("origin", [0.0, 0.0])),
		"extent": r.get("extent", {}),
		"respawn": _v2(r.get("respawn", r.get("origin", [0.0, 0.0]))),
		"clamp": clamp_block,
	}


func region_count() -> int:
	return _regions.size()


func origin_of(idx: int) -> Vector2:
	return _regions[idx]["origin"] if idx >= 0 and idx < _regions.size() else Vector2.ZERO


func region_id_of(idx: int) -> String:
	return str(_regions[idx]["id"]) if idx >= 0 and idx < _regions.size() else ""


# T-593 region_local_bounds audit: the effective clamp envelope for a region index (its own box if
# declared, else the global fallback), as {min: Vector2, max: Vector2}. The precision guard asserts
# every reachable point in a region (bounded by this box) sits within ±4 km of the region origin —
# the single-precision-forever invariant (docs/research/2026-07-19-godot-large-zones.md).
func clamp_box_of(idx: int) -> Dictionary:
	var mn := _global_min
	var mx := _global_max
	if idx >= 0 and idx < _regions.size() and _regions[idx]["clamp"] != null:
		mn = _regions[idx]["clamp"]["min"]
		mx = _regions[idx]["clamp"]["max"]
	return {"min": mn, "max": mx}


# The index of the region whose origin is NEAREST to (x, z) — the T-371 nearest-anchor idiom, mirror
# of broadcast_builder.region_of. Planar; y-height never gates domain. -1 when the table is empty.
func region_index(x: float, z: float) -> int:
	var best := -1
	var best_d2: float = INF
	for i in _regions.size():
		var o: Vector2 = _regions[i]["origin"]
		var dx := x - o.x
		var dz := z - o.y
		var d2 := dx * dx + dz * dz
		if d2 < best_d2:
			best_d2 = d2
			best = i
	return best


func region_id_at(x: float, z: float) -> String:
	return region_id_of(region_index(x, z))


func era_at(x: float, z: float) -> int:
	var idx := region_index(x, z)
	return int(_regions[idx]["era"]) if idx >= 0 else 1


func origin_at(x: float, z: float) -> Vector2:
	return origin_of(region_index(x, z))


# The overworld respawn anchor for a death at (x, z): the nearest region's own respawn point. Falls
# back to world origin when the table is empty. Replaces instance_service's hardcoded ZERO/Ashmoor
# branch (T-369/T-371) — byte-identical today, generalizing to every future zone for free.
func respawn_at(x: float, z: float) -> Vector2:
	var idx := region_index(x, z)
	return _regions[idx]["respawn"] if idx >= 0 else Vector2.ZERO


# The world clamp for (x, z): the containing/nearest region's own envelope if it declares one, else
# the global fallback. Replaces the flat ±500 box in movement + spawn validation.
func clamp_xz(x: float, z: float) -> Vector2:
	var mn := _global_min
	var mx := _global_max
	var idx := region_index(x, z)
	if idx >= 0 and _regions[idx]["clamp"] != null:
		mn = _regions[idx]["clamp"]["min"]
		mx = _regions[idx]["clamp"]["max"]
	return Vector2(clampf(x, mn.x, mx.x), clampf(z, mn.y, mx.y))


# Is (x, z) inside its region's clamp envelope (or the global fallback)? The spawn-dispersion
# safety oracle uses this instead of a flat ±500 test.
func in_bounds(x: float, z: float) -> bool:
	var mn := _global_min
	var mx := _global_max
	var idx := region_index(x, z)
	if idx >= 0 and _regions[idx]["clamp"] != null:
		mn = _regions[idx]["clamp"]["min"]
		mx = _regions[idx]["clamp"]["max"]
	return x >= mn.x and x <= mx.x and z >= mn.y and z <= mx.y


static func _v2(a: Variant) -> Vector2:
	if a is Vector2:
		return a
	if a is Array and (a as Array).size() >= 2:
		return Vector2(float(a[0]), float(a[1]))
	return Vector2.ZERO
