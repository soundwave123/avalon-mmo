class_name MaintenanceCountdown
extends RefCounted

# Pure, clock-injected restart countdown. The caller supplies elapsed seconds; no OS clock lives
# here. Standard beats are always present when the requested duration reaches them, while a custom
# duration also gets an immediate opening notice.
const STANDARD_BEATS := [600, 300, 120, 60, 30, 0]

var _remaining := 0.0
var _reason := ""
var _beats: Array = []
var _next_beat := 0
var _active := false


static func schedule(duration_seconds: int) -> Array:
	var duration := maxi(duration_seconds, 1)
	var out: Array = [duration]
	for beat: int in STANDARD_BEATS:
		if beat < duration and not out.has(beat):
			out.append(beat)
	return out


func start(minutes: int, reason: String) -> Dictionary:
	_remaining = float(minutes * 60)
	_reason = reason
	_beats = schedule(int(_remaining))
	_next_beat = 1
	_active = true
	return _notice(int(_remaining))


func advance(delta_seconds: float) -> Array:
	var events: Array = []
	if not _active or delta_seconds <= 0.0:
		return events
	var previous := _remaining
	_remaining = maxf(_remaining - delta_seconds, 0.0)
	while _next_beat < _beats.size():
		var beat := int(_beats[_next_beat])
		if previous > float(beat) and _remaining <= float(beat):
			events.append(_notice(beat))
			_next_beat += 1
			continue
		break
	if _remaining <= 0.0:
		_active = false
	return events


func current_notice() -> Dictionary:
	return _notice(int(ceil(_remaining))) if _active else {}


func is_active() -> bool:
	return _active


func _notice(remaining_seconds: int) -> Dictionary:
	var timing := "now"
	if remaining_seconds >= 60:
		var minutes := remaining_seconds / 60
		var seconds := remaining_seconds % 60
		timing = "%dm" % minutes
		if seconds > 0:
			timing += " %ds" % seconds
	elif remaining_seconds > 0:
		timing = "%ds" % remaining_seconds
	var text := "Server maintenance begins %s — %s" % [timing, _reason]
	if remaining_seconds == 0:
		text = "Server maintenance is beginning now — %s" % _reason
	return {
		"type": "maintenance",
		"remaining_seconds": remaining_seconds,
		"reason": _reason,
		"text": text,
	}
