class_name HudSafeZone
# T-608/T-634: the single shared source of truth for the standing HUD chrome's reserved rects at
# the 1280x720 base resolution.
#
# Root cause (proven twice): six deliberately-opened panels each hardcoded their own
# `offset_top = 56.0` / `offset_bottom = -56.0` independently, with no shared constant tying them
# to the ACTUAL standing chrome underneath — Quest Log/Character Sheet clipped VitalsFrame (T-608),
# Talents clipped the hotbar (T-608), and death_presentation.gd's toast/cue overlapped the hotbar
# from a completely separate composition (T-634). Every offending surface computed its OWN guess
# at "clear of the chrome" instead of reading it from one place.
#
# Rects are (x, y, width, height) in the 1280x720 base — the same base every panel already builds
# its fixed pixel offsets against (T-396's "anchor proportionally, offset absolutely" idiom).

extends RefCounted

const BASE_WIDTH := 1280.0
const BASE_HEIGHT := 720.0

# VitalsFrame (player_hud.gd: offset_left/right 20/276, offset_top/bottom 20/90) plus the T-571
# auto-attack indicator pip directly below it (offset_top/bottom 94/116) — the combined occupied
# band's bottom edge is y=116, not VitalsFrame's own y=90 (the T-640 lesson: a panel that only
# cleared 90 still clipped the "Auto-Attack: OFF" label). Height is 97, not the raw 96 the offset
# math gives — the Label's own font-driven minimum size expands its live rect by 1px (measured; see
# test_hud_safe_zone.gd), and this constant reserves the REAL rect, not the naive offset delta.
const VITALS_RECT := Rect2(20.0, 20.0, 256.0, 97.0)

# ActionBar (action_bar.gd) reserved at its WIDEST case — MAX_SLOTS=9 hotkeys, not the currently
# visible MIN_VISIBLE_SLOTS=6 — so a panel that clears it today never regresses when a kit grows
# past 6 abilities. At MAX_SLOTS: offset_left = -(9*(52+6))/2 = -261 -> x=640-261=379; the bar's
# y-band is 720 - 52 - 88 = 580 .. 632 (action_bar.gd's own offset math).
const ACTION_BAR_RECT := Rect2(379.0, 580.0, 522.0, 52.0)

# CompassStrip (compass_strip.gd: offset_left/right -70/70 off centre, offset_top/bottom 10/52).
const COMPASS_RECT := Rect2(570.0, 10.0, 140.0, 42.0)

# T-738 MinimapPanel: top-right corner (minimap_panel.gd: right-anchored, offset_left/right
# -170/-20, offset_top/bottom 10/160 -> 1110..1260 x 10..160 at the 1280x720 base). Reserved so
# future panels never clip the always-on minimap the way the T-608/T-634 offenders clipped vitals.
const MINIMAP_RECT := Rect2(1110.0, 10.0, 150.0, 150.0)

# The minimum `offset_top` a bottom-anchored (anchor_bottom=1), left-fixed panel needs so its top
# edge clears VITALS_RECT's bottom edge (117) with a small margin. Shared by quest_log_panel.gd /
# character_sheet_panel.gd / talent_panel.gd (T-640 shipped this value first as its own local
# SAFE_TOP; it now lives here so nobody re-derives — or mis-derives — it independently).
const PANEL_SAFE_TOP := 120.0

# The maximum `offset_bottom` (a negative number, anchor_bottom=1) a panel needs so its bottom edge
# clears ACTION_BAR_RECT's top edge (580) with a small margin, REGARDLESS of the panel's horizontal
# position or the hotbar's current slot count — vertical clearance alone is sufficient and doesn't
# require reasoning about MAX vs MIN_VISIBLE_SLOTS width. 720 - 148 = 572 <= 580 - 8.
const PANEL_SAFE_BOTTOM := -148.0

# T-759: the minimum `offset_top` a RIGHT-anchored, top-fixed panel needs so its top edge clears the
# always-on MinimapPanel (MINIMAP_RECT bottom = 160) with an 8 px margin. PANEL_SAFE_TOP (120) only
# clears the LEFT-side VitalsFrame; a right-side panel at that top still drove straight through the
# minimap (the audit's 4g table: inventory_panel 150x104, objective_tracker 150x50). 160 + 8 = 168.
# Consumers: inventory_panel.gd / recipe_panel.gd / pvp_panel.gd / objective_tracker.gd.
const MINIMAP_SAFE_TOP := 168.0

# T-759: the maximum `offset_bottom` (a POSITIVE number this time) an anchor=0.5 vertically-CENTERED
# fixed-size panel may use so its bottom edge clears ACTION_BAR_RECT's top (580). A centered panel's
# bottom sits at BASE_HEIGHT*0.5 + offset_bottom, so the ceiling is 580 - 360 - 8 = 212 (keep the
# panel's height by pulling offset_top up by the same amount). Consumers: wardrobe_panel.gd /
# weekly_panel.gd / cosmetic_shop_panel.gd — the centered modals the audit flagged over the hotbar.
const PANEL_SAFE_BOTTOM_CENTERED := 212.0


# T-747: the 1280x720 base above is REAL now — project.godot declares it as the content base under
# canvas_items stretch, where before this file described a resolution the client never actually
# ran at. One caveat comes with it, and it is the reason these accessors exist.
#
# stretch/aspect="expand" guarantees only the base HEIGHT. The content WIDTH grows on anything
# wider than 16:9 — a 21:9 monitor yields roughly 1706 — so the absolute x in three of the four
# rects above is a 16:9 snapshot, not a constant:
#
#   VITALS_RECT      left-anchored     x is genuinely fixed
#   ACTION_BAR_RECT  centre-anchored   x baked from 640-261; the real bar slides right
#   COMPASS_RECT     centre-anchored   x baked from 640±70; same
#   MINIMAP_RECT     right-anchored    x baked from 1280-170; the real minimap slides further
#
# Pass the live viewport width and you get the rect the chrome ACTUALLY occupies; omit it and you
# get the 16:9 case, which is what the shipped 1920x1080 window produces and what every existing
# caller means. Nothing shipped was ever at risk here — production consumes only PANEL_SAFE_TOP /
# PANEL_SAFE_BOTTOM, which are vertical — but a helper that silently returns the wrong rect on an
# ultrawide is a trap worth closing while the base is being made honest.
static func vitals_rect(_viewport_width: float = BASE_WIDTH) -> Rect2:
	return VITALS_RECT  # left-anchored: unaffected by a wider content rect


static func action_bar_rect(viewport_width: float = BASE_WIDTH) -> Rect2:
	return _recentre(ACTION_BAR_RECT, viewport_width)


static func compass_rect(viewport_width: float = BASE_WIDTH) -> Rect2:
	return _recentre(COMPASS_RECT, viewport_width)


static func minimap_rect(viewport_width: float = BASE_WIDTH) -> Rect2:
	var r := MINIMAP_RECT
	r.position.x += viewport_width - BASE_WIDTH  # right-anchored: tracks the full width delta
	return r


static func _recentre(rect: Rect2, viewport_width: float) -> Rect2:
	var r := rect
	r.position.x += (viewport_width - BASE_WIDTH) * 0.5  # centre-anchored: half the width delta
	return r


static func intersects_vitals(rect: Rect2, viewport_width: float = BASE_WIDTH) -> bool:
	return rect.intersects(vitals_rect(viewport_width))


static func intersects_action_bar(rect: Rect2, viewport_width: float = BASE_WIDTH) -> bool:
	return rect.intersects(action_bar_rect(viewport_width))


static func intersects_compass(rect: Rect2, viewport_width: float = BASE_WIDTH) -> bool:
	return rect.intersects(compass_rect(viewport_width))


static func intersects_minimap(rect: Rect2, viewport_width: float = BASE_WIDTH) -> bool:
	return rect.intersects(minimap_rect(viewport_width))
