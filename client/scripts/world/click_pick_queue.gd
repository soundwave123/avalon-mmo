class_name ClickPickQueue
# T-753: every world click is BUFFERED at input time and its raycast resolved in the next
# _physics_process.
#
# WHY. The Godot manual is explicit that PhysicsDirectSpaceState3D queries are only safe inside
# _physics_process: outside that window the space may be locked, and a locked space does not push an
# error — it returns an EMPTY result. So a dropped click is invisible. No warning, no log line, just
# a target that silently didn't select and a player who clicks again. main._unhandled_input and
# PartyInviteFlow._on_world_right_click both cast their ray straight out of the input callback,
# which is exactly that window.
#
# COST. The pick lands at most one physics frame late: 16.7 ms at the project's 60 Hz tick. That is
# well under the ~100 ms at which a click stops feeling instant, and an order of magnitude under the
# server round-trip that has to validate the selection anyway. Nothing about the feel changes.
#
# NO COALESCING. The queue drains its WHOLE batch every tick, so several clicks landing inside one
# render frame (uncapped render outruns physics several-to-one) each resolve to their own pick. The
# array is unbounded on purpose — a cap could only be enforced by dropping picks, which is the very
# bug this module exists to fix, and a fully-drained-60x/second queue cannot actually grow.

extends Node

var _main = null
var _pending: Array[Dictionary] = []


# A Node, not a RefCounted helper, for exactly one reason: only a Node gets _physics_process. main
# mounts it as a child so the queue lives and dies with the world.
static func mount(main) -> ClickPickQueue:
	var q := ClickPickQueue.new()
	q.name = "ClickPickQueue"
	q._main = main
	main.add_child(q)
	return q


# Buffer one click. `sink` receives the resolved target id — a peer/mob id, NPC_CLICK when an NPC
# body was hit, or -1 for "nothing targetable". Callers needing the click position (or any other
# context) at resolve time carry it through Callable.bind, which appends after the id.
func submit(screen_pos: Vector2, sink: Callable) -> void:
	_pending.append({"pos": screen_pos, "sink": sink})


# main's own left-click policy. It lives here rather than in main.gd because main.gd sits at the
# 1000-line cap — the same carve-out idiom PartyInviteFlow already uses.
func submit_target_click(screen_pos: Vector2) -> void:
	submit(screen_pos, _apply_target_pick)


func pending() -> int:  # test accessor: clicks captured but not yet resolved
	return _pending.size()


func _physics_process(_delta: float) -> void:
	drain()


# Split out of _physics_process so a test can step the queue deterministically instead of racing the
# engine's callback. Production never calls this directly.
func drain() -> void:
	if _pending.is_empty():
		return
	# Swapped BEFORE dispatch: a sink that submits a fresh click gets the NEXT tick, so a
	# click-begets-click handler can never spin this loop.
	var batch := _pending
	_pending = []
	var cam: Camera3D = _main.get_viewport().get_camera_3d() if _main != null else null
	if cam == null:
		return  # no camera means no ray; dropping beats reporting a false "you hit nothing"
	var entities: Dictionary = (
		_main.remote_entities.get("_entities") if _main.remote_entities != null else {}
	)
	for entry: Dictionary in batch:
		var sink: Callable = entry["sink"]
		if not sink.is_valid():
			continue  # the sink's object was freed between the click and this tick
		sink.call(TargetSelection.target_id_for_click(cam, entry["pos"], entities, _main.npc_world))


# T-057: left-click empty ground → deselect (like Esc). A click that hit an entity selects it, and
# an NPC body belongs to its own talk handler, which leaves the combat target alone.
func _apply_target_pick(picked: int) -> void:
	if picked == TargetSelection.NPC_CLICK:
		return
	if picked != -1:
		_main._on_entity_clicked(picked)
		return
	_main._clear_target()
