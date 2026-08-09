class_name ControlsReference
# T-376: the single source of truth for "how do I play" — the ordered list of controls the
# onboarding card (controls_card.gd) renders. Key labels are DERIVED from the same KEY_* keycode
# constants the live handlers use (main.gd._input, local_player.gd._unhandled_input), rendered via
# OS.get_keycode_string, so the card can never drift from the real bindings: change a binding and
# the label follows. Mouse gestures (no keycode) carry explicit text. Pure/static — headless-safe.

extends RefCounted

# Each row: a human "action" and EITHER a list of keycodes OR a mouse-gesture string.
# Keep this list in the order a new player needs it: move, look, fight, then the panels.
const _ROWS: Array = [
	{"action": "Move", "keys": [KEY_W, KEY_A, KEY_S, KEY_D]},
	{"action": "Walk / run", "keys": [KEY_SLASH]},
	{"action": "Look around", "mouse": "Hold Right-Mouse + drag"},
	{"action": "Orbit camera", "mouse": "Hold Left-Mouse + drag"},
	{"action": "Zoom", "mouse": "Mouse wheel"},
	{"action": "Target / talk", "mouse": "Left-click a foe or townsfolk"},
	{"action": "Auto-attack", "keys": [KEY_QUOTELEFT]},
	{"action": "Abilities", "keys": [KEY_1, KEY_2, KEY_3, KEY_4]},
	{"action": "Inventory", "keys": [KEY_I]},
	{"action": "Quest log", "keys": [KEY_L]},
	{"action": "Character", "keys": [KEY_C]},
	{"action": "Talents", "keys": [KEY_N]},
	{"action": "Wardrobe", "keys": [KEY_V]},
	{"action": "Cosmetics store", "keys": [KEY_H]},
	{"action": "Menu / cancel", "keys": [KEY_ESCAPE]},
	{"action": "This help card", "keys": [KEY_F1]},
]

# The keycode that re-opens the card (also the F1 row above). Sourced here so main.gd and the card
# agree on the one binding without a second literal.
const HELP_KEYCODE := KEY_F1

# T-426: the glossary — every load-bearing VERB/CONCEPT with a one-line plain-language explanation,
# so a new player can look anything up without leaving the game (GameFlow: "online help so players
# don't need a manual"). Terms are concepts, not binds — the derived key table above owns the binds.
const GLOSSARY: Array = [
	{"term": "Move", "tip": "W A S D walks; hold Right-Mouse and drag to steer your view."},
	{"term": "Target", "tip": "Left-click a foe to target it; Tab cycles nearby foes; Esc clears."},
	{"term": "Abilities", "tip": "Keys 1-4 fire your class abilities at your current target."},
	{
		"term": "GCD",
		"tip": "The global cooldown — a short beat between abilities (the slot sweep)."
	},
	{"term": "Casting", "tip": "Cast-time abilities need a still stance; moving cancels the cast."},
	{
		"term": "Interrupt",
		"tip": "Striking a caster mid-cast can break their spell — watch the bar."
	},
	{
		"term": "Threat",
		"tip": "Damage and healing draw a mob's ire; it attacks whoever tops threat."
	},
	{"term": "Loot", "tip": "Slain foes may drop items — they land straight in your bag."},
	{"term": "Equip", "tip": "Open your bag (I) and click an item to wear or wield it."},
	{
		"term": "Quests",
		"tip": "A gold ! offers a task; ? means turn it in. L opens your quest log."
	},
	{"term": "Party", "tip": "Group up to share kills and quests; party chat has its own tab."},
	{
		"term": "Guild & Help",
		"tip": "Chat tabs: guild speaks to your guild; help answers newcomers."
	},
	{"term": "Discovery", "tip": "Finding new places earns discovery rewards — wandering pays."},
]

# T-717: the FIRST-SHOW subset. A brand-new player is in learning mode, where working memory holds
# ~3 items — the full table (16 rows + glossary + hints) is the right REFERENCE and the wrong first
# impression, so the auto-shown card teaches only what minute one needs (move, look, talk) and
# points at F1 for the rest. Same derived labels, so it can't drift from the bindings either.
const _ESSENTIAL_ACTIONS: Array = ["Move", "Look around", "Target / talk"]


# The glossary rows the card renders: [{term, tip}] (a stable copy, same shape as GLOSSARY).
static func glossary_rows() -> Array:
	var out: Array = []
	for g: Dictionary in GLOSSARY:
		out.append({"term": str(g["term"]), "tip": str(g["tip"])})
	return out


# The rows the card renders: [{action, keys_label}]. keys_label is built live so it always reflects
# the current keycodes — never a hand-typed string that can rot when a binding moves.
static func rows() -> Array:
	var out: Array = []
	for r: Dictionary in _ROWS:
		out.append({"action": str(r["action"]), "keys_label": _label_for(r)})
	return out


static func essential_rows() -> Array:
	var out: Array = []
	for action in _ESSENTIAL_ACTIONS:
		for r: Dictionary in _ROWS:
			if str(r["action"]) == action:
				out.append({"action": action, "keys_label": _label_for(r)})
				break
	return out


# Render one row's key/mouse label. Keycodes go through OS.get_keycode_string (the engine's own
# printable name), joined with a thin space; a contiguous run (1-4) collapses to "1 – 4".
static func _label_for(row: Dictionary) -> String:
	if row.has("mouse"):
		return str(row["mouse"])
	var keys: Array = row["keys"]
	if _is_contiguous(keys):
		return "%s – %s" % [_key_name(keys[0]), _key_name(keys[keys.size() - 1])]
	var names: Array = []
	for k in keys:
		names.append(_key_name(int(k)))
	return "  ".join(names)


# A friendlier printable for a few keys whose engine name is unhelpful for players.
static func _key_name(keycode: int) -> String:
	match keycode:
		KEY_QUOTELEFT:
			return "`"
		KEY_SLASH:
			return "/"
		_:
			return OS.get_keycode_string(keycode)


static func _is_contiguous(keys: Array) -> bool:
	if keys.size() < 3:
		return false
	for i in range(1, keys.size()):
		if int(keys[i]) != int(keys[i - 1]) + 1:
			return false
	return true
