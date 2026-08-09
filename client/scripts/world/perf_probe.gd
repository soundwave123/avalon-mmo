extends Node

# T-692 diagnostic profiler (AVALON_PERF=1 only). Two jobs: (1) an on-screen overlay so a player
# sees live FPS/frametime/CPU-vs-physics/counts while playing, and (2) a once-per-second `[perf]`
# breakdown line to the log so the frame bottleneck can be read offline (process vs physics vs
# render, node/collider counts, draw calls, VRAM). Off by default — installed by main._enter_world
# only when AVALON_PERF=1, so it never touches normal play or the test suite.

var _label: Label
var _accum := 0.0
var _frames := 0
var _worst_frame_ms := 0.0


func _ready() -> void:
	set_process(true)
	var layer := CanvasLayer.new()
	layer.layer = 200  # above the HUD
	add_child(layer)
	_label = Label.new()
	_label.position = Vector2(14, 14)
	_label.add_theme_color_override("font_color", Color(0.55, 1.0, 0.55))
	_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	_label.add_theme_constant_override("outline_size", 4)
	_label.add_theme_font_size_override("font_size", 15)
	layer.add_child(_label)


func _process(delta: float) -> void:
	_accum += delta
	_frames += 1
	_worst_frame_ms = maxf(_worst_frame_ms, delta * 1000.0)
	if _accum < 1.0:
		return
	var fps := float(_frames) / _accum
	var frame_ms := 1000.0 / maxf(fps, 0.001)
	var proc_ms := Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
	var phys_ms := Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
	var nodes := int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))
	var orphans := int(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT))
	var draws := int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
	var prims := int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME))
	var robjs := int(Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME))
	var phys_active := int(Performance.get_monitor(Performance.PHYSICS_3D_ACTIVE_OBJECTS))
	var phys_pairs := int(Performance.get_monitor(Performance.PHYSICS_3D_COLLISION_PAIRS))
	var vmem_mb := Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0
	var smem_mb := Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0

	print(
		(
			(
				"[perf] fps=%.1f frame=%.1fms worst=%.0fms | process=%.2fms physics=%.2fms"
				+ " | nodes=%d orphans=%d | draw=%d prims=%d robjs=%d | phys_active=%d pairs=%d"
				+ " | vram=%.0fMB static=%.0fMB"
			)
			% [
				fps,
				frame_ms,
				_worst_frame_ms,
				proc_ms,
				phys_ms,
				nodes,
				orphans,
				draws,
				prims,
				robjs,
				phys_active,
				phys_pairs,
				vmem_mb,
				smem_mb
			]
		)
	)
	if is_instance_valid(_label):
		_label.text = (
			(
				"FPS %.0f   frame %.1fms   worst %.0fms\n"
				+ "process %.2fms   physics %.2fms\n"
				+ "nodes %d   draw %d   prims %s\n"
				+ "phys %d/%d   vram %.0fMB"
			)
			% [
				fps,
				frame_ms,
				_worst_frame_ms,
				proc_ms,
				phys_ms,
				nodes,
				draws,
				_short(prims),
				phys_active,
				phys_pairs,
				vmem_mb
			]
		)
	_accum = 0.0
	_frames = 0
	_worst_frame_ms = 0.0


static func _short(n: int) -> String:
	if n >= 1000000:
		return "%.1fM" % (float(n) / 1000000.0)
	if n >= 1000:
		return "%.0fk" % (float(n) / 1000.0)
	return str(n)
