class_name AchievementUi
extends RefCounted

# T-367: builds + routes the achievement surface (panel + earn toast) so client/main.gd — which sits
# at the gdlint file cap — wires the whole thing in a couple of lines, mirroring SocialUi. Panels
# ride the shared T-308 theme; the only intent is the read-only achievement_list refresh.

var panel: AchievementsPanel = null
var _toast: Label = null


func _init(hud: Node, theme_src: Control, send: Callable, is_typing: Callable = Callable()) -> void:
	panel = AchievementsPanel.new()
	panel.name = "AchievementsPanel"
	hud.add_child(panel)
	panel.setup(send, is_typing)
	_toast = Label.new()
	_toast.name = "AchievementToast"
	# T-759: CENTER_TOP anchors both edges at 0.5, so setting only offset_top left the box 0px WIDE —
	# a centered Label collapses and the text is clipped/mispositioned (the T-748-adjacent degenerate
	# -anchor trap; maintenance_banner.gd sets all four). Give it a real 720px-wide centered rect.
	_toast.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_toast.offset_left = -360.0
	_toast.offset_right = 360.0
	_toast.offset_top = 64.0
	_toast.offset_bottom = 160.0
	_toast.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_toast.modulate = Color(1, 1, 1, 0)
	_toast.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud.add_child(_toast)
	if theme_src != null and theme_src.theme != null:
		panel.theme = theme_src.theme
		_toast.theme = theme_src.theme


# client_net "achievements" category: achievement_list (panel feed) + achievements_earned (toast).
func on_achievements(data: Dictionary) -> void:
	match str(data.get("type", "")):
		"achievement_list":
			if panel != null:
				panel.render(data.get("achievements", []))
		"achievements_earned":
			for a in data.get("earned", []):
				_pop_toast(str((a as Dictionary).get("name", "Achievement")))
			if panel != null and panel.visible:
				panel.render(panel._rows)  # keep an open panel fresh (server re-list on next open)
		"discovery_earned":
			_pop_discovery_toast(data)
		"renown_list":  # T-678: hub-standing rows render at the top of the same panel
			if panel != null:
				panel.render_renown(data.get("renown", []))


func _pop_toast(name_txt: String) -> void:
	if _toast == null:
		return
	_toast.text = "Achievement earned: %s" % name_txt
	_toast.modulate = Color(1, 0.85, 0.3, 1)
	if not _toast.is_inside_tree():
		return
	var tween := _toast.create_tween()
	tween.tween_interval(2.5)
	tween.tween_property(_toast, "modulate:a", 0.0, 1.0)


func _pop_discovery_toast(data: Dictionary) -> void:
	var node: Dictionary = data.get("node", {})
	var total_xp := int(data.get("xp", 0)) + int(data.get("rested_bonus", 0))
	var lines := ["Discovered: %s" % str(node.get("name", "Unknown Landmark"))]
	if total_xp > 0:
		lines.append("+%d XP" % total_xp)
	var lore := str(node.get("lore", ""))
	if lore != "":
		lines.append(lore)
	if _toast == null:
		return
	_toast.text = "\n".join(lines)
	_toast.modulate = Color(0.55, 0.9, 1.0, 1)
	if not _toast.is_inside_tree():
		return
	var tween := _toast.create_tween()
	tween.tween_interval(3.5)
	tween.tween_property(_toast, "modulate:a", 0.0, 1.0)
