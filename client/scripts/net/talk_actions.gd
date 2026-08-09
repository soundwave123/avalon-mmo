class_name TalkActions
extends RefCounted

# T-056/T-519: build the quest-prompt model from a talk_result so clicking a quest-giver OPENS an
# offer / turn-in dialog. It used to silently auto-accept offered quests and auto-turn-in ready ones
# — which only flipped the `!`/`?` marker and never showed the player anything (T-519 defect). The
# server owns quest state and now sends `offers` (title + objectives + rewards per available/turn-in
# quest); this pure helper hands that model to the QuestOfferPanel, whose buttons fire the
# accept_quest / turn_in intents. Falls back to id-only cards if a reply predates the enrichment.
# Pure — unit-tested.


# talk_result → the offer/turn-in cards to show (empty when the server rejected on proximity, or the
# NPC offers nothing). Each card: {kind: "offer"|"turn_in", quest_id, title, objectives, xp, coins}.
static func prompt_model(talk_result: Dictionary) -> Array:
	if not bool(talk_result.get("ok", false)):
		return []
	var offers: Array = talk_result.get("offers", [])
	if not offers.is_empty():
		return offers.duplicate(true)
	# Legacy fallback: reply carries only ids (pre-T-519 server) — id-only cards still open a prompt.
	var out: Array = []
	for qid in talk_result.get("available", []):
		out.append(_stub("offer", str(qid)))
	for qid in talk_result.get("turn_in_ready", []):
		out.append(_stub("turn_in", str(qid)))
	return out


static func _stub(kind: String, quest_id: String) -> Dictionary:
	return {
		"kind": kind,
		"quest_id": quest_id,
		"title": quest_id,
		"objectives": [],
		"xp": 0,
		"coins": 0,
	}
