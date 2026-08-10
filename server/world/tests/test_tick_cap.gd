extends "res://addons/gut/test.gd"

# T-749: the regression test T-698 never had.
#
# T-698 capped the headless world's frame rate and gated its per-tick work on the tick edge.
# T-699 (broadcast scaling) was written off a pre-T-698 base and, when it landed, silently
# erased BOTH from server/world/scripts/main.gd — while leaving them intact in gateway/master.
# The world server then free-ran (~142 fps against a 20 Hz tick) for 17 days: ~7x CPU on the
# per-player process, an _ASM.new() per frame per pass, and combat timers advancing on frames
# instead of ticks. Nothing failed, because nothing asserted any of it.
#
# These tests assert the three properties by BEHAVIOUR, never by grepping the source:
#   1. booting the world caps Engine.max_fps (drives the real _ready());
#   2. the per-tick block runs exactly once per tick no matter how many frames land inside it,
#      counted through the HOISTED _asm member — so a re-introduced per-frame `_ASM.new()`
#      local bypasses the counter and fails this test too;
#   3. ServerConfig.now_tick() is bit-identical to the integer division it replaced at 20 Hz.

const ServerConfig = preload("res://scripts/server_config.gd")
const PlayerSessions = preload("res://scripts/player_sessions.gd")

const PEER := 91
# One ~60 fps frame. 1/64 rather than 1/60 so the broadcast accumulator's arithmetic is exact in
# binary and these tests can assert frame counts without float slop.
const FRAME := 1.0 / 64.0
const HALF_BROADCAST := 0.05  # exactly half the 10 Hz broadcast window (1.0/10), exact in binary

var _saved_max_fps: int = 0


# Boot probe: the REAL _ready() (print + Engine.max_fps + _boot_services), with the service and
# network wiring stubbed so entering the tree cannot open a master connection or bind ENet.
class _BootProbe:
	extends "res://scripts/main.gd"

	var boot_reached: bool = false

	func _boot_services() -> void:
		boot_reached = true

	func _process(_delta: float) -> void:
		pass  # nothing is wired; the probe must never tick


# Counting proxy for the hoisted _asm member. Delegates to the real FSM so behaviour is unchanged.
class _CountingAsm:
	extends RefCounted

	const _REAL = preload("res://scripts/combat/action_state_machine.gd")

	var advance_calls: int = 0
	var cast_tick_calls: int = 0
	var _real = _REAL.new()

	func advance_timers(state, now: int):
		advance_calls += 1
		return _real.advance_timers(state, now)

	func process_cast_tick(state, current_pos: Vector3, now: int):
		cast_tick_calls += 1
		return _real.process_cast_tick(state, current_pos, now)

	func tick(state, intent, now: int):
		return _real.tick(state, intent, now)

	func check_death_transition(state, resources, now: int, respawn_ticks: int):
		return _real.check_death_transition(state, resources, now, respawn_ticks)


# Tick harness: the real _process(), with the server clock scripted and the wire stubbed.
class _TickHarness:
	extends "res://scripts/main.gd"

	var scripted_tick: int = 0
	var broadcasts: int = 0

	func _now_tick() -> int:
		return scripted_tick

	func _broadcast_positions() -> void:
		broadcasts += 1


func before_each() -> void:
	_saved_max_fps = Engine.max_fps
	PlayerSessions._reset_for_test()


func after_each() -> void:
	Engine.max_fps = _saved_max_fps  # never leak a cap into the rest of the suite
	PlayerSessions._reset_for_test()


# ---- 1. the cap itself ---------------------------------------------------------------------


func test_world_boot_caps_engine_max_fps() -> void:
	Engine.max_fps = 0  # 0 = uncapped: exactly the free-running state T-699 left the world in
	var probe := _BootProbe.new()
	autofree(probe._world_clock)  # T-734 Node the stubbed wiring never reparents — no orphan
	add_child_autofree(probe)  # entering the tree runs the REAL _ready()
	assert_eq(Engine.max_fps, 60, "world boot must cap the headless _process (T-698/T-749)")
	assert_true(probe.boot_reached, "_ready() must still reach the service wiring after the cap")


# ---- 2. the tick-edge gate (and, implicitly, the hoisted _asm) -----------------------------


func _harness() -> _TickHarness:
	var m := _TickHarness.new()
	autofree(m)
	autofree(m._world_clock)  # T-734 Node the stubbed wiring never reparents — no orphan
	m._asm = _CountingAsm.new()
	return m


func test_per_tick_work_runs_once_per_tick_not_once_per_frame() -> void:
	var m := _harness()
	m._combat_states[PEER] = CombatState.new()  # one player: advance_timers has work every tick

	m.scripted_tick = 20  # three 60 fps frames land inside this single 20 Hz tick window
	m._process(FRAME)
	m._process(FRAME)
	m._process(FRAME)
	assert_eq(
		m._asm.advance_calls,
		1,
		"3 frames inside one tick must advance combat timers ONCE (this is the T-699 regression)"
	)

	m.scripted_tick = 21  # the next tick edge
	m._process(FRAME)
	assert_eq(m._asm.advance_calls, 2, "a new tick edge must advance timers exactly once")

	m.scripted_tick = 22
	m._process(FRAME)
	m._process(FRAME)
	assert_eq(m._asm.advance_calls, 3, "and once per tick again, however many frames arrive")


func test_casting_scan_is_inside_the_tick_gate() -> void:
	var m := _harness()
	var cs := CombatState.new()
	cs.state = CombatState.CombatStateEnum.CASTING
	cs.cast_end = 9_999  # far future: the scan runs and reports "ongoing", changing nothing
	cs.position_snapshot = Vector3.ZERO
	m._combat_states[PEER] = cs

	m.scripted_tick = 40
	m._process(FRAME)
	m._process(FRAME)
	m._process(FRAME)
	assert_eq(m._asm.cast_tick_calls, 1, "the CASTING scan must run once per tick, not per frame")

	m.scripted_tick = 41
	m._process(FRAME)
	assert_eq(m._asm.cast_tick_calls, 2, "and exactly once on the next tick edge")


func test_frame_paced_work_still_runs_every_frame() -> void:
	# The gate must not starve the delta-driven work ABOVE it — the handshake-timeout countdown
	# is the one with a player-visible deadline, so prove it still decrements off the tick edge.
	var m := _harness()
	m._handshake_timers[PEER] = 10.0
	m.scripted_tick = 60
	m._process(FRAME)
	m._process(FRAME)
	m._process(FRAME)
	assert_almost_eq(
		float(m._handshake_timers[PEER]),
		10.0 - 3.0 * FRAME,
		0.0001,
		"handshake timers are delta-driven: the tick gate must not swallow their frames"
	)


func test_broadcast_does_not_ride_the_tick_gate() -> void:
	# The 10 Hz positions broadcast sits above the gate on its own accumulator: it must fire from
	# accumulated delta alone, even while the tick clock stands completely still.
	var m := _harness()
	m.scripted_tick = 70  # frozen clock: every _process below is a NON-tick frame after the first
	for i in range(6):
		m._process(HALF_BROADCAST)  # 6 x 0.05 s = three full 10 Hz broadcast windows
	assert_eq(m.broadcasts, 3, "the broadcast accumulator must keep firing off the tick edge")


# ---- 3. the now_tick() sweep ---------------------------------------------------------------


func test_now_tick_is_bit_identical_to_the_expression_it_replaced() -> void:
	assert_eq(ServerConfig.TICK_RATE_HZ, 20, "this identity is proved for the shipped 20 Hz rate")
	for msec in [0, 1, 49, 50, 51, 99, 100, 101, 999, 1000, 1001, 123_456, 86_400_000]:
		# Exactly what all ~10 call sites used to inline before T-749.
		var replaced: int = msec / (1000 / ServerConfig.TICK_RATE_HZ)
		assert_eq(ServerConfig.tick_of_msec(msec), replaced, "tick drift at msec=%d" % msec)


func test_tick_of_msec_is_exact_arithmetic_not_a_truncated_divisor() -> void:
	# Independent oracle: the true tick index is floor(seconds * rate). The replaced form divided
	# by an ALREADY-truncated int (1000 / hz), so it only agreed while hz divided 1000 exactly —
	# at 30 Hz it divided by 33 instead of 33.33 (a ~1% fast clock on every cooldown and respawn).
	for msec in [0, 37, 999, 1000, 1500, 60_000, 3_600_123]:
		var truth: int = int(floor(float(msec) / 1000.0 * float(ServerConfig.TICK_RATE_HZ)))
		assert_eq(ServerConfig.tick_of_msec(msec), truth, "tick_of_msec wrong at msec=%d" % msec)


func test_now_tick_reads_the_live_clock_and_advances() -> void:
	var t0: int = ServerConfig.now_tick()
	assert_eq(t0, ServerConfig.tick_of_msec(Time.get_ticks_msec()), "now_tick = clock -> tick_of")
	assert_gt(t0, 0, "the live server clock must produce a positive tick index")
