# T-074: per-peer movement budget — the old speed cap was per-MESSAGE (100 units) with no
# limit on messages per second, so a client sending one max-delta per frame teleported at
# thousands of units/sec legally. This caps total distance per one-second window.
#
# Pure/clock-injected: `now_tick` is the server tick counter; no OS time here.

extends RefCounted

const _SC = preload("res://scripts/server_config.gd")

var _windows: Dictionary = {}  # peer_id -> {"start": window_start_tick, "used": float}


# True if the peer may move `distance` units now; consumes budget when allowed.
func allow(
	peer_id: int,
	distance: float,
	now_tick: int,
	units_per_second: float = _SC.MOVE_UNITS_PER_SECOND
) -> bool:
	var w: Dictionary = _windows.get(peer_id, {"start": now_tick, "used": 0.0})
	if now_tick - int(w["start"]) >= _SC.TICK_RATE_HZ:  # 1-second window
		w = {"start": now_tick, "used": 0.0}
	if float(w["used"]) + distance > units_per_second:
		_windows[peer_id] = w
		return false
	w["used"] = float(w["used"]) + distance
	_windows[peer_id] = w
	return true


func forget(peer_id: int) -> void:
	_windows.erase(peer_id)
