# T-034: Objective tracker — pure, deterministic per-objective progress logic.
#
# Operates on a quest's `objectives` (Array of Dictionary: {type, target, count, ...}) and a
# parallel `progress` Array[int]. Mirrors the pure-module idiom of quest_state_machine.gd
# (T-033) and action_state_machine.gd (T-017).
#
# HARD CONSTRAINTS:
#   - No DB, no OS time, no global state. Inputs are never mutated (returns NEW arrays).
#   - Determinism: same inputs always produce identical output.
#   - Integer math via mini() — progress is int (GUT int != float; matches threat_table note).
#
# kill / talk / reach are monotonic EVENTS (credit_event, +1 capped at count).
# collect is a SNAPSHOT (apply_collect, progress = min(inventory count, count)) and may decrease.

extends RefCounted


static func zeros(objectives: Array) -> Array:
	var p: Array = []
	p.resize(objectives.size())
	p.fill(0)
	return p


# Pad a (possibly short) progress array to objectives length, as a fresh copy.
static func _sized_copy(objectives: Array, progress: Array) -> Array:
	var result: Array = progress.duplicate()
	while result.size() < objectives.size():
		result.append(0)
	return result


# T-426: an objective target of "*" matches ANY target of that kind (e.g. "use any ability" — the
# tutorial can't name one ability slug because each class has a different starter).
static func target_matches(obj_target: String, event_target: String) -> bool:
	return obj_target == event_target or obj_target == "*"


static func credit_event(objectives: Array, progress: Array, kind: String, target: String) -> Array:
	var result := _sized_copy(objectives, progress)
	for i in range(objectives.size()):
		var obj: Dictionary = objectives[i]
		if str(obj.get("type", "")) == kind and target_matches(str(obj.get("target", "")), target):
			var count: int = int(obj.get("count", 1))
			result[i] = mini(int(result[i]) + 1, count)
	return result


static func apply_collect(objectives: Array, progress: Array, item_counts: Dictionary) -> Array:
	var result := _sized_copy(objectives, progress)
	for i in range(objectives.size()):
		var obj: Dictionary = objectives[i]
		if str(obj.get("type", "")) == "collect":
			var target: String = str(obj.get("target", ""))
			var count: int = int(obj.get("count", 1))
			result[i] = mini(int(item_counts.get(target, 0)), count)
	return result


static func is_complete(objectives: Array, progress: Array) -> bool:
	for i in range(objectives.size()):
		var count: int = int(objectives[i].get("count", 1))
		var prog: int = int(progress[i]) if i < progress.size() else 0
		if prog < count:
			return false
	return true
