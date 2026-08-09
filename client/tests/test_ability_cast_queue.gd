extends GutTest

# T-721: the client-side ability press queue — the fix for the 5-of-22 execution gap (the T-057
# autoattack timer holds the GCD ~94% of the time, so manual presses were refused on_gcd).
# Covers: the whole-session ledger, the PURE retry policy (retry_wait_s), pending-press
# lifecycle on server verdicts, and the live re-send through a real (stubbed) Main parent.

const QueueScript = preload("res://scripts/combat/ability_cast_queue.gd")


class NetSpy:
	extends RefCounted
	var used: Array = []

	func request_use_ability(ability_id: int, target_id: int) -> void:
		used.append([ability_id, target_id])


class MainStub:
	extends Node
	var _my_peer_id: int = 7
	var _net = NetSpy.new()


func _pending(abil: int, retries: int) -> Dictionary:
	return {"ability_id": abil, "target_id": 1051, "retries_left": retries}


func _reject(abil: int, reason: String, detail: Dictionary = {}) -> Dictionary:
	return {"type": "ability_rejected", "ability_id": abil, "reason": reason, "detail": detail}


# ---- ledger -------------------------------------------------------------------------------------


func test_ledger_counts_sends_blocks_and_verdicts() -> void:
	var q = QueueScript.new()
	autofree(q)
	q.note_manual_send(0, 101, 1051)
	q.note_blocked(2, "no_target")
	q.on_combat_event(_reject(101, "on_gcd", {"gcd_ready_in_ticks": 12}))
	q.on_combat_event({"type": "cast_started", "ability_id": 204})
	var counts: Dictionary = q.summary()["counts"]
	assert_eq(int(counts.get("send:101", 0)), 1, "manual send counted")
	assert_eq(int(counts.get("blocked:no_target:-1", 0)), 1, "blocked press counted with reason")
	assert_eq(int(counts.get("rejected:on_gcd:101", 0)), 1, "rejection counted with reason")
	assert_eq(int(counts.get("cast_started:204", 0)), 1, "cast start counted")


func test_ledger_ignores_other_casters_results() -> void:
	var stub = MainStub.new()
	add_child_autofree(stub)
	var q = QueueScript.new()
	stub.add_child(q)
	q.on_combat_event({"type": "ability_result", "caster_id": 99, "ability_id": 1})
	q.on_combat_event({"type": "ability_result", "caster_id": 7, "ability_id": 1})
	var counts: Dictionary = q.summary()["counts"]
	assert_eq(int(counts.get("result:1", 0)), 1, "only OUR results are counted")


# ---- retry policy (pure) ------------------------------------------------------------------------


func test_retry_wait_uses_server_gcd_ready_ticks() -> void:
	var wait: float = QueueScript.retry_wait_s(
		_pending(101, 3), _reject(101, "on_gcd", {"gcd_ready_in_ticks": 12})
	)
	assert_almost_eq(wait, 12 * 0.05 + 0.05, 0.001, "12 ticks @20Hz + margin")


func test_retry_wait_defaults_when_detail_missing() -> void:
	var wait: float = QueueScript.retry_wait_s(_pending(101, 3), _reject(101, "on_gcd"))
	assert_almost_eq(wait, 2 * 0.05 + 0.05, 0.001, "conservative 2-tick default")


func test_no_retry_for_other_ability_or_reason_or_exhausted() -> void:
	var gcd_kick := _reject(1, "on_gcd", {"gcd_ready_in_ticks": 5})
	assert_lt(
		QueueScript.retry_wait_s(_pending(101, 3), gcd_kick), 0.0, "autoattack strike ignored"
	)
	assert_lt(
		QueueScript.retry_wait_s(_pending(101, 3), _reject(101, "insufficient_resource")),
		0.0,
		"only on_gcd retries"
	)
	assert_lt(
		QueueScript.retry_wait_s(_pending(101, 0), _reject(101, "on_gcd")), 0.0, "cap exhausted"
	)
	assert_lt(QueueScript.retry_wait_s({}, _reject(101, "on_gcd")), 0.0, "nothing pending")


# ---- pending lifecycle --------------------------------------------------------------------------


func test_pending_cleared_by_result_and_by_non_retryable_reject() -> void:
	var q = QueueScript.new()
	autofree(q)
	q.note_manual_send(0, 101, 1051)
	q.on_combat_event(_reject(101, "insufficient_resource"))
	assert_true(q._pending.is_empty(), "non-retryable refusal drops the press")
	q.note_manual_send(0, 101, 1051)
	var stub = MainStub.new()
	add_child_autofree(stub)
	stub.add_child(q)  # parent so caster_id resolution sees _my_peer_id
	q.on_combat_event({"type": "ability_result", "caster_id": 7, "ability_id": 101})
	assert_true(q._pending.is_empty(), "a landed result drops the press")


func test_on_gcd_reject_of_autoattack_strike_keeps_pending() -> void:
	var q = QueueScript.new()
	autofree(q)
	q.note_manual_send(0, 101, 1051)
	q.on_combat_event(_reject(1, "on_gcd"))  # the autoattack timer's Strike, not our press
	assert_eq(int(q._pending.get("ability_id", -1)), 101, "our press stays queued")


# ---- live re-send through a stub Main -----------------------------------------------------------


func test_on_gcd_refusal_resends_when_gcd_frees() -> void:
	var stub = MainStub.new()
	add_child_autofree(stub)
	var q = QueueScript.new()
	stub.add_child(q)
	q.note_manual_send(0, 101, 1051)
	q.on_combat_event(_reject(101, "on_gcd", {"gcd_ready_in_ticks": 1}))
	await wait_seconds(0.4)
	assert_eq(stub._net.used, [[101, 1051]], "press re-sent once the server's GCD window frees")
	var counts: Dictionary = q.summary()["counts"]
	assert_eq(int(counts.get("retry:101", 0)), 1, "retry recorded in the ledger")
