extends "res://addons/gut/test.gd"
# T-367: AchievementsPanel — server-fed render (earned ★ vs in-progress ☆ + %), the earned/total
# summary, and the read-only refresh intent on open. The panel never asserts state.

var _panel: AchievementsPanel = null
var _sent: Array = []


func before_each() -> void:
	_panel = AchievementsPanel.new()
	add_child(_panel)
	await get_tree().process_frame
	_sent = []
	_panel.setup(func(msg): _sent.append(msg))


func after_each() -> void:
	_panel.queue_free()


func _rows() -> Array:
	return [
		{
			"id": "first_blood",
			"name": "First Blood",
			"desc": "Kill 1.",
			"earned": true,
			"fraction": 1.0
		},
		{"id": "slayer", "name": "Slayer", "desc": "Kill 10.", "earned": false, "fraction": 0.3},
	]


func test_renders_earned_and_progress() -> void:
	_panel.render(_rows())
	var body: String = _panel._body.text
	assert_true(body.contains("First Blood"))
	assert_true(body.contains("★"), "an earned achievement shows a filled star")
	assert_true(body.contains("Slayer"))
	assert_true(body.contains("30%"), "an in-progress achievement shows its completion %")
	assert_eq(_panel._summary.text, "1 / 2 earned")


func test_toggle_open_requests_the_list_read_only() -> void:
	assert_false(_panel.visible)
	_panel.toggle()
	assert_true(_panel.visible)
	assert_eq(_sent.size(), 2, "opening refreshes achievements + renown from the server")
	assert_eq(str(_sent[0]["type"]), "achievement_list", "the only intents are reads")
	assert_eq(str(_sent[1]["type"]), "renown_list", "T-678: hub standing rides the open refresh")
	_panel.toggle()
	assert_false(_panel.visible)
	assert_eq(_sent.size(), 2, "closing sends nothing")


func test_empty_registry_renders_placeholder() -> void:
	_panel.render([])
	assert_true(_panel._body.text.contains("no achievements"))
	assert_eq(_panel._summary.text, "0 / 0 earned")


# T-678: the renown_list reply renders a standing header above the achievement rows — hub name,
# rank name + number, and the points-toward-next-threshold bar text, all server-fed.
func test_renders_renown_standing_header() -> void:
	_panel.render(_rows())
	(
		_panel
		. render_renown(
			[
				{
					"hub": "highkeep",
					"name": "Highkeep",
					"points": 150,
					"rank": 2,
					"rank_name": "Newcomer",
					"next_points": 400,
				},
				{
					"hub": "ashmoor",
					"name": "Ashmoor",
					"points": 11000,
					"rank": 8,
					"rank_name": "Exalted",
					"next_points": -1,
				},
			]
		)
	)
	var body: String = _panel._body.text
	assert_true(body.contains("Highkeep"), "hub display name renders")
	assert_true(body.contains("Newcomer"), "rank name renders")
	assert_true(body.contains("150 / 400"), "points show progress toward the next threshold")
	assert_true(body.contains("11000 (max)"), "the top rank shows no next threshold")
	assert_true(body.contains("First Blood"), "achievement rows still render below the header")
