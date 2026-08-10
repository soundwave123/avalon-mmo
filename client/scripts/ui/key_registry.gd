class_name KeyRegistry
extends RefCounted
# T-761: the ONE table of every key Avalon binds, plus the two helpers that make a binding work on
# a keyboard that isn't American.
#
# WHY THIS FILE EXISTS
# The audit (godot47-full-audit-2026-08-09 item 14) found 20+ independent `_input` listeners whose
# only registry was a comment, and two hand-maintained keymap lists (settings_panel.KEYBINDS and
# controls_reference._ROWS) that already disagreed with what shipped. Nothing could answer "is K
# free?" without grepping. The table below is that answer, and test_key_registry.gd reads the
# source tree to prove it is COMPLETE — a new panel that binds a key without adding a row here
# fails the suite (the T-723 keyed-slot audit pattern, applied to the client).
#
# THE DESIGN CHOICE: a const table, not a register() call.
# Panels keep dispatching their own key in their own `_input` — forcing 20 files through a central
# dispatcher is the full InputMap migration, which the owner explicitly deferred (T-761 option b).
# What the table buys without that churn: duplicate detection, one place to read the whole keymap,
# and a single source for both rendered key lists. The follow-up InputMap ticket can turn these
# rows into actions without moving them.
#
# LAYOUT INDEPENDENCE (the actual bug this ticket fixes)
# Every key below is a PHYSICAL keycode — a position on the board, named by the US key that sits
# there. Dispatch reads event.physical_keycode (see event_code) so a French player's ZQSD walks by
# position, and DISPLAY reads label_for() so that same player is TOLD "Z", not "W". Those are two
# different directions of the same mapping and both are required: physical-only dispatch with
# US labels is a game that plays right and lies to you about which keys to press.
#
# Pure/static — no scene, no nodes, headless-safe.

# A world binding is live during normal play; its physical key must be unique across the table
# (test_no_duplicate_world_bindings). A modal binding only exists while a specific modal owns all
# keyboard input (class select, gender select, an open context menu, the chat line), so it MAY
# reuse a world key — that is not drift, it's scoping, and UiInputGate is what enforces it.
const SCOPE_WORLD := "world"
const SCOPE_MODAL := "modal"

# Row layout for _ROWS. It is a table, so it is written as one — a dict per row costs six lines of
# punctuation each once the formatter is done with it, which buries the keymap it is supposed to
# make readable. bindings() hands callers dicts; only this file indexes by position.
const COL_ID := 0
const COL_ACTION := 1
const COL_KEY := 2
const COL_SCOPE := 3
const COL_OWNER := 4

# Keys whose engine name reads badly in a key list. Applied to the RESOLVED label, never to the
# physical code — on AZERTY the physical KEY_SLASH position reports as ":", and the player must be
# told ":", so overriding before resolution would reintroduce the very US-centrism we're removing.
const _FRIENDLY_LABELS := {KEY_QUOTELEFT: "`", KEY_SLASH: "/"}

# Every non-ability binding in the game: [id, action, physical key, scope, owning script].
# `owner` is the script whose listener dispatches the key — documentation for a human, and
# test_every_owner_script_exists keeps it honest when files move.
#
# The nine ability slots are NOT rows here: they're generated from AbilityKeybinds (which still
# owns FIRST_KEYCODE/SLOT_COUNT, because the server-side T-723 audit greps that file for
# SLOT_COUNT). See bindings().
const _ROWS: Array = [
	# Movement + locomotion — polled every frame in local_player, not event-dispatched.
	["move_forward", "Move forward", KEY_W, SCOPE_WORLD, "scripts/world/local_player.gd"],
	["move_back", "Move back", KEY_S, SCOPE_WORLD, "scripts/world/local_player.gd"],
	["move_left", "Strafe left", KEY_A, SCOPE_WORLD, "scripts/world/local_player.gd"],
	["move_right", "Strafe right", KEY_D, SCOPE_WORLD, "scripts/world/local_player.gd"],
	["jump", "Jump", KEY_SPACE, SCOPE_WORLD, "scripts/world/local_player.gd"],
	["walk_toggle", "Walk / run", KEY_SLASH, SCOPE_WORLD, "scripts/world/local_player.gd"],
	# Combat + world hotkeys (main.gd's one dispatch block).
	["autoattack", "Auto-attack", KEY_QUOTELEFT, SCOPE_WORLD, "scripts/main.gd"],
	["target_cycle", "Cycle target", KEY_TAB, SCOPE_WORLD, "scripts/main.gd"],
	["mount", "Mount / dismount", KEY_M, SCOPE_WORLD, "scripts/main.gd"],
	["quest_log", "Quest log", KEY_L, SCOPE_WORLD, "scripts/main.gd"],
	["inventory", "Bags", KEY_I, SCOPE_WORLD, "scripts/main.gd"],
	["character_sheet", "Character sheet", KEY_C, SCOPE_WORLD, "scripts/main.gd"],
	["talents", "Talents", KEY_N, SCOPE_WORLD, "scripts/main.gd"],
	["menu", "Menu / cancel", KEY_ESCAPE, SCOPE_WORLD, "scripts/main.gd"],
	# Panel toggles — each panel owns its own listener; this table owns the key.
	["chat", "Chat", KEY_ENTER, SCOPE_WORLD, "scripts/ui/chat_panel.gd"],
	["help_card", "This help card", KEY_F1, SCOPE_WORLD, "scripts/ui/onboarding_controller.gd"],
	["spellbook", "Spellbook", KEY_B, SCOPE_WORLD, "scripts/ui/spellbook_panel.gd"],
	["guild", "Guild", KEY_G, SCOPE_WORLD, "scripts/ui/guild_panel.gd"],
	["cosmetics", "Cosmetics store", KEY_H, SCOPE_WORLD, "scripts/ui/cosmetic_shop_panel.gd"],
	["weekly", "Weekly goals", KEY_J, SCOPE_WORLD, "scripts/ui/weekly_panel.gd"],
	["recipes", "Recipes", KEY_K, SCOPE_WORLD, "scripts/ui/recipe_panel.gd"],
	["social", "Social", KEY_O, SCOPE_WORLD, "scripts/ui/social_panel.gd"],
	["pvp", "PvP", KEY_P, SCOPE_WORLD, "scripts/ui/pvp_panel.gd"],
	["recap", "Performance recap", KEY_R, SCOPE_WORLD, "scripts/ui/performance_recap_panel.gd"],
	["world_map", "World map", KEY_T, SCOPE_WORLD, "scripts/ui/world_map_panel.gd"],
	["lfg", "Looking for group", KEY_U, SCOPE_WORLD, "scripts/ui/lfg_panel.gd"],
	["wardrobe", "Wardrobe", KEY_V, SCOPE_WORLD, "scripts/ui/wardrobe_panel.gd"],
	["achievements", "Achievements", KEY_Y, SCOPE_WORLD, "scripts/ui/achievements_panel.gd"],
	# Modal-scoped. These deliberately alias world keys (1/2/3 are ability slots during play, class
	# picks while the class modal is up) — UiInputGate.is_blocking_modal_visible is the switch.
	["modal_pick_1", "Choose the first option", KEY_1, SCOPE_MODAL, "scripts/ui/class_panel.gd"],
	["modal_pick_2", "Choose the second option", KEY_2, SCOPE_MODAL, "scripts/ui/class_panel.gd"],
	["modal_pick_3", "Choose the third option", KEY_3, SCOPE_MODAL, "scripts/ui/class_panel.gd"],
	["modal_confirm", "Confirm", KEY_ENTER, SCOPE_MODAL, "scripts/ui/class_panel.gd"],
	[
		"modal_confirm_kp",
		"Confirm (keypad)",
		KEY_KP_ENTER,
		SCOPE_MODAL,
		"scripts/ui/class_panel.gd"
	],
	["modal_confirm_space", "Confirm (space)", KEY_SPACE, SCOPE_MODAL, "scripts/ui/class_panel.gd"],
	["modal_prev", "Previous option", KEY_UP, SCOPE_MODAL, "scripts/ui/class_panel.gd"],
	["modal_next", "Next option", KEY_DOWN, SCOPE_MODAL, "scripts/ui/class_panel.gd"],
	["modal_cancel", "Close / cancel", KEY_ESCAPE, SCOPE_MODAL, "scripts/ui/chat_panel.gd"],
]

# Cached because label_for runs once per row on every key-list rebuild and the display server
# cannot change mid-run. -1 = not yet probed.
static var _labels_cache := -1


# The whole keymap as dicts {id, action, key, scope, owner}: the rows above plus one generated
# entry per keyed ability slot.
static func bindings() -> Array:
	var out: Array = []
	for row: Array in _ROWS:
		out.append(_as_dict(row))
	for slot in range(AbilityKeybinds.SLOT_COUNT):
		var key := AbilityKeybinds.keycode_for_slot(slot)
		var label := "Ability slot %d" % (slot + 1)
		out.append(
			_as_dict(["ability_%d" % (slot + 1), label, key, SCOPE_WORLD, "scripts/main.gd"])
		)
	return out


# The physical keycode bound to `id`, or -1 when nothing is.
static func key_for(id: String) -> int:
	for b: Dictionary in bindings():
		if str(b["id"]) == id:
			return int(b["key"])
	return -1


# The player-facing label for `id` ("W" on QWERTY, "Z" on AZERTY). Empty for an unknown id.
static func label_for_id(id: String) -> String:
	var key := key_for(id)
	return "" if key == -1 else label_for(key)


# THE DISPATCH ACCESSOR. Every `_input`/`_unhandled_input` listener in the client reads its key
# through this instead of event.keycode.
#
# physical_keycode is the position on the board, so a binding follows the KEY rather than the
# LETTER PRINTED ON IT — that is the whole AZERTY/QWERTZ fix. The keycode fallback covers events
# that carry no physical code at all: on-screen/IME keyboards and a few synthesized events set only
# the logical code, and dispatching nothing at all for those would be a worse bug than dispatching
# by layout. On a US board the two are identical for every key this game binds, so the fallback is
# unobservable there (test_qwerty_dispatch_is_byte_identical_to_the_old_logical_read).
static func event_code(event: InputEventKey) -> int:
	if event == null:
		return 0
	if event.physical_keycode != 0:
		return event.physical_keycode
	return event.keycode


# THE DISPLAY ACCESSOR. Turns a physical keycode into the character actually engraved on the
# player's key: DisplayServer maps position -> that keyboard's label, so KEY_W renders "W" on a US
# board and "Z" on a French one.
#
# Headless/dummy display servers do not implement the mapping — they push an engine ERROR and hand
# the code straight back, which would spray the test logs — so we never call it there and fall back
# to the physical code's own US name. That fallback is also the right answer for a headless run:
# there is no keyboard to describe, so describing the position is the only honest thing left.
static func label_for(physical: int) -> String:
	var resolved := physical
	if _labels_supported():
		var mapped := DisplayServer.keyboard_get_label_from_physical(physical)
		if mapped != 0:  # belt-and-braces: an unmapped position falls back to its own name
			resolved = mapped
	return label_from_resolved(resolved)


# The second half of label_for, split out so both halves are testable: given the keycode the
# player's keyboard reports for a position, what do we PRINT? Headless can't run the resolution
# step (no keyboard), but it can run this, which is where the friendly-name policy lives — pass
# KEY_Z here to see exactly what a French player reads for the physical W position.
static func label_from_resolved(resolved: int) -> String:
	if _FRIENDLY_LABELS.has(resolved):
		return str(_FRIENDLY_LABELS[resolved])
	return OS.get_keycode_string(resolved)


# True when the display server can map a physical position to this keyboard's engraving. False
# headless — see label_for. Exposed so tests can state which of the two paths they just exercised.
static func labels_are_layout_aware() -> bool:
	return _labels_supported()


static func _as_dict(row: Array) -> Dictionary:
	return {
		"id": str(row[COL_ID]),
		"action": str(row[COL_ACTION]),
		"key": int(row[COL_KEY]),
		"scope": str(row[COL_SCOPE]),
		"owner": str(row[COL_OWNER]),
	}


static func _labels_supported() -> bool:
	if _labels_cache == -1:
		var server := DisplayServer.get_name().to_lower()
		var headless: bool = server == "headless" or server == "dummy"
		_labels_cache = 0 if headless else 1
	return _labels_cache == 1
