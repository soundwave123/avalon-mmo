extends "res://addons/gut/test.gd"

# T-688 H4: _preload_scenes used to fire a load_threaded_request for EVERY unique manifest scene
# (~187) in one call — the godot#111202 crash shape (many complex GLB requests at once). The
# throttle caps requests in flight and refills as earlier ones finish. The firing/status seams
# are FAKED here so the queue logic is provable headless, where real threaded GLB loads would
# corrupt the dummy renderer (the T-697 hazard the suite deliberately never touches).


class FakeThrottle:
	extends "res://scripts/world/preload_throttle.gd"

	var fired: Array = []
	var done: Dictionary = {}

	func _fire(scene_path: String) -> void:
		fired.append(scene_path)

	func _in_progress(scene_path: String) -> bool:
		return not done.has(scene_path)


func _paths(n: int) -> Array:
	var out: Array = []
	for k in n:
		out.append("res://fake_scene_%d.glb" % k)
	return out


func test_first_pump_fires_at_most_the_cap_never_the_whole_manifest() -> void:
	var t := FakeThrottle.new()
	for sp in _paths(10):
		t.queue(sp)
	var fired: Array = t.pump()
	assert_eq(fired.size(), t.MAX_IN_FLIGHT, "only the cap goes out — never 187-at-once")
	assert_eq(t.pending(), 10, "the rest wait in the backlog, still tracked")


func test_pump_refills_only_as_requests_finish() -> void:
	var t := FakeThrottle.new()
	for sp in _paths(10):
		t.queue(sp)
	t.pump()
	assert_eq(t.pump().size(), 0, "nothing finished -> nothing more fires")
	t.done[t.fired[0]] = true
	t.done[t.fired[1]] = true
	assert_eq(t.pump().size(), 2, "two finished -> exactly two more fire")
	assert_eq(t._inflight.size(), t.MAX_IN_FLIGHT, "in-flight never exceeds the cap")


func test_queue_dedupes_and_skip_drops_already_pinned_paths() -> void:
	var t := FakeThrottle.new()
	t.queue("res://a.glb")
	t.queue("res://a.glb")
	t.queue("")
	t.queue("res://b.glb")
	var fired: Array = t.pump({"res://a.glb": true})
	assert_eq(fired, ["res://b.glb"], "dupes/empties queue once at most; pinned paths never fire")


func test_drains_to_zero_and_clear_drops_everything() -> void:
	var t := FakeThrottle.new()
	for sp in _paths(6):
		t.queue(sp)
	while t.pending() > 0:
		for sp in t.fired:
			t.done[sp] = true
		t.pump()
	assert_eq(t.fired.size(), 6, "every queued path eventually fires exactly once")
	var t2 := FakeThrottle.new()
	for sp in _paths(3):
		t2.queue(sp)
	t2.pump()
	t2.clear()
	assert_eq(t2.pending(), 0, "the region seam clears the backlog + in-flight tracking")
