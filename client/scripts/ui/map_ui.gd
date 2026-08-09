class_name MapUi
extends Node

# T-730/T-738: the map system's mount seam (main.gd sits at its line cap — one call wires
# everything, the CraftingUi idiom) PLUS the shared per-zone terrain-bake cache. ONE baked image
# per zone serves BOTH surfaces: the world map draws it whole, the minimap crops it — the tickets'
# shared-pipeline contract, enforced by both panels reading textures from here.
#
# Baking is spread across frames (ROWS_PER_FRAME) so the RESOLUTION^2 field samples never land on
# one frame; the ImageTexture updates per chunk, so the chart fades in row by row.

const RESOLUTION := 512
const ROWS_PER_FRAME := 8

var world_map: WorldMapPanel = null
var minimap: MinimapPanel = null
var _baker = MapTerrainBaker.new()
var _bakes: Dictionary = {}  # zone_id -> {img, tex, rect, next_row}
var _zones: Array = []  # zone frames from map_data.json (loaded once)
var _static_cache: Dictionary = {}  # zone_id -> static markers (docs re-read only on zone change)


static func mount(hud: Node, main: Node, is_typing: Callable, settings_panel = null) -> MapUi:
	var ui := MapUi.new()
	ui.name = "MapSystem"
	hud.add_child(ui)
	ui._zones = MapMarkers.zones(MapMarkers.load_doc(MapMarkers.MAP_DATA_PATH))
	var providers := {
		"is_typing": is_typing,
		"player_pos": func() -> Vector3: return MapUi.player_ground_pos(main),
		"player_yaw": func() -> float: return MapUi.player_yaw(main),
		"texture_for": func(zone: Dictionary) -> Texture2D: return ui.texture_for(zone),
	}
	var wm := WorldMapPanel.new()
	hud.add_child(wm)
	wm.setup(providers)
	ui.world_map = wm
	# T-738: the minimap adds the live layers — every provider reads state the client ALREADY
	# holds (NpcMarkersLayer pips, the GatherNodes layer, last_positions + party roster); no new
	# server ops. Zoom changes persist through SettingsPanel (the one settings.cfg writer).
	var mm := MinimapPanel.new()
	hud.add_child(mm)
	var mm_providers := providers.duplicate()
	mm_providers["current_zone"] = func() -> Dictionary: return ui.current_zone(main)
	mm_providers["static_markers"] = func(zone: Dictionary) -> Array: return ui.static_markers(zone)
	mm_providers["quest_rows"] = func() -> Array: return MapUi.npc_rows(main)
	mm_providers["gather_rows"] = func() -> Array: return MapUi.gather_rows(main)
	mm_providers["party_state"] = func() -> Dictionary: return MapUi.party_state(main)
	# Profession gating seam: gathering is ungated server-side today, so every node qualifies
	# (MapMarkers.can_gather treats [] as no-gating); wire real known-professions here when the
	# profession system gates gathering.
	mm_providers["professions"] = func() -> Array: return []
	var on_zoom := Callable()
	if settings_panel != null:
		on_zoom = func(idx: int) -> void: settings_panel.notify_minimap_zoom(idx)
	mm.setup(mm_providers, on_zoom)
	ui.minimap = mm
	if settings_panel != null:
		settings_panel.bind_minimap(mm)  # boot restore + live toggles flow through settings
	return ui


# The map zone under the player right now (smallest containing frame — city inside vale wins).
func current_zone(main: Node) -> Dictionary:
	var p := MapUi.player_ground_pos(main)
	return MapMarkers.zone_for(p.x, p.z, _zones)


func static_markers(zone: Dictionary) -> Array:
	var zone_id := str(zone.get("id", ""))
	if zone_id == "":
		return []
	if not _static_cache.has(zone_id):
		_static_cache[zone_id] = MapMarkers.static_markers_for_zone(
			zone,
			MapMarkers.load_doc(MapMarkers.FLIGHT_PATH),
			MapMarkers.load_doc(MapMarkers.DISCOVERY_PATH),
			MapMarkers.load_doc(MapMarkers.MAP_DATA_PATH)
		)
	return _static_cache[zone_id]


# The one baked image per zone (starts the incremental bake on first request).
func texture_for(zone: Dictionary) -> Texture2D:
	var zone_id := str(zone.get("id", ""))
	if zone_id == "" or not (zone.get("rect") is Rect2):
		return null
	if not _bakes.has(zone_id):
		var img := Image.create(RESOLUTION, RESOLUTION, false, Image.FORMAT_RGB8)
		img.fill(MapTerrainBaker.BASE)
		_bakes[zone_id] = {
			"img": img,
			"tex": ImageTexture.create_from_image(img),
			"rect": zone["rect"],
			"next_row": 0,
		}
	return _bakes[zone_id]["tex"]


func bake_progress(zone_id: String) -> float:
	if not _bakes.has(zone_id):
		return 0.0
	return float(_bakes[zone_id]["next_row"]) / float(RESOLUTION)


func _process(_delta: float) -> void:
	for zone_id in _bakes:
		var bake: Dictionary = _bakes[zone_id]
		var row := int(bake["next_row"])
		if row >= RESOLUTION:
			continue
		_baker.bake_rows(bake["img"], bake["rect"], row, ROWS_PER_FRAME)
		bake["next_row"] = row + ROWS_PER_FRAME
		(bake["tex"] as ImageTexture).update(bake["img"])
		return  # one zone chunk per frame — the bake never stacks work on a frame


# ---- shared providers (null-safe before the world/player exist) ----


static func player_ground_pos(main: Node) -> Vector3:
	var lp = main.get("local_player")
	return (lp as Node3D).global_position if lp is Node3D else Vector3.ZERO


static func player_yaw(main: Node) -> float:
	var lp = main.get("local_player")
	return (lp as Node3D).rotation.y if lp is Node3D else 0.0


# Quest !/? rows straight from NpcMarkersLayer's markers (position wire (x,y) -> ground (x,z);
# symbol/color as NpcMarker.marker_style already decided them — no quest state re-derived).
static func npc_rows(main: Node) -> Array:
	var layer = main.get("npc_markers")
	var markers = layer.get("_markers") if layer != null else null
	if not (markers is Dictionary):
		return []
	var out: Array = []
	for npc_id in markers:
		var m = markers[npc_id]
		if m == null:
			continue
		var label = m.get("_label")
		(
			out
			. append(
				{
					"id": str(npc_id),
					"name": "",
					"x": (m as Node2D).position.x,
					"z": (m as Node2D).position.y,
					"symbol": str(m.get_symbol()),
					"color": label.modulate if label != null else Color.WHITE,
					"visible": bool(m.visible),
				}
			)
		)
	return out


# Gather rows from the T-414 GatherNodes layer (bodies already sit at Godot ground x/z).
static func gather_rows(main: Node) -> Array:
	var wv = main.get("world_view")
	var layer = (wv as Node).get_node_or_null("GatherNodes") if wv != null else null
	var nodes = layer.get("_nodes") if layer != null else null
	if not (nodes is Dictionary):
		return []
	var out: Array = []
	for node_id in nodes:
		var e: Dictionary = nodes[node_id]
		var body = e.get("body")
		if not (body is Node3D):
			continue
		(
			out
			. append(
				{
					"id": str(node_id),
					"name": "",
					"x": (body as Node3D).position.x,
					"z": (body as Node3D).position.z,
					"kind": str(e.get("kind", "")),
					"available": bool(e.get("available", false)),
				}
			)
		)
	return out


static func party_state(main: Node) -> Dictionary:
	return {
		"positions": main.get("last_positions"),
		"members": main.get("party_members"),
		"my_id": int(main.get("_my_peer_id")),
	}
