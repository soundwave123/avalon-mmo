class_name ControlsReference
# T-376: the single source of truth for "how do I play" — the ordered list of controls the
# onboarding card (controls_card.gd) renders.
#
# T-761: the rows no longer carry key literals of their own. Each names KeyRegistry binding IDs and
# asks the registry for the keycode, so this file can only ever describe what the live listeners
# actually dispatch — the previous "derived from the same KEY_* constants" arrangement still meant
# two copies of every literal, and copies rot. Labels resolve through KeyRegistry.label_for, so a
# French player reads "Z Q S D" for the same physical keys a US player reads as "W A S D".
# Mouse gestures (no keycode) carry explicit text. Pure/static — headless-safe.

extends RefCounted

# Each row: a human "action" and EITHER a list of KeyRegistry binding ids OR a mouse-gesture
# string. Keep this list in the order a new player needs it: move, look, fight, then the panels.
# The action wording is this card's own (it groups four move bindings into one "Move" row); the
# KEYS are always the registry's.
const _ROWS: Array = [
	{"action": "Move", "ids": ["move_forward", "move_left", "move_back", "move_right"]},
	{"action": "Walk / run", "ids": ["walk_toggle"]},
	{"action": "Look around", "mouse": "Hold Right-Mouse + drag"},
	{"action": "Orbit camera", "mouse": "Hold Left-Mouse + drag"},
	{"action": "Zoom", "mouse": "Mouse wheel"},
	{"action": "Target / talk", "mouse": "Left-click a foe or townsfolk"},
	{"action": "Auto-attack", "ids": ["autoattack"]},
	# T-723: no key literals here — the ability row renders the LIVE slot->key map (AbilityKeybinds),
	# so the handbook grew from "1 - 4" to the whole keyed bar the moment the bindings did.
	{"action": "Abilities", "ability_keys": true},
	{"action": "Inventory", "ids": ["inventory"]},
	{"action": "Quest log", "ids": ["quest_log"]},
	{"action": "Character", "ids": ["character_sheet"]},
	{"action": "Talents", "ids": ["talents"]},
	{"action": "World map", "ids": ["world_map"]},
	{"action": "Wardrobe", "ids": ["wardrobe"]},
	{"action": "Cosmetics store", "ids": ["cosmetics"]},
	{"action": "Menu / cancel", "ids": ["menu"]},
	{"action": "This help card", "ids": ["help_card"]},
]

# T-426: the glossary — every load-bearing VERB/CONCEPT with a one-line plain-language explanation,
# so a new player can look anything up without leaving the game (GameFlow: "online help so players
# don't need a manual"). Terms are concepts, not binds — the derived key table above owns the binds.
const GLOSSARY: Array = [
	{"term": "Move", "tip": "W A S D walks; hold Right-Mouse and drag to steer your view."},
	{"term": "Target", "tip": "Left-click a foe to target it; Tab cycles nearby foes; Esc clears."},
	{"term": "Abilities", "tip": "Keys {keys} fire your class abilities at your current target."},
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


# The physical keycode that re-opens the card (also the F1 row above). Kept as this file's public
# name because onboarding_controller dispatches on it; the VALUE is the registry's. A function
# rather than the old const because a const cannot call into the registry.
static func help_keycode() -> int:
	return KeyRegistry.key_for("help_card")


# The glossary rows the card renders: [{term, tip}] (a stable copy, same shape as GLOSSARY).
static func glossary_rows() -> Array:
	var out: Array = []
	var keys := AbilityKeybinds.range_label()  # T-723: {keys} = the live ability-key range
	for g: Dictionary in GLOSSARY:
		out.append({"term": str(g["term"]), "tip": str(g["tip"]).replace("{keys}", keys)})
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


# Render one row's key/mouse label. Keycodes resolve through KeyRegistry.label_for (this
# keyboard's engraving for that physical position), joined with a thin space; a contiguous run
# collapses to "1 – 9".
#
# Contiguity is tested on the PHYSICAL codes, not the labels: the number row is one unbroken run of
# positions on every layout, but its labels are "&é"'(" on AZERTY, so a label-based check would
# print nine separate glyphs there and a range here. Positions decide the shape, labels fill it in.
static func _label_for(row: Dictionary) -> String:
	if row.has("mouse"):
		return str(row["mouse"])
	var keys: Array = _row_keycodes(row)
	if _is_contiguous(keys):
		var last: int = int(keys[keys.size() - 1])
		return "%s – %s" % [KeyRegistry.label_for(int(keys[0])), KeyRegistry.label_for(last)]
	var names: Array = []
	for k in keys:
		names.append(KeyRegistry.label_for(int(k)))
	return "  ".join(names)


# The physical keycodes a row renders. T-723: the ability row carries no ids of its own — it asks
# AbilityKeybinds for the live slot->key map. T-761: every other row names registry ids.
static func _row_keycodes(row: Dictionary) -> Array:
	if row.has("ability_keys"):
		return AbilityKeybinds.keycodes()
	var out: Array = []
	for id in row.get("ids", []):
		out.append(KeyRegistry.key_for(str(id)))
	return out


static func _is_contiguous(keys: Array) -> bool:
	if keys.size() < 3:
		return false
	for i in range(1, keys.size()):
		if int(keys[i]) != int(keys[i - 1]) + 1:
			return false
	return true
