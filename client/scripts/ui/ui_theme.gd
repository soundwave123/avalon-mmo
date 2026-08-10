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

# ---- text scale (T-747) --------------------------------------------------
# THE font-size hook. Before this, no theme-level font size existed anywhere: the HUD ran entirely
# on Godot's built-in default plus 28 per-node add_theme_font_size_override() literals scattered
# across 21 files (measured histogram: 11, 12, 15, 16, 18, 20, 22, 24, 26, 40, 44, 54). With UI
# stretch now scaling the whole canvas (see ui_viewport.gd), a text-scale accessibility setting is
# a realistic near-term ask, and it needs ONE place to act on.
#
# 16 is deliberately Godot's own default — verified on 4.7.1 that Label, RichTextLabel, ProgressBar
# and Button all resolve font_size 16 with no theme at all. So switching the hook on is a provable
# no-op today: nothing on screen moves a pixel, and the wiring is in place for the day it changes.
#
# NOT swept in this ticket: the 28 per-node literals. add_theme_font_size_override() beats the
# theme unconditionally, so every one of them is still immune to this hook — a deliberate scope
# call, since retiring them is a per-panel visual judgement (a 40px death banner is not "body text
# at 2.5x") and doing it blind would regress layouts the safe-zone tests don't cover. Follow-up
# ticket territory; the histogram above is the worklist.
const BODY_FONT_SIZE := 16

# The RichTextLabel font-size items, which (unlike every other Control) are five separate keys —
# miss one and bold/italic/mono chat runs stay at the old size while normal text scales.
const RICH_TEXT_FONT_SIZE_ITEMS: PackedStringArray = [
	"normal_font_size",
	"bold_font_size",
	"italics_font_size",
	"bold_italics_font_size",
	"mono_font_size",
]

# T-759: the process-wide cached Theme (see build() for the full rationale). Declared here at global
# scope because gdlint requires all var definitions before the first function.
static var _shared: Theme = null


# THE MOUSE-FILTER IDIOM (T-651, made the documented default by T-748) — read this before adding
# ANY Control to the HUD.
#
# Godot facts this exists for:
#   * Control.mouse_filter defaults to MOUSE_FILTER_STOP (Label/RichTextLabel are the exceptions,
#     they default to IGNORE; Container defaults to PASS). So every ColorRect / Panel /
#     PanelContainer / ProgressBar you add is, by default, a click-eating surface the size of its
#     rect — decoration included.
#   * GUI picking walks the tree in REVERSE CHILD ORDER and IGNORES z_index (z_index only decides
#     the DRAW order — see modal_input.gd). The FIRST non-IGNORE control found under the cursor
#     wins; PASS only bubbles the event to ANCESTORS, never to the siblings underneath. So a
#     decoration child beats its own parent's gui_input, and a later full-rect sibling beats an
#     earlier modal no matter how high its z_index is.
#
# Setting mouse_filter on the OUTERMOST root alone is therefore never enough (T-645 did that; T-651
# found the inner art still eating world clicks; T-748 found three more). Pick one of the three
# recipes below, at the END of _ready() once the whole subtree exists:
#
#   (a) IDLE HUD SURFACE — nothing inside is ever clickable (vitals, xp belt, compass, cast bar):
#           UiTheme.set_mouse_filter_deep(self)
#   (b) CLICKABLE SURFACE WITH DECORATION — the click belongs to ONE node, everything else is art
#       (party_frames rows: a gui_input row root behind 7 decoration children):
#           UiTheme.set_mouse_filter_deep(row_root)
#           row_root.mouse_filter = Control.MOUSE_FILTER_STOP   # re-arm the ONE picker
#   (c) WINDOW / OVERLAY WITH REAL CONTROLS — never cascade (it would deafen the Buttons). IGNORE
#       the full-rect CHROME (root, dim/scrim, centering container) by hand and leave only the
#       bounded BODY at STOP, so the window blocks clicks over ITSELF and nothing more
#       (controls_card.gd — the "porous overlay" shape).
#
# A window root at STOP is CORRECT while it is open — that is what a window is. What is never
# correct is a full-rect STOP surface over a screen the player is still meant to play/click.
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


# T-759: ONE cached Theme for the whole client. build() used to mint a fresh Theme (plus a full set
# of StyleBox copies) on every one of its ~25 call sites — 25 identical resources where the engine
# only ever needed one, since a Theme is immutable-by-convention here (verified: no caller mutates
# the returned instance — the only set_*/apply_font_sizes writes live in this file, and the T-747
# text-scale hook is DESIGNED to mutate the single live theme in place). Lazily built on first call
# and shared by reference after, so every panel that assigns `theme = UiTheme.build()` points at the
# same resource — the least-invasive of the ticket's two options (callers are unchanged). The
# `_shared` var itself is declared at the top of the file (gdlint: vars before functions).


# Build (once) + return the shared Theme applied HUD-wide. Styles Panel/PanelContainer framing,
# Label/RichTextLabel text colour, and gives ProgressBar a bordered trough + gold fill (kills the
# flat-grey default). Idempotent: subsequent calls return the same cached instance.
static func build() -> Theme:
	if _shared == null:
		_shared = _build_theme()
	return _shared


# The actual construction, split out so build() can cache. Tests that need a throwaway theme to
# mutate (apply_font_sizes) build their own via Theme.new() rather than poisoning the singleton.
static func _build_theme() -> Theme:
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
	apply_font_sizes(theme, BODY_FONT_SIZE)
	return theme


# T-747: set the text scale in ONE call. `default_font_size` covers every Control type the theme
# doesn't name explicitly (Buttons, LineEdits, ItemLists — it short-circuits the lookup walk before
# the engine's fallback); the explicit per-type sizes cover the three types build() actually styles,
# so a reader of this file can see the HUD's text size without knowing the fallback rules.
#
# A future text-scale setting calls this with body * scale on the live theme — the whole point.
static func apply_font_sizes(theme: Theme, body: int) -> void:
	theme.set_default_font_size(body)
	theme.set_font_size("font_size", "Label", body)
	theme.set_font_size("font_size", "ProgressBar", body)
	for item in RICH_TEXT_FONT_SIZE_ITEMS:
		theme.set_font_size(item, "RichTextLabel", body)
