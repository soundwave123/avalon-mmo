extends GutTest

# T-120: pure RenderStats.format_line — the one-line [lod] instrumentation the orchestrator's
# qa-tour logs. Tested on injected values (no rendering context); snapshot() is the thin live
# wrapper over Performance monitors + world_props_layer, verified in-world by qa-tour (deferred).

const RenderStats = preload("res://scripts/world/render_stats.gd")


func test_format_line_reports_all_fields() -> void:
	var line := RenderStats.format_line(1200, 850000, 7, 3)
	assert_string_contains(line, "draw_calls=1200")
	assert_string_contains(line, "primitives=850000")
	assert_string_contains(line, "impostors=7/10")


func test_percent_of_impostorable_trees() -> void:
	assert_string_contains(RenderStats.format_line(0, 0, 7, 3), "(70%")
	assert_string_contains(RenderStats.format_line(0, 0, 0, 4), "(0%")
	assert_string_contains(RenderStats.format_line(0, 0, 4, 0), "(100%")


func test_no_impostorable_trees_is_zero_not_a_divide_by_zero() -> void:
	# No impostorable props at all -> 0/0, must read 0% and never crash.
	var line := RenderStats.format_line(500, 100, 0, 0)
	assert_string_contains(line, "impostors=0/0")
	assert_string_contains(line, "(0%")
