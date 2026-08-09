class_name ModalInput
extends RefCounted

# T-718 (portal #108): shared click plumbing for the creation modals (ClassPanel / GenderPanel /
# NamePanel).
#
# ROOT CAUSE it exists for: Godot's GUI mouse picking walks the node tree in REVERSE CHILD ORDER
# and IGNORES z_index — z_index only decides what is DRAWN on top. ClassPanel and GenderPanel are
# added to $HUD early (main.gd builds ~15 more panels/overlays after them), so their z_index = 200
# wins the draw and LOSES the pick: any later, visible, full-rect MOUSE_FILTER_STOP sibling
# swallows the press while the modal still looks clickable. That is exactly the s25 Handbook
# overlap trap, and #108 is the same failure with a different overlay — the click never produced a
# `set_class` intent at all (the `class=warrior` seen in the DB is the BOOTSTRAP DEFAULT from
# character_manager.ensure_character; `class_locked` stayed false, which is the real tell).
#
# The KEY path never had the bug because `_input` runs BEFORE GUI picking, so nothing can sit
# "above" it. Both helpers below close the gap from the two ends:
#   * hit_index()     — lets a modal route a click in its own `_input`, i.e. the same stage the
#                       keys already use. Pure (rect math only), so it unit-tests headlessly.
#   * raise_to_front() — makes the modal the LAST child of its parent while it is up, so ordinary
#                       GUI picking (hover, focus, LineEdit carets) also resolves to it.


# Which of `buttons` contains `pos` (viewport/global GUI coordinates)? -1 = none of them.
# Skips hidden buttons so a shared button list can hold rows that are not currently offered.
static func hit_index(buttons: Array, pos: Vector2) -> int:
	for i in range(buttons.size()):
		var control := buttons[i] as Control
		if control == null or not control.is_visible_in_tree():
			continue
		if control.get_global_rect().has_point(pos):
			return i
	return -1


# Re-parent-order `node` to the END of its parent's child list (topmost for BOTH draw and GUI
# picking). No-op when it is already last, when it has no parent, or outside the tree — so it is
# safe to call from a visibility_changed handler on every show.
static func raise_to_front(node: Control) -> void:
	if node == null or not node.is_inside_tree():
		return
	var parent := node.get_parent()
	if parent == null:
		return
	var last := parent.get_child_count() - 1
	if last < 0 or parent.get_child(last) == node:
		return
	parent.move_child(node, last)
