extends GutTest

# T-520: GenderPanelGate — the pure visibility + creation-ORDER decision. Gender is chosen FIRST,
# before class; the latch is monotonic (mirrors ClassPanelGate/T-320) so a stale class_kit resend
# carrying an empty gender can't reopen the panel after a successful pick.

const GenderPanelGate = preload("res://scripts/ui/gender_panel_gate.gd")
const ClassPanelGate = preload("res://scripts/ui/class_panel_gate.gd")


func test_fresh_character_shows_gender_panel() -> void:
	# Session start: latch false. A class_kit with no gender opens the gender panel.
	var gate: Dictionary = GenderPanelGate.next_visible(false, false)
	assert_false(gate["chosen"])
	assert_true(gate["visible"], "a character with no gender must see the gender panel")


func test_gender_present_hides_panel() -> void:
	var gate: Dictionary = GenderPanelGate.next_visible(false, true)
	assert_true(gate["chosen"])
	assert_false(gate["visible"], "a class_kit that carries a gender must hide the gender panel")


func test_stale_empty_resend_does_not_reopen_after_chosen() -> void:
	# The gender ack lands (set_gender_result ok / class_kit with gender set)...
	var chosen_gate: Dictionary = GenderPanelGate.next_visible(false, true)
	assert_false(chosen_gate["visible"])
	# ...then a stale/duplicate class_kit resend carries gender="" again.
	var stale: Dictionary = GenderPanelGate.next_visible(chosen_gate["chosen"], false)
	assert_true(stale["chosen"], "the latch stays chosen once set")
	assert_false(stale["visible"], "a later empty resend must NOT reopen the gender panel")


# The creation ORDER: the class panel appears ONLY after gender is chosen. This is the
# gender -> class ordering guarantee (login -> gender -> class -> world).
func test_class_panel_is_gated_behind_gender() -> void:
	# Fresh character, no gender yet: class_kit says class unlocked, but gender not chosen.
	var class_gate: Dictionary = ClassPanelGate.next_visible(false, false)
	assert_true(class_gate["visible"], "class latch alone would show it")
	assert_false(
		GenderPanelGate.class_visible(bool(class_gate["visible"]), false),
		"class panel must stay hidden until gender is chosen (order: gender first)"
	)
	assert_true(
		GenderPanelGate.class_visible(bool(class_gate["visible"]), true),
		"once gender is chosen, the still-unlocked class panel appears"
	)


func test_gender_chosen_but_class_locked_shows_neither() -> void:
	# Reroll edge / returning classed character: gender set AND class already locked -> world loads,
	# no panels.
	var class_gate: Dictionary = ClassPanelGate.next_visible(false, true)
	assert_false(
		GenderPanelGate.class_visible(bool(class_gate["visible"]), true),
		"a locked class shows no class panel even with gender chosen"
	)
