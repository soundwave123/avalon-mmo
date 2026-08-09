# T-033: Quest lifecycle state machine — pure, deterministic, server-authoritative.
#
# Decides whether a quest transition (accept / turn_in / abandon) is legal, given the quest
# definition + current persisted state + server-observed facts. Mirrors the pure-SM idiom of
# server/world/scripts/combat/action_state_machine.gd (T-017).
#
# HARD CONSTRAINTS:
#   - No DB access, no OS time, no global mutable state.
#   - Same inputs always produce identical QuestResult (determinism).
#   - Persisted states are the 3 in the T-032 schema: "active" | "complete" | "abandoned".
#     "Ready to turn in" is DERIVED (objectives_complete), never stored.
#
# The client sends INTENT only; every guard below is checked from server-held facts. Objective
# tracking (T-034), reward granting (T-035/T-036) and NPC proximity (T-037) are injected facts.

extends RefCounted

const STATE_ACTIVE := "active"
const STATE_COMPLETE := "complete"
const STATE_ABANDONED := "abandoned"

# T-621: quest-log cap (WoW classic = 20 active quests). A full log refuses the NEXT accept with a
# clean "log_full" reason (surfaced via the T-575 failure-toast path). The cap counts ACTIVE quests
# only — completed/abandoned rows don't occupy a log slot. Enforced in character_manager.try_accept
# (the pure evaluate_accept below stays count-agnostic so npc_interaction's marker eval never needs
# the roster count); would_exceed_log_cap is the single predicate both the gate and its test share.
const MAX_ACTIVE_QUESTS := 20


# True when accepting a NEW active quest would push the log past the cap. `active_count` is the
# character's current count of ACTIVE quests (the roster minus complete/abandoned rows).
static func would_exceed_log_cap(active_count: int) -> bool:
	return active_count >= MAX_ACTIVE_QUESTS


class QuestResult:
	var ok: bool = false
	var reason: String = ""  # stable rejection reason; "" when ok
	var new_state: String = ""  # target persisted state; "" when rejected
	var rewards: Dictionary = {}  # {"xp": int, "items": [...]} — only on a successful turn_in

	static func success(new_state: String, rewards: Dictionary = {}) -> QuestResult:
		var r := QuestResult.new()
		r.ok = true
		r.new_state = new_state
		r.rewards = rewards
		return r

	static func failure(reason: String) -> QuestResult:
		var r := QuestResult.new()
		r.ok = false
		r.reason = reason
		return r


# Treats null / "" / "active complete abandoned" consistently.
static func _has_prereq(quest: Dictionary) -> bool:
	var p: Variant = quest.get("prerequisite_quest", "")
	return p != null and str(p) != ""


static func evaluate_accept(
	quest: Dictionary, current_state: String, player_level: int, prereq_complete: bool
) -> QuestResult:
	if current_state == STATE_ACTIVE:
		return QuestResult.failure("already_active")
	# T-293: a `repeatable` quest (the bounty board's elite hunts) may be re-accepted after it was
	# completed — the loop is accept → kill → turn in → accept again. Non-repeatable quests stay
	# one-and-done. A time-based cooldown is DEFERRED: this pure SM's hard "no OS time" invariant
	# forbids reading a clock here, so a completed_at/now fact would have to be threaded in first.
	if current_state == STATE_COMPLETE and not bool(quest.get("repeatable", false)):
		return QuestResult.failure("already_complete")
	if player_level < int(quest.get("min_level", 1)):
		return QuestResult.failure("level_too_low")
	if _has_prereq(quest) and not prereq_complete:
		return QuestResult.failure("prerequisite_incomplete")
	# Fresh ("") or re-accept after "abandoned"/a completed repeatable.
	return QuestResult.success(STATE_ACTIVE)


static func evaluate_turn_in(
	quest: Dictionary, current_state: String, objectives_complete: bool, at_turnin_npc: bool
) -> QuestResult:
	if current_state != STATE_ACTIVE:
		return QuestResult.failure("not_active")
	if not objectives_complete:
		return QuestResult.failure("objectives_incomplete")
	if not at_turnin_npc:
		return QuestResult.failure("not_at_turnin_npc")
	var rewards: Dictionary = quest.get("rewards", {"xp": 0, "items": []})
	return QuestResult.success(STATE_COMPLETE, rewards)


static func evaluate_abandon(current_state: String) -> QuestResult:
	if current_state != STATE_ACTIVE:
		return QuestResult.failure("not_active")
	return QuestResult.success(STATE_ABANDONED)
