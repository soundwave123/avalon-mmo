class_name LevelUpUi
extends RefCounted

# T-635: the level-up celebration — the classic MMO "ding" beat. Previously reduced to a bare
# audio sting (T-111's `_last_level` tracking lived in main.gd, fired `audio.play_sfx("levelup")`
# and nothing else — no banner, no floating text, no chat line; see the ticket's evidence: `grep
# -rl "level_up|LevelUp|Level Up" client/scripts` returned zero matches because the sfx name and
# var never used those literal spellings).
#
# Owns level-climb detection itself now (main.gd sits at its 1000-line gdlint cap; mirrors the
# CharacterSheetPanel/QuestOfferPanel `mount()` idiom, T-640, so main.gd's wiring stays a single
# call) and fires the full beat off the SAME signal T-111 already used — the level climbing between
# two `player_stats` pushes — so no new server message is needed. Tasteful and brief (~1.5s): a
# centered banner, a "LEVEL n!" floating text over the local player, a system chat/log line (the
# T-575 combat-log surface), and a golden screen flash. Not a modal — never blocks input, never
# stacks on top of whatever panel is already open (the #78/#79 PerformanceRecapPanel complaint this
# ticket explicitly avoids repeating).

const _FLASH_COLOR := Color(1.0, 0.85, 0.3)  # golden — distinct from the red damage-taken flash
const _FLASH_PEAK_ALPHA := 0.35
const _FLASH_DURATION := 0.6
const _BANNER_COLOR := Color(1.0, 0.85, 0.3)
const _BANNER_HOLD := 1.2  # seconds at full opacity before the fade starts
const _BANNER_FADE := 0.6  # ~1.8s total on screen — "tasteful ~2s" per the ticket

# T-712: "show the locks" — the ding names what this level just unlocked, from a small data map so
# future levels slot in (Hodent: show the locks before the keys; Exile's Reach teaches explicitly).
# The talent-point line is appended separately from the server-fed talent_points count (talent_logic
# points_available truth — the client never mirrors the rule). Mirrored into chat by _celebrate.
const _UNLOCK_LINES := {
	2: "New ability ready — visit Master-at-Arms Kessa",
}

var _banner: Label = null
var _subline: Label = null  # T-712: the next-unlock line under the big "LEVEL n!"
# T-111 carryover: 0 = "no player_stats push observed yet" (nothing to compare the first push
# against, so it never falsely fires on connect/reconnect at whatever level the character is).
var _last_level: int = 0
var _talent_points: int = 0  # T-712: points_available from the latest player_stats push


static func mount(hud: Node, theme_src: Control) -> LevelUpUi:
	var ui := LevelUpUi.new()
	ui._banner = Label.new()
	ui._banner.name = "LevelUpBanner"
	# T-759: CENTER_TOP anchors both edges at 0.5 — setting only offset_top leaves a 0px-wide box that
	# collapses a centered Label (the degenerate-anchor trap; set all four, per maintenance_banner).
	ui._banner.set_anchors_preset(Control.PRESET_CENTER_TOP)
	ui._banner.offset_left = -400.0
	ui._banner.offset_right = 400.0
	ui._banner.offset_top = 120.0
	ui._banner.offset_bottom = 200.0
	ui._banner.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	ui._banner.modulate = Color(1, 1, 1, 0)
	ui._banner.add_theme_font_size_override("font_size", 40)
	ui._banner.add_theme_color_override("font_color", _BANNER_COLOR)
	ui._banner.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud.add_child(ui._banner)
	# T-712: the sub-line — smaller, parchment-toned, sharing the banner's hold-then-fade beat.
	ui._subline = Label.new()
	ui._subline.name = "LevelUpSubline"
	ui._subline.set_anchors_preset(Control.PRESET_CENTER_TOP)  # T-759: all four offsets (see banner)
	ui._subline.offset_left = -360.0
	ui._subline.offset_right = 360.0
	ui._subline.offset_top = 172.0
	ui._subline.offset_bottom = 220.0
	ui._subline.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	ui._subline.modulate = Color(1, 1, 1, 0)
	ui._subline.add_theme_font_size_override("font_size", 18)
	ui._subline.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud.add_child(ui._subline)
	if theme_src != null and theme_src.theme != null:
		ui._banner.theme = theme_src.theme
		ui._subline.theme = theme_src.theme
	return ui


# Called from main.gd's `player_stats` handler with the raw push + the audio/combat-feedback seams
# it needs. Fires the full celebration exactly once per level climb; silent on a repush of the same
# (or a lower — e.g. a stat resync) level, and silent on the very first push after connect (nothing
# to compare it to yet).
func on_player_stats(d: Dictionary, audio, combat_feedback) -> void:
	var lvl := int(d.get("level", 0))
	_talent_points = int(d.get("talent_points", _talent_points))  # T-712: rides the same push
	if _last_level > 0 and lvl > _last_level:
		_celebrate(lvl, audio, combat_feedback)
	_last_level = maxi(_last_level, lvl)


# T-712: what this level unlocked, as banner/chat lines. Data-driven (see _UNLOCK_LINES) plus the
# talent-point line whenever the server says points exist (from L2, per talent_logic). Pure/static
# so it unit-tests headless.
static func unlock_lines(level: int, talent_points: int) -> Array[String]:
	var lines: Array[String] = []
	var named := str(_UNLOCK_LINES.get(level, ""))
	if named != "":
		lines.append(named)
	if level >= 2 and talent_points > 0:
		lines.append("Talent point earned (%d)" % talent_points)
	return lines


func _celebrate(level: int, audio, combat_feedback) -> void:
	if audio != null:
		audio.play_sfx("levelup", -4.0)  # T-111's existing cue — the asset already ships (no gap)
	if combat_feedback != null:
		combat_feedback.report_system_message("You have reached level %d!" % level)
		for line in unlock_lines(level, _talent_points):  # T-712: chat mirrors the sub-line
			combat_feedback.report_system_message(line)
		combat_feedback.get_floating_pool().spawn_text(
			combat_feedback.local_player_id, "LEVEL %d!" % level, _FLASH_COLOR
		)
		combat_feedback.get_screen_flash().flash(_FLASH_COLOR, _FLASH_PEAK_ALPHA, _FLASH_DURATION)
	_pop_banner(level)


func _pop_banner(level: int) -> void:
	if _banner == null:
		return
	_banner.text = "LEVEL %d!" % level
	_banner.modulate = Color(1, 1, 1, 1)
	if _subline != null:  # T-712: name the unlocks right under the ding
		_subline.text = "\n".join(unlock_lines(level, _talent_points))
		_subline.modulate = Color(1, 1, 1, 1)
	if not _banner.is_inside_tree():
		return
	var tween := _banner.create_tween()
	tween.tween_interval(_BANNER_HOLD)
	tween.tween_property(_banner, "modulate:a", 0.0, _BANNER_FADE)
	if _subline != null and _subline.is_inside_tree():
		var sub_tween := _subline.create_tween()
		sub_tween.tween_interval(_BANNER_HOLD)
		sub_tween.tween_property(_subline, "modulate:a", 0.0, _BANNER_FADE)


func get_last_level() -> int:  # test hook
	return _last_level
