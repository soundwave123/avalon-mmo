class_name PilotCreation
# T-623: `create_character` — the full gender+class modal dance as ONE op. Replaces the hand-rolled
# key/poll/key/poll dance (world-knowledge boot recipe) whose keypress could be EATEN across the
# gender->class transition. Clicks the named Button directly (click_node-style) instead of raw
# keycodes, and polls panel-visibility to verify each step actually landed — no blind keypresses.
# next_action() is a PURE state-machine (unit-tested, see test_pilot_creation.gd); run() is the live
# click-and-poll driver. Kept out of pilot.gd to hold it under the 1000-line house cap.
#
# T-716 adds the NAME step (gender -> class -> name), which is the first creation modal that is not
# a row of buttons: it is typed. So `name` is optional — omit it and the op stops as soon as the
# name modal appears (the caller can then drive the field itself), pass it and the op types it and
# waits for the modal to clear like every other step.

extends RefCounted

# T-716: shared module — preloaded, never class_name (its copies would collide).
const CharacterName = preload("res://scripts/ui/character_name.gd")

const _STEP_TIMEOUT_MS := 8000
const _MAX_STEPS := 8  # dismiss handbook + gender + class + name + slack; guards a runaway loop

# ---- PURE (unit-tested) -----------------------------------------------------------------------


# Decide the next action from a `_dump_state()`-shaped snapshot. The Handbook check takes priority
# over gender/class/name: s25 ground truth found it can render OVER those panels and silently eat
# their clicks, so it must be dismissed first whenever it's up.
static func next_action(state: Dictionary) -> String:
	if bool(state.get("controls_card_visible", false)):
		return "dismiss_handbook"
	if bool(state.get("gender_panel_visible", false)):
		return "click_gender"
	if bool(state.get("class_panel_visible", false)):
		return "click_class"
	if bool(state.get("name_panel_visible", false)):
		return "type_name"  # T-716
	return "done"


# ---- LIVE ---------------------------------------------------------------------------------------


# `cmd` is the raw pilot op dict: {gender, class, name?}. Case is folded here (one place) so
# pilot.gd's dispatch stays a single line under its own file cap.
static func run(pilot, cmd: Dictionary) -> Dictionary:
	var gender := str(cmd.get("gender", "")).to_lower()
	var class_id := str(cmd.get("class", "")).to_lower()
	var char_name := CharacterName.normalize(str(cmd.get("name", "")))
	if gender == "" or class_id == "":
		return {"ok": false, "error": "gender and class are required"}
	var steps: Array = []
	for _i in range(_MAX_STEPS):
		var action := next_action(pilot._dump_state())
		var button := ""
		var visible_key := ""
		match action:
			"done":
				return {
					"ok": true,
					"gender": gender,
					"class": class_id,
					"name": char_name,
					"steps": steps,
				}
			"dismiss_handbook":
				button = "ControlsClose"
				visible_key = "controls_card_visible"
			"click_gender":
				button = "Btn_%s" % gender
				visible_key = "gender_panel_visible"
			"click_class":
				button = "Btn_%s" % class_id
				visible_key = "class_panel_visible"
			"type_name":  # T-716: typed, not clicked — see the header
				if char_name == "":
					steps.append("name modal up; no name argument given")
					return {
						"ok": true,
						"gender": gender,
						"class": class_id,
						"name": "",
						"name_pending": true,
						"steps": steps,
					}
				if not await _type_name_and_wait(pilot, char_name, steps):
					return {
						"ok": false, "error": "type_name: '%s' rejected" % char_name, "steps": steps
					}
				continue
		if not await _click_and_wait(pilot, button, visible_key, steps):
			return {
				"ok": false, "error": "%s: '%s' didn't respond" % [action, button], "steps": steps
			}
	return {"ok": false, "error": "exceeded step guard", "steps": steps}


# Click the named visible Control (searched tree-wide, like the `click_node` op) and poll
# `visible_key` off `_dump_state()` until it clears — the arrival-verification for a UI transition,
# same honesty principle as goto's arrival check.
static func _click_and_wait(pilot, button_name: String, visible_key: String, steps: Array) -> bool:
	var btn: Variant = pilot._find_visible_control(pilot.get_tree().root, button_name)
	if btn == null:
		steps.append("%s not found" % button_name)
		return false
	# A modal becomes visible_in_tree BEFORE its layout pass runs, so the rect read on that frame
	# can still be degenerate — clicking its "center" then lands somewhere else entirely and the
	# step silently does nothing. Wait for a laid-out, stable rect before synthesizing the click.
	var rect := await _settled_rect(pilot, btn as Control)
	if rect.size == Vector2.ZERO:
		steps.append("%s never laid out" % button_name)
		return false
	pilot._click_at(rect.get_center())
	steps.append("clicked %s" % button_name)
	return await _wait_cleared(pilot, visible_key, steps)


# The control's global rect once it stops changing (two identical non-zero reads), or a zero rect
# if it never settles within the budget.
static func _settled_rect(pilot, control: Control, max_frames: int = 30) -> Rect2:
	var last := Rect2()
	for _i in range(max_frames):
		await pilot.get_tree().process_frame
		var now := control.get_global_rect()
		if now.size.x > 0.0 and now.size.y > 0.0 and now == last:
			return now
		last = now
	return Rect2()


# T-716: the name step. The field is set DIRECTLY (a real LineEdit, so per-character key synthesis
# would be slow and flaky) and the panel's own Confirm button is clicked, so the same validation +
# server round-trip a human triggers runs here. A rejection (duplicate name, bad charset) leaves
# the modal up, which the poll reports honestly as a failure instead of a silent false success.
static func _type_name_and_wait(pilot, char_name: String, steps: Array) -> bool:
	var field: Variant = pilot._find_visible_control(pilot.get_tree().root, "NameField")
	var confirm: Variant = pilot._find_visible_control(pilot.get_tree().root, "Btn_confirm")
	if field == null or confirm == null:
		steps.append("name field/confirm not found")
		return false
	(field as LineEdit).text = char_name
	(field as LineEdit).text_changed.emit(char_name)
	var rect := await _settled_rect(pilot, confirm as Control)  # same layout race as the rows
	if rect.size == Vector2.ZERO:
		steps.append("Btn_confirm never laid out")
		return false
	pilot._click_at(rect.get_center())
	steps.append("typed name '%s' + confirmed" % char_name)
	return await _wait_cleared(pilot, "name_panel_visible", steps)


static func _wait_cleared(pilot, visible_key: String, steps: Array) -> bool:
	var deadline := Time.get_ticks_msec() + _STEP_TIMEOUT_MS
	while bool(pilot._dump_state().get(visible_key, false)):
		if Time.get_ticks_msec() >= deadline:
			steps.append("%s still visible %dms after the step" % [visible_key, _STEP_TIMEOUT_MS])
			return false
		await pilot.get_tree().process_frame
	return true
