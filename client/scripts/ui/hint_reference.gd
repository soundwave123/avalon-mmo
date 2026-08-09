class_name HintReference
# T-426: the single source of truth for the contextual control hints — the one-line, fire-once
# nudges that surface the FIRST time an action becomes possible (GameFlow "Player Skills": teach in
# the moment of need, never a wall of text). The toast (hint_toast.gd) renders them; the handbook
# (controls_card.gd) lists them for review; OnboardingPrefs remembers which fired per user. Keep
# every hint to ONE line — anything longer belongs in the handbook glossary, not a toast.

extends RefCounted

# Ordered: the order a brand-new player meets each moment. id is the stable per-user "seen" key.
const HINTS: Array = [
	{
		"id": "move",
		"text": "Press W A S D to move — hold Right-Mouse and drag to look around.",
	},
	{
		# T-557: the default range assumes the shipped 5-slot bar (T-464); main.gd overrides it with
		# the LIVE filled-slot count via target_hint() so it never undercounts a class's abilities.
		"id": "target",
		"text": "Target locked — press 1-5 to use an ability, or ` to auto-attack.",
	},
	{
		"id": "quest",
		"text": "A gold ! over a townsfolk means work — left-click them to talk (? turns in).",
	},
	{
		"id": "bag_item",
		"text": "An item is in your bag — press I to open it, then click the item to equip.",
	},
	{
		"id": "interrupt",
		"text": "Casting needs a still stance — moving cancels the cast.",
	},
	{
		# T-666 (portal #85): generic handbook copy — the live toast overrides it with the class
		# resource text via resource_hint() at the moment the first starved press happens.
		"id": "resource",
		"text":
		"Abilities cost a class resource — rage builds from attacks, mana refills over time.",
	},
	{
		# T-711 rule 1: the 60s no-quest stall — one directional nudge toward the tutorial giver
		# (the controller also aims the compass pip). Fires once per account, pre-graduation only.
		"id": "stall_find_hale",
		"text": "Drillmaster Hale is training recruits — head northwest.",
	},
	{
		# T-713: the graduation beat's social half — fired once, on the q_tut_03 turn-in. The LFG
		# board (T-625) shipped with no keybind mention anywhere, so nobody ever found it.
		"id": "lfg_graduation",
		"text": "Training's done — press U to find other adventurers heading the same way.",
	},
	{
		# T-711 rule 2: the 90s untouched-objective stall. The live toast overrides this with the
		# tracked quest's next objective (OnboardingStall.restate_text); this is the handbook copy.
		"id": "stall_objective",
		"text": "Stuck? The tracker (top right) lists your objective — the compass points the way.",
	},
]


# T-666 (portal #85): the one-liner for a brand-new character's FIRST resource-starved ability
# press (kind-keyed like combat_resources: rage | mana). Falls back to the generic HINTS copy for
# any other kind — hint("resource", "") resolves to text_for("resource").
static func resource_hint(resource_kind: String) -> String:
	match resource_kind:
		"rage":
			return "Not enough rage — your auto-attack (`) builds it."
		"mana":
			return "Not enough mana — it refills on its own; give it a moment."
	return ""


# T-557: the target-lock hint with its ability-key range bound to the REAL number of filled action-
# bar slots (the bar grew to 5 with T-464). One slot reads "press 1"; more read "press 1-N".
static func target_hint(slot_count: int) -> String:
	var range_text := "1" if slot_count <= 1 else "1-%d" % slot_count
	return "Target locked — press %s to use an ability, or ` to auto-attack." % range_text


static func ids() -> Array:
	var out: Array = []
	for h: Dictionary in HINTS:
		out.append(str(h["id"]))
	return out


# The one-liner for a hint id; "" for an unknown id (callers treat that as "no hint to show").
static func text_for(id: String) -> String:
	for h: Dictionary in HINTS:
		if str(h["id"]) == id:
			return str(h["text"])
	return ""


# T-483: read-only formatter for the authoritative appointment view. The handshake always carries
# streak state; a bounty browse can enrich it with objective titles, and T-480 can add `weekly`.
# Missing optional fields degrade to a truthful invitation rather than inventing progress.
static func return_reason_text(daily: Dictionary) -> String:
	if not bool(daily.get("ok", false)) or int(daily.get("streak", 0)) <= 0:
		return ""
	var text := "Day %d complete — a fresh reward waits tomorrow" % int(daily["streak"])
	var objectives: Array = daily.get("objectives", [])
	if not objectives.is_empty():
		var title := str((objectives[0] as Dictionary).get("title", "")).strip_edges()
		if title != "":
			text += ". Daily preview: %s" % title
	else:
		text += ", with a fresh daily set"
	var weekly: Dictionary = daily.get("weekly", {})
	var progress := int(weekly.get("progress", -1))
	var goal := int(weekly.get("goal", 0))
	if progress >= 0 and goal > 0:
		text += ". Weekly vault: %d/%d" % [progress, goal]
	return text + "."
