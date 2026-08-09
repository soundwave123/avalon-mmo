extends "res://addons/gut/test.gd"


func test_focused_input_placeholder_is_typing_prompt() -> void:
	var panel := ChatPanel.new()
	add_child_autofree(panel)
	await get_tree().process_frame

	panel._on_input_focus_entered()
	assert_eq(
		panel._input_box.placeholder_text, "Type a message...", "focused chat shows a typing prompt"
	)
	panel._on_input_focus_exited()
	assert_eq(
		panel._input_box.placeholder_text, "Press Enter to chat", "idle chat keeps the summon hint"
	)
