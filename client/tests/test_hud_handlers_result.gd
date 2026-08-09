extends GutTest

# T-575: the "result" category handler in hud_handlers.gd was a literal no-op stub — a failed
# quest accept/turn_in/talk/abandon gave the player ZERO feedback (portal #33: a transient turn_in
# credit race that recovered on retry, but looked identical to "the game is broken" either way).
# This file owns that handler's own tests so test_client_net.gd (already at the gdlint
# max-public-methods cap) doesn't have to grow.
#
# T-578 (portal report #36): the tests below prove `build()`'s "result" closure works when driven
# through the REAL ClientNet dispatch + a REAL CombatFeedback/CombatLog (not the FakeCombat stub
# used elsewhere in this file) — i.e. the client_net.gd -> hud_handlers.gd -> combat_feedback.gd
# path itself is sound. It is NOT the whole live-client picture: main.gd's _setup_networking() used
# to overwrite this exact closure before it ever reached the real dispatch (fixed in the same T-578
# commit) — see test_result_handler_wiring.gd for the regression test on THAT wiring.

const ClientNet = preload("res://scripts/net/client_net.gd")
const HudHandlers = preload("res://scripts/net/hud_handlers.gd")
const CombatFeedback = preload("res://scripts/combat/combat_feedback.gd")


class _FakeCombat:
	extends RefCounted
	var failures: Array = []  # report_action_failure(msg) calls, recorded for assertions

	func report_action_failure(msg: String) -> void:
		failures.append(msg)

	func process_event(_d: Dictionary) -> void:
		pass


func _net(combat) -> ClientNet:
	var n = ClientNet.new()
	n.setup(func(_m): pass, HudHandlers.build(null, null, combat))
	return n


func test_surfaces_quest_action_failures() -> void:
	var combat = _FakeCombat.new()
	var n = _net(combat)

	n.handle_server_message(
		{
			"type": "turn_in_result",
			"quest_id": "q007",
			"ok": false,
			"reason": "objectives_incomplete"
		}
	)
	assert_eq(combat.failures.size(), 1, "a failed turn_in must produce one visible notice")
	assert_string_contains(combat.failures[0], "turn in", "names the failed action")
	assert_string_contains(
		combat.failures[0], "objectives aren't finished", "carries the server reason, humanized"
	)

	n.handle_server_message({"type": "accept_quest_result", "ok": false, "reason": "level_too_low"})
	n.handle_server_message({"type": "talk_result", "ok": false, "reason": "too_far"})
	n.handle_server_message({"type": "abandon_result", "ok": false, "reason": "not_active"})
	assert_eq(combat.failures.size(), 4, "each of accept/talk/abandon also surfaces on failure")


func test_stays_quiet_on_success() -> void:
	var combat = _FakeCombat.new()
	var n = _net(combat)

	for t in ["accept_quest_result", "turn_in_result", "talk_result", "abandon_result"]:
		n.handle_server_message({"type": t, "ok": true})
	assert_eq(combat.failures.size(), 0, "success must not spam a toast")


func test_stays_quiet_on_malformed_or_unrelated_result_types() -> void:
	var combat = _FakeCombat.new()
	var n = _net(combat)

	# No "ok" key at all on a quest-action type — must not crash or toast.
	n.handle_server_message({"type": "turn_in_result"})
	assert_eq(combat.failures.size(), 0, "missing ok must default to quiet, not a false failure")

	# Other "result"-category types (client_net.gd routes service_ack, spend_talent_result,
	# set_class_result, set_gender_result here too) are out of scope for this ticket and must be
	# left exactly as before — no toast, no crash. (mount_state is now handled — see T-669 tests.)
	n.handle_server_message({"type": "service_ack", "ok": false, "reason": "no_gold"})
	n.handle_server_message(
		{"type": "spend_talent_result", "ok": false, "reason": "unknown_talent"}
	)
	assert_eq(
		combat.failures.size(), 0, "non-quest-action result types are untouched by this ticket"
	)


# T-583 (report #39): use_item_result was never routed at all — using an item gave zero client
# feedback (not even on a rejected use, e.g. an empty slot or a non-usable item). It rides the same
# "result" category + failure-toast idiom as the quest-action family above.
func test_surfaces_use_item_failures() -> void:
	var combat = _FakeCombat.new()
	var n = _net(combat)

	n.handle_server_message(
		{"type": "use_item_result", "slot_index": 2, "ok": false, "reason": "empty_slot"}
	)
	assert_eq(combat.failures.size(), 1, "a rejected use_item must produce one visible notice")
	assert_string_contains(combat.failures[0], "use that item", "names the failed action")
	assert_string_contains(
		combat.failures[0], "nothing in that slot", "carries the server reason, humanized"
	)

	n.handle_server_message(
		{"type": "use_item_result", "slot_index": 0, "ok": false, "reason": "not_usable"}
	)
	assert_eq(combat.failures.size(), 2)


# A successful use is already visible through the separate T-570/T-583 inventory push (the item
# vanishing from the bag) plus any live effect (e.g. HP change) — no toast spam on top of that.
func test_stays_quiet_on_successful_use_item() -> void:
	var combat = _FakeCombat.new()
	var n = _net(combat)

	n.handle_server_message(
		{
			"type": "use_item_result",
			"slot_index": 0,
			"ok": true,
			"effect": {"kind": "heal", "amount": 40}
		}
	)
	assert_eq(combat.failures.size(), 0, "a successful use must not spam a toast")


func test_unknown_reason_falls_back_to_a_readable_code() -> void:
	var combat = _FakeCombat.new()
	var n = _net(combat)

	n.handle_server_message(
		{"type": "turn_in_result", "ok": false, "reason": "some_new_server_code"}
	)
	assert_eq(combat.failures.size(), 1)
	assert_string_contains(combat.failures[0], "some new server code")


# T-648 (W1b flag): instance_denied (level_too_low/too_far/requires_raid/wrong_threshold) reached
# the client already but was routed nowhere — an under-level player bouncing off the crypt gate
# got zero visible feedback, same silent-failure family as T-575/T-624. Unlike the quest/item
# family above it carries no "ok" field: receiving the message at all IS the denial.
func test_surfaces_instance_denied_reasons() -> void:
	var combat = _FakeCombat.new()
	var n = _net(combat)

	n.handle_server_message({"type": "instance_denied", "reason": "level_too_low"})
	assert_eq(combat.failures.size(), 1, "an instance_denied must produce one visible notice")
	assert_string_contains(combat.failures[0], "not a high enough level")

	n.handle_server_message({"type": "instance_denied", "reason": "too_far"})
	n.handle_server_message({"type": "instance_denied", "reason": "requires_raid"})
	n.handle_server_message({"type": "instance_denied", "reason": "wrong_threshold"})
	assert_eq(combat.failures.size(), 4, "all four instance-vocabulary reasons surface")
	assert_string_contains(combat.failures[1], "too far away")
	assert_string_contains(combat.failures[2], "requires a raid group")
	assert_string_contains(combat.failures[3], "level requirement")


func test_instance_denied_has_no_ok_field_and_still_reports() -> void:
	# Sanity: unlike the quest/item family, an absent "ok" key must NOT be read as success here —
	# the message existing at all is the failure (server never sends instance_denied on success).
	var combat = _FakeCombat.new()
	var n = _net(combat)
	n.handle_server_message({"type": "instance_denied", "reason": "too_far"})
	assert_eq(combat.failures.size(), 1)


func test_instance_denied_unknown_reason_falls_back_to_a_readable_code() -> void:
	var combat = _FakeCombat.new()
	var n = _net(combat)
	n.handle_server_message({"type": "instance_denied", "reason": "some_new_gate_code"})
	assert_eq(combat.failures.size(), 1)
	assert_string_contains(combat.failures[0], "some new gate code")


# T-662 (#69): rift_sealed (dead/not_eligible/not_in_ashmoor) reached the client already but was
# routed nowhere — the era-rift monolith rejection was completely silent, same silent-failure
# family as T-575/T-624/T-648. Like instance_denied it carries no "ok" field.
func test_surfaces_rift_sealed_reasons() -> void:
	var combat = _FakeCombat.new()
	var n = _net(combat)

	n.handle_server_message({"type": "rift_sealed", "reason": "not_eligible"})
	assert_eq(combat.failures.size(), 1, "a rift_sealed must produce one visible notice")
	assert_string_contains(combat.failures[0], "The rift is sealed")
	assert_string_contains(combat.failures[0], "haven't met the requirements")

	n.handle_server_message({"type": "rift_sealed", "reason": "dead"})
	n.handle_server_message({"type": "rift_sealed", "reason": "not_in_ashmoor"})
	assert_eq(combat.failures.size(), 3, "all three rift-vocabulary reasons surface")
	assert_string_contains(combat.failures[1], "can't cross while defeated")
	assert_string_contains(combat.failures[2], "not at the rift anchor")


func test_rift_sealed_has_no_ok_field_and_still_reports() -> void:
	var combat = _FakeCombat.new()
	var n = _net(combat)
	n.handle_server_message({"type": "rift_sealed", "reason": "not_eligible"})
	assert_eq(combat.failures.size(), 1)


func test_rift_sealed_unknown_reason_falls_back_to_a_readable_code() -> void:
	var combat = _FakeCombat.new()
	var n = _net(combat)
	n.handle_server_message({"type": "rift_sealed", "reason": "some_new_gate_code"})
	assert_eq(combat.failures.size(), 1)
	assert_string_contains(combat.failures[0], "some new gate code")


func test_real_dispatch_surfaces_rift_sealed() -> void:
	var combat := CombatFeedback.new()
	add_child_autofree(combat)  # runs _ready -> builds the real CombatLog
	var n = ClientNet.new()
	n.setup(func(_m): pass, HudHandlers.build(null, null, combat))

	n.handle_server_message({"type": "rift_sealed", "reason": "not_eligible"})
	assert_eq(combat.get_combat_log().get_count(), 1, "rift_sealed reaches the real CombatLog")
	assert_string_contains(combat.get_combat_log().get_lines()[0], "haven't met the requirements")


# T-578 lesson: drives the REAL sink (a live CombatFeedback -> CombatLog) through the REAL
# ClientNet dispatch, matching how a live server message actually reaches the handler in
# production — confirms the client_net.gd -> hud_handlers.gd -> combat_feedback.gd chain is sound
# end to end for this reply type too, not just through the FakeCombat stub above.
func test_real_dispatch_surfaces_instance_denied() -> void:
	var combat := CombatFeedback.new()
	add_child_autofree(combat)  # runs _ready -> builds the real CombatLog
	var n = ClientNet.new()
	n.setup(func(_m): pass, HudHandlers.build(null, null, combat))

	n.handle_server_message({"type": "instance_denied", "reason": "level_too_low"})
	assert_eq(combat.get_combat_log().get_count(), 1, "instance_denied reaches the real CombatLog")
	assert_string_contains(combat.get_combat_log().get_lines()[0], "not a high enough level")


func test_null_combat_feedback_does_not_crash() -> void:
	# HudHandlers.build() is called with a null combat_feedback in at least one existing site
	# (test_npc_markers.gd) — the result handler must not assume it's always wired.
	var n = _net(null)
	n.handle_server_message({"type": "turn_in_result", "ok": false, "reason": "not_active"})
	pass_test("a null combat_feedback must not crash the result handler")


# T-578 (portal report #36): drives the REAL sink (a live CombatFeedback -> CombatLog, not the
# FakeCombat stub above) through the REAL ClientNet dispatch, matching how a live server message
# actually reaches the handler in production. Confirms the client_net.gd/hud_handlers.gd/
# combat_feedback.gd chain itself is intact — the T-575 fix's own code is sound end to end.
func test_real_combat_feedback_and_dispatch_surface_the_toast() -> void:
	var combat := CombatFeedback.new()
	add_child_autofree(combat)  # runs _ready -> builds the real CombatLog
	var n = ClientNet.new()
	n.setup(func(_m): pass, HudHandlers.build(null, null, combat))

	n.handle_server_message(
		{"type": "turn_in_result", "quest_id": "q007", "ok": false, "reason": "unknown_quest"}
	)
	assert_eq(combat.get_combat_log().get_count(), 1, "a failed turn_in reaches the real CombatLog")
	assert_string_contains(combat.get_combat_log().get_lines()[0], "turn in")

	n.handle_server_message({"type": "accept_quest_result", "ok": false, "reason": "level_too_low"})
	n.handle_server_message({"type": "talk_result", "ok": false, "reason": "too_far"})
	assert_eq(
		combat.get_combat_log().get_count(),
		3,
		"accept + talk failures also land on the real CombatLog through real dispatch"
	)


# T-669 (#97): session-25 root-caused that a bare M-keypress mount rejection was completely
# silent — the server-side block worked (DB-verified) and the NPC-dialog/trainer path already
# surfaced a message, but client_net.gd routed "mount_state" into this "result" category
# (T-431/T-572, only to cache _mounted) and hud_handlers.gd's _report_result never recognized the
# type — action fell to "" and it bailed before ever reading ok/reason. Unlike instance_denied/
# rift_sealed, mount_state DOES carry "ok" (true on a successful toggle or forced dismount).
func test_surfaces_mount_state_rejection_reasons() -> void:
	var combat = _FakeCombat.new()
	var n = _net(combat)

	n.handle_server_message({"type": "mount_state", "ok": false, "reason": "mount_not_learned"})
	assert_eq(combat.failures.size(), 1, "a rejected mount toggle must produce one visible notice")
	assert_string_contains(combat.failures[0], "haven't learned to ride")
	assert_string_contains(combat.failures[0], "riding trainer")

	n.handle_server_message({"type": "mount_state", "ok": false, "reason": "in_combat"})
	assert_eq(combat.failures.size(), 2)
	assert_string_contains(combat.failures[1], "can't mount while in combat")


func test_stays_quiet_on_successful_mount_toggle_and_forced_dismount() -> void:
	var combat = _FakeCombat.new()
	var n = _net(combat)

	n.handle_server_message({"type": "mount_state", "ok": true, "mounted": true, "visual": "horse"})
	# T-572: a combat-start forced dismount still carries ok: true (see mount_service.gd's
	# dismount()) — it's an informational state push, not a rejection, so it must stay quiet too.
	n.handle_server_message(
		{
			"type": "mount_state",
			"ok": true,
			"mounted": false,
			"visual": "",
			"reason": "combat_start"
		}
	)
	assert_eq(combat.failures.size(), 0, "success and forced dismount must not spam a toast")


func test_mount_state_unknown_reason_falls_back_to_a_readable_code() -> void:
	var combat = _FakeCombat.new()
	var n = _net(combat)
	n.handle_server_message({"type": "mount_state", "ok": false, "reason": "some_new_mount_code"})
	assert_eq(combat.failures.size(), 1)
	assert_string_contains(combat.failures[0], "some new mount code")


# T-578 lesson: drives the REAL sink (a live CombatFeedback -> CombatLog) through the REAL
# ClientNet dispatch — the actual path a bare M keypress travels in production, not just the
# FakeCombat stub above.
func test_real_dispatch_surfaces_mount_not_learned() -> void:
	var combat := CombatFeedback.new()
	add_child_autofree(combat)  # runs _ready -> builds the real CombatLog
	var n = ClientNet.new()
	n.setup(func(_m): pass, HudHandlers.build(null, null, combat))

	n.handle_server_message({"type": "mount_state", "ok": false, "reason": "mount_not_learned"})
	assert_eq(
		combat.get_combat_log().get_count(), 1, "mount_state rejection reaches the real CombatLog"
	)
	assert_string_contains(combat.get_combat_log().get_lines()[0], "haven't learned to ride")
