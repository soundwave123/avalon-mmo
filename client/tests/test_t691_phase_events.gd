extends GutTest

# T-691: the static login-phase bus (load_phases.gd) + the props layer's initial-populate gate.
# Asserts the canonical boot ordering, dedupe, timestamp sanity, and that a queued first populate
# fires `initial_populate_done` + the populate end mark exactly when the T-688 queue first drains
# — the loading screen's dismiss gate. The bus prints one `[loadphase]` line per mark, which is
# also the live headless E2E proof hook (grep the client log for the canonical order).

const LoadPhases = preload("res://scripts/ui/load_phases.gd")

# The coarse phases in canonical boot order (mirrors LoadProgressModel.PHASES).
const CANON := ["world", "props", "populate", "hud", "connect", "snapshot"]

var _events: Array = []  # captured [kind, phase, data] rows


func before_each() -> void:
	LoadPhases.reset()
	_events = []
	LoadPhases.add_listener(_capture)


func after_each() -> void:
	LoadPhases.reset()


func _capture(kind: String, phase: String, data: Dictionary) -> void:
	_events.append([kind, phase, data])


func _begins() -> Array:
	var out: Array = []
	for e: Array in _events:
		if e[0] == "begin":
			out.append(e[1])
	return out


func test_canonical_boot_order_and_sane_timestamps() -> void:
	# Drive the bus exactly the way main.gd/world_view/world_props do on a live login.
	LoadPhases.cut_now("world")
	LoadPhases.timed("terrain", func(): pass)  # world_view's sub-mark nests inside "world"
	LoadPhases.cut_now("props")
	LoadPhases.begin("populate")  # queued by the props layer, drains across later frames
	LoadPhases.cut_now("hud")
	LoadPhases.progress("populate", 40, 80)
	LoadPhases.cut_now("connect")
	LoadPhases.end("populate")  # initial queue drained mid-connect — overlap is the design
	LoadPhases.cut_now("snapshot")
	LoadPhases.end("snapshot")
	assert_eq(_begins(), ["world", "terrain", "props", "populate", "hud", "connect", "snapshot"])
	for phase: String in CANON:
		assert_true(LoadPhases._ended.has(phase), "%s ended" % phase)
		assert_true(
			int(LoadPhases._ended[phase]) >= int(LoadPhases._begun[phase]),
			"%s: end stamp is not before its begin stamp" % phase
		)


func test_begin_and_end_dedupe_and_require_order() -> void:
	LoadPhases.begin("world")
	LoadPhases.begin("world")
	LoadPhases.end("world")
	LoadPhases.end("world")
	LoadPhases.end("props")  # end before begin: dropped
	var kinds: Array = []
	for e: Array in _events:
		kinds.append("%s:%s" % [e[0], e[1]])
	assert_eq(kinds, ["begin:world", "end:world"], "first begin/end win; orphan end dropped")


func test_cut_now_closes_the_previously_open_phase() -> void:
	LoadPhases.cut_now("world")
	LoadPhases.cut_now("props")
	assert_true(LoadPhases._ended.has("world"), "the seam ended the open phase")
	assert_false(LoadPhases._ended.has("props"), "and left the new one running")


func test_progress_events_carry_counts_without_prints() -> void:
	LoadPhases.begin("populate")
	LoadPhases.progress("populate", 3, 9)
	var last: Array = _events[-1]
	assert_eq(last[0], "progress")
	assert_eq(int(last[2]["done"]), 3)
	assert_eq(int(last[2]["total"]), 9)


func test_reset_notifies_listeners_so_a_stale_screen_can_dismiss() -> void:
	LoadPhases.reset()
	assert_eq(_events[-1][0], "reset", "a superseding login tells the old screen to go away")


func test_queued_initial_populate_fires_the_dismiss_gate_on_first_drain() -> void:
	# Off-tree layer (the test_prop_load_perf idiom): _ready never runs, _active_region stays -999,
	# so stream_to is a genuine INITIAL populate we can steer with _queue_initial.
	var layer = autofree(WorldPropsLayer.new())
	var manifest: Array = []
	for k in 6:  # repeated rocks -> one batched chunk (a Vector3i queue item)
		manifest.append(
			{"scene": "res://assets/models/prop_rock_a.glb", "x": float(k * 3), "y": 0.0}
		)
	manifest.append({"scene": "res://assets/models/prop_cottage_v2.glb", "x": 0.0, "y": 8.0})
	layer.load_manifest(manifest)
	layer.set_stream_cfg({"flora_ring": 100.0, "building_ring": 900.0})
	layer._queue_initial = true
	watch_signals(layer)
	layer.stream_to(Vector2.ZERO)
	assert_signal_not_emitted(layer, "initial_populate_done", "queued: nothing placed yet")
	assert_true(LoadPhases._begun.has("populate"), "the populate phase begins at queue time")
	assert_false(LoadPhases._ended.has("populate"), "…and is still open while the queue drains")
	var guard := 0
	while not layer._load_queue.is_empty() and guard < 50:
		layer._drain_load_queue()
		guard += 1
	assert_signal_emitted(layer, "initial_populate_done", "first full drain = the dismiss gate")
	assert_true(LoadPhases._ended.has("populate"), "…and the phase end mark landed with it")
	var progressed := false
	for e: Array in _events:
		if e[0] == "progress" and e[1] == "populate" and int(e[2]["total"]) > 0:
			progressed = true
	assert_true(progressed, "the drain reported real placed-vs-queued progress")


func test_inline_initial_populate_still_closes_the_gate() -> void:
	# The headless/inline path (harness boots): the same gate must land synchronously.
	var layer = autofree(WorldPropsLayer.new())
	var manifest: Array = [{"scene": "res://assets/models/prop_rock_a.glb", "x": 0.0, "y": 0.0}]
	layer.load_manifest(manifest)
	layer.set_stream_cfg({"flora_ring": 100.0, "building_ring": 900.0})
	watch_signals(layer)
	layer.stream_to(Vector2.ZERO)  # initial + _queue_initial false -> places inline
	assert_signal_emitted(layer, "initial_populate_done", "inline populate finishes immediately")
	assert_true(LoadPhases._ended.has("populate"))


func test_empty_manifest_never_wedges_the_gate() -> void:
	var layer = autofree(WorldPropsLayer.new())
	layer.load_manifest([])
	watch_signals(layer)
	layer.stream_to(Vector2.ZERO)
	assert_signal_emitted(layer, "initial_populate_done", "nothing to place still closes the gate")
