extends "res://addons/gut/test.gd"
# T-635: the level-up celebration (banner + floating text + system chat line + golden screen
# flash + T-111's audio sting). LevelUpUi owns level-climb detection itself (see the class
# comment) so these tests drive it the same way main.gd's real `player_stats` handler does:
# on_player_stats(payload, audio, combat_feedback).


# Minimal play_sfx double — records calls instead of touching an AudioStreamPlayer pool, so these
# tests stay headless-safe and independent of AudioManager's own asset-loading test coverage.
class _FakeAudio:
	var play_sfx_calls: Array = []

	func play_sfx(sfx_name: String, volume_db := -9.0) -> void:
		play_sfx_calls.append({"name": sfx_name, "vol": volume_db})


var _hud: Control = null
var _feedback: CombatFeedback = null
var _audio: _FakeAudio = null
var _ui: LevelUpUi = null


func before_each() -> void:
	_hud = Control.new()
	add_child(_hud)
	_feedback = CombatFeedback.new()
	add_child(_feedback)
	await get_tree().process_frame
	_feedback.set_local_player(1)
	_audio = _FakeAudio.new()
	_ui = LevelUpUi.mount(_hud, null)


func after_each() -> void:
	_hud.queue_free()
	_feedback.queue_free()


# ---- The first push after connect is a baseline, never a "climb" -------------------------


func test_first_push_never_celebrates() -> void:
	_ui.on_player_stats({"level": 5}, _audio, _feedback)
	assert_eq(_audio.play_sfx_calls.size(), 0, "no sting on the initial push")
	assert_almost_eq(_ui._banner.modulate.a, 0.0, 0.001, "banner never popped")
	assert_eq(_feedback.get_combat_log().get_lines().size(), 0, "no chat/log line yet")
	assert_eq(_ui.get_last_level(), 5, "baseline is still recorded")


# ---- A genuine level climb fires the full beat exactly once -----------------------------


func test_level_climb_fires_the_full_celebration_once() -> void:
	watch_signals(_feedback.get_floating_pool())
	_ui.on_player_stats({"level": 5}, _audio, _feedback)  # baseline
	_ui.on_player_stats({"level": 6}, _audio, _feedback)  # the climb

	assert_eq(_audio.play_sfx_calls.size(), 1, "the levelup sting fires exactly once")
	assert_eq(_audio.play_sfx_calls[0]["name"], "levelup")

	assert_almost_eq(_ui._banner.modulate.a, 1.0, 0.001, "banner pops to full opacity")
	assert_eq(_ui._banner.text, "LEVEL 6!")

	var lines: Array = _feedback.get_combat_log().get_lines()
	assert_eq(lines.size(), 1, "exactly one system chat/log line")
	assert_string_contains(lines[0], "You have reached level 6!")

	assert_signal_emitted_with_parameters(
		_feedback.get_floating_pool(), "text_spawned", [1, "LEVEL 6!"]
	)
	assert_true(_feedback.get_screen_flash().is_flashing(), "golden flash triggered")


# ---- No repeat on a same-level (or lower) repush, e.g. a stat resync --------------------


func test_repush_of_the_same_level_does_not_refire() -> void:
	_ui.on_player_stats({"level": 5}, _audio, _feedback)  # baseline
	_ui.on_player_stats({"level": 6}, _audio, _feedback)  # the climb — fires once
	_ui.on_player_stats({"level": 6}, _audio, _feedback)  # repush — same level, must stay silent

	assert_eq(_audio.play_sfx_calls.size(), 1, "still exactly one sting, not two")
	assert_eq(_feedback.get_combat_log().get_lines().size(), 1, "still exactly one chat/log line")


# ---- Non-level pushes (or a lower level) never celebrate --------------------------------


func test_missing_level_field_is_silent_and_never_regresses_the_tracked_level() -> void:
	_ui.on_player_stats({"level": 8}, _audio, _feedback)  # baseline
	_ui.on_player_stats({}, _audio, _feedback)  # a push with no level key at all -> 0

	assert_eq(_audio.play_sfx_calls.size(), 0, "0 < 8 is never a climb")
	assert_eq(_ui.get_last_level(), 8, "tracked level never regresses on a malformed/lower push")


# ---- Multiple real climbs each fire once, independently ---------------------------------


func test_two_sequential_climbs_each_fire_once() -> void:
	_ui.on_player_stats({"level": 1}, _audio, _feedback)  # baseline
	_ui.on_player_stats({"level": 2}, _audio, _feedback)  # climb 1 (T-712: + the L2 unlock line)
	_ui.on_player_stats({"level": 3}, _audio, _feedback)  # climb 2

	assert_eq(_audio.play_sfx_calls.size(), 2)
	var lines: Array = _feedback.get_combat_log().get_lines()
	assert_eq(lines.size(), 3, "level 2 + its unlock mirror + level 3 (T-712)")
	assert_string_contains(lines[0], "level 2")
	assert_string_contains(lines[1], "Kessa", "the L2 ding names the trainer unlock in chat")
	assert_string_contains(lines[2], "level 3")


# ---- T-712: the banner names the next unlock (show the locks) ---------------------------


func test_unlock_lines_are_data_driven_and_match_server_talent_points() -> void:
	var l2 := LevelUpUi.unlock_lines(2, 1)
	assert_eq(l2.size(), 2, "L2 = the named unlock + the talent point line")
	assert_string_contains(l2[0], "Master-at-Arms Kessa")
	assert_eq(l2[1], "Talent point earned (1)", "N mirrors the server's points_available")
	assert_eq(
		LevelUpUi.unlock_lines(2, 0).size(), 1, "no server-reported point -> no phantom mention"
	)
	var l9 := LevelUpUi.unlock_lines(9, 8)
	assert_eq(l9.size(), 1, "an unmapped level still names its talent point")
	assert_eq(l9[0], "Talent point earned (8)")
	assert_eq(LevelUpUi.unlock_lines(1, 0).size(), 0, "L1 unlocks nothing")


func test_l2_ding_shows_the_sub_line_and_mirrors_it_in_chat() -> void:
	_ui.on_player_stats({"level": 1, "talent_points": 0}, _audio, _feedback)  # baseline
	_ui.on_player_stats({"level": 2, "talent_points": 1}, _audio, _feedback)  # the L2 ding

	assert_almost_eq(_ui._subline.modulate.a, 1.0, 0.001, "the sub-line pops with the banner")
	assert_string_contains(_ui._subline.text, "Master-at-Arms Kessa", "the unlock is named")
	assert_string_contains(_ui._subline.text, "Talent point earned (1)")

	var lines: Array = _feedback.get_combat_log().get_lines()
	assert_eq(lines.size(), 3, "the ding line + both unlock lines mirror to chat")
	assert_string_contains(lines[1], "Kessa")
	assert_string_contains(lines[2], "Talent point earned (1)")


func test_sub_line_is_empty_when_a_level_unlocks_nothing() -> void:
	_ui.on_player_stats({"level": 40}, _audio, _feedback)  # baseline, no talent_points key
	_ui.on_player_stats({"level": 41}, _audio, _feedback)
	assert_eq(_ui._subline.text, "", "no data row + no reported point -> a clean classic ding")
