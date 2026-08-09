class_name TelemetryQueue
extends RefCounted
# T-186: the world's fire-and-forget event buffer. enqueue() is O(1) and never blocks — if the
# buffer is full (master slow/unreachable) it DROPS the event and bumps a counter rather than
# growing unbounded or costing a frame. flush() drains the batch for the periodic master ship.
# Pure (no scene tree / no network), so overflow + batching unit-test directly.

const MAX_PENDING := 512  # hard cap: telemetry must never cost the frame or leak memory

var _pending: Array = []
var _dropped: int = 0


# Append one event. Returns false (and counts a drop) when the buffer is full — the caller
# never waits and never errors; losing telemetry under load is correct, blocking gameplay isn't.
func enqueue(event_type: String, account, character, payload: Dictionary = {}) -> bool:
	if _pending.size() >= MAX_PENDING:
		_dropped += 1
		return false
	(
		_pending
		. append(
			{
				"event_type": event_type,
				"account": account,
				"character": character,
				"payload": payload,
			}
		)
	)
	return true


# Drain the buffer and return the batch (empty Array when nothing is pending).
func flush() -> Array:
	var batch := _pending
	_pending = []
	return batch


func pending_count() -> int:
	return _pending.size()


func dropped_count() -> int:
	return _dropped
