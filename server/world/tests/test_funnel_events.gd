extends GutTest
# T-705: the world side of the first-session funnel — the emitter's once-per-session de-dupe and
# the funnel_events vocabulary (which beat, which failure reason, and the clamp on the one payload
# that originates on the client). Nothing here may await or touch gameplay state.

const FunnelEvents = preload("res://scripts/funnel_events.gd")
const TelemetryEmitter = preload("res://scripts/telemetry_emitter.gd")

var _sent: Array = []
var _funnel = null


func before_each() -> void:
	_sent = []
	_funnel = FunnelEvents.new()
	# Mirrors main._tel(event_type, peer_id, payload, once_key) without the session plumbing.
	_funnel.setup(
		func(event_type: String, pid: int, payload: Dictionary, once_key: String) -> void:
			_sent.append({"type": event_type, "pid": pid, "payload": payload, "once_key": once_key})
	)


func _types() -> Array:
	return _sent.map(func(e): return str(e["type"]))


# ---- the funnel beats ---------------------------------------------------------


func test_the_reward_beats_emit_with_their_identifiers() -> void:
	_funnel.quest_accept(7, "q_tut_01")
	_funnel.quest_turn_in(7, "q_tut_01")
	_funnel.loot(7, [{"item_id": "itm_pelt"}, {"item_id": "itm_fang"}])
	assert_eq(_types(), ["quest_accept", "quest_turn_in", "loot"])
	assert_eq(str(_sent[0]["payload"]["quest_id"]), "q_tut_01", "which quest they took")
	assert_eq(int(_sent[2]["payload"]["items"]), 2, "how many items dropped, not what they were")


func test_every_beat_is_recorded_once_per_session() -> void:
	# The funnel reads only the FIRST of each per session, so a player looting 200 wolves must add
	# one row, not two hundred — the once_key is what tells the emitter that.
	_funnel.quest_accept(1, "q001")
	_funnel.loot(1, [])
	_funnel.quest_turn_in(1, "q001")
	_funnel.inventory(1, "equip", {"ok": true})
	_funnel.boot_timing(1, {})
	assert_eq(_sent.size(), 5, "each beat emitted once")
	for entry in _sent:
		assert_eq(
			str(entry["once_key"]),
			str(entry["type"]),
			"%s is deduped per session" % str(entry["type"]),
		)


func test_an_equip_reply_emits_the_beat_and_a_failed_one_emits_the_reason() -> void:
	_funnel.inventory(3, "equip", {"ok": true})
	assert_eq(_types(), ["equip"], "a successful equip is the first_equip beat")
	_sent.clear()
	_funnel.inventory(3, "equip", {"ok": false, "reason": "bag_full"})
	assert_eq(_types(), ["intent_rejected"])
	assert_eq(str(_sent[0]["payload"]["reason"]), "bag_full")
	assert_eq(str(_sent[0]["payload"]["intent"]), "equip", "what they were trying to do")


func test_a_successful_non_equip_bag_op_is_not_a_funnel_beat() -> void:
	_funnel.inventory(3, "drop", {"ok": true})
	_funnel.inventory(3, "get_inventory", {"ok": true})
	assert_eq(_sent.size(), 0, "only equipping is a first-session beat")


# ---- the failure reasons ------------------------------------------------------


func test_rejections_carry_the_reason_and_dedupe_per_reason_not_per_session() -> void:
	_funnel.rejected(4, "use_ability", "insufficient_resource")
	_funnel.rejected(4, "turn_in", "too_far")
	assert_eq(_types(), ["intent_rejected", "intent_rejected"])
	assert_eq(
		str(_sent[0]["once_key"]),
		"reject:insufficient_resource",
		"a second reason is still recorded — only the same reason repeating is suppressed",
	)
	assert_eq(str(_sent[1]["once_key"]), "reject:too_far")


func test_an_empty_reason_emits_nothing() -> void:
	_funnel.rejected(4, "turn_in", "")
	assert_eq(_sent.size(), 0, "a blank reason would be an unreadable funnel row")


func test_a_service_ack_only_reports_refusals() -> void:
	_funnel.service(5, "trainer:starter", "train", {"ok": true})
	assert_eq(_sent.size(), 0, "a successful purchase is not a failure signal")
	_funnel.service(5, "trainer:starter", "train", {"ok": false, "reason": "insufficient_coins"})
	assert_eq(str(_sent[0]["payload"]["reason"]), "insufficient_coins")
	assert_eq(
		str(_sent[0]["payload"]["intent"]),
		"trainer:starter:train",
		"the intent names the service AND the action, so the reason is actionable",
	)


# ---- the one client-originated payload ----------------------------------------


func test_client_boot_timing_is_clamped_server_side() -> void:
	_funnel.boot_timing(9, {"launch_to_login_ms": 12000, "login_to_interactive_ms": 29000})
	assert_eq(int(_sent[0]["payload"]["launch_to_login_ms"]), 12000)
	assert_eq(int(_sent[0]["payload"]["login_to_interactive_ms"]), 29000)
	_sent.clear()
	# A forged report can only ever be a number in range — and it grants nothing either way.
	_funnel.boot_timing(9, {"launch_to_login_ms": -50000, "login_to_interactive_ms": 999999999})
	assert_eq(int(_sent[0]["payload"]["launch_to_login_ms"]), 0, "negatives clamp to zero")
	assert_eq(
		int(_sent[0]["payload"]["login_to_interactive_ms"]),
		FunnelEvents.BOOT_MS_MAX,
		"an absurd phase clamps to the hour cap instead of poisoning the median",
	)


func test_a_missing_boot_field_reads_as_zero_not_as_garbage() -> void:
	_funnel.boot_timing(9, {})
	assert_eq(int(_sent[0]["payload"]["launch_to_login_ms"]), 0)
	assert_eq(int(_sent[0]["payload"]["login_to_interactive_ms"]), 0)


func test_without_a_telemetry_pump_every_call_is_a_silent_no_op() -> void:
	# Measurement must never be load-bearing: an unwired funnel degrades to silence, not an error.
	var bare = FunnelEvents.new()
	bare.quest_accept(1, "q001")
	bare.rejected(1, "turn_in", "too_far")
	bare.boot_timing(1, {"launch_to_login_ms": 1})
	assert_eq(_sent.size(), 0, "nothing emitted and nothing raised")


# ---- the emitter's once-per-session de-dupe ------------------------------------


func _emitter() -> TelemetryEmitter:
	var e := TelemetryEmitter.new()
	add_child_autofree(e)
	return e


func test_record_once_ships_one_event_per_peer_per_key() -> void:
	var e := _emitter()
	for i in range(5):
		e.record_once(11, "loot", "acct", "hero", {"items": 1})
	assert_eq(e.queue().pending_count(), 1, "200 wolves cost one telemetry row")
	e.record_once(12, "loot", "acct2", "hero2", {})
	assert_eq(e.queue().pending_count(), 2, "a DIFFERENT peer re-arms the marker")


func test_record_once_narrows_on_the_key_when_one_is_given() -> void:
	var e := _emitter()
	e.record_once(11, "intent_rejected", "a", "h", {}, "reject:too_far")
	e.record_once(11, "intent_rejected", "a", "h", {}, "reject:too_far")
	e.record_once(11, "intent_rejected", "a", "h", {}, "reject:bag_full")
	assert_eq(e.queue().pending_count(), 2, "once per REASON, not once per event type")


func test_forget_peer_re_arms_the_markers_for_the_next_session() -> void:
	var e := _emitter()
	e.record_once(11, "equip", "acct", "hero", {})
	e.forget_peer(11)
	e.record_once(11, "equip", "acct", "hero", {})
	assert_eq(e.queue().pending_count(), 2, "a relog is a NEW first session for the funnel")


func test_plain_record_is_unaffected_by_the_once_markers() -> void:
	var e := _emitter()
	e.record_once(11, "kill", "acct", "hero", {})
	e.record("kill", "acct", "hero", {})
	e.record("kill", "acct", "hero", {})
	assert_eq(e.queue().pending_count(), 3, "the per-kill stream still records every kill")
