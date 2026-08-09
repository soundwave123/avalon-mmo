class_name OnboardingStall
# T-711: pure decisions for the escalating first-session stall detector (the OSRS Tutorial Island
# pattern), riding the T-426 fire-once hint chassis. OnboardingController owns the clocks and the
# live state; everything HERE is deterministic math on plain values so the escalation ladder
# unit-tests headless (mirrors OnboardingPrefs' decision/IO split). All three rules are
# pre-graduation only — a graduated account's alt is never nagged (the caller passes pre_grad).

extends RefCounted

# Rule 1: no quest accepted this long after gaining control -> one directional hint toward the
# tutorial giver (plus the compass pip the controller already aims pre-accept).
const NO_QUEST_SECS := 60.0
# Rule 2: an active quest whose objectives haven't moved for this long -> restate the objective.
const OBJECTIVE_STALL_SECS := 90.0
# Rule 3: this many failed casts with auto-attack OFF and a live target -> the resource wall.
const FAILED_CAST_LIMIT := 2


# Rule 1 — the 60s "never found Drillmaster Hale" stall. quest_seen latches on the first non-empty
# objectives model this session, so acting (accepting anything) permanently disarms it.
static func find_giver_due(pre_grad: bool, quest_seen: bool, control_secs: float) -> bool:
	return pre_grad and not quest_seen and control_secs >= NO_QUEST_SECS


# Rule 2 — the 90s untouched-objective stall. untouched_secs is time since the tracker model last
# CHANGED (any credit/accept/turn-in resets it), so a player making progress is never nagged.
static func objective_restate_due(pre_grad: bool, has_active: bool, untouched_secs: float) -> bool:
	return pre_grad and has_active and untouched_secs >= OBJECTIVE_STALL_SECS


# Rule 3 — the #85 silent resource wall, belt-and-braces beside T-666's first-press route:
# auto-attack OFF + a live target + repeated failed casts reads as "combat is broken", so the
# resource hint is surfaced through the same fire-once path regardless of the rejection label.
static func resource_wall_hit(
	pre_grad: bool, autoattack_on: bool, target_id: int, failed_casts: int
) -> bool:
	return pre_grad and not autoattack_on and target_id != -1 and failed_casts >= FAILED_CAST_LIMIT


# Rule 2's toast copy: restate the FIRST tracked quest's next objective (the tracker model already
# holds only incomplete objectives — quest_log_panel.active_tracker_model). "" = nothing to say.
static func restate_text(tracker_model: Array) -> String:
	if tracker_model.is_empty():
		return ""
	var quest: Dictionary = tracker_model[0]
	var title := str(quest.get("title", ""))
	var objectives: Array = quest.get("objectives", [])
	if objectives.is_empty():
		return '"%s" is done — return to the quest giver to turn it in.' % title
	return 'Still on "%s" — %s.' % [title, str((objectives[0] as Dictionary).get("desc", ""))]
