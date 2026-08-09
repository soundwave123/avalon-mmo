extends Node
# T-734: the SERVER-authoritative world day clock. Before this, every client free-ran its own
# day_t from join time, so two players in the same field disagreed about whether it was night.
# The world now owns ONE clock: day_t in 0..1 (T-415 convention: 0 = sunrise east, 0.25 = noon
# south, 0.5 = sunset west, 0.75 = midnight) advancing at the SAME rate the client renders.
# DAY_SECONDS mirrors client world_view.gd — mirror if the day length ever changes (the
# broadcast_builder REGION_ANCHORS idiom: a tiny cross-project const beats a new content seam).
#
# SYNC DESIGN: a joining client gets day_t inside handshake_ok (main.gd) and snaps once; from
# then on it free-runs at the shared rate and this node pushes a low-frequency "world_clock"
# resync every RESYNC_SEC, which the client slews toward gently (world_view.server_day_sync) —
# never a visible sun-snap. A dedicated low-rate message is deliberately chosen over a per-tick
# positions field: top-level positions fields are NOT delta-compressed (T-699 deltas cover only
# player/mob rows), so a per-tick day_t would re-serialize at 10 Hz forever (~measured in the
# T-734 ticket) while this push costs ~3 B/s/peer and touches no broadcast code.
#
# PERSISTENCE: the master is the persistent side by construction (it owns Postgres; the world is
# stateless on disk), so day_t checkpoints through master_client to the world.state KV
# (world_state_op, migration 056) every SAVE_SEC and on shutdown, fire-and-forget. Boot reads it
# back (retrying while the master WS is still connecting) so a restart RESUMES the shared time of
# day. A missing row / dead master falls back to DEFAULT_DAY_T — the same afternoon the old
# client free-run started at, so a cold seam regresses nothing.
#
# DEV OVERRIDE PRECEDENCE: AVALON_FREEZE_DAY stays a pure CLIENT pin (QA pilots/screenshots): a
# frozen client ignores every sync push; this server clock keeps running for everyone else.

const PlayerSessions = preload("res://scripts/player_sessions.gd")

const DAY_SECONDS := 1200.0  # mirrors client world_view.gd DAY_SECONDS (T-137: one in-game day)
const DEFAULT_DAY_T := 0.34  # mirrors world_view.gd's boot default (T-289 afternoon mood)
const RESYNC_SEC := 15.0  # client drift over 15 s is frame-jitter-sized at the shared rate
const SAVE_SEC := 5.0  # checkpoint staleness bounds the backward time-jump after a hard kill
const LOAD_RETRY_SEC := 1.0  # boot-read poll while the master WS is still connecting
const LOAD_MAX_ATTEMPTS := 30  # ~30 s of retries, then run from the default (fail-open)

var _day_t := DEFAULT_DAY_T
var _master = null  # MasterClient (call_master seam); untyped so tests inject a fake
var _send_to_peer: Callable = Callable()
var _resync_acc := 0.0
var _save_acc := 0.0
var _load_retry_acc := LOAD_RETRY_SEC  # first attempt fires on the first frame after boot
var _load_attempts := 0
var _loaded := false  # true once the boot read resolved (row adopted, no row, or gave up)
var _load_in_flight := false


func setup(master, send_to_peer: Callable) -> void:
	_master = master
	_send_to_peer = send_to_peer


func day_t() -> float:
	return _day_t


func _process(delta: float) -> void:
	_day_t = advance(_day_t, delta)
	if not _loaded:
		_try_load(delta)
	_resync_acc += delta
	if _resync_acc >= RESYNC_SEC:
		_resync_acc = 0.0
		_broadcast_resync()
	_save_acc += delta
	if _save_acc >= SAVE_SEC:
		_save_acc = 0.0
		_save()


# PURE (unit-tested): one clock step — the exact fmod walk the client renders with (T-137).
static func advance(day_t: float, delta: float, day_seconds: float = DAY_SECONDS) -> float:
	return fposmod(day_t + delta / day_seconds, 1.0)


# PURE: the resync push. One tiny reliable dict; the client slews, never snaps, on receipt.
static func resync_payload(day_t: float) -> Dictionary:
	return {"type": "world_clock", "day_t": day_t}


func _broadcast_resync() -> void:
	if not _send_to_peer.is_valid():
		return
	var payload := resync_payload(_day_t)
	for peer_id in PlayerSessions.list_players():
		_send_to_peer.call(peer_id, payload)


func _try_load(delta: float) -> void:
	_load_retry_acc += delta
	if _load_in_flight or _load_retry_acc < LOAD_RETRY_SEC:
		return
	_load_retry_acc = 0.0
	if _master == null or not _master.get_connection_status():
		_load_attempts += 1
		if _load_attempts >= LOAD_MAX_ATTEMPTS:
			_loaded = true  # master unreachable — run from the default rather than stall forever
			print("[world_clock] no master; day_t=%.4f (default)" % _day_t)
		return
	_load_in_flight = true
	_do_load()


func _do_load() -> void:
	var result: Dictionary = await _master.call_master(
		"world_state_op", {"op": "get", "key": "day_t"}
	)
	_load_in_flight = false
	if _loaded:
		return
	if result.has("error"):
		_load_attempts += 1  # transient (timeout / WS still opening) — retry next window
		if _load_attempts >= LOAD_MAX_ATTEMPTS:
			_loaded = true
			print("[world_clock] load kept failing; day_t=%.4f (default)" % _day_t)
		return
	_loaded = true
	if bool(result.get("found", false)):
		# Adopt the checkpoint (at most SAVE_SEC stale — an honest, tiny jump on the next resync,
		# far smaller than resetting the whole day). Replaces the default-based boot walk.
		_day_t = fposmod(float(result.get("value", DEFAULT_DAY_T)), 1.0)
		print("[world_clock] resumed day_t=%.4f" % _day_t)
	else:
		print("[world_clock] no checkpoint; day_t=%.4f (default)" % _day_t)


func _save() -> void:
	if _master == null or not _loaded or not _master.get_connection_status():
		return  # never overwrite before the boot read resolves; never poke a dead master
	# Fire-and-forget (the main.gd rested_logout idiom): the request leaves on the socket
	# synchronously; the reply is irrelevant — the next checkpoint supersedes it anyway.
	_master.call_master("world_state_op", {"op": "set", "key": "day_t", "value": _day_t})


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		_save()  # best-effort final checkpoint on a graceful shutdown
