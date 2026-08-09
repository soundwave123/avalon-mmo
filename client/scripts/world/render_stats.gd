# T-120: cheap render instrumentation for the T-210 FPS budget. A pure formatter (RefCounted,
# static) over Godot's built-in Performance monitors plus world_props_layer's live impostor/mesh
# split, so the orchestrator's qa-tour can log a single comparable `[lod]` line per station and
# watch the impostor win land. No pilot dependency here — the numbers come from Performance (which
# any running client exposes) + a count the props layer already tracks; this module only shapes
# them into one string so pilot.gd and qa-tour print the same thing.
#
# format_line() is unit-tested on injected values; snapshot() is the thin live wrapper.

extends RefCounted


# Shape a one-line snapshot. Inputs are injected so this is testable without a rendering context:
#   draw_calls / primitives — from Performance monitors
#   impostor / mesh — props currently drawn as billboard vs full mesh (world_props_layer)
static func format_line(draw_calls: int, primitives: int, impostor: int, mesh: int) -> String:
	var tree_total := impostor + mesh
	var pct := 0
	if tree_total > 0:
		pct = int(round(100.0 * float(impostor) / float(tree_total)))
	return (
		"[lod] draw_calls=%d primitives=%d impostors=%d/%d (%d%% of impostorable trees)"
		% [draw_calls, primitives, impostor, tree_total, pct]
	)


# Live snapshot from a running client. `props_layer` is the WorldPropsLayer (or null); the two
# Performance monitors are read here so callers don't have to know the enum names.
static func snapshot(props_layer) -> String:
	var draw_calls := int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
	var primitives := int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME))
	var impostor := 0
	var mesh := 0
	if props_layer != null and props_layer.has_method("impostor_split"):
		var split: Dictionary = props_layer.impostor_split()
		impostor = int(split.get("impostor", 0))
		mesh = int(split.get("mesh", 0))
	return format_line(draw_calls, primitives, impostor, mesh)
