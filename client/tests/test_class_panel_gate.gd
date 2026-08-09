extends GutTest

# T-320: the class-selection panel stuck open after the class-locked ack. Root cause: the client
# had no memory of "already locked," so a stale/duplicate class_kit resend claiming
# class_locked=false (racing the real lock, or a T-208-style kit refresh) could reopen it. Fix:
# ClassPanelGate — a monotonic locked latch (class_locked only ever flips false->true in a live
# session; reroll deletes the character row and reconnects fresh — a brand-new latch).

const ClassPanelGate = preload("res://scripts/ui/class_panel_gate.gd")


func test_fresh_character_flow_shows_panel() -> void:
	# Session start: latch false. An unlocked class_kit (fresh character) opens the panel.
	var gate: Dictionary = ClassPanelGate.next_visible(false, false)
	assert_false(gate["locked"])
	assert_true(gate["visible"], "an unlocked ack must open the panel for a fresh character")


func test_locked_ack_hides_panel() -> void:
	var gate: Dictionary = ClassPanelGate.next_visible(false, true)
	assert_true(gate["locked"])
	assert_false(gate["visible"], "a class_locked=true ack must hide the panel")


func test_stale_unlocked_broadcast_does_not_reopen_after_locked() -> void:
	# The class-locked ack lands first (set_class_result ok / class_kit locked=true)...
	var locked_gate: Dictionary = ClassPanelGate.next_visible(false, true)
	assert_false(locked_gate["visible"])
	# ...then a stale/duplicate broadcast claims class_locked=false again (the T-320 race).
	var stale_gate: Dictionary = ClassPanelGate.next_visible(locked_gate["locked"], false)
	assert_true(stale_gate["locked"], "the latch stays locked once set")
	assert_false(stale_gate["visible"], "a later false ack must NOT reopen an already-locked panel")


func test_reroll_is_a_fresh_session_with_its_own_latch() -> void:
	# Reroll (T-065) deletes the character row and reconnects — a brand-new client session
	# starts its latch at false again, so the fresh unlocked class_kit opens the panel exactly
	# like a first-time character.
	var fresh_session_gate: Dictionary = ClassPanelGate.next_visible(false, false)
	assert_true(fresh_session_gate["visible"], "reroll's fresh session must still offer the panel")
