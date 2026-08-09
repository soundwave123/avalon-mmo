extends RefCounted

# T-705: the first-session funnel measures from PROCESS LAUNCH, not spawn — the 20-30s
# launch→login→interactive window used to be invisible, and that is exactly where a refund clock
# runs. Time.get_ticks_msec() is already milliseconds since the engine started, so launch is 0 by
# construction and no wall clock is needed; nothing here ever leaves the client except two
# DURATIONS, so the report cannot place a session in time or identify a machine.
#
# Static because the login form is freed before the world handshake that reports the timing.

const MAX_PHASE_MS := 3_600_000  # an hour-long phase is a suspended process, not a boot

static var _login_ms: int = -1
static var _interactive_ms: int = -1


static func reset() -> void:
	_login_ms = -1
	_interactive_ms = -1


# The FIRST submit is the one the funnel measures — a retry after a typo is not launch→login.
static func mark_login_submit(now_ms: int = -1) -> void:
	if _login_ms < 0:
		_login_ms = _now(now_ms)


static func mark_interactive(now_ms: int = -1) -> void:
	if _interactive_ms < 0:
		_interactive_ms = _now(now_ms)


# {} until BOTH marks exist — a partial boot reports nothing rather than a misleading zero.
static func timing_payload() -> Dictionary:
	if _login_ms < 0 or _interactive_ms < 0:
		return {}
	return {
		"launch_to_login_ms": clampi(_login_ms, 0, MAX_PHASE_MS),
		"login_to_interactive_ms": clampi(_interactive_ms - _login_ms, 0, MAX_PHASE_MS),
	}


static func _now(now_ms: int) -> int:
	return int(Time.get_ticks_msec()) if now_ms < 0 else now_ms
