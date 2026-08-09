extends GutTest
# T-186: the world telemetry buffer — enqueue/batch/flush and drop-on-overflow (never blocks).

const TelemetryQueue = preload("res://scripts/telemetry_queue.gd")


func test_enqueue_then_flush_returns_the_batch() -> void:
	var q = TelemetryQueue.new()
	q.enqueue("session_start", "acc", "hero", {"peer": 1})
	q.enqueue("death", "acc", "hero", {})
	assert_eq(q.pending_count(), 2)
	var batch: Array = q.flush()
	assert_eq(batch.size(), 2, "flush drains the whole batch")
	assert_eq(str(batch[0]["event_type"]), "session_start")
	assert_eq(batch[0]["payload"]["peer"], 1, "payload rides along")
	assert_eq(q.pending_count(), 0, "flush empties the buffer")


func test_flush_when_empty_is_an_empty_array() -> void:
	var q = TelemetryQueue.new()
	assert_eq(q.flush(), [], "nothing pending -> empty batch, no error")


func test_overflow_drops_without_blocking_and_counts() -> void:
	var q = TelemetryQueue.new()
	var cap: int = TelemetryQueue.MAX_PENDING
	for i in range(cap + 25):  # push past the cap
		q.enqueue("spam", "acc", "hero", {})
	assert_eq(q.pending_count(), cap, "buffer never grows past the hard cap")
	assert_eq(
		q.dropped_count(), 25, "the overflow was dropped and counted (telemetry never blocks)"
	)


func test_enqueue_returns_false_on_a_full_buffer() -> void:
	var q = TelemetryQueue.new()
	for i in range(TelemetryQueue.MAX_PENDING):
		assert_true(q.enqueue("e", null, null, {}), "accepted while there is room")
	assert_false(q.enqueue("e", null, null, {}), "rejected (dropped) once full")


func test_nullable_account_and_character() -> void:
	var q = TelemetryQueue.new()
	q.enqueue("server_tick", null, null, {"n": 3})
	var batch: Array = q.flush()
	assert_null(batch[0]["account"], "account may be null (account-level event)")
	assert_null(batch[0]["character"], "character may be null")
