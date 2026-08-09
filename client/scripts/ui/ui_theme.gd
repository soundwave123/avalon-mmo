class_name UiTheme
# T-308: the shared medieval HUD skin, built entirely in code (.tscn/.tres are gitignored and
# off-limits). One Theme resource — parchment + dark iron + gold — applied to the vitals frame,
# action bar, XP belt and combat-log panel so the whole HUD reads as one grounded fantasy UI
# instead of default-grey Godot ProgressBars. No font files are committed to client/assets, so we
# keep Godot's default font and carry the medieval read entirely in colour, borders and framing.

extends RefCounted

# ---- palette (warm parchment / dark iron / gold) -------------------------
const IRON_DARK := Color(0.12, 0.11, 0.10)  # panel body — near-black forged iron
const IRON_MID := Color(0.20, 0.18, 0.16)  # inset bar troughs
const PARCHMENT := Color(0.87, 0.79, 0.62)  # warm text / labels
const PARCHMENT_DIM := Color(0.66, 0.60, 0.47)  # secondary text
const GOLD := Color(0.82, 0.66, 0.30)  # borders / accents
const GOLD_BRIGHT := Color(0.93, 0.80, 0.42)  # highlights, keybind pips
const BRONZE := Color(0.42, 0.32, 0.16)  # darker frame edge

# ---- vitals fills --------------------------------------------------------
const HEALTH := Color(0.62, 0.16, 0.14)  # blood red HP
const HEALTH_LOW := Color(0.85, 0.28, 0.20)  # brighter warning red when low
const MANA := Color(0.24, 0.42, 0.86)  # caster mana blue
const RAGE := Color(0.72, 0.20, 0.18)  # warrior rage red
const ENERGY := Color(0.85, 0.72, 0.24)  # energy/focus yellow


# T-651: T-645 only set mouse_filter=IGNORE on the OUTERMOST root of an idle HUD surface, leaving
# inner Panel/PanelContainer/ProgressBar art (which physically spans the visible bar and defaults
# to MOUSE_FILTER_STOP) still eating world clicks. Call this once at the END of _ready(), after the
# whole subtree is built, to cascade IGNORE onto EVERY Control descendant (root included) — for
# idle-only HUD surfaces where NOTHING inside (no button, no hoverable/clickable part) ever needs a
# click. Do not call this on a surface with interactive children (see chat_panel.gd's ChatTabs,
# which stays MOUSE_FILTER_STOP so it can wake the panel).
static func set_mouse_filter_deep(node: Node, filter: int = Control.MOUSE_FILTER_IGNORE) -> void:
	if node is Control:
		(node as Control).mouse_filter = filter
	for child in node.get_children():
		set_mouse_filter_deep(child, filter)


# The de-boxed standing-HUD surface (T-396): dark TRANSLUCENT body, NO gold border frame, only a
# hairline bronze edge and a soft shadow for separation. The idle HUD reads as world-first glass,
# not a forged-iron box. Deliberately-opened windows opt into the heavier `window_stylebox` instead.
static func panel_stylebox(radius: int = 4) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(IRON_DARK.r, IRON_DARK.g, IRON_DARK.b, 0.42)
	sb.border_color = Color(BRONZE.r, BRONZE.g, BRONZE.b, 0.55)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(radius)
	sb.set_content_margin_all(8)
	sb.shadow_color = Color(0, 0, 0, 0.35)
	sb.shadow_size = 3
	return sb


# The heavier surface for a window the player deliberately summoned (inventory/quest log/social):
# near-opaque forged iron with a thin gold inner line. Registered as the "SolidWindow" theme type
# variation ("Window" is a built-in class name and cannot be a variation) so such windows can stay
# solid while the standing HUD goes translucent (T-396). Applying the variation per-window is the
# orchestrator's visual pass — this helper is the single source.
static func window_stylebox(radius: int = 4) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(IRON_DARK.r, IRON_DARK.g, IRON_DARK.b, 0.94)
	sb.border_color = GOLD
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(radius)
	sb.set_content_margin_all(8)
	sb.shadow_color = Color(0, 0, 0, 0.5)
	sb.shadow_size = 4
	return sb


# #78: window_stylebox()'s 0.94 fill lets a WORLD-SPACE Label3D nameplate behind it show through as
# a faint ghost (a 6% alpha blend of a bright emissive nameplate colour reads as legible "ghosted"
# text, not a subtle tint) — confirmed on PerformanceRecapPanel, which auto-pops centered on screen
# mid-combat, i.e. squarely over where the just-fought mob's nameplate usually sits. A per-window
# override for a surface that specifically needs to guarantee full opacity over 3D world content.
static func opaque_window_stylebox(radius: int = 4) -> StyleBoxFlat:
	var sb := window_stylebox(radius)
	sb.bg_color = Color(IRON_DARK.r, IRON_DARK.g, IRON_DARK.b, 1.0)
	return sb


# T-460: the chat panel's subtle gradient, shared by every idle HUD surface that de-boxes to the
# T-396 model (compass, vitals, combat log). A 1x256 transparent→black ramp scaled to fill; the
# caller weights it (bottom-weighted for bottom-anchored surfaces, top-weighted for the compass) and
# tunes subtlety via `max_alpha` on the node's modulate — the reference model sits at ~25-30%.
static func gradient_backdrop(max_alpha: float = 0.28, bottom_weighted: bool = true) -> TextureRect:
	var grad := Gradient.new()
	grad.offsets = PackedFloat32Array([0.0, 0.55, 1.0])
	grad.colors = PackedColorArray([Color(0, 0, 0, 0.0), Color(0, 0, 0, 0.35), Color(0, 0, 0, 1.0)])
	var tex := GradientTexture2D.new()
	tex.gradient = grad
	tex.width = 1
	tex.height = 256
	tex.fill_from = Vector2(0, 0) if bottom_weighted else Vector2(0, 1)
	tex.fill_to = Vector2(0, 1) if bottom_weighted else Vector2(0, 0)
	var rect := TextureRect.new()
	rect.name = "GradientBackdrop"
	rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE  # purely decorative — never eats a click
	rect.texture = tex
	rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	rect.stretch_mode = TextureRect.STRETCH_SCALE
	rect.modulate.a = max_alpha
	return rect


# T-460: an invisible surface that still carries the panel's content margins — the idle HUD idiom
# (legibility lives in the TEXT; any darkening comes from gradient_backdrop, never a filled box).
static func no_box_stylebox(margin: float = 8.0) -> StyleBoxEmpty:
	var sb := StyleBoxEmpty.new()
	sb.set_content_margin_all(margin)
	return sb


# A chat tab (T-396): small and translucent. The ACTIVE tab is visually loud (warm gold-lit fill +
# bright text); the inactive tabs recede to near-nothing so the row is barely there when idle.
static func chat_tab_stylebox(active: bool) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	if active:
		sb.bg_color = Color(GOLD.r, GOLD.g, GOLD.b, 0.30)
		sb.border_color = Color(GOLD_BRIGHT.r, GOLD_BRIGHT.g, GOLD_BRIGHT.b, 0.85)
		sb.border_width_bottom = 2
	else:
		sb.bg_color = Color(0.0, 0.0, 0.0, 0.20)
		sb.border_color = Color(0, 0, 0, 0)
	sb.set_corner_radius_all(3)
	sb.content_margin_left = 8
	sb.content_margin_right = 8
	sb.content_margin_top = 2
	sb.content_margin_bottom = 2
	return sb


# The recessed trough a bar's fill sits inside. T-460: bg_alpha < 1 lets an idle surface (vitals)
# keep a readable trough without an opaque block; the hairline 1px border is the thin outline.
static func trough_stylebox(bg_alpha: float = 1.0) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(IRON_MID.r, IRON_MID.g, IRON_MID.b, bg_alpha)
	sb.border_color = BRONZE
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(2)
	return sb


# A coloured bar fill (health/mana/rage/xp). Slight top-lighting via a lighter border.
static func fill_stylebox(color: Color) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = color
	sb.border_color = color.lightened(0.25)
	sb.border_width_top = 1
	sb.set_corner_radius_all(2)
	return sb


# An empty action-bar slot: dark socket with a bronze rim; the pressed state brightens the rim.
static func slot_stylebox(pressed: bool = false) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.16, 0.14, 0.12) if not pressed else Color(0.26, 0.22, 0.15)
	sb.border_color = GOLD_BRIGHT if pressed else BRONZE
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(3)
	return sb


# Build the shared Theme applied HUD-wide. Styles Panel/PanelContainer framing, Label/RichTextLabel
# text colour, and gives ProgressBar a bordered trough + gold fill (kills the flat-grey default).
static func build() -> Theme:
	var theme := Theme.new()
	theme.set_stylebox("panel", "PanelContainer", panel_stylebox())
	theme.set_stylebox("panel", "Panel", panel_stylebox())
	# T-396: a deliberately-opened window keeps the solid forged-iron surface via this type variation
	# (set `theme_type_variation = "SolidWindow"` on the window root); standing HUD uses the default.
	theme.set_type_variation("SolidWindow", "PanelContainer")
	theme.set_stylebox("panel", "SolidWindow", window_stylebox())
	# Label legibility over the world without a box: warm text + a dark outline AND drop shadow so it
	# reads over bright sky/snow/grass (T-396). Outline is the box-free legibility the reference model
	# leans on.
	theme.set_color("font_color", "Label", PARCHMENT)
	theme.set_color("font_outline_color", "Label", Color(0, 0, 0, 0.9))
	theme.set_constant("outline_size", "Label", 3)
	theme.set_color("font_shadow_color", "Label", Color(0, 0, 0, 0.7))
	theme.set_constant("shadow_offset_x", "Label", 1)
	theme.set_constant("shadow_offset_y", "Label", 1)
	# RichTextLabel (chat + combat log): same box-free legibility — dark outline + soft shadow.
	theme.set_color("default_color", "RichTextLabel", PARCHMENT)
	theme.set_color("font_outline_color", "RichTextLabel", Color(0, 0, 0, 0.9))
	theme.set_constant("outline_size", "RichTextLabel", 3)
	theme.set_color("font_shadow_color", "RichTextLabel", Color(0, 0, 0, 0.7))
	theme.set_constant("shadow_offset_x", "RichTextLabel", 1)
	theme.set_constant("shadow_offset_y", "RichTextLabel", 1)
	# ProgressBar (the XP belt): dark studded trough + gold fill, no default grey.
	theme.set_stylebox("background", "ProgressBar", trough_stylebox())
	theme.set_stylebox("fill", "ProgressBar", fill_stylebox(GOLD))
	theme.set_color("font_color", "ProgressBar", PARCHMENT)
	return theme
