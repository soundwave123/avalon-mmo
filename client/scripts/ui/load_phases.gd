class_name LoadPhases
# T-691: the static login-phase bus (this project has no autoloads — same static-state idiom as
# boot_clock.gd). Boot code stamps begin/end/progress marks; every mark prints one greppable
# `[loadphase]` line (the headless E2E proof hook) and notifies listeners (the loading screen).
# P2-P5 of the login are ONE synchronous call chain off the `authenticated` callback — Godot paints
# NOTHING while the main thread never returns to the loop — so cut() also yields a single frame at
# each phase seam (live only) to let the screen repaint. Headless takes the no-await branch, so the
# harness boot order (pilot/smoke/observe) stays byte-equivalent apart from the added prints.

extends Object

static var _listeners: Array = []  # Callables: (kind: String, phase: String, data: Dictionary)
static var _begun: Dictionary = {}  # phase -> begin ticks_ms (first begin wins)
static var _ended: Dictionary = {}  # phase -> end ticks_ms (first end wins)
static var _open := ""  # the coarse phase cut() is currently driving


static func add_listener(cb: Callable) -> void:
	if not _listeners.has(cb):
		_listeners.append(cb)


static func remove_listener(cb: Callable) -> void:
	_listeners.erase(cb)


# Statics outlive a login (and a test) — called at boot-screen mount and from test hygiene. The
# "reset" notify lets a stale loading screen (a wedged first attempt superseded by a T-511
# reconnect login) dismiss itself instead of sitting opaque over the world forever.
static func reset() -> void:
	_notify("reset", "", {})
	_listeners.clear()
	_begun.clear()
	_ended.clear()
	_open = ""


static func begin(phase: String) -> void:
	if _begun.has(phase):
		return
	_begun[phase] = Time.get_ticks_msec()
	print("[loadphase] %s begin t=%d" % [phase, int(_begun[phase])])
	_notify("begin", phase, {})


static func end(phase: String) -> void:
	if not _begun.has(phase) or _ended.has(phase):
		return
	_ended[phase] = Time.get_ticks_msec()
	var dt := int(_ended[phase]) - int(_begun[phase])
	print("[loadphase] %s end t=%d dt=%d" % [phase, int(_ended[phase]), dt])
	_notify("end", phase, {})


# Real intra-phase progress (T-688 queue: props placed vs queued). Listener-only — a print per
# drained item would spam every frame of the populate.
static func progress(phase: String, done: int, total: int) -> void:
	_notify("progress", phase, {"done": done, "total": total})


# Wrap ONE synchronous call in begin/end marks without costing its call site a line (world_view
# sits at the 999/1000-line cap; `_build_ground()` becomes `LoadPhases.timed("terrain", ...)`).
static func timed(phase: String, work: Callable) -> void:
	begin(phase)
	work.call()
	end(phase)


# Phase seam: close the previous cut phase, open the next, and (live) yield one frame so the
# loading screen paints the new status before the phase's synchronous work freezes the loop.
# Headless never awaits — the whole login chain stays synchronous there, and awaiting a call that
# returned without suspending continues immediately, so `await cut(...)` is order-safe both ways.
static func cut(node: Node, next: String) -> void:
	cut_now(next)
	if node != null and node.is_inside_tree() and DisplayServer.get_name() != "headless":
		await node.get_tree().process_frame


# The seam without the repaint yield — for event/RPC contexts that must not suspend.
static func cut_now(next: String) -> void:
	if _open != "":
		end(_open)
	_open = next
	begin(next)


# Mount the loading screen (live only) and give it two frames to paint before the world build
# freezes the main thread. Headless: pure no-op beyond resetting bus state — no screen, no awaits.
static func boot_screen(hud: Node) -> void:
	reset()
	if DisplayServer.get_name() == "headless" or hud == null:
		return
	var screen: Control = (load("res://scripts/ui/loading_screen.gd") as GDScript).new()
	screen.name = "LoadingScreen"
	hud.add_child(screen)
	await hud.get_tree().process_frame
	await hud.get_tree().process_frame


static func _notify(kind: String, phase: String, data: Dictionary) -> void:
	for cb: Callable in _listeners.duplicate():  # a listener may remove itself mid-dispatch
		if cb.is_valid():
			cb.call(kind, phase, data)
