extends GutTest

const ServicePanel = preload("res://scripts/ui/service_panel.gd")


func _panel() -> ServicePanel:
	var panel = ServicePanel.new()
	add_child_autofree(panel)
	return panel


func _buttons_recursive(node: Node) -> Array:
	var out: Array = []
	for child in node.get_children():
		if child is Button:
			out.append(child)
		out.append_array(_buttons_recursive(child))
	return out


func test_ack_builds_wares_sell_and_buyback_tabs_with_intent_only_buttons() -> void:
	var panel = _panel()
	var sent: Array = []
	panel.setup(func(_npc_id, _action): pass)
	panel.setup_ex(func(_npc_id, action, extra): sent.append({"action": action, "extra": extra}))
	panel.open("npc_hk_vendor_general", "Merchant Tolley", "vendor")
	(
		panel
		. on_ack(
			{
				"npc_id": "npc_hk_vendor_general",
				"service": "vendor",
				"action": "browse",
				"ok": true,
				"coins": 120,
				"wares": [{"item_id": "potion", "name": "Minor Healing Potion", "price": 8}],
				"bag":
				[
					{
						"slot_index": 3,
						"item_id": "junk",
						"item_count": 4,
						"name": "Bent Spoon",
						"vendor_value": 3,
					}
				],
				"buyback":
				[{"index": 0, "item_id": "old", "count": 2, "name": "Old Boot", "price": 6}],
			}
		)
	)
	assert_not_null(panel._vendor_tabs, "vendor uses a real tab container")
	assert_eq(panel._vendor_tabs.get_tab_count(), 3, "Wares + Sell + Buyback tabs")
	assert_eq(panel._vendor_tabs.get_tab_title(0), "Wares")
	assert_eq(panel._vendor_tabs.get_tab_title(1), "Sell")
	assert_eq(panel._vendor_tabs.get_tab_title(2), "Buyback")
	var buttons := _buttons_recursive(panel._vendor_tabs)
	assert_eq(buttons.size(), 3, "one buy, one sell-stack, one buyback action")
	for button: Button in buttons:
		button.pressed.emit()
	assert_eq(str(sent[0]["action"]), "buy")
	assert_eq(sent[0]["extra"], {"item_id": "potion"}, "buy sends no price/count")
	assert_eq(str(sent[1]["action"]), "sell")
	assert_eq(sent[1]["extra"], {"slot_index": 3, "count": 4}, "sell sends owned-slot desire")
	assert_false(sent[1]["extra"].has("price"), "sell never echoes the displayed price")
	assert_eq(str(sent[2]["action"]), "buyback")
	assert_eq(sent[2]["extra"], {"buyback_index": 0}, "buyback sends only server-list index")


func test_sale_ack_refreshes_tabs_and_confirms_server_amount() -> void:
	var panel = _panel()
	panel.setup(func(_npc_id, _action): pass)
	panel.open("npc_hk_vendor_general", "Merchant Tolley", "vendor")
	(
		panel
		. on_ack(
			{
				"npc_id": "npc_hk_vendor_general",
				"service": "vendor",
				"action": "sell",
				"ok": true,
				"coins": 112,
				"wares": [],
				"bag": [],
				"buyback": [{"index": 0, "item_id": "junk", "count": 4, "price": 12}],
				"sold": "junk",
				"count": 4,
				"price": 12,
			}
		)
	)
	assert_true(panel._status.text.contains("12c"), "confirmation uses master proceeds")
	assert_eq(panel._vendor_tabs.get_tab_count(), 3, "post-sale response refreshes shortlist")
