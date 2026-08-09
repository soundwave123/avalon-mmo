extends GutTest

# T-427: the client displays only the server-confirmed discovery result. No intent or reward claim
# exists on this surface; AchievementUi reuses its brief top-center toast layer.

var _hud: Control
var _ui: AchievementUi


func before_each() -> void:
	_hud = Control.new()
	add_child(_hud)
	_ui = AchievementUi.new(_hud, null, func(_m): pass)
	await get_tree().process_frame


func after_each() -> void:
	_hud.queue_free()


func test_confirmed_discovery_shows_name_xp_and_lore() -> void:
	(
		_ui
		. on_achievements(
			{
				"type": "discovery_earned",
				"node": {"name": "The Hamlet Churchyard", "lore": "Old stones remember."},
				"xp": 40,
				"rested_bonus": 20,
			}
		)
	)
	assert_true(_ui._toast.text.contains("Discovered: The Hamlet Churchyard"))
	assert_true(_ui._toast.text.contains("60 XP"), "toast includes base + rested bonus")
	assert_true(
		_ui._toast.text.contains("Old stones remember."), "authored lore is surfaced lightly"
	)
