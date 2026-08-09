class_name MinimapPanel
extends Control

# T-738: the always-on corner minimap (WoW set): quest givers (!) and turn-ins (?) in tracking
# range, towns/hubs + flight points + dungeon entrances, gather nodes the character can gather,
# and nearby party members — live. Player-centered, north-locked by default with a rotate-with-
# facing settings toggle, wheel zoom steps; visibility/rotate/zoom persist via SettingsPanel.
#
# RENDERING: a drawn overlay, NOT a SubViewport — a viewport would re-render the 3D scene against
# the T-141 draw-call budget; this is ONE cropped draw of MapUi's cached zone bake (the SAME image
# the T-730 world map draws — the shared-pipeline contract) plus a handful of glyphs, redrawn at
# 10 Hz. The terrain quad is drawn oversized and clipped (clip_contents) so rotate mode never
# exposes corner gaps; near a zone edge the crop window clamps inside the frame (the player marker
# slides off-center instead of the crop sampling off the image).

const MARKER_SOURCE = preload("res://scripts/ui/map_markers.gd")  # the ONE pipeline (T-738 DoD)
const SIZE_PX := 150.0
const RADIUS_PX := 71.0  # marker scale radius (center -> rim)
const ZOOM_RADII: Array = [40.0, 70.0, 120.0]  # meters shown center->rim per zoom step
const DEFAULT_ZOOM := 1
const TRACK_RANGE := 120.0  # quest-pip tracking radius (m)
const REFRESH_INTERVAL := 0.1  # 10 Hz — no per-frame work (T-210 budget idiom)
const OVERSIZE := 1.5  # terrain window overdraw so a rotated quad still covers the frame
const BG := Color(0.10, 0.09, 0.08)
const PARTY_COLOR := Color(0.35, 0.55, 1.0)
const PLAYER_COLOR := Color(1.0, 1.0, 1.0)
const STATIC_COLORS := {
	"hub": Color(1.0, 0.82, 0.0),
	"flight": Color(0.45, 0.78, 0.47),
	"dungeon": Color(0.86, 0.36, 0.30),
}
const GATHER_COLORS := {
	"herb": Color(0.55, 0.85, 0.40),
	"ore": Color(0.85, 0.65, 0.35),
	"timber": Color(0.70, 0.50, 0.30),
	"fibre": Color(0.80, 0.80, 0.55),
	"fishing": Color(0.45, 0.70, 0.90),
}

var rotate_mode := false
var zoom_idx := DEFAULT_ZOOM
var _providers: Dictionary = {}
var _on_zoom_change: Callable = Callable()
var _accum := 0.0
var _zone: Dictionary = {}
var _static_markers: Array = []
var _last_counts: Dictionary = {}  # marker-class counts from the latest draw (observe truth)


func _ready() -> void:
	name = "MinimapPanel"
	# Top-right corner — the one unreserved HudSafeZone slot (MINIMAP_RECT mirrors this).
	anchor_left = 1.0
	anchor_right = 1.0
	anchor_top = 0.0
	anchor_bottom = 0.0
	offset_left = -SIZE_PX - 20.0
	offset_right = -20.0
	offset_top = 10.0
	offset_bottom = 10.0 + SIZE_PX
	clip_contents = true  # the oversized/rotated terrain quad clips to the frame
	mouse_filter = Control.MOUSE_FILTER_STOP  # wheel-over-minimap = zoom (camera keeps it elsewhere)


func setup(providers: Dictionary, on_zoom_change: Callable = Callable()) -> void:
	_providers = providers
	_on_zoom_change = on_zoom_change


# SettingsPanel pushes persisted state through here (boot restore + live toggles).
func apply_settings(show: bool, rotate: bool, zoom: int) -> void:
	visible = show
	rotate_mode = rotate
	zoom_idx = clampi(zoom, 0, ZOOM_RADII.size() - 1)
	queue_redraw()


func _gui_input(event: InputEvent) -> void:
	if not (event is InputEventMouseButton) or not event.is_pressed():
		return
	var btn := (event as InputEventMouseButton).button_index
	if btn == MOUSE_BUTTON_WHEEL_UP:
		_set_zoom(zoom_idx - 1)  # in — fewer meters per pixel
	elif btn == MOUSE_BUTTON_WHEEL_DOWN:
		_set_zoom(zoom_idx + 1)
	else:
		return
	accept_event()


func _set_zoom(idx: int) -> void:
	var clamped := clampi(idx, 0, ZOOM_RADII.size() - 1)
	if clamped == zoom_idx:
		return
	zoom_idx = clamped
	if _on_zoom_change.is_valid():
		_on_zoom_change.call(zoom_idx)  # SettingsPanel persists the step
	queue_redraw()


func _process(delta: float) -> void:
	if not visible:
		return
	_accum += delta
	if _accum >= REFRESH_INTERVAL:
		_accum = 0.0
		_refresh_zone()
		queue_redraw()


func _refresh_zone() -> void:
	var zone_fn: Callable = _providers.get("current_zone", Callable())
	if not zone_fn.is_valid():
		return
	var zone: Dictionary = zone_fn.call()
	if str(zone.get("id", "")) == str(_zone.get("id", "")):
		return
	_zone = zone
	var static_fn: Callable = _providers.get("static_markers", Callable())
	_static_markers = static_fn.call(_zone) if static_fn.is_valid() and not _zone.is_empty() else []


func _draw() -> void:
	var center := size * 0.5
	var radius_m := float(ZOOM_RADII[zoom_idx])
	var p: Vector3 = _call_or(_providers.get("player_pos", Callable()), Vector3.ZERO)
	var yaw := float(_call_or(_providers.get("player_yaw", Callable()), 0.0))
	var counts := {"hub": 0, "flight": 0, "dungeon": 0, "quest": 0, "gather": 0, "party": 0}
	draw_rect(Rect2(Vector2.ZERO, size), BG)
	_draw_terrain(center, radius_m, p, yaw)
	var wc := _window_center(p, radius_m)
	for m: Dictionary in _static_markers:
		var kind := str(m["kind"])
		if not STATIC_COLORS.has(kind):
			continue
		var off := _offset(m, wc, radius_m, yaw)
		off = MARKER_SOURCE.clamp_to_edge(off, RADIUS_PX - 5.0)  # off-window hubs read at the rim
		draw_circle(center + off, 5.0, Color(0.0, 0.0, 0.0, 0.8))
		draw_circle(center + off, 3.8, STATIC_COLORS[kind])
		counts[kind] += 1
	counts["quest"] = _draw_quest_pips(center, wc, p, radius_m, yaw)
	counts["gather"] = _draw_gather_pips(center, wc, radius_m, yaw)
	counts["party"] = _draw_party_dots(center, wc, radius_m, yaw)
	_draw_player(center, yaw)
	_draw_north(center, yaw)
	draw_rect(Rect2(Vector2.ZERO, size), Color(1.0, 0.82, 0.0, 0.55), false, 2.0)
	_last_counts = counts


func _draw_terrain(center: Vector2, radius_m: float, p: Vector3, yaw: float) -> void:
	if _zone.is_empty():
		return
	var tex_fn: Callable = _providers.get("texture_for", Callable())
	var tex: Texture2D = tex_fn.call(_zone) if tex_fn.is_valid() else null
	if tex == null:
		return
	var zone_rect: Rect2 = _zone["rect"]
	var scale_px := RADIUS_PX / radius_m  # px per meter
	var half_m := minf(radius_m * OVERSIZE, minf(zone_rect.size.x, zone_rect.size.y) * 0.5)
	var wc := _window_center(p, radius_m)
	var res := Vector2(float(tex.get_width()), float(tex.get_height()))
	var c_px := MARKER_SOURCE.world_to_px(wc.x, wc.y, zone_rect, res)
	var src_half := Vector2(half_m / zone_rect.size.x * res.x, half_m / zone_rect.size.y * res.y)
	var quad_half := half_m * scale_px
	draw_set_transform(center, -yaw if rotate_mode else 0.0, Vector2.ONE)
	draw_texture_rect_region(
		tex,
		Rect2(-quad_half, -quad_half, quad_half * 2.0, quad_half * 2.0),
		Rect2(c_px - src_half, src_half * 2.0)
	)
	draw_set_transform_matrix(Transform2D())


# The crop window's world center: the player, clamped so the window never samples off the frame.
func _window_center(p: Vector3, radius_m: float) -> Vector2:
	if _zone.is_empty():
		return Vector2(p.x, p.z)
	var zone_rect: Rect2 = _zone["rect"]
	var half_m := minf(radius_m * OVERSIZE, minf(zone_rect.size.x, zone_rect.size.y) * 0.5)
	return Vector2(
		clampf(p.x, zone_rect.position.x + half_m, zone_rect.end.x - half_m),
		clampf(p.z, zone_rect.position.y + half_m, zone_rect.end.y - half_m)
	)


func _offset(m: Dictionary, wc: Vector2, radius_m: float, yaw: float) -> Vector2:
	return MARKER_SOURCE.minimap_offset(
		float(m["x"]), float(m["z"]), wc, radius_m, RADIUS_PX, yaw, rotate_mode
	)


func _draw_quest_pips(center: Vector2, wc: Vector2, p: Vector3, radius_m: float, yaw: float) -> int:
	var rows_fn: Callable = _providers.get("quest_rows", Callable())
	if not rows_fn.is_valid():
		return 0
	var font := ThemeDB.fallback_font
	var drawn := 0
	for m: Dictionary in MARKER_SOURCE.from_npc_markers(rows_fn.call()):
		if Vector2(float(m["x"]) - p.x, float(m["z"]) - p.z).length() > TRACK_RANGE:
			continue  # tracking range, not the whole zone
		var off: Vector2 = MARKER_SOURCE.clamp_to_edge(
			_offset(m, wc, radius_m, yaw), RADIUS_PX - 7.0
		)
		var at := center + off + Vector2(-4.0, 5.0)
		draw_string_outline(
			font,
			at,
			str(m["symbol"]),
			HORIZONTAL_ALIGNMENT_LEFT,
			-1,
			14,
			3,
			Color(0.0, 0.0, 0.0, 0.9)
		)
		draw_string(font, at, str(m["symbol"]), HORIZONTAL_ALIGNMENT_LEFT, -1, 14, m["color"])
		drawn += 1
	return drawn


func _draw_gather_pips(center: Vector2, wc: Vector2, radius_m: float, yaw: float) -> int:
	var rows_fn: Callable = _providers.get("gather_rows", Callable())
	if not rows_fn.is_valid():
		return 0
	var prof_fn: Callable = _providers.get("professions", Callable())
	var professions: Array = prof_fn.call() if prof_fn.is_valid() else []
	var drawn := 0
	for m: Dictionary in MARKER_SOURCE.from_gather(rows_fn.call(), professions):
		var off := _offset(m, wc, radius_m, yaw)
		if off.length() > RADIUS_PX - 4.0:
			continue  # gather pips show in-window only (no rim clutter, WoW behavior)
		var color: Color = GATHER_COLORS.get(str(m.get("gather_kind", "")), Color.WHITE)
		draw_circle(center + off, 3.6, Color(0.0, 0.0, 0.0, 0.8))
		draw_circle(center + off, 2.6, color)
		drawn += 1
	return drawn


func _draw_party_dots(center: Vector2, wc: Vector2, radius_m: float, yaw: float) -> int:
	var state_fn: Callable = _providers.get("party_state", Callable())
	if not state_fn.is_valid():
		return 0
	var st: Dictionary = state_fn.call()
	var members: Array = MARKER_SOURCE.party_markers(
		st.get("positions", {}), st.get("members", []), int(st.get("my_id", 0))
	)
	for m: Dictionary in members:
		var off: Vector2 = MARKER_SOURCE.clamp_to_edge(
			_offset(m, wc, radius_m, yaw), RADIUS_PX - 5.0
		)
		draw_circle(center + off, 5.0, Color(1.0, 1.0, 1.0, 0.9))  # white ring reads over terrain
		draw_circle(center + off, 3.6, PARTY_COLOR)
	return members.size()


func _draw_player(center: Vector2, yaw: float) -> void:
	# North-locked: the arrow spins with facing. Rotate mode: the MAP spins, the arrow points up.
	var rot := 0.0 if rotate_mode else -yaw
	var pts := PackedVector2Array()
	for local: Vector2 in [Vector2(0.0, -7.0), Vector2(5.0, 5.5), Vector2(-5.0, 5.5)]:
		pts.append(center + local.rotated(rot))
	draw_colored_polygon(pts, PLAYER_COLOR)
	draw_polyline(PackedVector2Array([pts[0], pts[1], pts[2], pts[0]]), Color.BLACK, 1.2)


func _draw_north(center: Vector2, yaw: float) -> void:
	var dir := Vector2(0.0, -1.0).rotated(-yaw) if rotate_mode else Vector2(0.0, -1.0)
	var at := center + dir * (RADIUS_PX - 9.0) + Vector2(-4.0, 5.0)
	var font := ThemeDB.fallback_font
	draw_string_outline(
		font, at, "N", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, 3, Color(0.0, 0.0, 0.0, 0.9)
	)
	draw_string(font, at, "N", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(1.0, 0.9, 0.4))


func _call_or(fn: Callable, fallback: Variant) -> Variant:
	return fn.call() if fn.is_valid() else fallback


# ---- pilot observe hook (marker presence assertable without a screenshot) ----
func observe() -> Dictionary:
	return {
		"visible": visible,
		"rotate": rotate_mode,
		"zoom": zoom_idx,
		"radius_m": float(ZOOM_RADII[zoom_idx]),
		"zone": str(_zone.get("id", "")),
		"counts": _last_counts.duplicate(),
	}
