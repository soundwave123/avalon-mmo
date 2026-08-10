class_name ServicePanel
# T-145: the stub interaction panel for Highkeep's WoW-capital service NPCs — banker, general +
# weapon vendors, innkeeper, flight master. Built in CODE (no .tscn; the SettingsPanel idiom) and
# added under the HUD by main.gd. STUB: opening a service fires a `browse` intent (proves the
# client→server→ack round-trip in real play) and the inn's "Set Hearth" button fires `set_home`;
# the server acks (service_ack) — no real economy/travel yet. open()/close_panel() drive
# visibility; _build_body rebuilds per NPC, so the whole thing is headless-unit-testable.

extends Control

# service tag -> the heading shown under the NPC name.
const _HEADINGS := {
	"bank": "Vault",
	"vendor": "Wares",
	"inn": "Innkeeper",
	"flight": "Flight Master",
	"auction": "Auction House",  # T-204: stub until T-208 lands listings
	"bounty": "Bounty Board",  # T-293: open-world elite party hunts
}
# main.gd injects the send path: Callable(npc_id: String, action: String) -> void (→ ClientNet).
var _send_intent: Callable = Callable()
# T-208: real ops carry parameters; ClientNet packs extras into the intent message.
var _send_intent_ex: Callable = Callable()
# T-293: the bounty board accepts a listed hunt via the normal accept_quest intent (→ ClientNet).
var _accept_quest: Callable = Callable()
# T-613: MailPanel.mount() injects itself here — the "Mailbox" button (below) opens it, and
# on_ack forwards every mail-shaped ack to it (MailPanel.on_ack self-filters on the "inbox" key),
# so main.gd's _on_result never needs to know MailPanel exists.
var _mail: MailPanel = null
var _npc_id: String = ""
var _service: String = ""

var _title: Label = null
var _heading: Label = null
var _body: VBoxContainer = null
var _status: Label = null
var _vendor_tabs: TabContainer = null  # T-430: Wares / Sell / Buyback server-fed views
var _coins_label: Label = null  # T-655 (#66): live handle so repair/repair_quote can refresh it


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	visible = false  # opened from a service NPC's talk_result (main.gd)
	# T-759: the panel below requests the "SolidWindow" variation but no theme was ever in scope, so
	# the variation never resolved and the window rendered default Godot grey. Carry the shared theme.
	theme = UiTheme.build()
	var dim := ColorRect.new()
	dim.color = Color(0.0, 0.0, 0.0, 0.55)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(dim)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(center)
	var panel := PanelContainer.new()
	panel.theme_type_variation = "SolidWindow"  # T-396: deliberate window = opaque opt-in
	center.add_child(panel)
	var box := VBoxContainer.new()
	box.custom_minimum_size = Vector2(380.0, 0.0)
	box.add_theme_constant_override("separation", 6)
	panel.add_child(box)

	_title = Label.new()
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title.add_theme_font_size_override("font_size", 22)
	box.add_child(_title)

	_heading = Label.new()
	_heading.add_theme_color_override("font_color", Color(1.0, 0.85, 0.4))
	box.add_child(_heading)

	# T-759: the bank vault (~16 slots) and vendor lists overflowed the window off the bottom of the
	# screen — a plain VBox in a CenterContainer grows unbounded. Cap it in a scroll so the title
	# above and the Close button below stay on screen and only the list scrolls (inventory idiom).
	var body_scroll := ScrollContainer.new()
	body_scroll.name = "SvcScroll"
	body_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	body_scroll.custom_minimum_size = Vector2(380.0, 380.0)
	box.add_child(body_scroll)
	_body = VBoxContainer.new()
	_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_body.add_theme_constant_override("separation", 4)
	body_scroll.add_child(_body)

	_status = Label.new()
	_status.add_theme_color_override("font_color", Color(0.6, 0.85, 0.6))
	box.add_child(_status)

	var close := Button.new()
	close.name = "SvcClose"
	close.text = "Close"
	close.pressed.connect(close_panel)
	box.add_child(close)


# main.gd: the send path (→ ClientNet.service_intent). Injected once at wiring.
func setup(send_intent: Callable) -> void:
	_send_intent = send_intent


# Open for one NPC + service: rebuild the body and fire the `browse` round-trip. Called from
# main._on_result when a talk_result carries a non-empty `service`.
func open(npc_id: String, npc_name: String, service: String) -> void:
	_npc_id = npc_id
	_service = service
	_title.text = npc_name
	_heading.text = str(_HEADINGS.get(service, "Service"))
	_status.text = ""
	_build_body(service)
	visible = true
	# T-208: real services open with their data fetch; stubs keep the browse round-trip
	if service == "bank":
		_emit("vault_list")
	elif service == "auction":
		_emit("auction_browse")
	elif service.begins_with("trainer:"):
		_emit("catalog")
	elif service == "vendor":
		_emit("browse")
		_emit("repair_quote")  # T-364: fetch the Repair-All cost preview (no side effect)
	elif service == "flight":
		_emit("list")
	else:
		_emit("browse")


func close_panel() -> void:
	visible = false


# The server's service_ack for THIS open panel — a visible confirmation the stub round-tripped.
func on_ack(data: Dictionary) -> void:
	if _mail != null:
		_mail.on_ack(data)  # T-613: self-filters on the "inbox" key + its own visibility
	if not visible or str(data.get("npc_id", "")) != _npc_id:
		return
	if not bool(data.get("ok", false)):
		_status.text = "Unavailable (%s)." % str(data.get("reason", ""))
	elif str(data.get("action", "")) == "set_home":
		_status.text = "Hearth set here."
	elif data.has("vault"):
		_build_bank_body(data)
	elif data.has("auctions"):
		_build_auction_body(data)
	elif data.has("catalog"):
		_build_trainer_body(data)
	elif data.has("bounties"):
		_build_bounty_body(data)
	elif data.has("destinations"):
		_build_flight_body(data)
	elif data.has("wares") and data.has("bag") and data.has("buyback"):
		_build_vendor_body(data)
		match str(data.get("action", "")):
			"sell":
				_status.text = (
					"Sold %d item(s) for %dc."
					% [int(data.get("count", 0)), int(data.get("price", 0))]
				)
			"buy":
				_status.text = "Purchased for %dc." % int(data.get("price", 0))
			"buyback":
				_status.text = "Bought back for %dc." % int(data.get("price", 0))
	elif data.has("quote"):  # T-364: repair cost preview → a Repair-All button
		_refresh_coins(data)
		_show_repair_quote(int(data.get("cost", 0)))
	elif str(data.get("action", "")) == "repair":  # T-364: repair done
		# T-655 (#66): repair_op's ack carries the post-repair coins (durability_ops.repair_op), but
		# this branch used to touch only _status.text — the Coins line stayed at its last buy/sell
		# cache until the panel was closed and reopened, showing a balance too HIGH by the repair
		# cost the whole time the player kept shopping.
		_refresh_coins(data)
		_status.text = (
			"Repaired %d piece(s) for %dc."
			% [int(data.get("repaired", 0)), int(data.get("cost", 0))]
		)
		_emit("repair_quote")  # refresh the (now zero) quote
	elif str(data.get("action", "")) == "fly":
		_status.text = "Flight complete — %dc remain." % int(data.get("coins", 0))


func _emit(action: String) -> void:
	if _send_intent.is_valid():
		_send_intent.call(_npc_id, action)


# T-655 (#66): updates the already-rendered Coins line in place — no full _build_vendor_body
# rebuild, so the Wares/Sell/Buyback tab the player has open (and its scroll position) survives a
# repair the same way it already survives switching tabs.
func _refresh_coins(data: Dictionary) -> void:
	if _coins_label != null and is_instance_valid(_coins_label) and data.has("coins"):
		_coins_label.text = "Coins: %dc" % int(data["coins"])


func setup_ex(send_intent_ex: Callable) -> void:
	_send_intent_ex = send_intent_ex


# T-293: main.gd injects the accept path — Callable(quest_id: String) -> void (→ accept_quest).
func setup_accept(accept_quest: Callable) -> void:
	_accept_quest = accept_quest


# T-613: MailPanel.mount() calls this with itself.
func setup_mail(mail: MailPanel) -> void:
	_mail = mail


# T-293: the server's accept_quest_result for a bounty picked from this board — surface it in-panel
# so the player sees the pickup confirm (or the reason it bounced) without leaving the board.
func on_accept_result(data: Dictionary) -> void:
	if not visible or _service != "bounty":
		return
	if bool(data.get("ok", false)):
		_status.text = "Bounty accepted — check your quest log (L)."
	else:
		_status.text = "Cannot accept: %s" % str(data.get("reason", ""))


func _emit_ex(action: String, extra: Dictionary) -> void:
	if _send_intent_ex.is_valid():
		_send_intent_ex.call(_npc_id, action, extra)
	else:
		_emit(action)


func _clear_body() -> void:
	_vendor_tabs = null
	_coins_label = null  # T-655: a full rebuild replaces it — stop pointing at the freed one
	for child in _body.get_children():
		_body.remove_child(child)
		child.queue_free()


func _button(text: String, on_press: Callable) -> void:
	_button_to(_body, text, on_press)


func _button_to(parent: Control, text: String, on_press: Callable) -> void:
	var btn := Button.new()
	btn.text = text
	# stable, harness-clickable name (pilot clicknode): first word of the label + index
	btn.name = "Svc%s%d" % [text.get_slice(" ", 0), parent.get_child_count()]
	btn.pressed.connect(on_press)
	parent.add_child(btn)


func _line_to(parent: Control, text: String) -> void:
	var lbl := Label.new()
	lbl.text = text
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	lbl.custom_minimum_size = Vector2(340.0, 0.0)
	parent.add_child(lbl)


# T-430: all display data is the master's post-op view. Buttons carry only selection desires;
# prices stay presentation-only and are never echoed back as authority.
func _build_vendor_body(data: Dictionary) -> void:
	_clear_body()
	_coins_label = _line("Coins: %dc" % int(data.get("coins", 0)))
	_vendor_tabs = TabContainer.new()
	_vendor_tabs.name = "VendorTabs"
	_vendor_tabs.custom_minimum_size = Vector2(360.0, 240.0)
	_body.add_child(_vendor_tabs)

	var wares_tab := VBoxContainer.new()
	wares_tab.name = "Wares"
	_vendor_tabs.add_child(wares_tab)
	var wares: Array = data.get("wares", [])
	if wares.is_empty():
		_line_to(wares_tab, "This merchant has no wares in stock.")
	for ware: Dictionary in wares:
		var item_id := str(ware.get("item_id", ""))
		# T-571 (report #31): a missing server name used to fall through to the raw item_id
		# ("itm_potion_minor_healing") — humanize it instead, mirroring T-557's wardrobe fix.
		var name := ItemNaming.display_name(item_id, str(ware.get("name", "")))
		var price := int(ware.get("price", 0))
		_line_to(wares_tab, "%s — %dc" % [name, price])
		_button_to(wares_tab, "Buy %s" % name, func(): _emit_ex("buy", {"item_id": item_id}))

	var sell_tab := VBoxContainer.new()
	sell_tab.name = "Sell"
	_vendor_tabs.add_child(sell_tab)
	var bag: Array = data.get("bag", [])
	if bag.is_empty():
		_line_to(sell_tab, "No sellable items in your bags.")
	for row: Dictionary in bag:
		var slot_index := int(row.get("slot_index", -1))
		var count := int(row.get("item_count", 0))
		var name := ItemNaming.display_name(str(row.get("item_id", "")), str(row.get("name", "")))
		var total := int(row.get("vendor_value", 0)) * count
		_line_to(sell_tab, "%s x%d — %dc" % [name, count, total])
		_button_to(
			sell_tab,
			"Sell %s x%d" % [name, count],
			func(): _emit_ex("sell", {"slot_index": slot_index, "count": count})
		)

	var buyback_tab := VBoxContainer.new()
	buyback_tab.name = "Buyback"
	_vendor_tabs.add_child(buyback_tab)
	var buyback: Array = data.get("buyback", [])
	if buyback.is_empty():
		_line_to(buyback_tab, "No recently sold items.")
	for row: Dictionary in buyback:
		var index := int(row.get("index", -1))
		var name := ItemNaming.display_name(str(row.get("item_id", "")), str(row.get("name", "")))
		var count := int(row.get("count", 0))
		var price := int(row.get("price", 0))
		_line_to(buyback_tab, "%s x%d — %dc" % [name, count, price])
		_button_to(
			buyback_tab, "Buyback %s" % name, func(): _emit_ex("buyback", {"buyback_index": index})
		)


# T-208 bank: vault grid + bag rows with move buttons (server re-acks the new state).
func _build_bank_body(data: Dictionary) -> void:
	_clear_body()
	_line(
		(
			"Coins: %dc   Vault %d/%d"
			% [
				int(data.get("coins", 0)),
				(data.get("vault", []) as Array).size(),
				int(data.get("vault_slots", 12)),
			]
		)
	)
	# T-613: mailbox bundled onto the banker's hub — close this window, open MailPanel.
	_button(
		"Mailbox",
		func():
			close_panel()
			_mail.open(_npc_id)
	)
	# T-611: the T-412 upgrade sink, finally reachable. Cost + resulting capacity come from the
	# server's ack (vault_next_cost 0 = max tier); the server re-acks grown capacity + debited coins.
	var next_cost := int(data.get("vault_next_cost", 0))
	if next_cost > 0:
		var next_slots := int(data.get("vault_next_slots", 0))
		if int(data.get("coins", 0)) >= next_cost:
			_button(
				"Upgrade Vault to %d slots — %dc" % [next_slots, next_cost],
				func(): _emit_ex("vault_upgrade", {})
			)
		else:
			_line("Upgrade Vault to %d slots — %dc (not enough coin)" % [next_slots, next_cost])
	for row in data.get("vault", []):
		var index := int(row["slot_index"])
		# T-646: route through ItemNaming like the vendor branch (T-571).
		var item_id := str(row["item_id"])
		var name := ItemNaming.display_name(item_id, str(row.get("name", "")))
		_line("Vault %d: %s x%d" % [index, name, int(row["item_count"])])
		_button(
			"Withdraw %s" % name,
			func(): _emit_ex("vault_move", {"from_type": "vault", "from_index": index})
		)
	for row in data.get("bag", []):
		var index := int(row["slot_index"])
		var item_id := str(row["item_id"])
		var name := ItemNaming.display_name(item_id, str(row.get("name", "")))
		_button(
			"Deposit %s x%d" % [name, int(row["item_count"])],
			func(): _emit_ex("vault_move", {"from_type": "bag", "from_index": index})
		)


# T-208 auction: live lots with bid/buyout; a lean list form for bag slot 0.
func _build_auction_body(data: Dictionary) -> void:
	_clear_body()
	_line("Coins: %dc" % int(data.get("coins", 0)))
	for lot in data.get("auctions", []):
		var lot_id := int(lot["id"])
		var high := int(lot.get("high_bid", 0))
		var next_bid := maxi(int(lot["min_bid"]), high + 1)
		var buyout := int(lot.get("buyout", 0))
		_line("#%d %s x%d — high %dc" % [lot_id, str(lot["item_id"]), int(lot["item_count"]), high])
		_button(
			"Bid %dc" % next_bid,
			func(): _emit_ex("auction_bid", {"auction_id": lot_id, "amount": next_bid})
		)
		if buyout > 0:
			_button(
				"Buyout %dc" % buyout, func(): _emit_ex("auction_buyout", {"auction_id": lot_id})
			)
	_button(
		"List bag slot 0 (min 10c, buyout 25c, 1h)",
		func():
			_emit_ex(
				"auction_list", {"from_index": 0, "min_bid": 10, "buyout": 25, "duration_s": 3600}
			)
	)


# T-208 trainer: the class catalog with train buttons; owned entries read as known.
func _build_trainer_body(data: Dictionary) -> void:
	_clear_body()
	_line("Coins: %dc" % int(data.get("coins", 0)))
	var unlocked: Array = data.get("unlocked", [])
	for offer in data.get("catalog", []):
		var ability_id := int(offer["ability"])
		if ability_id in unlocked:
			_line("%s — known" % str(offer.get("name", ability_id)))
		else:
			_line(
				(
					"%s — %dc (L%d+)"
					% [
						str(offer.get("name", ability_id)),
						int(offer["cost"]),
						int(offer["min_level"])
					]
				)
			)
			_button(
				"Train %s" % str(offer.get("name", ability_id)),
				func(): _emit_ex("train", {"ability_id": ability_id})
			)


# T-293 bounty board: a parchment list of open-world elite hunts, each with an Accept button that
# fires the accept_quest intent (server guards level/repeat). Turn-in rides the standard talk flow —
# the board is each bounty's turn-in NPC, so talking to it hands in any completed hunt.
func _build_bounty_body(data: Dictionary) -> void:
	_clear_body()
	var bounties: Array = data.get("bounties", [])
	var daily: Dictionary = data.get("daily", {})
	if bool(daily.get("ok", false)):
		_line("Today's goals — Streak %d" % int(daily.get("streak", 0)))
		for objective: Dictionary in daily.get("objectives", []):
			var marker := "Available"
			if bool(objective.get("claimed", false)):
				marker = "Claimed"
			elif not bool(objective.get("eligible", true)):
				marker = "Locked (level %d)" % int(objective.get("min_level", 1))
			_line("   %s — %s" % [marker, str(objective.get("title", "Daily objective"))])
		var bonus := (
			"Bonus ready" if bool(daily.get("first_bonus_available", false)) else "Bonus claimed"
		)
		_line("   First bounty: %s" % bonus)
		_line("")
	if bounties.is_empty():
		_line("No bounties are posted right now.")
		return
	_line("Wanted — named elites. Gather a party; these quarry cannot be soloed.")
	for b in bounties:
		var quest_id := str(b.get("quest_id", ""))
		_line("")
		_line("%s" % str(b.get("title", quest_id)))
		_line("   %s" % str(b.get("target_desc", "")))
		_line("   Where: %s" % str(b.get("location_hint", "")))
		_line(
			(
				"   Party: %d+    Reward: %d XP, %dc"
				% [
					int(b.get("recommended_players", 1)),
					int(b.get("xp", 0)),
					int(b.get("coins", 0)),
				]
			)
		)
		_button("Accept %s" % str(b.get("title", quest_id)), _accept_bounty.bind(quest_id))


# T-431: route list is wholly server-fed. Buttons send only the destination id; cost, coordinates,
# discovery and region are re-derived by world/master and never echoed as client authority.
func _build_flight_body(data: Dictionary) -> void:
	_clear_body()
	_line("Coins: %dc" % int(data.get("coins", 0)))
	var destinations: Array = data.get("destinations", [])
	if destinations.is_empty():
		_line("No connected roosts are known yet. Speak to another flight master to learn it.")
		return
	for route: Dictionary in destinations:
		var dest := str(route.get("id", ""))
		_button(
			"Fly to %s (%dc)" % [str(route.get("name", dest)), int(route.get("cost", 0))],
			func(): _emit_ex("fly", {"dest": dest})
		)


# T-364: the repair coin sink UX — a single "Repair All" button with a server-computed cost preview.
# Per-item repair UI is deferred (a demo only needs the bounded all-gear sink). The cost is
# master-authoritative; the client only sends the `repair` intent.
func _show_repair_quote(cost: int) -> void:
	if not visible or _service != "vendor":
		return
	if cost <= 0:
		_line("Your gear is in good repair.")
	else:
		_button("Repair All (%dc)" % cost, func(): _emit("repair"))


func _accept_bounty(quest_id: String) -> void:
	if _accept_quest.is_valid():
		_accept_quest.call(quest_id)
		_status.text = "Requesting bounty..."


# ---- per-service stub body (rebuilt each open; detach-then-free so tests see only the new rows) --


func _build_body(service: String) -> void:
	# T-751: _build_body is a second, independent clear of the SAME children _clear_body clears —
	# and it used to skip the handle nulls _clear_body documents (T-655), so a rebuild through this
	# path left `_vendor_tabs`/`_coins_label` pointing at rows that had just been queue_free'd.
	# Freed is not null, so the next `if _coins_label != null` read true and wrote to a corpse.
	_vendor_tabs = null
	_coins_label = null
	for child in _body.get_children():
		_body.remove_child(child)
		child.queue_free()
	match service:
		"bank":
			_line("The vault is being dug — your coin and gear will be safe here soon.")
		"vendor":
			_line("Loading this merchant's server stock...")
		"inn":
			_line("Rest a while. Bind your hearth here to return by stone.")
			var btn := Button.new()
			btn.text = "Set Hearth Here"
			btn.pressed.connect(func(): _emit("set_home"))
			_body.add_child(btn)
		"flight":
			_line("Checking the routes this roost can reach...")
		"auction":
			_line("The block opens soon — list a lot or raise a paddle when T-208 rings the bell.")
		"bounty":
			_line("Reading the postings...")  # T-293: replaced by _build_bounty_body on the ack
		_:
			_line("This service is not yet open.")


func _line(text: String) -> Label:
	var lbl := Label.new()
	lbl.text = text
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	lbl.custom_minimum_size = Vector2(360.0, 0.0)
	_body.add_child(lbl)
	return lbl
