class_name PilotWait
# T-623: `wait_until` — the poll-don't-sleep idiom every QA session hand-rolled ("sleep N, check
# state, repeat" for class_panel_visible / hp thresholds / arrival-near). resolve_path()/matches()
# are PURE (unit-tested headlessly, see test_pilot_wait.gd); run() is the live per-frame poll loop.
# Kept out of pilot.gd to hold it under the 1000-line house cap.

extends RefCounted


# LIVE: poll a snapshot of pilot._dump_state() + the live player's vitals every frame until `path`
# matches `raw_value`, or ack a timeout. Never sleeps — the wait is one Pilot op instead of a driver
# hand-rolling repeated `state`/`observe` calls with sleeps in between.
static func run(pilot, path: String, raw_value: String, timeout_s: float) -> Dictionary:
	var deadline := Time.get_ticks_msec() + int(maxf(timeout_s, 0.0) * 1000.0)
	var current: Variant = null
	while true:
		current = resolve_path(_snapshot(pilot), path)
		if matches(current, raw_value):
			return {"ok": true, "path": path, "value": raw_value, "actual": current}
		if Time.get_ticks_msec() >= deadline:
			return {
				"ok": false,
				"error": "timeout",
				"path": path,
				"wanted": raw_value,
				"actual": current,
				"timeout_s": timeout_s,
			}
		await pilot.get_tree().process_frame
	return {}  # unreachable — the loop above only exits via one of the two returns above


static func _snapshot(pilot) -> Dictionary:
	var snap: Dictionary = pilot._dump_state()
	var main: Node = pilot.get_tree().root.get_node_or_null("Main")
	if main != null:
		snap["player"] = PilotObserve._live_player(main)  # hp/max_hp/mana/level/alive/class
	return snap


# ---- PURE (unit-tested) ---------------------------------------------------------------------


# Dot-path lookup into a nested Dictionary snapshot, e.g. "player.hp" or "class_panel_visible".
# A missing/non-Dictionary segment resolves to null rather than erroring — a typo'd path just never
# matches (and shows up as "actual": null in the timeout ack) instead of crashing the poll loop.
static func resolve_path(snapshot: Dictionary, path: String) -> Variant:
	var cur: Variant = snapshot
	for part in path.split("."):
		if cur is Dictionary and (cur as Dictionary).has(part):
			cur = (cur as Dictionary)[part]
		else:
			return null
	return cur


# Grammar: ">=N" "<=N" ">N" "<N" "!=N" numeric compare (hp-above etc); "x,z[,tol]" planar-distance
# near (position-near, default tol 1.0); "true"/"false" bool equality; else numeric equality if both
# sides parse as a float, else plain string equality.
static func matches(current: Variant, raw_value: String) -> bool:
	var value := raw_value.strip_edges()
	for cmp_op in ["!=", ">=", "<=", ">", "<"]:
		if value.begins_with(cmp_op):
			return _numeric_compare(current, cmp_op, value.substr(cmp_op.length()))
	if value.contains(","):
		return _position_near(current, value)
	if value == "true" or value == "false":
		# bool(current) would throw on a non-bool Variant (e.g. null from a missing path) — compare
		# directly instead so an unresolved path just fails to match rather than erroring.
		return typeof(current) == TYPE_BOOL and current == (value == "true")
	if value.is_valid_float() and (typeof(current) == TYPE_INT or typeof(current) == TYPE_FLOAT):
		return absf(float(current) - value.to_float()) < 0.0001
	return str(current) == value


static func _numeric_compare(current: Variant, cmp_op: String, rhs: String) -> bool:
	if (
		not rhs.is_valid_float()
		or not (typeof(current) == TYPE_INT or typeof(current) == TYPE_FLOAT)
	):
		return false
	var cur_f := float(current)
	var target := rhs.to_float()
	match cmp_op:
		">=":
			return cur_f >= target
		"<=":
			return cur_f <= target
		">":
			return cur_f > target
		"<":
			return cur_f < target
		"!=":
			return absf(cur_f - target) >= 0.0001
	return false


static func _position_near(current: Variant, value: String) -> bool:
	var parts := value.split(",")
	if parts.size() < 2 or not parts[0].is_valid_float() or not parts[1].is_valid_float():
		return false
	var want := Vector2(parts[0].to_float(), parts[1].to_float())
	var tol := parts[2].to_float() if parts.size() > 2 and parts[2].is_valid_float() else 1.0
	var have: Variant = _xz(current)
	if have == null:
		return false
	return (have as Vector2).distance_to(want) <= tol


# Accepts an [x,y,z] array (the goto/player_pos shape — z lives at index 2) or a {"x":..,"z":..}
# dict; anything else resolves to null (no match, not a crash).
static func _xz(current: Variant) -> Variant:
	if current is Array and (current as Array).size() >= 3:
		return Vector2(float(current[0]), float(current[2]))
	if (
		current is Dictionary
		and (current as Dictionary).has("x")
		and (current as Dictionary).has("z")
	):
		return Vector2(float(current["x"]), float(current["z"]))
	return null
