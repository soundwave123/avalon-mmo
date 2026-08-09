class_name WorldMapPanel
extends Control

# T-730: the full-screen world map (toggle T — M is the mount; E/F stay free as likely interact
# keys). Per-zone: the current frame comes from MapMarkers.zone_for on the player position, the
# backdrop is MapUi's runtime-baked terrain image (the SAME image the T-738 minimap crops), and
# every marker comes from the shared MapMarkers pipeline — this panel draws, it never derives.
# Code-built like every panel; draws its own window box so markers can paint OVER the frame
# (children would cover a parent's _draw). Fog-of-war/exploration reveal: explicitly OUT of v1
# (T-730 note) — the whole zone renders charted.

const MARKER_SOURCE = preload("res://scripts/ui/map_markers.gd")  # the ONE pipeline (T-738 DoD)
const TOGGLE_KEYCODE := KEY_T
const HOVER_RADIUS_PX := 14.0
const REFRESH_INTERVAL := 0.1  # 10 Hz player-marker refresh while open (T-210 budget idiom)
const MARGIN := Vector2(64.0, 40.0)
const MAP_INSET_TOP := 74.0
const MAP_INSET := 18.0
const KIND_STYLE := {
	"hub": {"color": Color(1.0, 0.82, 0.0), "radius": 6.0},
	"dungeon": {"color": Color(0.86, 0.36, 0.30), "radius": 5.5},
	"flight": {"color": Color(0.45, 0.78, 0.47), "radius": 5.0},
	"landmark": {"color": Color(0.91, 0.86, 0.72), "radius": 4.0},
}
const PLAYER_COLOR := Color(1.0, 1.0, 1.0)

var _is_typing: Callable = Callable()
var _player_pos: Callable = Callable()  # -> Vector3 (Godot ground x/z)
var _player_yaw: Callable = Callable()  # -> float (local_player.rotation.y — compass convention)
var _texture_for: Callable = Callable()  # (zone) -> Texture2D (parchment-dark while baking)
var _zone: Dictionary = {}
var _markers: Array = []
var _markers_px: Array = []  # parallel to _markers, rebuilt per draw — the hover hit-test set
var _title: Label = null
var _subtitle: Label = null
var _tooltip: PanelContainer = null
var _tooltip_label: Label = null
var _accum := 0.0
var _frame_style: StyleBox = null
var _docs := {"flight": {}, "discovery": {}, "map": {}}


func _ready() -> void:
	name = "WorldMapPanel"
	visible = false
	theme = UiTheme.build()
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP  # open map owns the mouse (hover tooltips)
	_frame_style = UiTheme.opaque_window_stylebox()
	_docs["flight"] = MARKER_SOURCE.load_doc(MARKER_SOURCE.FLIGHT_PATH)
	_docs["discovery"] = MARKER_SOURCE.load_doc(MARKER_SOURCE.DISCOVERY_PATH)
	_docs["map"] = MARKER_SOURCE.load_doc(MARKER_SOURCE.MAP_DATA_PATH)
	_title = Label.new()
	_title.name = "MapTitle"
	_title.add_theme_font_size_override("font_size", 24)
	_title.add_theme_color_override("font_color", UiTheme.GOLD_BRIGHT)
	_title.position = MARGIN + Vector2(24.0, 12.0)
	add_child(_title)
	_subtitle = Label.new()
	_subtitle.name = "MapSubtitle"
	_subtitle.add_theme_color_override("font_color", UiTheme.PARCHMENT_DIM)
	_subtitle.position = MARGIN + Vector2(24.0, 44.0)
	add_child(_subtitle)
	_tooltip = PanelContainer.new()
	_tooltip.name = "MapTooltip"
	_tooltip.theme_type_variation = "SolidWindow"
	_tooltip.visible = false
	_tooltip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tooltip_label = Label.new()
	_tooltip_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_tooltip_label.custom_minimum_size = Vector2(260.0, 0.0)
	_tooltip.add_child(_tooltip_label)
	add_child(_tooltip)


func setup(providers: Dictionary) -> void:
	_is_typing = providers.get("is_typing", Callable())
	_player_pos = providers.get("player_pos", Callable())
	_player_yaw = providers.get("player_yaw", Callable())
	_texture_for = providers.get("texture_for", Callable())


func _input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.is_pressed() or event.is_echo():
		return
	if (event as InputEventKey).keycode != TOGGLE_KEYCODE:
		return
	if UiInputGate.is_text_input_focused(get_viewport()):
		return
	if _is_typing.is_valid() and bool(_is_typing.call()):
		return  # chat holds the keyboard
	toggle()
	get_viewport().set_input_as_handled()


func toggle() -> void:
	visible = not visible
	if visible:
		refresh_zone()
		queue_redraw()
	else:
		_tooltip.visible = false


func _process(delta: float) -> void:
	if not visible:
		return
	_accum += delta
	if _accum >= REFRESH_INTERVAL:
		_accum = 0.0
		queue_redraw()  # live player marker + bake progress fade-in


# Re-resolve the current zone + its static markers from the shared pipeline.
func refresh_zone() -> void:
	var zone_list: Array = MARKER_SOURCE.zones(_docs["map"])
	var p := _pos()
	_zone = MARKER_SOURCE.zone_for(p.x, p.z, zone_list)
	if _zone.is_empty() and not zone_list.is_empty():
		_zone = zone_list[0]  # off-frame safety: chart the home zone rather than nothing
	_markers = MARKER_SOURCE.static_markers_for_zone(
		_zone, _docs["flight"], _docs["discovery"], _docs["map"]
	)
	_title.text = str(_zone.get("name", ""))
	_subtitle.text = str(_zone.get("desc", ""))


func _draw() -> void:
	if _zone.is_empty():
		return
	var frame := Rect2(MARGIN, size - MARGIN * 2.0)
	draw_style_box(_frame_style, frame)
	var avail := Rect2(
		frame.position + Vector2(MAP_INSET, MAP_INSET_TOP),
		frame.size - Vector2(MAP_INSET * 2.0, MAP_INSET_TOP + MAP_INSET)
	)
	var zone_rect: Rect2 = _zone["rect"]
	var fit := fit_rect(zone_rect.size, avail)
	var tex: Texture2D = _texture_for.call(_zone) if _texture_for.is_valid() else null
	if tex != null:
		draw_texture_rect(tex, fit, false)
	else:
		draw_rect(fit, MapTerrainBaker.BASE)
	draw_rect(fit, UiTheme.GOLD.darkened(0.4), false, 2.0)  # chart border
	var font := ThemeDB.fallback_font
	draw_string(  # the map is always north-up
		font,
		fit.position + Vector2(8.0, 22.0),
		"N",
		HORIZONTAL_ALIGNMENT_LEFT,
		-1,
		18,
		UiTheme.GOLD_BRIGHT
	)
	_markers_px = []
	for m: Dictionary in _markers:
		var px: Vector2 = (
			fit.position
			+ MARKER_SOURCE.world_to_px(float(m["x"]), float(m["z"]), zone_rect, fit.size)
		)
		_markers_px.append(px)
		var style: Dictionary = KIND_STYLE.get(str(m["kind"]), KIND_STYLE["landmark"])
		var r := float(style["radius"])
		draw_circle(px, r + 1.5, Color(0.0, 0.0, 0.0, 0.8))
		draw_circle(px, r, style["color"])
		if str(m["kind"]) == "hub":  # hubs carry their name on the chart itself, WoW-style
			draw_string(
				font,
				px + Vector2(9.0, 5.0),
				str(m["name"]),
				HORIZONTAL_ALIGNMENT_LEFT,
				-1,
				13,
				UiTheme.PARCHMENT
			)
	_draw_player(fit, zone_rect)


func _draw_player(fit: Rect2, zone_rect: Rect2) -> void:
	var p := _pos()
	if not zone_rect.has_point(Vector2(p.x, p.z)):
		return  # off this frame (e.g. an offset instance region) — no fake position
	var px: Vector2 = fit.position + MARKER_SOURCE.world_to_px(p.x, p.z, zone_rect, fit.size)
	var yaw := float(_player_yaw.call()) if _player_yaw.is_valid() else 0.0
	# CompassStrip convention: yaw 0 = north = map up; the arrow spins with the player's facing.
	var pts := PackedVector2Array()
	for local: Vector2 in [Vector2(0.0, -9.0), Vector2(6.0, 7.0), Vector2(-6.0, 7.0)]:
		pts.append(px + local.rotated(-yaw))
	draw_colored_polygon(pts, PLAYER_COLOR)
	draw_polyline(
		PackedVector2Array([pts[0], pts[1], pts[2], pts[0]]), Color(0.0, 0.0, 0.0, 0.9), 1.5
	)


func _gui_input(event: InputEvent) -> void:
	if not (event is InputEventMouseMotion):
		return
	var idx := MARKER_SOURCE.nearest_marker(
		_markers_px, (event as InputEventMouseMotion).position, HOVER_RADIUS_PX
	)
	if idx < 0:
		_tooltip.visible = false
		return
	var m: Dictionary = _markers[idx]
	_tooltip_label.text = "%s\n%s" % [str(m["name"]), str(m["desc"])]
	_tooltip.position = (event as InputEventMouseMotion).position + Vector2(16.0, 12.0)
	_tooltip.reset_size()
	_tooltip.visible = true


# Keep-aspect fit of a zone frame into the available rect, centered (pure — unit-tested).
static func fit_rect(src_size: Vector2, avail: Rect2) -> Rect2:
	var scale_f: float = minf(avail.size.x / src_size.x, avail.size.y / src_size.y)
	var out_size := src_size * scale_f
	return Rect2(avail.position + (avail.size - out_size) * 0.5, out_size)


func _pos() -> Vector3:
	return _player_pos.call() if _player_pos.is_valid() else Vector3.ZERO


# ---- pilot observe hook (T-730 DoD: marker presence assertable without a screenshot) ----
func observe() -> Dictionary:
	var kinds := {}
	var names: Array = []
	for m: Dictionary in _markers:
		kinds[str(m["kind"])] = int(kinds.get(str(m["kind"]), 0)) + 1
		names.append(str(m["name"]))
	return {
		"open": visible,
		"zone": str(_zone.get("id", "")),
		"marker_kinds": kinds,
		"marker_names": names,
	}
