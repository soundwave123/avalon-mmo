extends GutTest

# T-734: the server-authoritative world day clock — advance math, resync/save cadences, and the
# master checkpoint load/save protocol, all against an injected fake master (no sockets).

const WorldClock = preload("res://scripts/world_clock.gd")


# Fake MasterClient: records world_state_op calls; scripted connection + get result.
class FakeMaster:
	extends RefCounted
	var connected := true
	var calls: Array = []
	var get_result: Dictionary = {"ok": true, "found": false}

	func get_connection_status() -> bool:
		return connected

	func call_master(method: String, params: Dictionary) -> Dictionary:
		calls.append([method, params.duplicate(true)])
		if str(params.get("op", "")) == "get":
			return get_result
		return {"ok": true}


var _clock = null
var _master: FakeMaster
var _sent: Array = []


func before_each() -> void:
	_clock = WorldClock.new()
	_master = FakeMaster.new()
	_sent.clear()
	_clock.setup(_master, func(pid, payload): _sent.append([pid, payload]))


func after_each() -> void:
	_clock.free()


func test_advance_walks_at_the_shared_rate() -> void:
	# 12 s of a 1200 s day = 0.01 of the cycle (the exact client fmod walk).
	assert_almost_eq(WorldClock.advance(0.25, 12.0, 1200.0), 0.26, 0.000001)


func test_advance_wraps_past_midnight() -> void:
	assert_almost_eq(WorldClock.advance(0.999, 2.4, 1200.0), 0.001, 0.000001)


func test_resync_payload_shape() -> void:
	var payload := WorldClock.resync_payload(0.42)
	assert_eq(payload["type"], "world_clock")
	assert_almost_eq(float(payload["day_t"]), 0.42, 0.000001)


func test_boot_default_matches_the_old_client_free_run_start() -> void:
	assert_almost_eq(_clock.day_t(), 0.34, 0.000001)


func test_load_adopts_the_persisted_checkpoint() -> void:
	_master.get_result = {"ok": true, "found": true, "value": 0.75}
	_clock._process(0.016)  # first frame: load attempt fires (accumulator pre-armed)
	assert_almost_eq(_clock.day_t(), 0.75, 0.001)
	assert_true(_clock._loaded)
	assert_eq(_master.calls[0][0], "world_state_op")
	assert_eq(str(_master.calls[0][1]["op"]), "get")


func test_load_with_no_row_keeps_the_default() -> void:
	_clock._process(0.016)
	assert_true(_clock._loaded)
	assert_almost_eq(_clock.day_t(), 0.34, 0.001)


func test_load_retries_while_master_is_down_then_fails_open() -> void:
	_master.connected = false
	for _i in WorldClock.LOAD_MAX_ATTEMPTS:
		_clock._process(WorldClock.LOAD_RETRY_SEC)
	assert_true(_clock._loaded)  # gave up after the attempt budget — runs from the default
	assert_eq(_master.calls.size(), 0)  # never called a dead master


func test_save_fires_on_cadence_with_the_current_day_t() -> void:
	_clock._process(0.016)  # resolves the load (no row -> default)
	_master.calls.clear()
	_clock._process(WorldClock.SAVE_SEC)
	var sets: Array = _master.calls.filter(func(c): return str(c[1].get("op", "")) == "set")
	assert_eq(sets.size(), 1)
	assert_eq(str(sets[0][1]["key"]), "day_t")
	assert_almost_eq(float(sets[0][1]["value"]), _clock.day_t(), 0.001)


func test_save_never_overwrites_before_the_load_resolves() -> void:
	_master.connected = false  # load can't resolve; _loaded stays false
	_clock._process(WorldClock.SAVE_SEC)  # save cadence elapses anyway
	assert_eq(_master.calls.size(), 0)


func test_resync_pushes_one_world_clock_payload_per_listed_player() -> void:
	_clock._process(0.016)  # resolve load
	_sent.clear()
	# PlayerSessions is a shared static store — measure against whatever is listed right now
	# (other suites may have seeded it) instead of assuming empty.
	var listed: int = WorldClock.PlayerSessions.list_players().size()
	_clock._process(WorldClock.RESYNC_SEC)
	assert_eq(_sent.size(), listed)
	for entry in _sent:
		assert_eq(str(entry[1]["type"]), "world_clock")
	# The live fan-out is the ops_service list_players() idiom, exercised end-to-end by
	# scripts/test-t734-dayclock-e2e.sh.
