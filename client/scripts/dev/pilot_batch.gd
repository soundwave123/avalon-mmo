class_name PilotBatch
# T-623: `batch` runs N ops from ONE pilot.py invocation with ONE combined ack, replacing N separate
# cmds.jsonl round-trips (each paying its own file-write + poll latency from the PYTHON side) with a
# single round-trip whose payload is a LIST of ops — cuts per-op subprocess+file overhead ~3x for
# scripted sequences. Each sub-op still runs through Pilot._run() completely untouched (every
# existing op, and any future one, "just works" inside a batch); only the wait for a sub-op's
# completion changes, from a cross-process file poll to an in-process frame poll. Ops run in order,
# one at a time; a failing op does NOT abort the batch (partial-failure semantics — every result is
# reported so a scripted sequence's full diagnostic trail survives one bad step). Kept out of
# pilot.gd to hold it under the 1000-line house cap.

extends RefCounted

const _SUBOP_TIMEOUT_MS := 30000  # generous — covers a slow key_hold/drag/record inside a batch
const _ID_BASE := 1000000000  # synthetic ack ids namespaced well above any real cmds.jsonl line id


static func run(pilot, id: int, ops: Variant) -> Dictionary:
	if not (ops is Array):
		return {"ok": false, "error": "ops must be an array", "results": []}
	var results: Array = []
	var all_ok := true
	for i in range(ops.size()):
		var sub_result := await _run_one(pilot, id, ops[i], i)
		results.append(sub_result)
		if not bool(sub_result.get("ok", false)):
			all_ok = false
	return {"ok": all_ok, "results": results}


static func _run_one(pilot, batch_id: int, sub: Variant, index: int) -> Dictionary:
	if not (sub is Dictionary):
		return {"ok": false, "error": "batch item %d is not an object" % index}
	var sub_id := _ID_BASE + batch_id * 100000 + index
	var ack_path: String = pilot._dir.path_join("ack_%d.json" % sub_id)
	if FileAccess.file_exists(ack_path):
		DirAccess.remove_absolute(ack_path)  # stale leftover from a prior batch reusing this slot
	pilot._run(sub_id, sub)
	var deadline := Time.get_ticks_msec() + _SUBOP_TIMEOUT_MS
	while not FileAccess.file_exists(ack_path):
		if Time.get_ticks_msec() >= deadline:
			return {"ok": false, "error": "batch item %d timed out" % index}
		await pilot.get_tree().process_frame
	var f := FileAccess.open(ack_path, FileAccess.READ)
	var parsed = JSON.parse_string(f.get_as_text()) if f != null else null
	if f != null:
		f.close()
	DirAccess.remove_absolute(ack_path)
	return (
		parsed if parsed is Dictionary else {"ok": false, "error": "batch item %d: bad ack" % index}
	)
