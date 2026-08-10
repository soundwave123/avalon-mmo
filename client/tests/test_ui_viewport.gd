extends "res://addons/gut/test.gd"
# T-747: the stretch keys are the load-bearing part of the UI's coordinate contract, and they live
# in project.godot — a file the editor rewrites wholesale on any settings change. Nothing else in
# the suite would notice if a regen silently dropped them; the HUD would just quietly go back to
# being pixel-mapped and ~0.45% of a 4K screen. These tests are that alarm.
#
# They also pin the two-space arithmetic in ui_viewport.gd against the live engine rather than
# against my reading of the manual, so a 4.7 -> 4.8 change in how content scaling composes shows
# up here instead of as mysteriously misplaced pilot clicks.


func test_project_declares_canvas_items_stretch_at_the_authored_base() -> void:
	assert_eq(
		str(ProjectSettings.get_setting("display/window/stretch/mode", "")),
		"canvas_items",
		"UI stretch must stay on — without it the HUD is pixel-mapped again (T-747)",
	)
	assert_eq(
		str(ProjectSettings.get_setting("display/window/stretch/aspect", "")),
		"expand",
		"expand shows MORE world on ultrawide instead of letterboxing",
	)
	assert_eq(
		UiViewport.base_size(),
		Vector2(1280.0, 720.0),
		"the content base every HudSafeZone constant and all 91 UI files were authored against",
	)


func test_the_os_window_still_opens_at_a_sensible_size() -> void:
	# The base is the CONTENT size, not the window. Without the overrides the client would open as
	# a 1280x720 window on the owner's 1920x1080+ monitor.
	assert_eq(
		UiViewport.window_size(),
		Vector2i(1920, 1080),
		"the shipped window stays 1920x1080 while the content base is 1280x720",
	)
	var base := UiViewport.base_size()
	var win := UiViewport.window_size()
	assert_almost_eq(
		float(win.x) / float(win.y),
		base.x / base.y,
		0.001,
		"window and base share an aspect, so the shipped client's content is exactly the base",
	)


func test_normalising_the_headless_root_yields_exactly_the_authored_base() -> void:
	# A headless window boots ~64x64, and under `expand` that squashes the content rect to the
	# window's aspect (1280x1280, not 1280x720). Normalising to the shipped window size restores
	# the real base — this is what makes the unpinned HUD tests honest.
	UiViewport.normalize_headless(self)
	await get_tree().process_frame
	var root := get_tree().root
	assert_eq(
		root.get_visible_rect().size,
		UiViewport.base_size(),
		"the live content rect IS the authored base once the window is normalised",
	)


func test_content_and_window_spaces_convert_both_ways() -> void:
	UiViewport.normalize_headless(self)
	await get_tree().process_frame
	var vp := get_viewport()
	var scale := UiViewport.content_scale(vp)
	assert_almost_eq(scale, 1.5, 0.001, "1920 window over a 1280 base is a 1.5x canvas stretch")
	# The content centre is the window centre — the single conversion most likely to be skipped
	# because it "looks like it already works" (both are centres; the NUMBERS differ).
	assert_almost_eq(
		UiViewport.content_to_window(vp, Vector2(640.0, 360.0)),
		Vector2(960.0, 540.0),
		Vector2(0.01, 0.01),
		"content centre maps to window centre, not to itself",
	)
	assert_almost_eq(
		UiViewport.window_to_content(vp, Vector2(960.0, 540.0)),
		Vector2(640.0, 360.0),
		Vector2(0.01, 0.01),
	)
	# Round-trip an arbitrary off-centre point: the two helpers must be exact inverses.
	var p := Vector2(137.0, 611.0)
	assert_almost_eq(
		UiViewport.window_to_content(vp, UiViewport.content_to_window(vp, p)),
		p,
		Vector2(0.01, 0.01),
		"content -> window -> content is the identity",
	)


func test_injected_event_positions_are_window_space_but_arrive_as_content_space() -> void:
	# The asymmetry ui_viewport.gd exists for, asserted against the live engine: what you SEND to
	# Input.parse_input_event is window space; what a Control RECEIVES is content space. If this
	# ever stops being true, every pilot click coordinate fix in this ticket is wrong.
	UiViewport.normalize_headless(self)
	await get_tree().process_frame
	var received: Array[Vector2] = []
	var probe := Control.new()
	probe.size = get_tree().root.get_visible_rect().size
	probe.mouse_filter = Control.MOUSE_FILTER_STOP
	probe.gui_input.connect(
		func(e: InputEvent) -> void:
			if e is InputEventMouseButton and (e as InputEventMouseButton).pressed:
				received.append((e as InputEventMouseButton).position)
	)
	get_tree().root.add_child(probe)
	await get_tree().process_frame

	var aimed_at_content_centre := UiViewport.content_to_window(get_viewport(), Vector2(640, 360))
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = true
	ev.position = aimed_at_content_centre
	ev.global_position = aimed_at_content_centre
	Input.parse_input_event(ev)
	Input.flush_buffered_events()
	await get_tree().process_frame

	probe.queue_free()
	assert_eq(received.size(), 1, "the synthesized press reached the probe control")
	if received.size() == 1:
		assert_almost_eq(
			received[0],
			Vector2(640.0, 360.0),
			Vector2(0.01, 0.01),
			"a converted injection lands where it was aimed, in content space",
		)
