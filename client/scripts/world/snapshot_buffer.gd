class_name SnapshotBuffer
extends RefCounted

# T-055: snapshot interpolation for a remote entity (Gambetta Part III / Source pattern). Remote
# players/mobs can't be predicted (no input), so we render them ~RENDER_DELAY in the past and lerp
# between the two buffered snapshots bracketing that time: smooth motion that absorbs jitter, at a
# small visual delay. Pure + deterministic, so unit-tested; remote_entities_layer.gd owns the mesh.

const MAX_SNAPSHOTS := 16

var _snaps: Array = []  # [{pos: Vector3, t: int}], in arrival (time-ascending) order


func push(pos: Vector3, t_ms: int) -> void:
	_snaps.append({"pos": pos, "t": t_ms})
	while _snaps.size() > MAX_SNAPSHOTS:
		_snaps.pop_front()


# Interpolated position at render_t_ms. Clamps to the ends when out of range (so a stalled stream
# holds the last known position rather than snapping to origin); lerps between the bracketing pair.
func sample(render_t_ms: int) -> Vector3:
	if _snaps.is_empty():
		return Vector3.ZERO
	if _snaps.size() == 1 or render_t_ms <= int(_snaps[0]["t"]):
		return _snaps[0]["pos"]
	if render_t_ms >= int(_snaps[-1]["t"]):
		return _snaps[-1]["pos"]
	for i in range(_snaps.size() - 1):
		var a: Dictionary = _snaps[i]
		var b: Dictionary = _snaps[i + 1]
		if render_t_ms >= int(a["t"]) and render_t_ms <= int(b["t"]):
			var span := float(int(b["t"]) - int(a["t"]))
			var f := 0.0 if span <= 0.0 else float(render_t_ms - int(a["t"])) / span
			return (a["pos"] as Vector3).lerp(b["pos"], f)
	return _snaps[-1]["pos"]


func size() -> int:
	return _snaps.size()
