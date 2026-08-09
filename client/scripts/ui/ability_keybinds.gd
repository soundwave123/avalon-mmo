class_name AbilityKeybinds
extends RefCounted
# T-723: the ONE map between an action-bar SLOT and the keyboard key that casts it.
#
# Before this, main.gd._input hard-coded `KEY_1 .. KEY_4` while the bar rendered up to nine slots
# with 1-9 pips, so slots 5+ were pure decoration: a keyboard player could not fire them at all.
# That hit the abilities that matter most — the role-free interrupts (Pummel 106, Counterspell 206)
# sit at the END of a trained class kit (index 5 on the default id-sorted layout), i.e. exactly in
# the dead range the tutorial's interrupt lesson asks the player to press.
#
# Everything that renders or dispatches a binding reads THIS file — the input handler (main.gd),
# the bar's keybind pips + tooltips (action_bar.gd), the F1 handbook (controls_reference.gd) and
# the Esc > Controls list (settings_panel.gd). Change the range here and all four follow; no second
# literal to keep in sync by hand (the T-078 "kept in sync by hand" comment is what rotted).
#
# Pure/static — headless-safe, no scene, no InputMap (remapping stays the named T-078 deferral).

# The number row is contiguous in keycode order (KEY_1 = 49 ... KEY_9 = 57), so slot N binds to
# FIRST_KEYCODE + N. If the bar ever grows to a tenth slot, that one takes KEY_0 (the WoW layout)
# and keycode_for_slot/slot_for_keycode need the wrap-around case — they are the only two places.
const FIRST_KEYCODE := KEY_1

# How many slots the keyboard can reach. Held equal to ActionBar.MAX_SLOTS (the bar draws nine
# pips) by test_ability_keybinds.test_keyed_range_covers_the_whole_bar — a keyed range SHORTER than
# the drawn bar is the T-723 bug itself, and a LONGER one binds keys to slots that never render.
const SLOT_COUNT := 9

# Rendered into a label that lists the whole range at once ("1 - 9"); the F1 handbook derives its
# own en-dash form from keycodes() instead.
const RANGE_SEPARATOR := " - "


# Every ability keycode, slot order — the F1 handbook's "Abilities" row renders from this.
static func keycodes() -> Array:
	var out: Array = []
	for slot in range(SLOT_COUNT):
		out.append(keycode_for_slot(slot))
	return out


# The key that casts `slot`, or -1 for a slot the keyboard cannot reach.
static func keycode_for_slot(slot: int) -> int:
	if slot < 0 or slot >= SLOT_COUNT:
		return -1
	return FIRST_KEYCODE + slot


# The slot a pressed key casts, or -1 when the key is not an ability key at all. main.gd._input
# branches on this, so a non-ability number key can never swallow another hotkey.
static func slot_for_keycode(keycode: int) -> int:
	var slot: int = keycode - FIRST_KEYCODE
	if slot < 0 or slot >= SLOT_COUNT:
		return -1
	return slot


# The printable key name for a slot — the bar's keybind pip and the tooltip's "Key: N" line. Empty
# for an unreachable slot, so a pip can never advertise a key that does nothing.
static func slot_label(slot: int) -> String:
	var keycode: int = keycode_for_slot(slot)
	if keycode == -1:
		return ""
	return OS.get_keycode_string(keycode)


# "1 - 9": the whole keyed range as one label (Esc > Controls, the glossary line).
static func range_label() -> String:
	return slot_label(0) + RANGE_SEPARATOR + slot_label(SLOT_COUNT - 1)
