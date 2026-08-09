# T-379: server-side movement collision (anti-noclip). The movement intake path
# (main.gd::_on_request_move) already speed-caps, per-second-budgets and bounds-clamps a delta and
# derives z from the terrain field, but it never tested the move against world geometry — a modified
# client sending rate-legal deltas *through* a wall was accepted (noclip: skip a palisade, clip into
# the keep vault, escape a choke). This module is the geometry gate: a coarse blocker-volume test
# (the ticket's "buildings/walls before full navmesh" tier), NOT a full per-tick navmesh path query.
#
# A barrier is a set of impassable WALL SEGMENTS in server planar coords (x, z) == PlayerSessions
# pos (x, y). A move is blocked iff its from->to segment crosses any wall segment. Door/gate
# openings are GAPS between segments, so legitimate traversal through a door crosses nothing (this
# keeps the walk-in mandate legal — the same opening the navmesh bake / walkin-audit walk uses).
#
# Non-noclip legitimate motion is untouched by design: the server is PLANAR-authoritative and
# derives z itself, so falling/knockback/bridge/interior-floor height and the SERVER-initiated era
# rift (which repositions via update_position, not request_move) never reach this gate. Only a
# client-driven request_move delta is tested.
#
# Pure / injectable: no OS time, no engine singletons. Barriers load once from data
# (res://data/regions/barriers.json); geometry never changes at runtime, so the wall list is built
# at boot and the per-move test is a handful of segment-crossing checks.

extends RefCounted

const _SC = preload("res://scripts/server_config.gd")
const _WR = preload("res://scripts/world_regions.gd")  # T-590: region-aware world clamp

# Each entry is a PackedVector2Array [a, b] wall segment; a move segment crossing any of these is
# blocked. Kept flat (not per-barrier) so the hot path is one linear scan.
var _walls: Array[PackedVector2Array] = []
# T-590: the region table drives the world clamp — a move's landing point is clamped to its region's
# envelope (else the global fallback). Null (no data file) degrades to the flat ±500 box. Today
# every region -> the global ±500 box, so the clamp is byte-identical to the pre-T-590 behaviour.
var _regions = null


func _init(
	barriers_path: String = "res://data/regions/barriers.json",
	regions_path: String = "res://data/regions/regions.json"
) -> void:
	if barriers_path != "" and FileAccess.file_exists(barriers_path):
		load_barriers(barriers_path)
	if regions_path != "":
		_regions = _WR.load_from(regions_path)


func load_barriers(path: String) -> void:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_warning("[movement_collision] cannot open barriers %s" % path)
		return
	var doc = JSON.parse_string(f.get_as_text())
	if typeof(doc) != TYPE_DICTIONARY:
		push_warning("[movement_collision] malformed barriers %s" % path)
		return
	for b in doc.get("barriers", []):
		if typeof(b) != TYPE_DICTIONARY:
			continue
		match str(b.get("type", "")):
			"polyline":
				add_polyline(b.get("points", []), bool(b.get("closed", false)))
			"rect":
				add_rect(
					_v2(b.get("center", [0, 0])),
					_v2(b.get("half", [0, 0])),
					float(b.get("rot_deg", 0.0)),
					b.get("doors", [])
				)
			_:
				push_warning("[movement_collision] unknown barrier type %s" % b.get("type"))


# A wall run of consecutive vertices; `closed` adds the last->first segment (an unbroken ring).
# An OPEN polyline leaves the last->first gap unwalled — that is how a gate opening is expressed.
func add_polyline(points: Array, closed: bool) -> void:
	var n := points.size()
	if n < 2:
		return
	for i in range(n - 1):
		_add_segment(_v2(points[i]), _v2(points[i + 1]))
	if closed:
		_add_segment(_v2(points[n - 1]), _v2(points[0]))


# A rotated rectangle footprint (solid building) as four wall segments, minus any door gaps. `doors`
# is a list of {"center":[x,z], "half":w} openings in WORLD coords; the wall segment that a door
# straddles is split so the opening itself is passable. Provided for the visual lane to register
# solid buildings later; the seed barrier set uses only the curtain-wall polyline.
func add_rect(center: Vector2, half: Vector2, rot_deg: float, doors: Array) -> void:
	var th := deg_to_rad(rot_deg)
	var c := cos(th)
	var s := sin(th)
	var corners: Array[Vector2] = []
	for lc in [
		Vector2(-half.x, -half.y),
		Vector2(half.x, -half.y),
		Vector2(half.x, half.y),
		Vector2(-half.x, half.y)
	]:
		corners.append(center + Vector2(lc.x * c - lc.y * s, lc.x * s + lc.y * c))
	for i in range(4):
		_add_edge_with_doors(corners[i], corners[(i + 1) % 4], doors)


# Full request_move intake validation for a delta from `current` (planar x,z). Returns
# {ok:bool, reason:String, pos:Vector2}. Order (fail-closed): per-message speed cap -> per-second
# budget (the injected MoveRateLimiter, consumed only when the move is otherwise legal-speed) ->
# bounds clamp -> anti-noclip geometry gate. `reason` is a debug tag ("speed"/"rate"/"collision").
# Pure apart from the injected limiter + clock tick, so it unit-tests end-to-end.
func resolve(
	current: Vector2,
	delta: Vector2,
	peer_id: int,
	now_tick: int,
	limiter,
	max_speed: float = _SC.MAX_SPEED_PER_TICK,
	units_per_second: float = _SC.MOVE_UNITS_PER_SECOND
) -> Dictionary:
	var speed := delta.length()
	if speed > max_speed:
		return {"ok": false, "reason": "speed", "pos": current}
	if not limiter.allow(peer_id, speed, now_tick, units_per_second):
		return {"ok": false, "reason": "rate", "pos": current}
	var np := current + delta
	# Out-of-bounds is clamped (not rejected): T-590 routes this through the per-region envelope (the
	# hard box the mountain ring hides), which today is the flat ±500 box for every region.
	np = _clamp_world(np)
	if segment_blocked(current.x, current.y, np.x, np.y):
		return {"ok": false, "reason": "collision", "pos": current}
	return {"ok": true, "reason": "", "pos": np}


# T-590: clamp a planar point to its region's world envelope (else the flat ±500 fallback when the
# region table is unloaded — unit tests that skip the data file keep the pre-T-590 clamp exactly).
func _clamp_world(p: Vector2) -> Vector2:
	if _regions != null:
		return _regions.clamp_xz(p.x, p.y)
	return Vector2(
		clampf(p.x, _SC.BOUNDS_MIN, _SC.BOUNDS_MAX), clampf(p.y, _SC.BOUNDS_MIN, _SC.BOUNDS_MAX)
	)


# --- the gate: true if the from->to move segment crosses any wall segment -----
func segment_blocked(fx: float, fz: float, tx: float, tz: float) -> bool:
	var a := Vector2(fx, fz)
	var b := Vector2(tx, tz)
	# Exact equality only: is_equal_approx's RELATIVE epsilon (~6e-5 at town coords) skipped the
	# micro-steps the NPC separation shuffle produces, letting a mover tunnel through a wall in
	# sub-epsilon increments (Report #15: Nell inching into the cottage). A zero-length segment
	# crosses nothing; any real step, however tiny, must face the crossing test.
	if a == b:
		return false
	for w in _walls:
		if _segments_cross(a, b, w[0], w[1]):
			return true
	return false


# Transversal segment crossing: true iff a-b cuts across the wall line c-d within the wall's
# span. Collinear overlap (sliding ALONG a wall, d1 == d2 == 0) and a step LEAVING a point on
# the wall line (d1 == 0) stay legal, so walking beside a wall is never false-positived — but a
# transversal step may not END exactly ON the wall line (d2 == 0 with d1 != 0 counts as a hit):
# Report #15 showed that landing on the line lets the NEXT step continue through (a two-step
# wall leak — Nell pinned "inside" the cottage boundary), and point_inside parity reads such a
# boundary point as inside. Blocking the landing keeps strictly-outside movers strictly outside.
# (Godot's Geometry2D.segment_intersects_segment counts collinear overlap as a hit; that would
# block along-wall motion, so we do the orientation test ourselves.)
func _segments_cross(a: Vector2, b: Vector2, c: Vector2, d: Vector2) -> bool:
	var d1 := _orient(c, d, a)
	var d2 := _orient(c, d, b)
	var d3 := _orient(a, b, c)
	var d4 := _orient(a, b, d)
	return (
		((d1 > 0.0 and d2 <= 0.0) or (d1 < 0.0 and d2 >= 0.0))
		and ((d3 > 0.0 and d4 < 0.0) or (d3 < 0.0 and d4 > 0.0))
	)


# Signed area (z of the cross product) of a->b vs a->c: >0 left turn, <0 right, 0 collinear.
func _orient(a: Vector2, b: Vector2, c: Vector2) -> float:
	return (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)


func wall_count() -> int:
	return _walls.size()


# T-373: is the planar point (x, z) enclosed by a barrier footprint? Even-odd ray-crossing over the
# wall segments (a horizontal ray to +x; an odd crossing count == inside). Exact for CLOSED
# footprints (add_rect building boxes / closed polylines = solid volumes); for the OPEN curtain-wall
# polyline it reads correct deep inside the ring — a spawn hub is never authored at the gate mouth
# where the gap could leak a ray. spawn_dispersion.gd uses it to reject a hub inside geometry.
func point_inside(x: float, z: float) -> bool:
	var crossings := 0
	for w in _walls:
		var az := w[0].y
		var bz := w[1].y
		if (az > z) != (bz > z):  # the segment straddles the ray's z
			var ix := w[0].x + (z - az) / (bz - az) * (w[1].x - w[0].x)
			if ix > x:  # crossing is to the +x side of the point
				crossings += 1
	return (crossings & 1) == 1


# --- internals ----------------------------------------------------------------
func _add_segment(a: Vector2, b: Vector2) -> void:
	if not a.is_equal_approx(b):
		_walls.append(PackedVector2Array([a, b]))


func _add_edge_with_doors(a: Vector2, b: Vector2, doors: Array) -> void:
	# Carve each door opening out of this edge: split the edge at the door's projected span so the
	# opening is a gap. Multiple doors on one edge are carved in order along the edge parameter.
	var length := a.distance_to(b)
	if length <= 0.0001:
		return
	var dir := (b - a) / length
	var cuts: Array = []  # [t_lo, t_hi] gaps in edge param [0,1]
	for d in doors:
		if typeof(d) != TYPE_DICTIONARY:
			continue
		var dc := _v2(d.get("center", [0, 0]))
		var dw := float(d.get("half", 0.0))
		var t := (dc - a).dot(dir) / length  # projection of door center onto the edge
		var perp := absf((dc - a).cross(dir))  # distance of the door from the edge line
		if perp > maxf(dw, 0.5) or t < -0.05 or t > 1.05:
			continue  # this door isn't on this edge
		var span := dw / length
		cuts.append([clampf(t - span, 0.0, 1.0), clampf(t + span, 0.0, 1.0)])
	cuts.sort_custom(func(x, y): return x[0] < y[0])
	var cursor := 0.0
	for gap in cuts:
		if gap[0] > cursor:
			_add_segment(a + dir * (length * cursor), a + dir * (length * gap[0]))
		cursor = maxf(cursor, gap[1])
	if cursor < 1.0:
		_add_segment(a + dir * (length * cursor), b)


func _v2(arr) -> Vector2:
	if arr is Vector2:
		return arr
	if arr is Array and arr.size() >= 2:
		return Vector2(float(arr[0]), float(arr[1]))
	return Vector2.ZERO
