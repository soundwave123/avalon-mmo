class_name CompassStrip
# T-308 (absorbs T-316's HUD half): a simple heading indicator tied to camera yaw. Per
# docs/design/world-conventions.md, yaw 0 faces -Z = NORTH, and Godot's Ry(yaw) turns the forward
# vector toward +X as yaw grows, so yaw 90deg = EAST, 180 = SOUTH, 270 = WEST — compass bearing
# measured clockwise from north. A full minimap is OUT of scope (deferred); this is the interface-
# layer wayfinding cue that T-316 flagged as the biggest hole.

extends Control

const _CARDINALS_8 := ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
# T-710/T-711: the guidance pip's mapping — a relative bearing inside ±this many degrees places the
# pip proportionally across the strip; anything beyond clamps to the edge (the pip never vanishes,
# whatever the distance or direction — "independent of marker distance" is the ticket's point).
const PIP_HALF_RANGE_DEG := 90.0
const _PIP_HALF_WIDTH := 62.0  # px from strip center to the clamp edge (strip is 140 wide)

var _label: Label = null
var _bearing: Label = null
var _last_index: int = -1
var _pip: Label = null  # T-710/T-711: the "▼" guidance marker; hidden unless guidance is active
var _pip_offset := INF  # last applied pixel offset (skip re-layout on an unchanged frame)


func _ready() -> void:
	# Explicit anchors (4.7-proof — see the HUD-judge anchor regression, 2026-07-13).
	anchor_left = 0.5
	anchor_right = 0.5
	anchor_top = 0.0
	anchor_bottom = 0.0
	offset_left = -70.0
	offset_right = 70.0
	offset_top = 10.0
	offset_bottom = 52.0
	# T-645: never eat world clicks while idle.
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	# T-460: no box on an idle surface (T-396 rule 2/5) — the strip renders its two lines of
	# outlined+shadowed text over a subtle top-weighted gradient, not a filled/bordered panel.
	# Legibility over bright sky comes from the Label outline/shadow the shared theme carries.
	var backdrop := UiTheme.gradient_backdrop(0.26, false)
	backdrop.name = "CompassGradient"
	add_child(backdrop)

	var panel := PanelContainer.new()
	panel.name = "CompassPanel"
	panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	panel.add_theme_stylebox_override("panel", UiTheme.no_box_stylebox(4.0))
	add_child(panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 0)
	panel.add_child(vbox)

	_label = Label.new()
	_label.name = "Cardinal"
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.add_theme_color_override("font_color", UiTheme.GOLD_BRIGHT)
	_label.add_theme_font_size_override("font_size", 20)
	vbox.add_child(_label)

	_bearing = Label.new()
	_bearing.name = "Bearing"
	_bearing.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_bearing.add_theme_color_override("font_color", UiTheme.PARCHMENT_DIM)
	vbox.add_child(_bearing)

	# T-710/T-711: the guidance pip — a small gold "▼" riding the strip's lower edge at the target's
	# relative bearing (same outlined-glyph legibility as the cardinal; no box, per T-396/T-460).
	_pip = Label.new()
	_pip.name = "GuidePip"
	_pip.text = "▼"
	_pip.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_pip.add_theme_color_override("font_color", UiTheme.GOLD_BRIGHT)
	_pip.add_theme_font_size_override("font_size", 12)
	_pip.anchor_left = 0.5
	_pip.anchor_right = 0.5
	_pip.anchor_top = 0.0
	_pip.anchor_bottom = 0.0
	_pip.offset_top = 30.0
	_pip.offset_bottom = 44.0
	_pip.visible = false
	add_child(_pip)

	update_heading(0.0)
	# T-651: T-645 only IGNORE'd the root — CompassPanel (PanelContainer, default STOP) still spanned
	# the Cardinal/Bearing labels and ate world clicks. Cascade to the whole idle subtree; no child
	# here is ever interactive (no buttons/tooltips).
	UiTheme.set_mouse_filter_deep(self)


# Drive from the local player's yaw (radians). Only touches the labels when the cardinal changes,
# so the per-frame call in main._process does no work while you hold a heading (T-210 budget).
func update_heading(yaw_rad: float) -> void:
	var deg := CompassStrip.normalize_deg(rad_to_deg(yaw_rad))
	var idx := CompassStrip.cardinal_index(deg)
	if idx == _last_index:
		return
	_last_index = idx
	_label.text = _CARDINALS_8[idx]
	_bearing.text = "%d°" % int(round(deg))


# T-710/T-711: show the guidance pip at a relative bearing (deg; 0 = dead ahead, +right/-left).
# The offset guard makes the per-frame call from the controller free while heading/target hold.
func set_pip(rel_deg: float) -> void:
	if _pip == null:
		return
	_pip.visible = true
	var off := pip_offset(rel_deg, _PIP_HALF_WIDTH)
	if absf(off - _pip_offset) < 0.5:
		return
	_pip_offset = off
	_pip.offset_left = off - 8.0
	_pip.offset_right = off + 8.0


func clear_pip() -> void:
	if _pip != null:
		_pip.visible = false


# ---- pure heading math (static → unit-testable without a scene) ----------
# T-710/T-711 guidance-pip math, same convention as update_heading (yaw 0 = north/-Z, 90 = east/+X;
# bearing measured clockwise from north). Only ground-plane x/z matter.


# Compass bearing (deg, [0,360)) of `to` as seen from `from`.
static func bearing_to_deg(from: Vector3, to: Vector3) -> float:
	return normalize_deg(rad_to_deg(atan2(to.x - from.x, -(to.z - from.z))))


# Signed relative bearing [-180,180): 0 = dead ahead on the current heading, positive = clockwise.
static func relative_bearing_deg(yaw_rad: float, from: Vector3, to: Vector3) -> float:
	return wrapf(bearing_to_deg(from, to) - normalize_deg(rad_to_deg(yaw_rad)), -180.0, 180.0)


# Pixel offset from strip center for a relative bearing; clamps to ±half_width so an off-screen
# target still reads AT the edge (the pip never disappears).
static func pip_offset(rel_deg: float, half_width: float) -> float:
	return clampf(rel_deg / PIP_HALF_RANGE_DEG, -1.0, 1.0) * half_width


static func normalize_deg(deg: float) -> float:
	var d := fmod(deg, 360.0)
	if d < 0.0:
		d += 360.0
	return d


# 8-point cardinal index for a bearing in [0,360). N=0 at 0deg, wrapping every 45deg.
static func cardinal_index(deg: float) -> int:
	return int(round(normalize_deg(deg) / 45.0)) % 8


static func cardinal(yaw_rad: float) -> String:
	return _CARDINALS_8[cardinal_index(rad_to_deg(yaw_rad))]


# ---- test accessor -------------------------------------------------------
func get_cardinal() -> String:
	return _label.text if _label != null else ""


func is_pip_visible() -> bool:  # T-710/T-711
	return _pip != null and _pip.visible
