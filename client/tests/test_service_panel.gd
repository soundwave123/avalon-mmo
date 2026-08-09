extends GutTest
# T-145: the service-hub stub panel is built in code, so its wiring is headlessly unit-testable
# (add_child_autofree → _ready builds the shell). These prove the structure, that open() titles the
# panel + fires the `browse` round-trip through the injected send path + rebuilds the body per
# service, the inn's Set-Hearth button fires `set_home`, and on_ack() surfaces the server reply.
# The live rendering is play-test-verified.

const ServicePanel = preload("res://scripts/ui/service_panel.gd")
const MailPanel = preload("res://scripts/ui/mail_panel.gd")  # T-613


# Spy for the injected Callable(npc_id, action) send path (→ ClientNet.service_intent).
class SendSpy:
	var sent: Array = []

	func intent(npc_id: String, action: String) -> void:
		sent.append({"npc_id": npc_id, "action": action})


func _panel() -> ServicePanel:
	var p = ServicePanel.new()
	add_child_autofree(p)  # _ready builds the shell (title / heading / body / status / close)
	return p


func _find_button(node: Node) -> Button:
	for child in node.get_children():
		if child is Button:
			return child
	return null


func test_panel_builds_shell() -> void:
	var p = _panel()
	assert_not_null(p._title, "title label")
	assert_not_null(p._heading, "heading label")
	assert_not_null(p._body, "body container")
	assert_not_null(p._status, "status label")
	assert_false(p.visible, "starts hidden (opened from a talk_result)")


func test_open_titles_fires_browse_and_shows() -> void:
	var p = _panel()
	var spy := SendSpy.new()
	p.setup(spy.intent)
	p.open("npc_hk_vendor_general", "Merchant Tolley", "vendor")
	assert_true(p.visible, "open shows the panel")
	assert_eq(p._title.text, "Merchant Tolley", "title is the NPC name")
	# T-364: the vendor opens with a browse AND a repair-cost quote (Repair-All preview).
	var vendor_actions: Array = spy.sent.map(func(s): return s["action"])
	assert_true(vendor_actions.has("browse"), "a vendor opens with a browse")
	assert_true(vendor_actions.has("repair_quote"), "a vendor fetches the repair quote")
	assert_eq(spy.sent[0]["npc_id"], "npc_hk_vendor_general")
	# T-208: a real service opens with its data fetch instead
	spy.sent.clear()
	p.open("npc_hk_banker", "Banker Coyne", "bank")
	assert_eq(spy.sent[0]["action"], "vault_list", "bank opens with the vault fetch")


func test_vendor_body_waits_for_server_wares() -> void:
	var p = _panel()
	p.setup(func(_n, _a): pass)
	p.open("npc_hk_vendor_general", "Merchant Tolley", "vendor")
	var texts := []
	for child in p._body.get_children():
		if child is Label:
			texts.append(child.text)
	assert_true(
		" ".join(texts).contains("stock"), "vendor waits for server stock, not placeholders"
	)


func test_inn_set_hearth_button_fires_set_home() -> void:
	var p = _panel()
	var spy := SendSpy.new()
	p.setup(spy.intent)
	p.open("npc_hk_innkeeper", "Innkeeper Doran", "inn")
	var btn := _find_button(p._body)
	assert_not_null(btn, "inn has a Set-Hearth button")
	if btn != null:
		btn.emit_signal("pressed")
	var actions: Array = spy.sent.map(func(s): return s["action"])
	assert_true(actions.has("set_home"), "the button fires a set_home intent")


func test_flight_panel_lists_server_routes_and_sends_destination_intent_only() -> void:
	var p = _panel()
	var sent: Array = []
	p.setup(func(_n, action): sent.append({"action": action, "extra": {}}))
	p.setup_ex(func(_n, action, extra): sent.append({"action": action, "extra": extra}))
	p.open("npc_hk_flightmaster", "Gryphon Master Kest", "flight")
	assert_eq(str(sent[0]["action"]), "list", "open fetches the known route list")
	sent.clear()
	(
		p
		. on_ack(
			{
				"npc_id": "npc_hk_flightmaster",
				"ok": true,
				"action": "list",
				"coins": 100,
				"destinations": [{"id": "ashmoor", "name": "Ashmoor Sky Dock", "cost": 60}],
			}
		)
	)
	var fly: Button = _find_button(p._body)
	assert_not_null(fly, "known direct destination gets a travel button")
	fly.pressed.emit()
	assert_eq(str(sent[0]["action"]), "fly")
	assert_eq(sent[0]["extra"], {"dest": "ashmoor"}, "client sends no price/position/region")


func test_on_ack_confirms_set_home() -> void:
	var p = _panel()
	p.setup(func(_n, _a): pass)
	p.open("npc_hk_innkeeper", "Innkeeper Doran", "inn")
	p.on_ack({"npc_id": "npc_hk_innkeeper", "ok": true, "action": "set_home"})
	assert_ne(p._status.text, "", "a successful set_home shows a confirmation")


func test_on_ack_ignores_other_npc() -> void:
	var p = _panel()
	p.setup(func(_n, _a): pass)
	p.open("npc_hk_innkeeper", "Innkeeper Doran", "inn")
	p.on_ack({"npc_id": "npc_hk_banker", "ok": true, "action": "set_home"})
	assert_eq(p._status.text, "", "an ack for a different NPC is ignored")


func test_open_rebuilds_body_between_services() -> void:
	var p = _panel()
	p.setup(func(_n, _a): pass)
	p.open("npc_hk_innkeeper", "Innkeeper Doran", "inn")
	assert_not_null(_find_button(p._body), "inn built a button")
	p.open("npc_hk_banker", "Banker Coyne", "bank")
	assert_null(_find_button(p._body), "bank body was rebuilt (no leftover inn button)")


func test_close_hides_panel() -> void:
	var p = _panel()
	p.setup(func(_n, _a): pass)
	p.open("npc_hk_banker", "Banker Coyne", "bank")
	p.close_panel()
	assert_false(p.visible, "close hides the panel")


func test_auction_heading_and_stub_body() -> void:
	# T-204: the auction house hub titles with its own heading (not the "Service" fallback)
	# and shows the stub line until T-208 lands listings.
	var p = _panel()
	p.setup(func(_n, _a): pass)
	p.open("npc_hk_auctioneer", "Auctioneer Hollis", "auction")
	assert_eq(p._heading.text, "Auction House", "auction heading registered")
	var texts := []
	for c in p._body.get_children():
		if c is Label:
			texts.append(c.text)
	assert_true(" ".join(texts).contains("lot"), "auction stub body present")


# ---- T-293: the bounty board tab ----


func _bounty_ack() -> Dictionary:
	return {
		"npc_id": "npc_hk_bounty_board",
		"ok": true,
		"action": "browse",
		"service": "bounty",
		"daily":
		{
			"ok": true,
			"date_key": "2026-07-15",
			"streak": 3,
			"first_bonus_available": true,
			"objectives":
			[
				{
					"quest_id": "qb01",
					"title": "Bounty: Greymaw the Alpha",
					"min_level": 3,
					"claimed": false,
					"eligible": true,
				},
				{
					"quest_id": "qb02",
					"title": "Bounty: Grexrok",
					"min_level": 3,
					"claimed": true,
					"eligible": true,
				},
			],
		},
		"bounties":
		[
			{
				"quest_id": "qb01",
				"title": "Bounty: Greymaw the Alpha",
				"target": "mob_greymaw",
				"target_desc": "Slay Greymaw the Alpha",
				"location_hint": "Northern wolds (48, 40).",
				"recommended_players": 3,
				"xp": 600,
				"coins": 150,
			}
		],
	}


func test_bounty_board_opens_and_browses() -> void:
	var p = _panel()
	var spy := SendSpy.new()
	p.setup(spy.intent)
	p.open("npc_hk_bounty_board", "Highkeep Bounty Board", "bounty")
	assert_true(p.visible)
	assert_eq(p._heading.text, "Bounty Board", "bounty heading registered")
	assert_eq(spy.sent[0]["action"], "browse", "the board opens with a browse round-trip")


func test_bounty_ack_lists_hunts_with_accept_button() -> void:
	var p = _panel()
	p.setup(func(_n, _a): pass)
	p.open("npc_hk_bounty_board", "Highkeep Bounty Board", "bounty")
	p.on_ack(_bounty_ack())
	var texts := []
	var accept_btn: Button = null
	for c in p._body.get_children():
		if c is Label:
			texts.append(c.text)
		elif c is Button:
			accept_btn = c
	assert_true(" ".join(texts).contains("Greymaw"), "the hunt is listed by name")
	assert_true(" ".join(texts).contains("Streak 3"), "endowed streak is visible with clear goals")
	assert_true(" ".join(texts).contains("Available"), "available-today state is explicit")
	assert_true(" ".join(texts).contains("Claimed"), "claimed-today state is explicit")
	assert_true(" ".join(texts).contains("Bonus ready"), "first-completion gift is legible")
	assert_not_null(accept_btn, "each bounty gets an Accept button")


func test_bounty_accept_button_fires_accept_quest() -> void:
	var p = _panel()
	var accepted := []
	p.setup(func(_n, _a): pass)
	p.setup_accept(func(quest_id): accepted.append(quest_id))
	p.open("npc_hk_bounty_board", "Highkeep Bounty Board", "bounty")
	p.on_ack(_bounty_ack())
	var accept_btn: Button = null
	for c in p._body.get_children():
		if c is Button:
			accept_btn = c
	assert_not_null(accept_btn)
	accept_btn.emit_signal("pressed")
	assert_eq(accepted, ["qb01"], "Accept fires the accept_quest intent with the bounty id")


func test_bounty_on_accept_result_surfaces_confirm() -> void:
	var p = _panel()
	p.setup(func(_n, _a): pass)
	p.setup_accept(func(_q): pass)
	p.open("npc_hk_bounty_board", "Highkeep Bounty Board", "bounty")
	p.on_ack(_bounty_ack())
	p.on_accept_result({"ok": true, "quest_id": "qb01"})
	assert_true(p._status.text.contains("accepted"), "a successful pickup confirms in-panel")
	p.on_accept_result({"ok": false, "reason": "already_active", "quest_id": "qb01"})
	assert_true(p._status.text.contains("already_active"), "a rejection surfaces the reason")


# ---- T-364: the repair coin sink UX (Repair-All button + cost preview) ----


func test_repair_quote_renders_repair_all_button() -> void:
	var p = _panel()
	var spy := SendSpy.new()
	p.setup(spy.intent)
	p.open("npc_hk_vendor_general", "Merchant Tolley", "vendor")
	p.on_ack(
		{
			"npc_id": "npc_hk_vendor_general",
			"ok": true,
			"action": "repair_quote",
			"quote": true,
			"cost": 40,
			"coins": 100
		}
	)
	var repair_btn: Button = null
	for c in p._body.get_children():
		if c is Button and str(c.text).begins_with("Repair"):
			repair_btn = c
	assert_not_null(repair_btn, "a non-zero quote renders a Repair-All button")
	assert_true(str(repair_btn.text).contains("40c"), "the button shows the server-computed cost")
	repair_btn.pressed.emit()
	assert_true(
		spy.sent.map(func(s): return s["action"]).has("repair"),
		"pressing Repair-All fires the repair intent (no client-supplied cost)"
	)


func test_repair_quote_zero_shows_no_button() -> void:
	var p = _panel()
	p.setup(func(_n, _a): pass)
	p.open("npc_hk_vendor_general", "Merchant Tolley", "vendor")
	p.on_ack(
		{
			"npc_id": "npc_hk_vendor_general",
			"ok": true,
			"action": "repair_quote",
			"quote": true,
			"cost": 0,
			"coins": 100
		}
	)
	var repair_btn := false
	var good_line := false
	for c in p._body.get_children():
		if c is Button and str(c.text).begins_with("Repair"):
			repair_btn = true
		elif c is Label and str(c.text).contains("good repair"):
			good_line = true
	assert_false(repair_btn, "fully-repaired gear offers no Repair button")
	assert_true(good_line, "a zero quote shows the good-repair line")


func test_repair_done_ack_confirms() -> void:
	var p = _panel()
	p.setup(func(_n, _a): pass)
	p.open("npc_hk_vendor_general", "Merchant Tolley", "vendor")
	p.on_ack(
		{
			"npc_id": "npc_hk_vendor_general",
			"ok": true,
			"action": "repair",
			"repaired": 2,
			"cost": 40,
			"coins": 60
		}
	)
	assert_true(p._status.text.contains("Repaired"), "a completed repair confirms in-panel")


# ---- T-655 (#66): the vendor panel's Coins line went stale after Repair until the panel reopened
# (durability_ops.repair_op's ack already carries the post-repair coins; on_ack just never wired
# the repair/repair_quote branches into the rendered Coins label like the buy/sell/buyback ones) --


func _vendor_ack(coins: int) -> Dictionary:
	return {
		"npc_id": "npc_hk_vendor_general",
		"ok": true,
		"action": "browse",
		"coins": coins,
		"wares": [],
		"bag": [],
		"buyback": [],
	}


func test_repair_ack_refreshes_coins_in_place_without_rebuilding_the_open_tabs() -> void:
	var p = _panel()
	p.setup(func(_n, _a): pass)
	p.open("npc_hk_vendor_general", "Merchant Tolley", "vendor")
	p.on_ack(_vendor_ack(537))
	assert_eq(p._coins_label.text, "Coins: 537c", "the vendor body renders the pre-repair balance")
	var tabs_before: TabContainer = p._vendor_tabs
	(
		p
		. on_ack(
			{
				"npc_id": "npc_hk_vendor_general",
				"ok": true,
				"action": "repair",
				"repaired": 2,
				"cost": 60,
				"coins": 477,
			}
		)
	)
	assert_eq(
		p._coins_label.text, "Coins: 477c", "repair's ack coins now update the same label in place"
	)
	assert_true(p._status.text.contains("Repaired"), "the status confirmation still surfaces too")
	# The fix updates the label in place instead of re-running _build_vendor_body — proven by the
	# Wares/Sell/Buyback TabContainer staying the same object (so the player's open tab survives).
	assert_eq(p._vendor_tabs, tabs_before, "the vendor tab container is not rebuilt on repair")


func test_repair_quote_ack_also_refreshes_coins() -> void:
	var p = _panel()
	p.setup(func(_n, _a): pass)
	p.open("npc_hk_vendor_general", "Merchant Tolley", "vendor")
	p.on_ack(_vendor_ack(537))
	(
		p
		. on_ack(
			{
				"npc_id": "npc_hk_vendor_general",
				"ok": true,
				"action": "repair_quote",
				"quote": true,
				"cost": 0,
				"coins": 477,
			}
		)
	)
	assert_eq(
		p._coins_label.text,
		"Coins: 477c",
		"the auto-refetched quote after a repair also carries (and applies) the updated coins"
	)


# ---- T-208: the three real tabs render from ack payloads ----


func test_bank_ack_renders_vault_and_move_buttons() -> void:
	var p = _panel()
	var sent := []
	p.setup(func(_n, _a): pass)
	p.setup_ex(func(_n, action, extra): sent.append({"action": action, "extra": extra}))
	p.open("npc_hk_banker", "Banker Coyne", "bank")
	(
		p
		. on_ack(
			{
				"npc_id": "npc_hk_banker",
				"ok": true,
				"action": "vault_list",
				"vault": [{"slot_index": 0, "item_id": "wolf_pelt", "item_count": 3}],
				"bag": [{"slot_index": 1, "item_id": "iron_ingot", "item_count": 2}],
				"vault_slots": 12,
				"coins": 90,
			}
		)
	)
	var buttons := []
	var texts := []
	for c in p._body.get_children():
		if c is Button:
			buttons.append(c)
		elif c is Label:
			texts.append(c.text)
	# T-613: +1 for the Mailbox button bundled onto this same bank body.
	assert_eq(buttons.size(), 3, "mailbox + withdraw + deposit buttons")
	# T-646: ItemNaming may humanize item_ids, so check for "pelt" instead of "wolf_pelt"
	assert_true(" ".join(texts).to_lower().contains("pelt"), "vault stack listed")
	var withdraw_btn: Button = null
	for b in buttons:
		if str(b.text).begins_with("Withdraw"):
			withdraw_btn = b
	assert_not_null(withdraw_btn, "a Withdraw button for the vault stack")
	withdraw_btn.pressed.emit()
	assert_eq(sent.size(), 1)
	assert_eq(str(sent[0]["action"]), "vault_move")
	assert_eq(str(sent[0]["extra"]["from_type"]), "vault")
	# T-611: this ack carries no vault_next_cost — no upgrade affordance may appear.
	for b in buttons:
		assert_false(str(b.text).begins_with("Upgrade Vault"), "no cost data -> no upgrade button")


# ---- T-611: the vault tier-upgrade sink is reachable from the bank body ----


func _bank_ack(coins: int) -> Dictionary:
	return {
		"npc_id": "npc_hk_banker",
		"ok": true,
		"action": "vault_list",
		"vault": [],
		"bag": [],
		"vault_slots": 12,
		"vault_tier": 0,
		"vault_next_cost": 500,
		"vault_next_slots": 18,
		"coins": coins,
	}


func test_bank_ack_renders_upgrade_button_that_emits_vault_upgrade() -> void:
	var p = _panel()
	var sent := []
	p.setup(func(_n, _a): pass)
	p.setup_ex(func(_n, action, extra): sent.append({"action": action, "extra": extra}))
	p.open("npc_hk_banker", "Banker Coyne", "bank")
	p.on_ack(_bank_ack(600))  # affordable: 600 >= 500
	var upgrade_btn: Button = null
	for c in p._body.get_children():
		if c is Button and str(c.text).begins_with("Upgrade Vault"):
			upgrade_btn = c
	assert_not_null(upgrade_btn, "affordable next tier renders the upgrade button")
	assert_true(str(upgrade_btn.text).contains("18 slots"), "button states the resulting capacity")
	assert_true(str(upgrade_btn.text).contains("500c"), "button states the server-derived cost")
	upgrade_btn.pressed.emit()
	assert_eq(sent.size(), 1)
	assert_eq(str(sent[0]["action"]), "vault_upgrade")


func test_bank_ack_upgrade_unaffordable_is_a_line_not_a_button() -> void:
	var p = _panel()
	p.setup(func(_n, _a): pass)
	p.setup_ex(func(_n, _action, _extra): pass)
	p.open("npc_hk_banker", "Banker Coyne", "bank")
	p.on_ack(_bank_ack(100))  # 100 < 500
	var texts := []
	for c in p._body.get_children():
		assert_false(
			c is Button and str(c.text).begins_with("Upgrade Vault"),
			"insufficient coins -> no pressable upgrade"
		)
		if c is Label:
			texts.append(c.text)
	assert_true(
		" ".join(texts).contains("not enough coin"), "the locked upgrade is still advertised"
	)


func test_auction_ack_renders_lots_with_bid_and_buyout() -> void:
	var p = _panel()
	var sent := []
	p.setup(func(_n, _a): pass)
	p.setup_ex(func(_n, action, extra): sent.append({"action": action, "extra": extra}))
	p.open("npc_hk_auctioneer", "Auctioneer Hollis", "auction")
	(
		p
		. on_ack(
			{
				"npc_id": "npc_hk_auctioneer",
				"ok": true,
				"action": "auction_browse",
				"auctions":
				[
					{
						"id": 7,
						"item_id": "iron_ingot",
						"item_count": 2,
						"min_bid": 10,
						"high_bid": 12,
						"buyout": 40,
						"seller_id": 1
					}
				],
				"coins": 100,
			}
		)
	)
	var buttons := []
	for c in p._body.get_children():
		if c is Button:
			buttons.append(c)
	assert_eq(buttons.size(), 3, "bid + buyout + list form")
	buttons[0].pressed.emit()
	assert_eq(str(sent[0]["action"]), "auction_bid")
	assert_eq(int(sent[0]["extra"]["amount"]), 13, "next bid = high + 1")
	buttons[1].pressed.emit()
	assert_eq(str(sent[1]["action"]), "auction_buyout")
	assert_eq(int(sent[1]["extra"]["auction_id"]), 7)


func test_trainer_ack_renders_catalog_and_train() -> void:
	var p = _panel()
	var sent := []
	p.setup(func(_n, _a): pass)
	p.setup_ex(func(_n, action, extra): sent.append({"action": action, "extra": extra}))
	p.open("npc_hk_mage_trainer", "Archmage Sylvaine", "trainer:mage")
	(
		p
		. on_ack(
			{
				"npc_id": "npc_hk_mage_trainer",
				"ok": true,
				"action": "catalog",
				"catalog": [{"ability": 203, "name": "Frost Nova", "cost": 60, "min_level": 2}],
				"unlocked": [],
				"coins": 100,
			}
		)
	)
	var train_btn: Button = null
	for c in p._body.get_children():
		if c is Button and str(c.text).begins_with("Train"):
			train_btn = c
	assert_not_null(train_btn, "train button offered")
	train_btn.pressed.emit()
	assert_eq(str(sent[0]["action"]), "train")
	assert_eq(int(sent[0]["extra"]["ability_id"]), 203)
	# known entries render as text, not buttons
	(
		p
		. on_ack(
			{
				"npc_id": "npc_hk_mage_trainer",
				"ok": true,
				"action": "train",
				"catalog": [{"ability": 203, "name": "Frost Nova", "cost": 60, "min_level": 2}],
				"unlocked": [203],
				"coins": 40,
			}
		)
	)
	var buttons_after := 0
	for c in p._body.get_children():
		if c is Button and str(c.text).begins_with("Train"):
			buttons_after += 1
	assert_eq(buttons_after, 0, "known ability offers no train button")


# ---- T-613: the mailbox bundled onto the banker's "bank" hub ----


func _mail_panel() -> MailPanel:
	var m = MailPanel.new()
	add_child_autofree(m)
	return m


func test_bank_body_has_a_mailbox_button_that_opens_mail_panel() -> void:
	var p = _panel()
	var m = _mail_panel()
	p.setup(func(_n, _a): pass)
	m.setup_ex(func(_n, _a, _e): pass)
	p.setup_mail(m)
	p.open("npc_hk_banker", "Banker Coyne", "bank")
	(
		p
		. on_ack(
			{
				"npc_id": "npc_hk_banker",
				"ok": true,
				"action": "vault_list",
				"vault": [],
				"bag": [],
				"vault_slots": 12,
				"coins": 90,
			}
		)
	)
	var mailbox_btn: Button = null
	for c in p._body.get_children():
		if c is Button and str(c.text) == "Mailbox":
			mailbox_btn = c
	assert_not_null(mailbox_btn, "the bank body offers a Mailbox button")
	mailbox_btn.pressed.emit()
	assert_false(p.visible, "opening mail closes the bank window")
	assert_true(m.visible, "the Mailbox button opens MailPanel")


func test_on_ack_forwards_mail_shaped_acks_to_the_mail_panel() -> void:
	var p = _panel()
	var m = _mail_panel()
	p.setup(func(_n, _a): pass)
	m.setup_ex(func(_n, _a, _e): pass)
	p.setup_mail(m)
	m.open("npc_hk_banker")  # MailPanel must be visible for on_ack to render (self-filter)
	p.on_ack({"ok": true, "inbox": [], "coins": 100, "bag": []})
	var texts := []
	for c in m._inbox_list.get_children():
		if c is Label:
			texts.append(c.text)
	assert_true(" ".join(texts).contains("empty"), "ServicePanel.on_ack forwarded the mail ack")
