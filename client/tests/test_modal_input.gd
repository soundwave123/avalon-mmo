extends "res://addons/gut/test.gd"
# T-718 (portal #108): ModalInput — the shared click plumbing that makes a creation modal's CLICK
# path behave exactly like its key path. Pure rect math + a tree-order raise, both headless-safe.


func _button_at(rect: Rect2) -> Button:
	var button := Button.new()
	button.position = rect.position
	button.size = rect.size
	add_child(button)
	return button


func test_hit_index_finds_the_button_under_the_point() -> void:
	var first := _button_at(Rect2(0, 0, 100, 20))
	var second := _button_at(Rect2(0, 30, 100, 20))
	assert_eq(ModalInput.hit_index([first, second], Vector2(50, 10)), 0)
	assert_eq(ModalInput.hit_index([first, second], Vector2(50, 40)), 1)


func test_hit_index_is_minus_one_off_every_button() -> void:
	var only := _button_at(Rect2(0, 0, 100, 20))
	assert_eq(ModalInput.hit_index([only], Vector2(400, 400)), -1, "a miss must not pick a row")
	assert_eq(ModalInput.hit_index([], Vector2(0, 0)), -1, "an empty row list is a clean miss")


func test_hit_index_skips_hidden_buttons() -> void:
	var hidden := _button_at(Rect2(0, 0, 100, 20))
	hidden.visible = false
	assert_eq(ModalInput.hit_index([hidden], Vector2(50, 10)), -1, "hidden rows are not clickable")


func test_hit_index_tolerates_nulls_in_the_row_list() -> void:
	var real := _button_at(Rect2(0, 30, 100, 20))
	assert_eq(ModalInput.hit_index([null, real], Vector2(50, 40)), 1)


# The picking half of the fix: z_index wins the DRAW, tree order wins the PICK — so a modal built
# early in $HUD has to re-order itself to the end while it is up.
func test_raise_to_front_moves_the_node_last_among_its_siblings() -> void:
	var parent := Control.new()
	add_child(parent)
	var modal := Control.new()
	parent.add_child(modal)
	var later := Control.new()
	parent.add_child(later)
	assert_eq(parent.get_child(1), later, "precondition: the modal is NOT last")
	ModalInput.raise_to_front(modal)
	assert_eq(parent.get_child(1), modal, "the modal now wins GUI picking")
	ModalInput.raise_to_front(modal)  # idempotent
	assert_eq(parent.get_child(1), modal)
	parent.queue_free()


func test_raise_to_front_is_a_safe_no_op_outside_the_tree() -> void:
	var orphan := Control.new()
	ModalInput.raise_to_front(orphan)  # must not error
	ModalInput.raise_to_front(null)
	assert_true(true, "no crash on an orphan / null control")
	orphan.queue_free()
