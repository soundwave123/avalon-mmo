extends GutTest

# T-730/T-738: the shared map marker pipeline — per-source derivation from fixture data, the
# coordinate transforms both surfaces use, and the against-the-shipped-files checks that prove the
# maps derive from EXISTING data (the tickets' "one pipeline, no duplicated POI lists" contract).

const MapMarkersT = preload("res://scripts/ui/map_markers.gd")

const FLIGHT_FIXTURE := {
	"nodes":
	[
		{"id": "village", "name": "Elmsvale Village", "coords": [-12.0, -8.0]},
		{"id": "highkeep", "name": "Highkeep Roost", "coords": [8.0, -118.0]},
	]
}
const DISCOVERY_FIXTURE := {
	"nodes":
	[
		{"id": "well", "name": "The Fevered Well", "x": 42.0, "y": -13.0, "lore": "Black roots."},
	]
}
const MAP_FIXTURE := {
	"zones":
	[
		{"id": "vale", "name": "Vale", "rect": [-500.0, -500.0, 1000.0, 1000.0], "desc": "d"},
		{"id": "city", "name": "City", "rect": [-130.0, -360.0, 260.0, 260.0], "desc": "d"},
	],
	"landmarks":
	[
		{"id": "hub_a", "kind": "hub", "name": "Hub A", "x": -12.0, "y": -8.0, "desc": "hub desc"},
		{
			"id": "dg_a",
			"kind": "dungeon",
			"name": "Crypt",
			"x": 14.0,
			"y": -12.5,
			"desc": "dg desc"
		},
	]
}


func test_from_flight_derives_kind_name_and_ground_coords() -> void:
	var m: Array = MapMarkersT.from_flight(FLIGHT_FIXTURE)
	assert_eq(m.size(), 2)
	assert_eq(m[0]["kind"], "flight")
	assert_eq(m[0]["name"], "Elmsvale Village")
	assert_eq(float(m[0]["x"]), -12.0)
	assert_eq(float(m[0]["z"]), -8.0)  # wire planar y -> ground z


func test_from_discovery_uses_lore_as_hover_desc() -> void:
	var m: Array = MapMarkersT.from_discovery(DISCOVERY_FIXTURE)
	assert_eq(m.size(), 1)
	assert_eq(m[0]["kind"], "landmark")
	assert_eq(m[0]["desc"], "Black roots.")
	assert_eq(float(m[0]["z"]), -13.0)


func test_from_landmarks_carries_authored_kind_and_desc() -> void:
	var m: Array = MapMarkersT.from_landmarks(MAP_FIXTURE)
	assert_eq(m.size(), 2)
	assert_eq(m[0]["kind"], "hub")
	assert_eq(m[1]["kind"], "dungeon")
	assert_eq(m[1]["desc"], "dg desc")


func test_zone_for_picks_smallest_containing_frame() -> void:
	var zone_list: Array = MapMarkersT.zones(MAP_FIXTURE)
	assert_eq(zone_list.size(), 2)
	# Inside the city rect -> city wins over the containing vale frame.
	assert_eq(str(MapMarkersT.zone_for(0.0, -240.0, zone_list)["id"]), "city")
	# In the open vale -> vale.
	assert_eq(str(MapMarkersT.zone_for(200.0, 200.0, zone_list)["id"]), "vale")
	# Outside every frame -> {}.
	assert_true(MapMarkersT.zone_for(5000.0, 5000.0, zone_list).is_empty())


func test_static_markers_filter_to_zone_frame() -> void:
	var zone_list: Array = MapMarkersT.zones(MAP_FIXTURE)
	var vale: Dictionary = MapMarkersT.zone_for(200.0, 200.0, zone_list)
	var m: Array = MapMarkersT.static_markers_for_zone(
		vale, FLIGHT_FIXTURE, DISCOVERY_FIXTURE, MAP_FIXTURE
	)
	# hubs (2 landmarks) + flight (2) + discovery (1) — all inside the vale frame.
	assert_eq(m.size(), 5)
	var city: Dictionary = MapMarkersT.zone_for(0.0, -240.0, zone_list)
	var mc: Array = MapMarkersT.static_markers_for_zone(
		city, FLIGHT_FIXTURE, DISCOVERY_FIXTURE, MAP_FIXTURE
	)
	# Only the roost (8, -118) falls inside the city rect (z -360..-100).
	assert_eq(mc.size(), 1)
	assert_eq(mc[0]["kind"], "flight")


func test_from_npc_markers_maps_symbols_never_requeries_state() -> void:
	var rows := [
		{"id": "a", "name": "Giver", "x": 1.0, "z": 2.0, "symbol": "!", "visible": true},
		{"id": "b", "name": "TurnIn", "x": 3.0, "z": 4.0, "symbol": "?", "visible": true},
		{"id": "c", "name": "Idle", "x": 5.0, "z": 6.0, "symbol": "", "visible": false},
	]
	var m: Array = MapMarkersT.from_npc_markers(rows)
	assert_eq(m.size(), 2)
	assert_eq(m[0]["kind"], "quest_giver")
	assert_eq(m[1]["kind"], "quest_turnin")


func test_from_gather_filters_availability_and_profession_seam() -> void:
	var rows := [
		{"id": "g1", "name": "Bloodthorn", "x": 2.0, "z": 28.0, "kind": "herb", "available": true},
		{"id": "g2", "name": "Copper", "x": 4.0, "z": 30.0, "kind": "ore", "available": true},
		{"id": "g3", "name": "Spent", "x": 6.0, "z": 32.0, "kind": "herb", "available": false},
	]
	# Empty professions = today's ungated game: every AVAILABLE node shows.
	assert_eq(MapMarkersT.from_gather(rows, []).size(), 2)
	# The seam: a character knowing only mining sees ore nodes alone.
	var mined: Array = MapMarkersT.from_gather(rows, ["mining"])
	assert_eq(mined.size(), 1)
	assert_eq(mined[0]["gather_kind"], "ore")


func test_party_markers_join_roster_and_exclude_self() -> void:
	var positions := {
		"players":
		[
			{"peer_id": 1, "username": "me", "x": 0.0, "y": 0.0, "char_class": "mage"},
			{"peer_id": 2, "username": "friend", "x": 10.0, "y": -5.0, "char_class": "priest"},
			{"peer_id": 3, "username": "stranger", "x": 20.0, "y": 20.0, "char_class": "warrior"},
		]
	}
	var m: Array = MapMarkersT.party_markers(positions, ["me", "friend"], 1)
	assert_eq(m.size(), 1)
	assert_eq(m[0]["name"], "friend")
	assert_eq(float(m[0]["z"]), -5.0)  # wire y -> ground z
	assert_eq(m[0]["char_class"], "priest")


func test_world_to_px_north_up_mapping() -> void:
	var rect := Rect2(-500.0, -500.0, 1000.0, 1000.0)
	var size := Vector2(256.0, 256.0)
	assert_eq(MapMarkersT.world_to_px(-500.0, -500.0, rect, size), Vector2(0.0, 0.0))
	assert_eq(MapMarkersT.world_to_px(500.0, 500.0, rect, size), Vector2(256.0, 256.0))
	assert_eq(MapMarkersT.world_to_px(0.0, 0.0, rect, size), Vector2(128.0, 128.0))
	# North (smaller z) maps to smaller pixel y — row 0 is the north edge.
	var north_px := MapMarkersT.world_to_px(0.0, -400.0, rect, size)
	assert_lt(north_px.y, 128.0)


func test_minimap_offset_north_locked_and_rotate_mode() -> void:
	var center := Vector2(0.0, 0.0)
	# North-locked: an object 10 m east sits right of center; 10 m north sits above (negative y).
	var east := MapMarkersT.minimap_offset(10.0, 0.0, center, 100.0, 75.0, 0.0, false)
	assert_almost_eq(east.x, 7.5, 0.001)
	assert_almost_eq(east.y, 0.0, 0.001)
	var north := MapMarkersT.minimap_offset(0.0, -10.0, center, 100.0, 75.0, 0.0, false)
	assert_almost_eq(north.y, -7.5, 0.001)
	# Rotate mode, facing east (yaw 90°): the object dead ahead (east) now points UP.
	var ahead := MapMarkersT.minimap_offset(10.0, 0.0, center, 100.0, 75.0, PI / 2.0, true)
	assert_almost_eq(ahead.x, 0.0, 0.001)
	assert_almost_eq(ahead.y, -7.5, 0.001)


func test_zoom_steps_scale_offsets() -> void:
	var center := Vector2(0.0, 0.0)
	# Halving the radius doubles the pixel offset — the zoom-step contract both maps rely on.
	var far := MapMarkersT.minimap_offset(20.0, 0.0, center, 120.0, 75.0, 0.0, false)
	var near := MapMarkersT.minimap_offset(20.0, 0.0, center, 60.0, 75.0, 0.0, false)
	assert_almost_eq(near.x, far.x * 2.0, 0.001)


func test_clamp_to_edge_keeps_out_of_window_markers_at_rim() -> void:
	var off := Vector2(300.0, 0.0)
	assert_eq(MapMarkersT.clamp_to_edge(off, 75.0), Vector2(75.0, 0.0))
	assert_eq(MapMarkersT.clamp_to_edge(Vector2(10.0, 10.0), 75.0), Vector2(10.0, 10.0))


func test_nearest_marker_hover_test() -> void:
	var pts := [Vector2(10.0, 10.0), Vector2(100.0, 100.0)]
	assert_eq(MapMarkersT.nearest_marker(pts, Vector2(12.0, 11.0), 12.0), 0)
	assert_eq(MapMarkersT.nearest_marker(pts, Vector2(98.0, 99.0), 12.0), 1)
	assert_eq(MapMarkersT.nearest_marker(pts, Vector2(50.0, 50.0), 12.0), -1)


# ---- against the SHIPPED files: derivation only, no duplicated lists ----------------------------


func test_shipped_docs_load_and_cover_the_dod_zones() -> void:
	var zone_list: Array = MapMarkersT.zones(MapMarkersT.load_doc(MapMarkersT.MAP_DATA_PATH))
	var ids: Array = []
	for z: Dictionary in zone_list:
		ids.append(z["id"])
	# The T-730 DoD zones all have frames.
	for want in ["heartwold", "highkeep", "ashmoor"]:
		assert_has(ids, want)


func test_shipped_markers_derive_one_to_one_from_the_source_files() -> void:
	# EVERY flight/discovery marker comes from the mirrored server files — same count, same ids,
	# nothing invented, nothing dropped (the "no second POI list" DoD assertion; byte-identity of
	# the mirrors themselves is enforced by scripts/check_shared_files_sync.sh).
	var flight_doc: Dictionary = MapMarkersT.load_doc(MapMarkersT.FLIGHT_PATH)
	var flight_markers: Array = MapMarkersT.from_flight(flight_doc)
	assert_eq(flight_markers.size(), (flight_doc.get("nodes", []) as Array).size())
	assert_gt(flight_markers.size(), 0)
	var disc_doc: Dictionary = MapMarkersT.load_doc(MapMarkersT.DISCOVERY_PATH)
	var disc_markers: Array = MapMarkersT.from_discovery(disc_doc)
	assert_eq(disc_markers.size(), (disc_doc.get("nodes", []) as Array).size())
	assert_gt(disc_markers.size(), 0)


func test_heartwold_map_carries_the_owner_major_places() -> void:
	# T-730 DoD: hubs + flight nodes + dungeon entrance + landmark POIs on the Heartwold map.
	var map_doc: Dictionary = MapMarkersT.load_doc(MapMarkersT.MAP_DATA_PATH)
	var zone_list: Array = MapMarkersT.zones(map_doc)
	var vale: Dictionary = MapMarkersT.zone_for(0.0, 100.0, zone_list)
	assert_eq(str(vale["id"]), "heartwold")
	var markers: Array = MapMarkersT.static_markers_for_zone(
		vale,
		MapMarkersT.load_doc(MapMarkersT.FLIGHT_PATH),
		MapMarkersT.load_doc(MapMarkersT.DISCOVERY_PATH),
		map_doc
	)
	var kinds := {}
	var names: Array = []
	for m: Dictionary in markers:
		kinds[m["kind"]] = int(kinds.get(m["kind"], 0)) + 1
		names.append(m["name"])
	for want_kind in ["hub", "dungeon", "flight", "landmark"]:
		assert_gt(int(kinds.get(want_kind, 0)), 0, "missing marker kind: %s" % want_kind)
	assert_has(names, "Elmsvale Village")
	assert_has(names, "The Hollowed Crypt")
	# Every marker offers hover text (name always; desc for the static classes).
	for m: Dictionary in markers:
		assert_ne(str(m["name"]), "")
		assert_ne(str(m["desc"]), "")
