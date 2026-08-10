extends GutTest
# T-265: the player cast bar's pure state machine (empty -> casting -> done | cancelled),
# driven off the broadcast cast truth and locally interpolated. No scene tree needed — the
# render path guards on null nodes, so update_cast() alone exercises every transition.

const PlayerCastBar = preload("res://scripts/ui/player_cast_bar.gd")

const _CAST := {"ability_id": 5, "remaining_s": 2.0, "total_s": 2.0}


# T-756: `.new()` with no autofree leaked one orphan PlayerCastBar per call — eight per run
# from the state-machine tests below, which never add the bar to the tree. Orphans are exactly
# the noise that trains people to ignore GUT's orphan counter, so the counter stops being able
# to report a real leak. Registering here covers every caller; _tree_bar() therefore uses a
# plain add_child, because registering the same node with GUT twice frees it twice.
func _bar() -> PlayerCastBar:
	var b: PlayerCastBar = PlayerCastBar.new()
	b.set_ability_names({5: "Frostbolt"})
	return autofree(b)


func test_starts_casting_from_empty() -> void:
	var b := _bar()
	b.update_cast(_CAST, 0.0)
	assert_true(b.is_active(), "a non-empty cast makes the bar active")
	assert_eq(b.ability_id(), 5)
	assert_almost_eq(b.fill_ratio(), 0.0, 0.01, "fresh cast is empty")


func test_interpolates_between_broadcasts() -> void:
	var b := _bar()
	b.update_cast(_CAST, 0.0)
	# same broadcast dict repeated (remaining_s unchanged) -> local interpolation
	b.update_cast(_CAST, 0.5)
	assert_almost_eq(b.remaining(), 1.5, 0.01, "remaining ticks down locally by dt")
	assert_almost_eq(b.fill_ratio(), 0.25, 0.01)


func test_resyncs_to_a_fresh_broadcast() -> void:
	var b := _bar()
	b.update_cast(_CAST, 0.0)
	b.update_cast(_CAST, 0.9)  # drift local to ~1.1
	# a fresh broadcast with authoritative remaining snaps us back
	b.update_cast({"ability_id": 5, "remaining_s": 1.0, "total_s": 2.0}, 0.0)
	assert_almost_eq(b.remaining(), 1.0, 0.01, "snap to server truth on a fresh tick")


func test_completes_and_hides() -> void:
	var b := _bar()
	b.update_cast({"ability_id": 5, "remaining_s": 0.1, "total_s": 2.0}, 0.0)
	b.update_cast({}, 0.0)  # cast dict gone with almost no time left -> completed
	assert_false(b.is_active())
	assert_false(b.is_flashing(), "a clean completion does not flash")


func test_cancellation_flashes() -> void:
	var b := _bar()
	b.update_cast(_CAST, 0.0)  # 2.0s remaining
	b.update_cast({}, 0.0)  # vanished with lots of time left -> interrupted
	assert_false(b.is_active())
	assert_true(b.is_flashing(), "an early vanish flashes the bar")


func test_flash_decays() -> void:
	var b := _bar()
	b.update_cast(_CAST, 0.0)
	b.update_cast({}, 0.0)
	assert_true(b.is_flashing())
	b.update_cast({}, PlayerCastBar.FLASH_TIME)  # let the flash timer run out
	assert_false(b.is_flashing(), "flash clears after FLASH_TIME")


func test_new_cast_of_same_ability_restarts() -> void:
	var b := _bar()
	b.update_cast({"ability_id": 5, "remaining_s": 0.2, "total_s": 2.0}, 0.0)
	# same ability id but remaining jumps back up -> a brand new cast, not interpolation
	b.update_cast({"ability_id": 5, "remaining_s": 2.0, "total_s": 2.0}, 0.0)
	assert_almost_eq(b.remaining(), 2.0, 0.01, "a re-cast restarts the fill")
	assert_almost_eq(b.fill_ratio(), 0.0, 0.01)


func test_switching_ability_adopts_new_cast() -> void:
	var b := _bar()
	b.update_cast(_CAST, 0.0)
	b.update_cast({"ability_id": 9, "remaining_s": 3.0, "total_s": 3.0}, 0.0)
	assert_eq(b.ability_id(), 9, "a different ability replaces the current cast")
	assert_almost_eq(b.remaining(), 3.0, 0.01)


# ---- T-748: the 320x22 click blackhole ----------------------------------------------------------
#
# The root was already IGNORE, but `_bar` (ProgressBar, PRESET_FULL_RECT, default STOP) spans the
# whole bar — so mid-cast, every click inside that band was eaten and never reached the world. The
# exact bug xp_bar.gd:48-50 documents as fixed. Nothing on this bar is ever clickable.


func _tree_bar() -> PlayerCastBar:
	var b := _bar()  # already autofree-registered
	add_child(b)
	return b


func test_every_child_ignores_the_mouse() -> void:
	var b := _tree_bar()
	assert_eq(b.mouse_filter, Control.MOUSE_FILTER_IGNORE, "the root never eats a click")
	var pending: Array = b.get_children()
	assert_gt(pending.size(), 0, "the bar really did build its children")
	while not pending.is_empty():
		var node: Node = pending.pop_back()
		if node is Control:
			assert_eq(
				(node as Control).mouse_filter,
				Control.MOUSE_FILTER_IGNORE,
				"%s inside an idle HUD bar must not eat a click" % node.name
			)
		pending.append_array(node.get_children())


func test_click_in_the_cast_band_reaches_the_world_mid_cast() -> void:
	var sv := SubViewport.new()
	sv.size = Vector2i(1280, 720)
	add_child_autofree(sv)
	var world := Control.new()  # stands in for the world/HUD under the bar; added FIRST
	world.set_anchors_preset(Control.PRESET_FULL_RECT)
	var got: Array = []
	world.gui_input.connect(func(ev: InputEvent): got.append(ev))
	sv.add_child(world)
	var b := _bar()
	sv.add_child(b)
	b.update_cast(_CAST, 0.0)  # mid-cast: the bar is visible and covers its band
	await get_tree().process_frame
	assert_true(b.visible, "the bar is up — the blackhole only existed while casting")
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = true
	ev.position = b.get_global_rect().get_center()
	sv.push_input(ev)
	await get_tree().process_frame
	assert_eq(got.size(), 1, "a click inside the cast band passes straight through the bar")
