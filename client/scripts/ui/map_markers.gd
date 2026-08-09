class_name MapMarkers
extends RefCounted

# T-730/T-738: the ONE marker/POI pipeline BOTH map surfaces read (the tickets' explicit contract:
# no duplicated POI lists). Every marker class derives from data that already exists — nothing here
# authors a parallel list:
#   flight       — res://assets/flight_nodes.json (byte-identical mirror of the server file, the
#                  shared-files sync gate enforces it)
#   landmark     — res://assets/discovery_nodes.json (mirror; the lore line IS the hover text)
#   hub/dungeon  — res://assets/map_data.json (the ONE authored file: zone frames + the few places
#                  no existing data file positions; zonegen --check validates it)
#   quest_giver / quest_turnin — the live NpcMarkersLayer state (server npc_indicators, T-037/T-048)
#   gather       — the live GatherNodesLayer rows (server gather_nodes feed)
#   party        — the positions broadcast joined against the party roster (PartyFrameView idiom)
#
# COORDINATES: markers speak Godot ground (x, z). Wire/data planar pairs are (x, y) with y == ground
# z (docs/design/world-conventions.md; remote_entities_layer._remap is the precedent) — every from_*
# converts at the boundary, so no consumer ever touches the wire convention.
# Pure statics only — unit-tested headlessly from fixture data (test_map_markers.gd).

const FLIGHT_PATH := "res://assets/flight_nodes.json"
const DISCOVERY_PATH := "res://assets/discovery_nodes.json"
const MAP_DATA_PATH := "res://assets/map_data.json"

# Gather-kind -> profession. Gathering is UNGATED server-side today (craft_service._gather checks
# proximity/availability only — no skill test exists yet), so an empty known-professions array means
# "no gating: show all". When professions gate gathering, the caller passes what the character knows
# and this seam starts filtering — the minimap needs no change.
const GATHER_PROFESSIONS := {
	"herb": "herbalism",
	"ore": "mining",
	"timber": "woodcutting",
	"fibre": "tailoring",
	"fishing": "fishing",
}


static func load_doc(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var parsed = JSON.parse_string(f.get_as_text())
	return parsed if parsed is Dictionary else {}


# ---- zones ---------------------------------------------------------------


# Zone frames from map_data: [{id, name, desc, rect: Rect2(min_x, min_z, size_x, size_z)}].
static func zones(map_doc: Dictionary) -> Array:
	var out: Array = []
	for z in map_doc.get("zones", []):
		if not (z is Dictionary):
			continue
		var r: Array = z.get("rect", [])
		if r.size() != 4:
			continue
		(
			out
			. append(
				{
					"id": str(z.get("id", "")),
					"name": str(z.get("name", "")),
					"desc": str(z.get("desc", "")),
					"rect": Rect2(float(r[0]), float(r[1]), float(r[2]), float(r[3])),
				}
			)
		)
	return out


# The map zone for a ground position: the SMALLEST containing frame (Highkeep sits inside the
# Heartwold frame — city wins), or {} when outside every frame.
static func zone_for(x: float, z: float, zone_list: Array) -> Dictionary:
	var best: Dictionary = {}
	var best_area := INF
	for zone: Dictionary in zone_list:
		var rect: Rect2 = zone["rect"]
		if not rect.has_point(Vector2(x, z)):
			continue
		var area := rect.size.x * rect.size.y
		if area < best_area:
			best_area = area
			best = zone
	return best


# ---- static (world-map) marker derivation --------------------------------


static func from_flight(doc: Dictionary) -> Array:
	var out: Array = []
	for n in doc.get("nodes", []):
		if not (n is Dictionary):
			continue
		var coords: Array = n.get("coords", [])
		if coords.size() != 2:
			continue
		(
			out
			. append(
				{
					"id": "flight_" + str(n.get("id", "")),
					"kind": "flight",
					"name": str(n.get("name", "")),
					"desc": "Flight point — gryphon routes across the realm.",
					"x": float(coords[0]),
					"z": float(coords[1]),
				}
			)
		)
	return out


static func from_discovery(doc: Dictionary) -> Array:
	var out: Array = []
	for n in doc.get("nodes", []):
		if not (n is Dictionary):
			continue
		(
			out
			. append(
				{
					"id": "poi_" + str(n.get("id", "")),
					"kind": "landmark",
					"name": str(n.get("name", "")),
					"desc": str(n.get("lore", "")),
					"x": float(n.get("x", 0.0)),
					"z": float(n.get("y", 0.0)),
				}
			)
		)
	return out


static func from_landmarks(map_doc: Dictionary) -> Array:
	var out: Array = []
	for n in map_doc.get("landmarks", []):
		if not (n is Dictionary):
			continue
		(
			out
			. append(
				{
					"id": str(n.get("id", "")),
					"kind": str(n.get("kind", "landmark")),
					"name": str(n.get("name", "")),
					"desc": str(n.get("desc", "")),
					"x": float(n.get("x", 0.0)),
					"z": float(n.get("y", 0.0)),
				}
			)
		)
	return out


# All static markers inside one zone frame — the world map's whole marker set, and the minimap's
# hub/flight layer. The three docs are parameters (fixtures in tests, the shipped files live).
static func static_markers_for_zone(
	zone: Dictionary, flight_doc: Dictionary, discovery_doc: Dictionary, map_doc: Dictionary
) -> Array:
	var rect: Rect2 = zone.get("rect", Rect2())
	var out: Array = []
	for m: Dictionary in (
		from_landmarks(map_doc) + from_flight(flight_doc) + from_discovery(discovery_doc)
	):
		if rect.has_point(Vector2(float(m["x"]), float(m["z"]))):
			out.append(m)
	return out


# ---- live (minimap) marker derivation ------------------------------------


# Quest !/? pips from NpcMarkersLayer state rows: {name, x, z, symbol, color, visible}. The symbol
# and color come straight from NpcMarker.marker_style (the T-037/T-048 style oracle) — this maps,
# it never re-decides quest state.
static func from_npc_markers(rows: Array) -> Array:
	var out: Array = []
	for r in rows:
		if not (r is Dictionary) or not bool(r.get("visible", true)):
			continue
		var symbol := str(r.get("symbol", ""))
		if symbol != "!" and symbol != "?":
			continue
		(
			out
			. append(
				{
					"id": "quest_" + str(r.get("id", "")),
					"kind": "quest_giver" if symbol == "!" else "quest_turnin",
					"name": str(r.get("name", "")),
					"desc": "",
					"x": float(r.get("x", 0.0)),
					"z": float(r.get("z", 0.0)),
					"symbol": symbol,
					"color": r.get("color", Color.WHITE),
				}
			)
		)
	return out


static func can_gather(gather_kind: String, known_professions: Array) -> bool:
	if known_professions.is_empty():
		return true  # no profession gating exists in the game today (see const note)
	return str(GATHER_PROFESSIONS.get(gather_kind, "")) in known_professions


# Gather pips from GatherNodesLayer rows: {id, name, x, z, kind, available}.
static func from_gather(rows: Array, known_professions: Array) -> Array:
	var out: Array = []
	for r in rows:
		if not (r is Dictionary) or not bool(r.get("available", false)):
			continue
		var gkind := str(r.get("kind", ""))
		if not can_gather(gkind, known_professions):
			continue
		(
			out
			. append(
				{
					"id": "gather_" + str(r.get("id", "")),
					"kind": "gather",
					"name": str(r.get("name", "")),
					"desc": "",
					"x": float(r.get("x", 0.0)),
					"z": float(r.get("z", 0.0)),
					"gather_kind": gkind,
				}
			)
		)
	return out


# Party-member markers from the positions broadcast (wire rows: x, y=ground z) joined against the
# roster — the PartyFrameView join, projected instead of listed. Own row excluded (the player IS
# the minimap center).
static func party_markers(positions: Dictionary, party_members: Array, my_peer_id: int) -> Array:
	var out: Array = []
	for p in positions.get("players", []):
		if not (p is Dictionary) or int(p.get("peer_id", -1)) == my_peer_id:
			continue
		var uname := str(p.get("username", ""))
		if not (uname in party_members):
			continue
		(
			out
			. append(
				{
					"id": "party_" + uname,
					"kind": "party",
					"name": uname,
					"desc": "",
					"x": float(p.get("x", 0.0)),
					"z": float(p.get("y", 0.0)),
					"char_class": str(p.get("char_class", "")),
				}
			)
		)
	return out


# ---- coordinate transforms (both surfaces) -------------------------------


# World ground -> zone-image pixel. Image row 0 = the frame's min z edge = NORTH (smaller z is
# further north; yaw 0 faces -Z), so baked images are north-up with no flip.
static func world_to_px(x: float, z: float, rect: Rect2, img_size: Vector2) -> Vector2:
	return Vector2(
		(x - rect.position.x) / rect.size.x * img_size.x,
		(z - rect.position.y) / rect.size.y * img_size.y
	)


# World ground -> minimap pixel offset from center. North-locked: north up, east right. Rotate
# mode: the player's facing points up, so the whole frame counter-rotates by yaw (yaw 0 = north,
# growing clockwise — CompassStrip convention).
static func minimap_offset(
	x: float,
	z: float,
	center: Vector2,
	radius_m: float,
	half_px: float,
	yaw_rad: float,
	rotate_mode: bool
) -> Vector2:
	var base := Vector2(x - center.x, z - center.y) * (half_px / maxf(radius_m, 0.001))
	return base.rotated(-yaw_rad) if rotate_mode else base


# Clamp an offset to the minimap edge (a hub beyond the window still reads AT the rim, WoW-style).
static func clamp_to_edge(offset: Vector2, half_px: float) -> Vector2:
	return offset if offset.length() <= half_px else offset.normalized() * half_px


# Nearest marker (index into markers_px, -1 if none within max_dist) — the world map's hover test.
static func nearest_marker(markers_px: Array, mouse: Vector2, max_dist: float) -> int:
	var best := -1
	var best_d := max_dist
	for i in markers_px.size():
		var d: float = (markers_px[i] as Vector2).distance_to(mouse)
		if d <= best_d:
			best_d = d
			best = i
	return best
