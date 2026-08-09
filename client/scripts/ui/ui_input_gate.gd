class_name UiInputGate
extends RefCounted

# T-504: one viewport-wide source of truth for keyboard ownership. Panel listeners run before GUI
# controls receive an event, so they must leave every key untouched while a free-type field owns
# focus. TextEdit also covers derived multiline editors.


static func is_text_input_focused(viewport: Viewport) -> bool:
	if viewport == null:
		return false
	# T-512: a blocking modal (class selection) captures ALL key input the same way a text field
	# does — panel listeners must stay hands-off so the modal's own 1/2/3/Enter/arrows aren't
	# stolen underneath (the fresh-account class panel focuses a Button, not a text field, so the
	# focus check below missed it and world hotkeys fired — "Enter opened chat").
	if is_blocking_modal_visible(viewport):
		return true
	var focus_owner := viewport.gui_get_focus_owner()
	return focus_owner is LineEdit or focus_owner is TextEdit


# T-512: any visible node in the "ui_blocking_modal" group owns input exclusively (class select).
static func is_blocking_modal_visible(viewport: Viewport) -> bool:
	var tree := viewport.get_tree()
	if tree == null:
		return false
	for node in tree.get_nodes_in_group("ui_blocking_modal"):
		if node is CanvasItem and (node as CanvasItem).is_visible_in_tree():
			return true
	return false
