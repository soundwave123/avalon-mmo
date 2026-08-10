extends GutTest

# T-518: spamming SPACE (jump) must never open the help/onboarding handbook. Two collisions are
# guarded here:
#   1) The always-visible "?" HelpAffordance is a Button. Godot's default ui_accept is Space+Enter,
#      so a keyboard-focusable "?" fires its pressed->toggle() on SPACE and pops the handbook while
#      the player is jumping. It must be FOCUS_NONE (mouse-only), like the chat tabs.
#   2) The controller's own _input toggles the card on the help key ONLY (F1), never on SPACE.

const OnboardingController = preload("res://scripts/ui/onboarding_controller.gd")
const ControlsReference = preload("res://scripts/ui/controls_reference.gd")


func _make() -> OnboardingController:
	# A bare HUD host: setup() parents the controller + card + "?" under it.
	var hud := Control.new()
	add_child_autofree(hud)
	var oc := OnboardingController.new()
	oc.setup(hud, null)
	return oc


func _help_button(oc: OnboardingController) -> Button:
	return oc.get_parent().get_node("HelpAffordance") as Button


func _key(code: int) -> InputEventKey:
	var e := InputEventKey.new()
	e.keycode = code
	e.physical_keycode = code  # T-761: the controller dispatches on the PHYSICAL code
	e.pressed = true
	return e


func test_help_affordance_is_mouse_only() -> void:
	var oc := _make()
	var btn := _help_button(oc)
	assert_not_null(btn, "the '?' help affordance is built under the HUD")
	assert_eq(
		btn.focus_mode,
		Control.FOCUS_NONE,
		"the '?' must not take keyboard focus, or SPACE (ui_accept) would toggle the handbook"
	)


func test_space_does_not_open_the_handbook() -> void:
	var oc := _make()
	assert_false(oc.card.visible, "handbook starts hidden")
	oc._input(_key(KEY_SPACE))
	assert_false(oc.card.visible, "SPACE (jump) must never open the help handbook")


func test_help_key_still_toggles_the_handbook() -> void:
	# The intended opener (F1) still works — we fixed SPACE without breaking help.
	var oc := _make()
	assert_false(oc.card.visible, "handbook starts hidden")
	oc._input(_key(ControlsReference.help_keycode()))
	assert_true(oc.card.visible, "the help key (F1) opens the handbook")
	oc._input(_key(ControlsReference.help_keycode()))
	assert_false(oc.card.visible, "the help key toggles the handbook closed again")


# T-532: the idle "?" must read as an outlined HUD hint, not an opaque gray box. Its normal
# stylebox carries NO flat fill and NO border (the de-boxed T-460 idiom), and the glyph gets its
# legibility from an outline — not a panel. FOCUS_NONE (T-518) is re-asserted here as the guard.
func test_help_affordance_is_deboxed() -> void:
	var oc := _make()
	var btn := _help_button(oc)
	var normal := btn.get_theme_stylebox("normal")
	assert_true(
		normal is StyleBoxEmpty,
		"the idle '?' must have no opaque StyleBoxFlat fill (de-boxed to the T-460 idiom)"
	)
	assert_false(normal is StyleBoxFlat, "the idle '?' must carry no flat panel fill / border")
	assert_gt(
		btn.get_theme_constant("outline_size"),
		0,
		"the '?' glyph's legibility must live in a text outline, not a panel fill"
	)
	assert_eq(
		btn.focus_mode,
		Control.FOCUS_NONE,
		"de-boxing must NOT re-introduce keyboard focus (T-518 regression guard)"
	)
