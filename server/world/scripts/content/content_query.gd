# T-041/T-043: pure content-query helpers — convert/filter the world's loaded content registries
# into the shapes the master RPC consumes. No node state; deterministic; unit-testable in isolation.

extends RefCounted

const _QDIFF = preload("res://scripts/content/quest_difficulty.gd")  # T-621: difficulty colours
# T-621: silver "!future" range — a quest that unlocks within this many levels shows as a visible
# promise (see npc_indicators_from_state). Mirrors npc_interaction.SILVER_MARKER_RANGE.
const SILVER_MARKER_RANGE := 3


# QuestData → the plain dict the master RPC + quest state machine consume.
static func quest_to_dict(quest) -> Dictionary:
	return {
		"id": quest.id,
		"title": quest.title,
		"min_level": quest.min_level,
		"prerequisite_quest": quest.prerequisite_quest,
		"giver_npc": quest.giver_npc,
		"turnin_npc": quest.turnin_npc,
		"objectives": quest.objectives,
		"rewards": quest.rewards,
		"provided_items": quest.provided_items,
		"repeatable": quest.repeatable,  # T-293: the SM allows a completed repeatable to re-accept
		"bounty": quest.bounty,  # T-450: daily pool eligibility is world-authored, never client data
		# T-707: no new accepts; mid-quest characters unaffected. Object.get + `== true` tolerates
		# the duck-typed quest fixtures older tests inject (missing property -> null -> false).
		"retired": quest.get("retired") == true,
	}


# T-293: the bounty-board list — a display summary of every `bounty` quest (the elite hunts). The
# board is a service hub (T-145 pattern); this is the world-local payload it acks with `browse`.
# One entry per bounty: id, title, the elite kill target + count, location hint, group size, reward.
static func bounty_defs(content_quests: Dictionary) -> Array:
	var out: Array = []
	for quest_id: String in content_quests:
		var quest = content_quests[quest_id]
		if not quest.bounty:
			continue
		var target := ""
		var target_desc := ""
		for obj: Dictionary in quest.objectives:
			if str(obj.get("type", "")) == "kill":
				target = str(obj.get("target", ""))
				target_desc = str(obj.get("desc", ""))
				break
		(
			out
			. append(
				{
					"quest_id": quest.id,
					"title": quest.title,
					"target": target,
					"target_desc": target_desc,
					"location_hint": quest.location_hint,
					"recommended_players": quest.recommended_players,
					"xp": int(quest.rewards.get("xp", 0)),
					"coins": int(quest.rewards.get("coins", 0)),
				}
			)
		)
	out.sort_custom(func(a, b): return str(a["quest_id"]) < str(b["quest_id"]))
	return out


# item_id -> {slot, stackable, max_stack} for the master's stacking/equip checks.
static func item_registry(content_items: Dictionary) -> Dictionary:
	var reg: Dictionary = {}
	for item_id: String in content_items:
		var it = content_items[item_id]
		reg[item_id] = {
			"slot": it.slot,
			"stackable": it.stackable,
			"max_stack": it.max_stack,
			"armor_type": it.armor_type,
			"rarity": it.rarity,  # T-412: lets the master rarity-scale the repair coin sink
			"use_effect": it.use_effect,  # T-414: server-read consumable effect (never client-named)
			"vendor_value": it.vendor_value,  # T-414: field-repair kit value bounds its repair cap
			# T-681: the level dimension the master's shared gate (item_level_gate.gd) reads on
			# BOTH the equip path and the use_effect path. Without it here, the gate fails open.
			"item_level": it.item_level,
			"required_level": it.required_level,
		}
	return reg


# T-399: item_id -> its authored {stat: amount} block, injected into master's get_character_combat
# so the gear fold (durability.effective_stats) can read stats items.json owns cross-project. Items
# with no `stats` contribute an empty dict (the reader sums nothing for them).
static func item_stats(content_items: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for item_id: String in content_items:
		out[item_id] = content_items[item_id].stats
	return out


# Quests with a `kill` objective for this mob alias, as the dicts the master credit RPC consumes.
static func kill_quest_defs(content_quests: Dictionary, mob_alias: String) -> Dictionary:
	var out: Dictionary = {}
	if mob_alias == "":
		return out
	for quest_id: String in content_quests:
		var quest = content_quests[quest_id]
		for obj: Dictionary in quest.objectives:
			if str(obj.get("type", "")) == "kill" and str(obj.get("target", "")) == mob_alias:
				out[quest_id] = quest_to_dict(quest)
				break
	return out


# T-426: quests with an `interrupt` objective for this mob alias (the tactical teaching verb). "*"
# targets match any interrupted channel, mirroring ability_quest_defs / kill_quest_defs.
static func interrupt_quest_defs(content_quests: Dictionary, mob_alias: String) -> Dictionary:
	var out: Dictionary = {}
	if mob_alias == "":
		return out
	for quest_id: String in content_quests:
		var quest = content_quests[quest_id]
		for obj: Dictionary in quest.objectives:
			var t := str(obj.get("target", ""))
			if str(obj.get("type", "")) == "interrupt" and (t == mob_alias or t == "*"):
				out[quest_id] = quest_to_dict(quest)
				break
	return out


# T-426: quests with a `use_ability` objective targeting this ability icon slug (tutorial verb).
static func ability_quest_defs(content_quests: Dictionary, ability_slug: String) -> Dictionary:
	var out: Dictionary = {}
	if ability_slug == "":
		return out
	for quest_id: String in content_quests:
		var quest = content_quests[quest_id]
		for obj: Dictionary in quest.objectives:
			# T-426: "*" target means "use any ability" (the tutorial verb across classes).
			var t := str(obj.get("target", ""))
			if str(obj.get("type", "")) == "use_ability" and (t == ability_slug or t == "*"):
				out[quest_id] = quest_to_dict(quest)
				break
	return out


# Is the player (at ppos) within `radius` of the named NPC? (server-authoritative proximity gate)
# T-577: `anchor`, when passed a Vector3, overrides the position measured against — callers pass
# a wandering NPC's fixed POST (npc_director.post_of) instead of its live wander-ticked npc.x/npc.y,
# so proximity is stable regardless of where the NPC currently is in its wander/patrol cycle. Static
# (untracked) NPCs never pass an anchor and behave exactly as before (live pos == authored pos).
static func near_npc(
	content_npcs: Dictionary, npc_id: String, ppos: Vector3, radius: float, anchor = null
) -> bool:
	if not content_npcs.has(npc_id):
		return false
	var npc = content_npcs[npc_id]
	var npc_pos: Vector3 = anchor if anchor is Vector3 else Vector3(npc.x, npc.y, 0.0)
	return ppos.distance_to(npc_pos) <= radius


# Is the player within `radius` of the quest's turn-in NPC? See `near_npc` re: `anchor`.
static func at_turnin_npc(
	content_npcs: Dictionary, quest, ppos: Vector3, radius: float, anchor = null
) -> bool:
	return near_npc(content_npcs, str(quest.turnin_npc), ppos, radius, anchor)


# T-603: Is the player within `radius` of the quest's GIVER NPC? Mirrors at_turnin_npc so the
# accept path carries the same server-authority proximity gate the turn-in path always had.
static func at_giver_npc(
	content_npcs: Dictionary, quest, ppos: Vector3, radius: float, anchor = null
) -> bool:
	return near_npc(content_npcs, str(quest.giver_npc), ppos, radius, anchor)


# NpcData → the {id, gives_quests, talk_text} dict the master npc_talk RPC consumes.
static func npc_to_dict(npc) -> Dictionary:
	return {
		"id": npc.id,
		"gives_quests": npc.gives_quests,
		"talk_text": npc.talk_text,
		"trainer": npc.trainer,  # T-065
	}


# Every loaded quest as {quest_id -> def dict} — passed to npc_talk so it can scan talk objectives.
static func all_quest_defs(content_quests: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for quest_id: String in content_quests:
		out[quest_id] = quest_to_dict(content_quests[quest_id])
	return out


# T-322: compute !/? from the master's small persisted-state snapshot while content stays in world.
# T-621: also emit the silver "!future" state — a quest this NPC gives that the player will unlock
# within SILVER_MARKER_RANGE levels (the WoW "visible promise" wayfinding: you can see WHERE your
# next quests come from before you're high enough to take them).
static func npc_indicators_from_state(
	npcs: Dictionary, npc_quest_index: Dictionary, raw_quests: Array, player_level: int
) -> Dictionary:
	var states: Dictionary = {}
	for entry: Dictionary in raw_quests:
		states[str(entry.get("quest_id", ""))] = entry
	var out: Dictionary = {}
	for npc_id: String in npcs:
		var npc = npcs[npc_id]
		var defs: Dictionary = npc_quest_index.get(npc_id, {})
		var available := false
		var available_soon := false  # T-621: silver ! — unlocks within SILVER_MARKER_RANGE levels
		var turn_in_ready := false
		var turn_in_active := false
		for quest_id: String in defs:
			var quest: Dictionary = defs[quest_id]
			var entry: Dictionary = states.get(quest_id, {})
			var state := str(entry.get("state", ""))
			var prereq := str(quest.get("prerequisite_quest", ""))
			var prereq_state: Dictionary = states.get(prereq, {})
			var prereq_complete := prereq == "" or str(prereq_state.get("state", "")) == "complete"
			if quest_id in npc.gives_quests:
				var repeatable := bool(quest.get("repeatable", false))
				var state_allows := state != "active" and (state != "complete" or repeatable)
				var min_level := int(quest.get("min_level", 1))
				var level_allows := player_level >= min_level
				available = available or (state_allows and level_allows and prereq_complete)
				# T-621: takeable-but-for-level, and that level is within reach (never a prereq gap —
				# a prereq quest is not a "visible promise" the player can plan around by levelling).
				var gap := min_level - player_level
				available_soon = (
					available_soon
					or (
						state_allows
						and prereq_complete
						and not level_allows
						and gap > 0
						and gap <= SILVER_MARKER_RANGE
					)
				)
			var turnin := str(quest.get("turnin_npc", quest.get("giver_npc", "")))
			if turnin != npc_id:
				continue
			var progress: Array = entry.get("progress", [])
			var objectives_complete := true
			for i in range(quest.get("objectives", []).size()):
				var required := int(quest["objectives"][i].get("count", 1))
				if i >= progress.size() or int(progress[i]) < required:
					objectives_complete = false
					break
			turn_in_ready = turn_in_ready or (state == "active" and objectives_complete)
			turn_in_active = turn_in_active or state == "active"
		# Priority: ready-to-turn-in > available > in-progress-here > future-available > nothing.
		out[npc_id] = (
			"?"
			if turn_in_ready
			else (
				"!"
				if available
				else ("?grey" if turn_in_active else "!future" if available_soon else "")
			)
		)
	return out


# T-038: enrich the raw master quest log ({quest_id, state, progress:[int]}) with content (title +
# per-objective desc/required) into the client quest-log view-model. Pairs progress[i] with
# objectives[i]; unknown quest_id falls back to the id as title with no objectives.
static func enrich_quest_log(
	raw_quests: Array, content_quests: Dictionary, char_level: int = 1
) -> Array:
	var out: Array = []
	for rq: Dictionary in raw_quests:
		var quest_id := str(rq.get("quest_id", ""))
		var progress: Array = rq.get("progress", [])
		var title := quest_id
		var objectives: Array = []
		# T-621: quest_level (min_level) + difficulty colour ride the view-model so the client log +
		# tracker paint the band without a second lookup. Unknown quest -> a neutral yellow at own level.
		var quest_level := char_level
		# T-622: the group/elite marker rides the active-quest view-model too, so the Quest Log and
		# the always-on tracker paint the same "Elite" badge the offer card showed (rec_players > 1).
		var elite := false
		if content_quests.has(quest_id):
			var quest = content_quests[quest_id]
			title = quest.title
			quest_level = int(quest.min_level)
			elite = int(quest.recommended_players) > 1
			for i in range(quest.objectives.size()):
				var obj: Dictionary = quest.objectives[i]
				(
					objectives
					. append(
						{
							"desc": str(obj.get("desc", "")),
							"current": int(progress[i]) if i < progress.size() else 0,
							"required": int(obj.get("count", 0)),
						}
					)
				)
		(
			out
			. append(
				{
					"quest_id": quest_id,
					"title": title,
					"state": str(rq.get("state", "")),
					"objectives": objectives,
					"quest_level": quest_level,  # T-621
					"difficulty": _QDIFF.color(quest_level, char_level),  # T-621
					"elite": elite,  # T-622: group/elite marker for the log + tracker badge
				}
			)
		)
	return out


# T-519: the quest-prompt previews the client's offer/turn-in dialog renders. `available` quest ids
# become "offer" cards (the `!`), `turn_in_ready` become "turn_in" cards (the `?`). Each carries the
# quest's title, objective descriptions (+ required counts) and reward summary — the server is the
# authority on what a quest offers; the client only draws it + fires the accept/turn_in intent.
# T-710: the giver NPC of the quest that directly follows `quest_id` in a chain (a quest whose
# prerequisite_quest is quest_id), or "" when the chain ends there. Chains are authored linear, so
# the first match is the successor. Pure: content in, npc id out — the turn-in path uses it to
# decide whether to re-offer the next step in the same dialog flow (the WoW pattern).
static func chain_successor_giver(quest_id: String, content_quests: Dictionary) -> String:
	if quest_id == "":
		return ""
	for qid: String in content_quests:
		if str(content_quests[qid].prerequisite_quest) == quest_id:
			return str(content_quests[qid].giver_npc)
	return ""


static func talk_previews(
	available: Array, turn_in_ready: Array, content_quests: Dictionary
) -> Array:
	var out: Array = []
	for quest_id in available:
		# T-707: a retired quest never renders an offer card (kept only for mid-quest turn-ins) —
		# belt-and-suspenders under the accept gate, for any stale gives_quests listing.
		if (
			content_quests.has(str(quest_id))
			and content_quests[str(quest_id)].get("retired") == true
		):
			continue
		out.append(_quest_preview("offer", str(quest_id), content_quests))
	for quest_id in turn_in_ready:
		out.append(_quest_preview("turn_in", str(quest_id), content_quests))
	return out


static func _quest_preview(
	kind: String, quest_id: String, content_quests: Dictionary
) -> Dictionary:
	var title := quest_id
	var objectives: Array = []
	var xp := 0
	var coins := 0
	# T-622: recommended_players > 1 => a GROUP/ELITE quest. The offer panel paints an "Elite" badge
	# from this flag (pairs with T-621's difficulty colour). Reuses the T-293 field, so no new quest
	# schema key: bounties + the named-mob hunts tag automatically.
	var elite := false
	var turnin_text := ""  # T-713: the giver's spoken line on the TURN-IN card only
	if content_quests.has(quest_id):
		var quest = content_quests[quest_id]
		title = quest.title
		if kind == "turn_in":
			turnin_text = str(quest.turnin_text)
		for obj: Dictionary in quest.objectives:
			objectives.append(
				{"desc": str(obj.get("desc", "")), "required": int(obj.get("count", 0))}
			)
		xp = int(quest.rewards.get("xp", 0))
		coins = int(quest.rewards.get("coins", 0))
		elite = int(quest.recommended_players) > 1
	return {
		"kind": kind,
		"quest_id": quest_id,
		"title": title,
		"objectives": objectives,
		"xp": xp,
		"coins": coins,
		"elite": elite,  # T-622: group/elite marker (recommended_players > 1)
		"turnin_text": turnin_text,  # T-713: "" on offer cards and on quests with nothing to say
	}


# T-046: reach-objective targets whose (x,y,radius) contains ppos (world credits these on entry).
# T-698: the live hot path uses reach_targets_from over the load-time reach_objectives list; this
# full scan stays as the reference implementation (the precompute-equivalence test compares them).
static func reach_targets_at(content_quests: Dictionary, ppos: Vector3) -> Array:
	var out: Array = []
	for quest_id: String in content_quests:
		for obj: Dictionary in content_quests[quest_id].objectives:
			if str(obj.get("type", "")) != "reach":
				continue
			var center := Vector3(float(obj.get("x", 0.0)), float(obj.get("y", 0.0)), 0.0)
			if ppos.distance_to(center) <= float(obj.get("radius", 0.0)):
				var target := str(obj.get("target", ""))
				if not out.has(target):
					out.append(target)
	return out


# T-698: the static reach-objective list, computed ONCE at content load — reach objectives never
# change at runtime (only ~21 exist), so per-move checks walk this flat list instead of every
# quest's whole objective array. Row shape: {target, center: Vector3, radius}. Quest/objective
# iteration order is preserved, so reach_targets_from over this list is exactly reach_targets_at.
static func reach_objectives(content_quests: Dictionary) -> Array:
	var out: Array = []
	for quest_id: String in content_quests:
		for obj: Dictionary in content_quests[quest_id].objectives:
			if str(obj.get("type", "")) != "reach":
				continue
			(
				out
				. append(
					{
						"target": str(obj.get("target", "")),
						"center": Vector3(float(obj.get("x", 0.0)), float(obj.get("y", 0.0)), 0.0),
						"radius": float(obj.get("radius", 0.0)),
					}
				)
			)
	return out


# T-698: reach targets containing ppos, from the precomputed reach_objectives list.
static func reach_targets_from(reach_objs: Array, ppos: Vector3) -> Array:
	var out: Array = []
	for row: Dictionary in reach_objs:
		if ppos.distance_to(row["center"]) <= float(row["radius"]):
			var target: String = row["target"]
			if not out.has(target):
				out.append(target)
	return out


# T-698: {kill target -> {quest_id: def}} built once at content load. kill_quest_defs(quests, m)
# == kill_quest_index(quests).get(m, {}) for every alias (equivalence-tested) — the per-kill
# O(quests x objectives) scan + per-quest re-serialization becomes one dict probe.
static func kill_quest_index(content_quests: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for quest_id: String in content_quests:
		var quest = content_quests[quest_id]
		for obj: Dictionary in quest.objectives:
			if str(obj.get("type", "")) != "kill":
				continue
			var target := str(obj.get("target", ""))
			if target == "" or (out.has(target) and out[target].has(quest_id)):
				continue
			if not out.has(target):
				out[target] = {}
			out[target][quest_id] = quest_to_dict(quest)
	return out


# T-039: enrich raw inventory slots ({slot_type, slot_index, item_id, item_count}) for the inventory
# UI — add item `name` (content; fallback to id) and normalize `slot_index`/`count` to int (the DB
# read returns them as strings — TD-001).
# T-233: also thread through `slot` (equip slot), `stats`, `vendor_value`, `description` — the
# tooltip's body lines — mirroring how T-230 threaded `rarity` through for the name color.
static func enrich_inventory(raw_slots: Array, content_items: Dictionary) -> Array:
	var out: Array = []
	for slot: Dictionary in raw_slots:
		var item_id := str(slot.get("item_id", ""))
		var name := item_id
		var rarity := "common"
		var item_slot := ""
		var stats: Dictionary = {}
		var vendor_value := 0
		var description := ""
		var armor_type := "none"  # T-420: worn-visual armor family (equipped_from_slots routes by it)
		var item_level := 1  # T-681: tooltip level dimension (1/1 = ungated, renders nothing)
		var required_level := 1
		if content_items.has(item_id):
			var item = content_items[item_id]
			name = item.name
			rarity = item.rarity  # T-230: the client colors names by this
			item_slot = item.slot
			stats = item.stats
			vendor_value = item.vendor_value
			description = item.description
			armor_type = item.armor_type
			item_level = item.item_level  # T-681
			required_level = item.required_level
		(
			out
			. append(
				{
					"slot_type": str(slot.get("slot_type", "")),
					"slot_index": int(slot.get("slot_index", 0)),
					"item_id": item_id,
					"name": name,
					"rarity": rarity,
					"count": int(slot.get("item_count", 1)),
					"slot": item_slot,
					"stats": stats,
					"vendor_value": vendor_value,
					"description": description,
					"armor_type": armor_type,
					"item_level": item_level,  # T-681: tooltip level lines
					"required_level": required_level,
				}
			)
		)
		# T-375/T-428: keep the master-authored presentation overlay while enriching item display
		# metadata. Dropping these keys here silently erased transmog before equipped_from_slots.
		for cosmetic_key in [
			"appearance_override",
			"appearance_armor_type",
			"appearance_hidden",
			"tint",
			"dye_mask",
		]:
			if slot.has(cosmetic_key):
				(out[-1] as Dictionary)[cosmetic_key] = slot[cosmetic_key]
	return out
