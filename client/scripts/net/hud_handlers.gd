# T-048: the message→widget wiring for ClientNet — single source of truth so main.gd + tests don't
# drift. UI-aware (knows the HUD widgets); client_net.gd stays UI-agnostic (just routes). Slice A.
extends RefCounted

# T-575: quest_state_machine's stable rejection codes (server/master/scripts/quest_state_machine.gd)
# + the world's own proximity/lookup reasons, mapped to a player-facing clause. Unknown/blank
# reasons fall back to the raw code with underscores turned to spaces — never a hard failure.
const _REASONS := {
	"already_active": "you already have that quest",
	"already_complete": "you've already completed that quest",
	"log_full": "your quest log is full",  # T-621: the 21st accept is refused (cap = 20)
	"level_too_low": "you're not a high enough level yet",
	"prerequisite_incomplete": "you haven't finished the prerequisite quest",
	"not_active": "that quest isn't active",
	"objectives_incomplete": "the objectives aren't finished yet",
	"not_at_turnin_npc": "you're not at the turn-in spot",
	"unknown_quest": "that quest isn't recognized",
	"unknown_character": "your character couldn't be found",
	"unknown_npc": "that NPC isn't recognized",
	"too_far": "you're too far away",
	"bags_full": "your bags are full",
	"empty_slot": "there's nothing in that slot",
	"not_usable": "that item can't be used",
}

# T-575: the ONLY "result"-category types this handles — the quest-action family the stub's own
# comment named. service_ack/mount_state/spend_talent_result/etc share the "result" category too
# (see client_net.gd) but are left untouched here to avoid changing behavior nobody asked to change.
const _QUEST_ACTIONS := {
	"accept_quest_result": "accept the quest",
	"turn_in_result": "turn in the quest",
	"talk_result": "talk to them",
	"abandon_result": "abandon the quest",
}

# T-583 (report #39): use_item_result rides the same "result" category + failure-toast idiom as the
# quest-action family above (a silent "use" failure — empty slot, non-usable item — reads as "the
# game is broken" the same way a silent quest-action failure does). Success stays quiet here too: a
# successful use already shows through the separate T-570/T-583 inventory push (the item vanishing
# from the bag) plus any live HP change, so this only needs to catch the failure case.
const _ITEM_ACTIONS := {
	"use_item_result": "use that item",
}

# T-648 (W1b flag): instance_denied's own vocabulary (level_too_low/too_far already exist in
# _REASONS above and are reused as-is — the quest and instance systems happen to share those two
# codes verbatim). requires_raid/wrong_threshold are new to this reply type.
const _INSTANCE_REASONS := {
	"requires_raid": "that instance requires a raid group",
	"wrong_threshold": "your group doesn't meet the level requirement for that instance",
}

# T-719: which dungeon the churchyard stair just opened onto. The server sends the KIND, never the
# copy (the _INSTANCE_REASONS idiom) — this is where the player learns that the deep vault exists,
# what level it opens at, and therefore what to come back for. A kind with no line here says
# nothing, so the crypt/Vault/rift thresholds stay silent exactly as they are today.
const _INSTANCE_ENTERED := {
	"trial":
	(
		"The Shallow Graves — the upper galleries. The deep vault below is sealed to you "
		+ "until level 12; you'll want a group for it."
	),
}

# T-662 (#69): rift_sealed's own vocabulary (instance_service.gd's enter_era/leave_era). "dead" is
# shared with the instance family's own dead-while-crossing case (not in _REASONS/_INSTANCE_REASONS
# yet, so it's added here); not_eligible/not_in_ashmoor are new to this reply type.
const _RIFT_REASONS := {
	"dead": "you can't cross while defeated",
	"not_eligible": "you haven't met the requirements to cross",
	"not_in_ashmoor": "you're not at the rift anchor",
}

# T-669 (#97): mount_service.gd's own reject reasons (server/world/scripts/mount_service.gd
# handle()). mount_not_learned is the bare M-keypress case session-25 root-caused as silent —
# the NPC-dialog (riding trainer) path already surfaces a message, only the direct keypress didn't.
const _MOUNT_REASONS := {
	"mount_not_learned": "You haven't learned to ride yet — see a riding trainer.",
	"in_combat": "You can't mount while in combat.",
}


# Build the ClientNet handler map that feeds the HUD widgets. The router passes each whole server
# message dict to the matching category handler; these extract the payload + drive the widget.
static func build(quest_panel, inventory_panel, combat_feedback, npc_markers = null) -> Dictionary:
	return {
		"quest_log": func(d): _render_quests(quest_panel, d),
		"inventory": func(d): _render_inventory(inventory_panel, d),
		"npc_indicators": func(d): _update_markers(npc_markers, d),
		"result": func(d): _report_result(combat_feedback, d),
		"combat": func(d): combat_feedback.process_event(d),
		"loot_notice": func(d): _report_loot_notice(combat_feedback, d),
	}


# T-578 (portal report #36): main.gd owns a SECOND "result" handler (_on_result — quest-flow panel
# routing) and used to REPLACE this file's `build()`-produced "result" closure with it wholesale,
# which silently discarded the T-575 failure toast in the real client (its own tests only ever
# exercised `build()`'s output directly, never main.gd's wiring). A caller with its own handler for
# a category `build()` also populates must CHAIN the two, not overwrite — both run, in order.
static func chain(first: Callable, second: Callable) -> Callable:
	return func(d):
		first.call(d)
		second.call(d)


# T-575: a silent accept/turn_in/talk/abandon failure reads as "the game is broken" (portal #33 —
# a transient turn_in credit race that DID recover on retry, but gave zero feedback either way).
# Surfaces failures on the combat log (the HUD's existing transient-notice surface, T-402 idiom);
# stays quiet on success (avoid toast spam) and on anything malformed/not a quest action.
static func _report_result(combat_feedback, data: Dictionary) -> void:
	var reply_type := str(data.get("type", ""))
	if reply_type == "instance_denied":  # T-648: no "ok" field — receiving it IS the denial
		_report_instance_denied(combat_feedback, data)
		return
	if reply_type == "instance_entered":  # T-719: a positive notice, not a denial
		_report_instance_entered(combat_feedback, data)
		return
	if reply_type == "rift_sealed":  # T-662 (#69): same no-"ok" convention as instance_denied
		_report_rift_sealed(combat_feedback, data)
		return
	if reply_type == "mount_state":  # T-669 (#97): unlike instance_denied/rift_sealed this DOES
		# carry "ok" (true on a successful toggle/forced dismount) — gate on it inside the helper.
		_report_mount_state(combat_feedback, data)
		return
	var action: String = _QUEST_ACTIONS.get(reply_type, _ITEM_ACTIONS.get(reply_type, ""))
	if action == "" or combat_feedback == null:
		return
	if bool(data.get("ok", true)):
		return
	var reason := str(data.get("reason", ""))
	var clause: String = _REASONS.get(reason, reason.replace("_", " "))
	var msg := "Couldn't %s — try again." % action
	if clause != "":
		msg = "Couldn't %s — %s." % [action, clause]
	combat_feedback.report_action_failure(msg)


# T-648 (W1b flag): an under-level/too-far/wrong-group player bouncing off an instance gate (the
# crypt threshold) got a server-side rejection with zero visible feedback — same silent-failure
# family as T-575/T-624. Unlike the quest/item family above, instance_denied carries no "ok" —
# the message existing at all is the failure, so this always reports (no ok-gate to check).
static func _report_instance_denied(combat_feedback, data: Dictionary) -> void:
	if combat_feedback == null:
		return
	var reason := str(data.get("reason", ""))
	var clause: String = _REASONS.get(
		reason, _INSTANCE_REASONS.get(reason, reason.replace("_", " "))
	)
	var msg := "Can't enter — try again."
	if clause != "":
		msg = "Can't enter — %s." % clause
	combat_feedback.report_action_failure(msg)


# T-719: the ONLY member of this family that is not a failure. The tutorial capstone routes an
# under-level party into the Shallow Graves rather than bouncing it off the L12 gate, so the player
# must be told which dungeon they entered and what the door below opens at — otherwise "one stair,
# two dungeons" reads as the game silently deciding something. Rides report_system_message (the
# neutral notice surface), never report_action_failure: nothing failed here.
static func _report_instance_entered(combat_feedback, data: Dictionary) -> void:
	if combat_feedback == null:
		return
	var line: String = _INSTANCE_ENTERED.get(str(data.get("kind", "")), "")
	if line != "":
		combat_feedback.report_system_message(line)


# T-662 (#69): the era-rift monolith rejection (enter_era/leave_era's rift_sealed reply) was
# completely silent client-side — same silent-failure family as T-575/T-624/T-648, mirroring the
# instance_denied fix exactly. No "ok" field: receiving rift_sealed at all is the denial.
static func _report_rift_sealed(combat_feedback, data: Dictionary) -> void:
	if combat_feedback == null:
		return
	var reason := str(data.get("reason", ""))
	var clause: String = _RIFT_REASONS.get(reason, reason.replace("_", " "))
	var msg := "The rift is sealed — try again."
	if clause != "":
		msg = "The rift is sealed — %s." % clause
	combat_feedback.report_action_failure(msg)


# T-669 (#97): the bare M-keypress mount rejection was completely silent. client_net.gd already
# routed "mount_state" into this "result" category (T-431/T-572, for the _mounted cache), but
# _report_result only recognized the _QUEST_ACTIONS/_ITEM_ACTIONS families — an unmatched type
# fell to action == "" and bailed BEFORE ever looking at ok/reason. mount_state carries its own
# "ok" (true on a successful toggle or a forced combat-start dismount), so this mirrors the
# quest/item ok-gate above, just with mount_service.gd's own reason vocabulary.
static func _report_mount_state(combat_feedback, data: Dictionary) -> void:
	if combat_feedback == null or bool(data.get("ok", true)):
		return
	var reason := str(data.get("reason", ""))
	var msg: String = _MOUNT_REASONS.get(reason, "Couldn't mount — %s." % reason.replace("_", " "))
	combat_feedback.report_action_failure(msg)


# T-649 (portal #89): kill loot that couldn't fit any bag in range is HELD server-side for retry,
# never destroyed — but that must be VISIBLE (the T-575 rule this whole category exists to enforce),
# so "bags full, item lost" doesn't read as a silent failure. Item names resolve client-side via the
# same ItemNaming humanizer the vendor/bank lists already use (T-571) — the server sends only ids.
static func _report_loot_notice(combat_feedback, data: Dictionary) -> void:
	if combat_feedback == null or str(data.get("reason", "")) != "bag_full_held":
		return
	var names: Array = []
	for row: Dictionary in data.get("items", []):
		names.append(ItemNaming.humanize_item_id(str(row.get("item_id", "")), "an item"))
	if names.is_empty():
		return
	combat_feedback.report_action_failure(
		"Bags full — %s held, will grant when there's room." % ", ".join(names)
	)


static func _update_markers(layer, data: Dictionary) -> void:
	if layer != null:
		layer.update(data.get("npcs", []))


static func _render_quests(panel, data: Dictionary) -> void:
	panel.render(data.get("result", {}).get("quests", []))


static func _render_inventory(panel, data: Dictionary) -> void:
	# inventory + equip/unequip/drop replies carry the post-op slots; a failed op may omit them.
	if data.has("slots"):
		panel.render(data["slots"])
