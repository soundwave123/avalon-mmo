# T-688 H2: budgeted region teardown — the mirror image of the load budget. _teardown_all used to
# free the WHOLE outgoing region + every _scene_pin ref in ONE seam frame: the same RID-burst
# class the load side budgeted after Bug #102 (godot#82576, #114998, #119879). Instead, outgoing
# children move into a hidden, processing-DISABLED "dying" container (invisible + out of the
# physics space immediately) and drain() frees a small budget per frame, pin refs riding the SAME
# budget after the nodes. `generation` bumps per teardown and the layer clears its tracking dicts
# at retire time, so a re-entered region always places FRESH instances — nothing resurrects, and
# the drain completes even if the player immediately crosses back.
extends RefCounted

const FREE_BUDGET_PER_FRAME := 3

var generation: int = 0
var _dying: Node3D = null
var _free_queue: Array = []
var _pin_release: Array = []


# Move every child of `layer` (except the dying container itself) out of gameplay and onto the
# budgeted free queue; take over the pinned PackedScene refs so their release is budgeted too.
func retire(layer: Node3D, pins: Dictionary) -> void:
	generation += 1
	var dying := _container(layer)
	for c in layer.get_children():
		if c == dying or c.is_queued_for_deletion():
			continue  # something (ring stream-out, a prior sweep) already owns that free
		layer.remove_child(c)
		dying.add_child(c)
		_free_queue.append(c)
	for path in pins:
		_pin_release.append(pins[path])


# One frame's worth of frees: node roots first, then pin releases, ONE shared budget. Once both
# queues empty, the container is swept (when its children finish deleting), so the tree returns
# to its pre-crossing shape and child-count leak invariants stay exact. Returns the work done.
func drain() -> int:
	var done := 0
	while done < FREE_BUDGET_PER_FRAME and not _free_queue.is_empty():
		var node = _free_queue.pop_front()
		if not is_instance_valid(node):
			continue  # already gone — skip cheaply, don't spend budget
		node.queue_free()
		done += 1
	while done < FREE_BUDGET_PER_FRAME and _free_queue.is_empty() and not _pin_release.is_empty():
		_pin_release.pop_front()
		done += 1
	if _free_queue.is_empty() and _pin_release.is_empty() and _dying != null:
		if not is_instance_valid(_dying):
			_dying = null
		elif _dying.get_child_count() == 0:
			_dying.queue_free()
			_dying = null
	return done


func pending() -> int:
	return _free_queue.size() + _pin_release.size()


# True while ANY teardown work remains (incl. the final container sweep) — _process keeps draining.
func active() -> bool:
	return pending() > 0 or _dying != null


func _container(layer: Node3D) -> Node3D:
	if _dying == null or not is_instance_valid(_dying):
		_dying = Node3D.new()
		_dying.name = "DyingRegion"
		_dying.visible = false
		_dying.process_mode = Node.PROCESS_MODE_DISABLED
		layer.add_child(_dying)
	return _dying
