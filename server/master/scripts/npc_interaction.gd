# T-037: NPC interaction — pure, deterministic indicator + talk-plan logic.
#
# Given an NPC, the quest defs it touches (as giver and/or turn-in point), and per-quest facts
# drawn from the player's persisted state, decides the `!`/`?` indicator and the talk plan. Mirrors
# the pure-module idiom of quest_state_machine.gd (T-033), objective_tracker.gd (T-034),
# leveling.gd (T-035) and inventory_logic.gd (T-036).
#
# HARD CONSTRAINTS:
#   - No DB, no OS time, no global state. Inputs are never mutated.
#   - Determinism: same inputs always produce identical output.
#   - REUSE: acceptability / turn-in-ability are quest_state_machine's guards, never re-implemented
#     here — this module only aggregates their QuestResults into an indicator + talk plan.
#
# An indicator is shown ON the NPC, so turn-in is evaluated with at_turnin_npc = true (being at the
# NPC is implied). `?` (turn-in ready) outranks `!` (acceptable); else "".

extends RefCounted

const _QSM = preload("res://scripts/quest_state_machine.gd")
# T-754: quest_defs arrives from the world over the wire — its VALUES are unvalidated.
const _RI = preload("res://scripts/rpc_intake.gd")

# T-621: silver "!future" — a quest this NPC gives that unlocks within this many levels (the WoW
# "visible promise" wayfinding). Kept in lock-step with content_query.SILVER_MARKER_RANGE (the world
# owns the live-broadcast copy; this master authority mirrors it for the RPC/offer path).
const SILVER_MARKER_RANGE := 3


# npc:        {id, gives_quests: [quest_id], talk_text}
# quest_defs: { quest_id -> quest dict }  (quests this NPC gives and/or turns in)
# facts:      { quest_id -> {state, player_level, prereq_complete, objectives_complete} }
static func evaluate(npc: Dictionary, quest_defs: Dictionary, facts: Dictionary) -> Dictionary:
	var npc_id := str(npc.get("id", ""))
	var available: Array = []
	var available_soon: Array = []  # T-621: takeable within SILVER_MARKER_RANGE levels → silver !
	var turn_in_ready: Array = []
	var turn_in_active: Array = []  # turns in here but not ready yet → grey ? (find where to hand in)
	var talk_targets: Array = []

	# Quests this NPC GIVES → acceptable now? (T-033 evaluate_accept)
	for quest_id: String in npc.get("gives_quests", []):
		if not quest_defs.has(quest_id):
			continue
		var f: Dictionary = facts.get(quest_id, {})
		var player_level := int(f.get("player_level", 1))
		var given: Dictionary = _RI.shaped(quest_defs, quest_id, {})  # T-754: wire-supplied value
		var r := _QSM.evaluate_accept(
			given, str(f.get("state", "")), player_level, bool(f.get("prereq_complete", false))
		)
		if r.ok:
			available.append(quest_id)
		elif r.reason == "level_too_low":
			# T-621: only the level gate stands between the player and this quest, and it's within
			# reach — a silver "!future". (evaluate_accept checks level BEFORE prereq, but a still-
			# locked prereq is a separate wall, so require prereq_complete too before promising it.)
			var gap := int(given.get("min_level", 1)) - player_level
			if bool(f.get("prereq_complete", false)) and gap > 0 and gap <= SILVER_MARKER_RANGE:
				available_soon.append(quest_id)

	# Quests this NPC TURNS IN (turnin_npc, defaulting to giver_npc) → turn-in ready now?
	for quest_id: String in quest_defs:
		var quest: Dictionary = _RI.shaped(quest_defs, quest_id, {})  # T-754: wire-supplied value
		var turnin := str(quest.get("turnin_npc", quest.get("giver_npc", "")))
		if turnin != npc_id:
			continue
		var f: Dictionary = facts.get(quest_id, {})
		var r := _QSM.evaluate_turn_in(
			quest, str(f.get("state", "")), bool(f.get("objectives_complete", false)), true
		)
		if r.ok:
			turn_in_ready.append(quest_id)
		elif str(f.get("state", "")) == _QSM.STATE_ACTIVE:
			turn_in_active.append(quest_id)  # have it, objectives not done → grey ?

	# Active quests with a `talk` objective targeting this NPC (T-034 credit candidates).
	for quest_id: String in quest_defs:
		var f: Dictionary = facts.get(quest_id, {})
		if str(f.get("state", "")) != _QSM.STATE_ACTIVE:
			continue
		var talk_def: Dictionary = _RI.shaped(quest_defs, quest_id, {})  # T-754
		for obj: Variant in _RI.shaped(talk_def, "objectives", []):
			if not obj is Dictionary:
				continue
			if str(obj.get("type", "")) == "talk" and str(obj.get("target", "")) == npc_id:
				talk_targets.append(quest_id)
				break

	var indicator := ""
	if not turn_in_ready.is_empty():
		indicator = "?"  # gold ? — ready to turn in
	elif not available.is_empty():
		indicator = "!"  # gold ! — quest available
	elif not turn_in_active.is_empty():
		indicator = "?grey"  # grey ? — turns in here but objectives aren't done yet
	elif not available_soon.is_empty():
		indicator = "!future"  # T-621: silver ! — unlocks within a few levels (visible promise)

	return {
		"indicator": indicator,
		"available": available,
		"available_soon": available_soon,  # T-621
		"turn_in_ready": turn_in_ready,
		"turn_in_active": turn_in_active,
		"talk_targets": talk_targets,
	}
