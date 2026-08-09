class_name HudPanelSweep
extends RefCounted
# T-576: the "which HUD panels are currently open" sweep, pulled out of main.gd (already sitting at
# the 1000-line gdlint cap — see FROSTBOLT_ABILITY_ID and neighbors) so a second Esc-close-first
# member (the Performance Recap panel) has somewhere to live. Pure/no side effects: main.gd's
# _open_hud_panels() calls this and applies the result (T-571's CLOSE_PANELS branch closes each).
#
# The recap panel can't just join _panel_set — it's ALSO that set's #27 watcher
# (watch_panels(_panel_set) in main.gd), so self-membership would make it observe its own
# visibility_changed and close itself the instant it opens. It's passed as its own "extra" entry
# instead, alongside the onboarding handbook card (same reason T-376 already special-cased it).


static func open_panels(panel_set: Array, extras: Array) -> Array:
	var open := []
	for p in panel_set:
		if p != null and p.visible:
			open.append(p)
	for p in extras:
		if p != null and p.visible:
			open.append(p)
	return open
