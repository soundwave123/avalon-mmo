class_name CombatLogPanel
# T-027 §4: Visual combat-log panel — renders CombatLog entries into a RichTextLabel.
#
# T-607: RETIRED as an on-screen HUD surface — it used to stand alone over the same bottom-left
# rect as ChatPanel with its own independent fade timer, and the two garbled together whenever
# both had fresh content. CombatLog entries now route into ChatPanel directly
# (`ChatPanel.bind_combat_log`), which is the live merged surface. This class is kept only as a
# plain, headlessly-testable RichTextLabel renderer (see client/tests/test_combat_log_panel.gd) —
# main.gd no longer instantiates or mounts it. Uses BBCode for per-line color.
#
# Truncation is version-safe: we keep an Array of the last MAX_LINES BBCode strings and
# rebuild `RichTextLabel.text` from it (reassigning .text reparses BBCode when
# bbcode_enabled is true). We do NOT rely on RichTextLabel.remove_paragraph().
#
# Bind to a CombatLog with bind(log); each entry_added is rendered. Or call append_line()
# directly. Testable headlessly: get_line_count(), get_text().

extends Control

const MAX_LINES: int = 200
# The LogFrame PanelContainer's content margin per side (UiTheme.panel_stylebox content_margin_all).
const _FRAME_MARGIN: float = 8.0

var _rtl: RichTextLabel = null
var _lines: Array[String] = []
# T-396: same glanceable presence as the chat panel — the log is invisible while silent (an empty
# framed box was the idle HUD's worst offender) and fades in on a combat line, back out after the
# shared ChatPresence idle delay. Read-only surface: it stays click-through in every state.
var _presence := ChatPresence.new()


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	modulate.a = 0.0  # born silent — nothing to show until a combat line lands
	_rtl = RichTextLabel.new()
	_rtl.name = "LogText"
	_rtl.bbcode_enabled = true
	_rtl.scroll_following = true  # auto-scroll to newest line
	_rtl.scroll_active = true
	_rtl.set_anchors_preset(Control.PRESET_FULL_RECT)
	_rtl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_rtl)
	_render()


func _process(delta: float) -> void:
	_presence.tick(delta)
	modulate.a = _presence.area_alpha


func bind(combat_log: CombatLog) -> void:
	"""Render every entry the given CombatLog appends from now on."""
	combat_log.entry_added.connect(append_line)
	combat_log.entry_updated.connect(_update_last_line)  # T-556: coalesced repeat -> rewrite last line


# T-556: a coalesced repeat updates the newest line's "(xN)" count in place instead of adding a new
# line. Re-wakes the presence fade so the refreshed count is legible, like a fresh line.
func _update_last_line(msg: String, color: Color = Color.WHITE) -> void:
	if _lines.is_empty():
		append_line(msg, color)
		return
	_presence.notify_line()
	var hex: String = color.to_html(false)
	_lines[-1] = "[color=#%s]%s[/color]" % [hex, msg]
	_render()


# T-308: dock the log bottom-left instead of free-floating text over the world. T-465: the dock is
# the CHAT treatment, not a box — the LogFrame carries no fill or border (margins only); a subtle
# bottom-weighted gradient sits behind the outlined/shadowed lines, and the whole surface keeps the
# T-396 idle fade (_process above). Called after the shared theme is assigned (text outline/shadow
# ride the theme's RichTextLabel defaults).
func apply_frame() -> void:
	set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	offset_left = 20.0
	offset_right = 480.0
	offset_top = -370.0
	offset_bottom = -185.0
	# T-400: size the visible text rect to a WHOLE number of lines so the top line never clips
	# mid-glyph (judge flag). RTL clip height = frame height − both content margins; snap it to an
	# integer multiple of the theme's line pitch by pulling the top edge up to the nearest line.
	var pitch := get_line_pitch()
	var avail := (offset_bottom - offset_top) - _FRAME_MARGIN * 2.0
	var visible_lines := maxi(1, int(floor(avail / pitch)))
	offset_top = offset_bottom - (float(visible_lines) * pitch + _FRAME_MARGIN * 2.0)
	var backdrop := UiTheme.gradient_backdrop(ChatPresence.BG_IDLE_ALPHA, true)
	backdrop.name = "LogGradient"
	add_child(backdrop)
	move_child(backdrop, 0)  # behind everything
	var frame := PanelContainer.new()
	frame.name = "LogFrame"
	frame.set_anchors_preset(Control.PRESET_FULL_RECT)
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# T-465: no box — an empty stylebox keeps the content margins (the T-400 line-pitch contract)
	# while dropping the fill/border; legibility lives in the line outline/shadow + the gradient.
	frame.add_theme_stylebox_override("panel", UiTheme.no_box_stylebox(_FRAME_MARGIN))
	add_child(frame)
	move_child(frame, 1)  # behind the RichTextLabel, over the gradient
	if _rtl != null:
		_rtl.reparent(frame)
		_rtl.set_anchors_preset(Control.PRESET_FULL_RECT)


# T-400: the theme's per-line pitch (font height + RichTextLabel line_separation) at its real size.
# Falls back to Godot's default 16px font when no theme is assigned (headless).
func get_line_pitch() -> float:
	var fsize := get_theme_default_font_size()
	if fsize <= 0:
		fsize = 16
	var h := 16.0
	var font := get_theme_default_font()
	if font != null:
		h = font.get_height(fsize)
	var sep := 0.0
	if has_theme_constant("line_separation", "RichTextLabel"):
		sep = float(get_theme_constant("line_separation", "RichTextLabel"))
	return h + sep


# T-400: the RichTextLabel's clipped height inside the frame — asserted to be a whole-line multiple.
func get_visible_text_height() -> float:
	return (offset_bottom - offset_top) - _FRAME_MARGIN * 2.0


func append_line(msg: String, color: Color = Color.WHITE) -> void:
	_presence.notify_line()  # T-396: wake the faded log so the line lands legible
	var hex: String = color.to_html(false)  # rrggbb, no alpha
	_lines.append("[color=#%s]%s[/color]" % [hex, msg])
	while _lines.size() > MAX_LINES:
		_lines.pop_front()
	_render()


func _render() -> void:
	if _rtl == null:
		return
	_rtl.text = "\n".join(_lines)


func clear() -> void:
	_lines.clear()
	_render()


func get_line_count() -> int:
	return _lines.size()


func get_text() -> String:
	return "\n".join(_lines)
