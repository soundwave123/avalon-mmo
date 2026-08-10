extends "res://addons/gut/test.gd"
# T-363: TradePanel — server-fed rendering (offers/confirms/bag from the trade_update view),
# desire-only sends, and the ended/rejected paths.

var _panel: TradePanel = null
var _sent: Array = []


func before_each() -> void:
	_panel = TradePanel.new()
	add_child(_panel)
	await get_tree().process_frame
	_sent = []
	_panel.setup(func(msg): _sent.append(msg))


func after_each() -> void:
	_panel.queue_free()


func _view(overrides: Dictionary = {}) -> Dictionary:
	var v := {
		"state": "active",
		"partner": "Bob",
		"mine": {"items": [{"slot_index": 0, "item_id": "wolf_pelt", "count": 3}], "coins": 0},
		"theirs": {"items": [], "coins": 40},
		"my_confirm": false,
		"their_confirm": true,
		"my_bag": [{"slot_index": 0, "item_id": "wolf_pelt", "item_count": 5}],
	}
	v.merge(overrides, true)
	return {"type": "trade_update", "ended": false, "view": v}


func test_hidden_until_a_session_arrives() -> void:
	assert_false(_panel.visible)
	_panel.receive(_view())
	assert_true(_panel.visible, "a trade_update opens the window")


func test_renders_both_offers_and_confirm_flags() -> void:
	_panel.receive(_view())
	assert_true(_panel.body_text().contains("wolf_pelt x3"), "my staged stack renders")
	assert_true(_panel.body_text().contains("Bob's offer"), "partner column renders")
	assert_true(_panel.body_text().contains("(40 coins)"), "their coins render")
	assert_true(_panel.status_text().contains("[them: OK]"), "their confirm flag shows")
	assert_false(_panel.status_text().contains("[you: OK]"), "mine does not")


func test_pending_invite_offers_accept_decline() -> void:
	_panel.receive(_view({"state": "pending"}))
	assert_true(_panel.body_text().contains("Accept trade"))
	_panel._on_meta("accept")
	assert_eq(str(_sent[0]["type"]), "trade_accept")


func test_bag_click_sends_offer_desire_only() -> void:
	_panel.receive(_view())
	_panel._on_meta("offer|0|5")
	assert_eq(_sent.size(), 1)
	assert_eq(str(_sent[0]["type"]), "trade_offer_item")
	assert_eq(int(_sent[0]["slot_index"]), 0)
	assert_eq(int(_sent[0]["count"]), 5)
	_panel._on_meta("retract|0")
	assert_eq(str(_sent[1]["type"]), "trade_retract_item")


func test_ended_update_closes_the_window() -> void:
	_panel.receive(_view())
	_panel.receive({"type": "trade_update", "ended": true, "reason": "cancelled", "view": {}})
	assert_false(_panel.visible, "an ended trade closes the window")


func test_rejection_shows_reason_without_closing() -> void:
	_panel.receive(_view())
	_panel.receive({"type": "trade_result", "ok": false, "reason": "rate_limited"})
	assert_true(_panel.visible)
	assert_true(_panel.status_text().contains("rate_limited"))


# ---- T-755: BBCode injection through the trade partner's name ------------------
#
# The stakes here are unusually concrete: an unclosed tag in the partner's name swallows every line
# rendered BELOW the header — which is the list of items you are about to hand over. A trade window
# that hides its own contents is worse than a cosmetic defacement.
func test_hostile_partner_name_cannot_hide_the_offer_list() -> void:
	_panel.receive(
		_view({"partner": "[color=#000000]mallory", "theirs": {"items": [], "coins": 40}})
	)
	var rtl := RichTextLabel.new()
	rtl.bbcode_enabled = true
	add_child_autofree(rtl)
	rtl.text = _panel.body_text()
	var parsed := rtl.get_parsed_text()
	assert_string_contains(parsed, "[color=#000000]mallory", "the partner name renders as text")
	assert_string_contains(parsed, "wolf_pelt x3", "your own staged offer stays visible")
	assert_string_contains(parsed, "Your bag", "the sections below the header survive")
