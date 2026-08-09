class_name SettingsEscGate
extends RefCounted

# T-078 / T-320 idiom: the pure decision for what the Esc key does, so the precedence is unit-
# testable with no live tree and no duplicate state. WoW order:
#   1. options menu open        -> close it
#   2. any OTHER HUD panel open -> close those first (quest log, bag, talents, sheet, service)
#   3. a target is selected     -> deselect it
#   4. nothing open             -> open the options menu
# One owner (main.gd) reads the returned action and applies it — no panel drives its own Esc,
# so open/close stays idempotent (the T-320 stuck-panel lesson).

const CLOSE_MENU := "close_menu"
const CLOSE_PANELS := "close_panels"
const CLEAR_TARGET := "clear_target"
const OPEN_MENU := "open_menu"


static func next_action(menu_open: bool, any_panel_open: bool, has_target: bool) -> String:
	if menu_open:
		return CLOSE_MENU
	if any_panel_open:
		return CLOSE_PANELS
	if has_target:
		return CLEAR_TARGET
	return OPEN_MENU
