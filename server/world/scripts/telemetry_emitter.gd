class_name TelemetryEmitter
extends Node
# T-186: the world's telemetry pump. Owns a TelemetryQueue and a flush Timer; every
# FLUSH_INTERVAL it ships the batch to the master fire-and-forget (record_events RPC) via an
# injected callable — the send is never awaited, so a slow/unreachable master can't stall the
# world. main.gd only calls record(...); all the buffering/timer lives here to keep main lean.

const _Q = preload("res://scripts/telemetry_queue.gd")
const FLUSH_INTERVAL_S := 5.0

var _queue = _Q.new()
var _flush_cb: Callable = Callable()  # main._master.call_master (method, params) -> reply (ignored)
var _timer: Timer = null
var _once: Dictionary = {}  # T-705: peer_id -> {event_type: true} for the once-per-session signals


func _ready() -> void:
	_timer = Timer.new()
	_timer.wait_time = FLUSH_INTERVAL_S
	_timer.one_shot = false
	_timer.timeout.connect(_on_flush)
	add_child(_timer)
	_timer.start()


# main injects the master transport (call_master). Without it, events still buffer (and drop
# past the cap) — they just never ship, which is the correct degraded behavior.
func set_flush_callable(cb: Callable) -> void:
	_flush_cb = cb


# The single instrumentation entrypoint. account/character may be null for account-level events.
func record(event_type: String, account, character, payload: Dictionary = {}) -> void:
	_queue.enqueue(event_type, account, character, payload)


# T-705: the funnel only ever reads the FIRST of each event per session, so the high-frequency
# signals (loot / equip / quest_accept) ship ONE event per session instead of one per action — the
# append-only log stays small and the rollup is byte-identical. Keyed by PEER, so a reconnect or a
# second character re-arms every marker; forget_peer() below drops the key with the session.
# `key` defaults to the event type; pass a narrower one (e.g. "intent_rejected:too_far") when the
# same event type should be allowed once per VARIANT rather than once per session.
func record_once(
	peer_id: int, event_type: String, account, character, payload: Dictionary = {}, key := ""
) -> void:
	var once_key := event_type if key == "" else key
	var seen: Dictionary = _once.get(peer_id, {})
	if seen.has(once_key):
		return
	seen[once_key] = true
	_once[peer_id] = seen
	record(event_type, account, character, payload)


# Called from main's per-peer teardown so the once-per-session markers die with the session.
func forget_peer(peer_id: int) -> void:
	_once.erase(peer_id)


func _on_flush() -> void:
	if _queue.pending_count() == 0 or not _flush_cb.is_valid():
		return
	var batch := _queue.flush()
	# Fire-and-forget: call the async RPC WITHOUT awaiting so the flush never blocks the world.
	_flush_cb.call("record_events", {"events": batch})


func queue() -> Object:  # test accessor
	return _queue
