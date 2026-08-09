extends GutTest

# T-571 (report #31): the vendor Wares/Sell/Buyback tabs used to fall through to a raw internal id
# (itm_potion_minor_healing) whenever the server ack carried no display name — the same class of
# bug T-557 already fixed for the Wardrobe. Split out of test_service_panel.gd to stay under the
# gdlint 20-public-methods-per-file cap.

const ServicePanel = preload("res://scripts/ui/service_panel.gd")


func _panel() -> ServicePanel:
	var p = ServicePanel.new()
	add_child_autofree(p)
	return p


func _labels(p: ServicePanel) -> String:
	var texts := []
	for c in p._body.find_children("*", "Label", true, false):
		texts.append(c.text)
	return " ".join(texts)


func test_vendor_wares_humanizes_a_missing_display_name() -> void:
	var p = _panel()
	p.setup(func(_n, _a): pass)
	p.open("npc_hk_vendor_general", "Merchant Tolley", "vendor")
	(
		p
		. on_ack(
			{
				"npc_id": "npc_hk_vendor_general",
				"ok": true,
				"action": "browse",
				"coins": 100,
				"wares": [{"item_id": "itm_potion_minor_healing", "price": 15}],
				"bag": [],
				"buyback": [],
			}
		)
	)
	var joined := _labels(p)
	assert_true(joined.contains("Potion Minor Healing"), "the raw id is humanized for display")
	assert_false(joined.contains("itm_"), "the raw item id never surfaces in the Wares tab")


func test_vendor_wares_prefers_a_server_supplied_name_verbatim() -> void:
	var p = _panel()
	p.setup(func(_n, _a): pass)
	p.open("npc_hk_vendor_general", "Merchant Tolley", "vendor")
	(
		p
		. on_ack(
			{
				"npc_id": "npc_hk_vendor_general",
				"ok": true,
				"action": "browse",
				"coins": 100,
				"wares":
				[
					{
						"item_id": "itm_potion_minor_healing",
						"name": "Minor Healing Draught",
						"price": 15,
					}
				],
				"bag": [],
				"buyback": [],
			}
		)
	)
	assert_true(_labels(p).contains("Minor Healing Draught"), "a real server name wins verbatim")


func test_vendor_sell_and_buyback_tabs_humanize_missing_names_too() -> void:
	var p = _panel()
	p.setup(func(_n, _a): pass)
	p.open("npc_hk_vendor_general", "Merchant Tolley", "vendor")
	(
		p
		. on_ack(
			{
				"npc_id": "npc_hk_vendor_general",
				"ok": true,
				"action": "browse",
				"coins": 100,
				"wares": [],
				"bag":
				[{"slot_index": 0, "item_id": "itm_wolf_pelt", "item_count": 2, "vendor_value": 3}],
				"buyback": [{"index": 0, "item_id": "itm_iron_ingot", "count": 1, "price": 5}],
			}
		)
	)
	var joined := _labels(p)
	assert_true(joined.contains("Wolf Pelt"), "the Sell tab humanizes a missing name")
	assert_true(joined.contains("Iron Ingot"), "the Buyback tab humanizes a missing name")
	assert_false(joined.contains("itm_"), "no raw item id surfaces anywhere in the vendor panel")
