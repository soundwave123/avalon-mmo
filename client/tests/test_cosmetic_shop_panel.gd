extends GutTest

# T-476: the store front browses the server board + balance and sends only an appearance_id to buy.
# It never asserts a price, never sends a stat, and refuses to buy an owned or unaffordable look.

const CosmeticShopPanel = preload("res://scripts/ui/cosmetic_shop_panel.gd")
const ReplyRouter = preload("res://scripts/net/reply_router.gd")

var _panel
var _sent: Array


func before_each() -> void:
	_sent = []
	_panel = CosmeticShopPanel.new()
	add_child_autofree(_panel)
	var router := ReplyRouter.new()
	_panel.setup(func(m): _sent.append(m), func(): return false, router)
	assert_true(router.has_route("wardrobe_state"))


func _state(balance: int, owned: Array = []) -> Dictionary:
	return {
		"type": "wardrobe_state",
		"cosmetic_currency": balance,
		"appearances": owned,
		"store":
		[
			{"id": "cos_gilded_blade", "name": "Gilded Blade", "slot": "weapon", "price": 120},
			{"id": "cos_smith_broadsword", "name": "Broadsword", "slot": "weapon", "price": 60},
		],
	}


func test_panel_has_store_controls() -> void:
	assert_not_null(_panel.get_node_or_null("Frame/List/Balance"))
	assert_not_null(_panel.get_node_or_null("Frame/List/Items"))
	assert_not_null(_panel.get_node_or_null("Frame/List/Detail"), "the item detail card exists")


func test_open_requests_state_that_carries_the_board_and_balance() -> void:
	_panel.toggle()
	assert_eq(_sent[-1], {"type": "wardrobe_list"})


func test_browse_shows_price_and_balance() -> void:
	_panel.receive(_state(200))
	assert_string_contains(_panel.get_balance_text(), "200")
	_panel._select_for_test("cos_gilded_blade")
	assert_string_contains(_panel.get_detail_text(), "Gilded Blade")
	assert_string_contains(_panel.get_detail_text(), "120")


func test_buy_sends_id_only_no_price_no_stats() -> void:
	_panel.receive(_state(200))
	_panel._select_for_test("cos_gilded_blade")
	_panel._buy_selected()
	assert_eq(
		_sent[-1],
		{"type": "wardrobe_buy", "appearance_id": "cos_gilded_blade"},
		"the client names only the id; the server owns the price and the debit"
	)


func test_cannot_buy_an_unaffordable_look() -> void:
	_panel.receive(_state(50))  # can't afford the 120 blade
	_panel._select_for_test("cos_gilded_blade")
	_panel._buy_selected()
	assert_eq(_sent.size(), 0, "no purchase message is sent when the purse is short")


func test_cannot_rebuy_an_owned_look() -> void:
	_panel.receive(_state(500, [{"id": "cos_gilded_blade", "name": "Gilded Blade"}]))
	_panel._select_for_test("cos_gilded_blade")
	_panel._buy_selected()
	assert_eq(_sent.size(), 0, "an owned look is never re-bought from the client")
	assert_string_contains(_panel.get_detail_text(), "Owned")


# T-553: the store must actually be reachable — mounted into the live HUD and opened by a key
# that does not collide with the Spellbook (B).
func test_mount_adds_a_named_panel_to_the_hud() -> void:
	var hud := Node.new()
	add_child_autofree(hud)
	var router := ReplyRouter.new()
	CosmeticShopPanel.mount(hud, func(_m): pass, func(): return false, router)
	var mounted = hud.get_node_or_null("CosmeticShopPanel")
	assert_not_null(mounted, "the store is mounted into the HUD tree, not just its own test")
	assert_true(mounted is CosmeticShopPanel)


# T-571: mount() now returns the instance so main.gd can fold it into the centralized Esc panel
# set (report #28) — a caller ignoring the return, like the test above, still works fine.
func test_mount_returns_the_mounted_instance() -> void:
	var hud := Node.new()
	add_child_autofree(hud)
	var router := ReplyRouter.new()
	var mounted := CosmeticShopPanel.mount(hud, func(_m): pass, func(): return false, router)
	assert_not_null(mounted)
	assert_same(mounted, hud.get_node_or_null("CosmeticShopPanel"))


func _key_event(code: int) -> InputEventKey:
	var ev := InputEventKey.new()
	ev.keycode = code
	ev.pressed = true
	return ev


func test_open_key_does_not_collide_with_the_spellbook_b() -> void:
	# B belongs to the Spellbook — pressing it must NOT open the store.
	_panel._input(_key_event(KEY_B))
	assert_false(_panel.visible, "B is the Spellbook, never the store")
	assert_eq(_sent.size(), 0, "no store fetch fires on the Spellbook key")


func test_h_opens_the_store_and_fetches_the_board() -> void:
	_panel._input(_key_event(KEY_H))
	assert_true(_panel.visible, "H opens the store")
	assert_eq(_sent[-1], {"type": "wardrobe_list"}, "opening fetches the board + balance")
	_panel._input(_key_event(KEY_H))
	assert_false(_panel.visible, "H toggles it closed again")


# T-571 (report #28): Esc used to close the panel locally AND race main.gd's own Esc handling
# (which didn't know this panel existed), sometimes leaving Options opening on top of it. Esc
# precedence is now main.gd's alone (SettingsEscGate) — this panel must no longer react to it.
func test_escape_does_not_close_the_store_locally_anymore() -> void:
	_panel._input(_key_event(KEY_H))
	assert_true(_panel.visible)
	_panel._input(_key_event(KEY_ESCAPE))
	assert_true(_panel.visible, "Esc is main.gd's call now, not this panel's own")


# T-569 (portal #23): the item dropdown must never retain viewport keyboard focus. Before this
# fix, an OptionButton's default FOCUS_ALL meant clicking it left it as the GUI focus owner even
# after the popup closed, so global keybinds (H, L, ...) stopped reaching main.gd until Escape.
# Mirrors the FOCUS_NONE convention chat_panel/talent_panel/etc. use for the same failure class.
func test_item_dropdown_never_grabs_keyboard_focus() -> void:
	# FOCUS_NONE itself is the regression guard: Godot refuses grab_focus() on a FOCUS_NONE control
	# (even warns if you try), so asserting the mode directly proves the dropdown can never become —
	# or stay — the viewport's GUI focus owner, which is what silenced global keybinds before this fix.
	var option := _panel.get_node_or_null("Frame/List/Items") as OptionButton
	assert_not_null(option, "the store's item dropdown")
	assert_eq(
		option.focus_mode, Control.FOCUS_NONE, "the dropdown must not become the GUI focus owner"
	)
	assert_false(option.has_focus(), "the dropdown starts with no GUI focus")
