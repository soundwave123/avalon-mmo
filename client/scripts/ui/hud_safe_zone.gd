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


static func intersects_vitals(rect: Rect2) -> bool:
	return rect.intersects(VITALS_RECT)


static func intersects_action_bar(rect: Rect2) -> bool:
	return rect.intersects(ACTION_BAR_RECT)


static func intersects_compass(rect: Rect2) -> bool:
	return rect.intersects(COMPASS_RECT)
