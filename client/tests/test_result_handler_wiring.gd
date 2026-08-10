extends GutTest

# T-578 (portal report #36): a play-agent found quest/talk failures SILENT again in the live
# build, right after T-575 shipped a fix + green tests for exactly that. T-575's own tests
# (test_hud_handlers_result.gd) drive HudHandlers.build()'s "result" closure directly and stay
# green — that code is fine in isolation. The real bug was one layer up: main.gd's
# _setup_networking() built the handler map via HudHandlers.build() (which sets
# handlers["result"] to T-575's failure-toast closure) and then OVERWROTE that same key with its
# own `_on_result` (quest-flow panel routing, pre-existing since T-056/T-519) instead of running
# both. The toast closure was built, then discarded, every single time — T-575's fix never ran in
# the shipped client. This is the "unit-passed / live-failed" gap: nothing in T-575's tests ever
# touched main.gd's wiring, so the regression shipped clean.
#
# The fix (same T-578 commit) extracts main.gd's composition into `_wire_result_handler()`, which
# now chains the two handlers via HudHandlers.chain() instead of overwriting, and is called from
# _setup_networking(). This test calls THAT SAME METHOD on a real MainScene instance — not a
# hand-rolled reimplementation of what the wiring "should" do — so a future regression (e.g.
# someone reverting the chain back to an overwrite) fails this test even though it never opens a
# live connection.

const MainScene = preload("res://scripts/main.gd")
const HudHandlers = preload("res://scripts/net/hud_handlers.gd")
const CombatFeedback = preload("res://scripts/combat/combat_feedback.gd")
const ClientNet = preload("res://scripts/net/client_net.gd")
const HarnessProbe = preload("res://scripts/net/harness_probe.gd")

var _m = null


func before_each() -> void:
	_m = MainScene.new()
	_m._smoke = false
	# _on_result() calls _refresh_timer.start() unconditionally on every quest-action result, and
	# Timer.start() requires being inside the scene tree — the real Timer is only built (and added)
	# in _setup_networking() (which also opens a live ENet connection, far too heavy for a unit
	# test), so a tree-attached stand-in is enough to prove _on_result runs without crashing.
	_m._refresh_timer = add_child_autofree(Timer.new())


func after_each() -> void:
	if _m != null:
		_m.free()
		_m = null


func test_failed_turn_in_toasts_through_the_real_main_wiring() -> void:
	var combat := CombatFeedback.new()
	add_child_autofree(combat)  # runs _ready -> builds the real CombatLog
	var quest_action_toast: Callable = HudHandlers.build(null, null, combat)["result"]
	var handler: Callable = _m._wire_result_handler(quest_action_toast)  # the REAL production method

	handler.call(
		{"type": "turn_in_result", "quest_id": "q007", "ok": false, "reason": "unknown_quest"}
	)

	assert_eq(
		combat.get_combat_log().get_count(),
		1,
		"T-578: main.gd's real _wire_result_handler must still surface the T-575 toast"
	)
	assert_string_contains(combat.get_combat_log().get_lines()[0], "turn in")


func test_failed_accept_and_abandon_also_toast_through_the_real_wiring() -> void:
	var combat := CombatFeedback.new()
	add_child_autofree(combat)
	var quest_action_toast: Callable = HudHandlers.build(null, null, combat)["result"]
	var handler: Callable = _m._wire_result_handler(quest_action_toast)

	handler.call({"type": "accept_quest_result", "ok": false, "reason": "level_too_low"})
	handler.call({"type": "abandon_result", "ok": false, "reason": "not_active"})

	assert_eq(combat.get_combat_log().get_count(), 2)


func test_successful_results_stay_quiet_but_still_drive_on_result() -> void:
	# Non-regression: chaining must not break _on_result's own behavior (the debounced refresh) or
	# spam a toast on success.
	var combat := CombatFeedback.new()
	add_child_autofree(combat)
	var quest_action_toast: Callable = HudHandlers.build(null, null, combat)["result"]
	var handler: Callable = _m._wire_result_handler(quest_action_toast)

	handler.call({"type": "turn_in_result", "ok": true})

	assert_eq(combat.get_combat_log().get_count(), 0, "success stays quiet")
	assert_true(_m._refresh_timer.time_left > 0.0, "_on_result's debounced refresh still ran")


func test_smoke_mode_also_chains_the_toast() -> void:
	# The smoke branch's fallback is HarnessProbe.on_accept, not _on_result — it calls
	# main._net.request_npc_indicators(), so give it a real (no-op send) ClientNet to run against.
	_m._smoke = true
	_m._net = ClientNet.new()
	_m._net.setup(func(_msg): pass, {})
	var combat := CombatFeedback.new()
	add_child_autofree(combat)
	var quest_action_toast: Callable = HudHandlers.build(null, null, combat)["result"]
	var handler: Callable = _m._wire_result_handler(quest_action_toast)

	handler.call({"type": "turn_in_result", "ok": false, "reason": "not_at_turnin_npc"})

	assert_eq(combat.get_combat_log().get_count(), 1, "the toast must fire in smoke mode too")

	# T-756: the second assertion here was `assert_false(_m._accept_ok, "on_accept still ran")`.
	# _accept_ok is already false on a fresh MainScene, and on_accept early-returns on any type
	# that isn't accept_quest_result — so asserting it was STILL false proved nothing about the
	# probe having run. Unwiring HarnessProbe completely left it green. Send the reply on_accept
	# actually grades, and assert its positive effects.
	handler.call({"type": "accept_quest_result", "ok": true})
	assert_true(_m._accept_ok, "HarnessProbe.on_accept graded the accept reply alongside the toast")
	assert_true(_m._awaiting_indicators, "and chained on into the NPC-indicator request")


# talk_result is deliberately NOT driven through _wire_result_handler here: on ok==false,
# _on_result() reaches ($HUD.get_node("QuestOfferPanel") as QuestOfferPanel) — real off-tree scene
# nodes main.tscn provides, not present on a bare MainScene.new(). It IS covered end to end (real
# ClientNet dispatch + real CombatFeedback) in test_hud_handlers_result.gd, which never touches
# main.gd's own QuestOfferPanel lookup.
func test_unknown_reason_falls_back_to_a_readable_code_through_the_real_wiring() -> void:
	var combat := CombatFeedback.new()
	add_child_autofree(combat)
	var quest_action_toast: Callable = HudHandlers.build(null, null, combat)["result"]
	var handler: Callable = _m._wire_result_handler(quest_action_toast)

	handler.call({"type": "turn_in_result", "ok": false, "reason": "gizmo_offline"})

	assert_eq(combat.get_combat_log().get_count(), 1)
	assert_string_contains(combat.get_combat_log().get_lines()[0], "gizmo offline")
