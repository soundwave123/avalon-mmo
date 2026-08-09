class_name MentorCredit
extends RefCounted

# T-481 pure, additive mentor-recognition rules. The caller injects every observation; this module
# reads no clock/DB/global state, mutates no input, and returns only presentation/collection grants.

const CREDIT_PER_COMPLETION := 1
const _THRESHOLDS := [
	{"credit": 1, "key": "mentor_title", "kind": "title", "id": "title:Mentor"},
	{"credit": 5, "key": "guiding_hand", "kind": "achievement", "id": "guiding_hand"},
	{"credit": 10, "key": "mentor_sigil", "kind": "cosmetic", "id": "mentor_sigil_blade"},
]
const _POWER_NEUTRAL_KINDS := ["title", "achievement", "cosmetic"]


static func new_state() -> Dictionary:
	return {"credit": 0, "granted": []}


# One server-observed completed-content edge may add one credit. Toggle time alone is inert.
static func accrue(state: Dictionary, observation: Dictionary) -> Dictionary:
	var out := {
		"credit": maxi(0, int(state.get("credit", 0))),
		"granted": (state.get("granted", []) as Array).duplicate(),
	}
	if not eligible(observation):
		return {"state": out, "credit_delta": 0, "grants": []}
	var before := int(out["credit"])
	out["credit"] = before + CREDIT_PER_COMPLETION
	var grants: Array = []
	for threshold: Dictionary in _THRESHOLDS:
		var key := str(threshold["key"])
		if before < int(threshold["credit"]) and int(out["credit"]) >= int(threshold["credit"]):
			if not out["granted"].has(key):
				out["granted"].append(key)
				grants.append(threshold.duplicate(true))
	return {"state": out, "credit_delta": CREDIT_PER_COMPLETION, "grants": grants}


static func rewards_are_power_neutral(grants: Array) -> bool:
	for grant: Dictionary in grants:
		if str(grant.get("kind", "")) not in _POWER_NEUTRAL_KINDS:
			return false
		for forbidden in ["coins", "xp", "item", "gear", "stats", "damage", "currency"]:
			if grant.has(forbidden):
				return false
	return true


static func eligible(observation: Dictionary) -> bool:
	var true_level := int(observation.get("true_level", 0))
	var effective_level := int(observation.get("effective_level", true_level))
	var max_level := int(observation.get("max_level", 0))
	return (
		bool(observation.get("opted_in", false))
		and bool(observation.get("content_completed", false))
		and bool(observation.get("active_participation", false))
		and max_level > 0
		and true_level == max_level
		and effective_level >= 1
		and effective_level < true_level
	)
