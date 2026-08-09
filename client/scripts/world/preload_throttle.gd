# T-688 H4: in-flight cap for the threaded GLB preload. _preload_scenes used to fire a
# load_threaded_request for EVERY unique manifest scene (~187) in one call — the godot#111202
# crash shape (many complex GLB scene requests at once). The throttle keeps at most MAX_IN_FLIGHT
# requests outstanding: pump() (refilled from _process) retires finished requests and fires from
# the backlog up to the cap. Firing/status live in two thin seams (_fire/_in_progress) so the
# queue logic is provable headless, where real threaded GLB loads would corrupt the dummy
# renderer (the T-697 hazard). Only ever active under opt-in AVALON_THREADED_LOAD=1.
extends RefCounted

const MAX_IN_FLIGHT := 4

var _backlog: Array = []
var _inflight: Array = []
var _queued: Dictionary = {}


func queue(scene_path: String) -> void:
	if scene_path == "" or _queued.has(scene_path):
		return
	_queued[scene_path] = true
	_backlog.append(scene_path)


# Retire finished requests, then fire up to the cap. `skip` (scene_path -> anything; the layer
# passes its scene pin) drops backlog entries something already loaded synchronously. Returns the
# paths fired THIS call so the layer can mark them collectable (_requested).
func pump(skip: Dictionary = {}) -> Array:
	for j in range(_inflight.size() - 1, -1, -1):
		if not _in_progress(_inflight[j]):
			_inflight.remove_at(j)
	var fired: Array = []
	while _inflight.size() < MAX_IN_FLIGHT and not _backlog.is_empty():
		var sp: String = _backlog.pop_front()
		if skip.has(sp):
			continue
		_fire(sp)
		_inflight.append(sp)
		fired.append(sp)
	return fired


func pending() -> int:
	return _backlog.size() + _inflight.size()


# Region seam: drop the backlog and stop tracking whatever is still in flight.
func clear() -> void:
	_backlog.clear()
	_inflight.clear()
	_queued.clear()


func _fire(scene_path: String) -> void:
	ResourceLoader.load_threaded_request(scene_path)


func _in_progress(scene_path: String) -> bool:
	return (
		ResourceLoader.load_threaded_get_status(scene_path)
		== ResourceLoader.THREAD_LOAD_IN_PROGRESS
	)
