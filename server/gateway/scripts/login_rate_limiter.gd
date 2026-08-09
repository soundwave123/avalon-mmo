class_name LoginRateLimiter
extends RefCounted

# Failed-login budget keyed by the TCP source address. The caller injects monotonic time so this
# policy stays deterministic under test and reconnecting WebSockets cannot reset the budget.

var _max_failures: int
var _window_ms: int
var _failures: Dictionary = {}  # source -> Array[int] monotonic timestamps


func _init(max_failures: int = 5, window_ms: int = 60_000) -> void:
	_max_failures = max(1, max_failures)
	_window_ms = max(1, window_ms)


func can_attempt(source: String, now_ms: int) -> bool:
	return _recent_failures(source, now_ms).size() < _max_failures


func record_failure(source: String, now_ms: int) -> void:
	var recent := _recent_failures(source, now_ms)
	recent.append(now_ms)
	_failures[source] = recent


func _recent_failures(source: String, now_ms: int) -> Array:
	var cutoff := now_ms - _window_ms
	var recent: Array = []
	for timestamp: int in _failures.get(source, []):
		if timestamp > cutoff:
			recent.append(timestamp)
	if recent.is_empty():
		_failures.erase(source)
	else:
		_failures[source] = recent
	return recent
