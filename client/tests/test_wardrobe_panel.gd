extends GutTest

const WardrobePanel = preload("res://scripts/ui/wardrobe_panel.gd")
const ReplyRouter = preload("res://scripts/net/reply_router.gd")

var _panel
var _sent: Array


func before_each() -> void:
	_sent = []
	_panel = WardrobePanel.new()
	add_child_autofree(_panel)
	var router := ReplyRouter.new()
	_panel.setup(func(m): _sent.append(m), func(): return false, router)
	assert_true(router.has_route("wardrobe_state"))
	assert_true(router.has_route("wardrobe_result"))


func _state() -> Dictionary:
	return {
		"type": "wardrobe_state",
		"appearances":
		[
			{
				"id": "cos_gilded_blade",
				"name": "Gilded Blade",
				"display_item": "itm_iron_sword",
				"slot": "weapon",
				"rarity": "epic",
			}
		],
		"dyes": [{"id": "dye_crimson", "name": "Crimson", "color": "#9f3142"}],
		"looks": {},
		"slots": [{"slot_type": "weapon", "item_id": "itm_epic_axe"}],
	}


func test_code_built_panel_has_slot_controls_and_paperdoll_preview() -> void:
	assert_not_null(_panel.get_node_or_null("Frame/List/Slots"))
	assert_not_null(_panel.get_node_or_null("Frame/List/Appearance"))
	assert_not_null(_panel.get_node_or_null("Frame/List/Dye"))
	assert_not_null(_panel.get_node_or_null("Frame/List/Preview"), "paper-doll preview exists")


func test_open_requests_authoritative_state() -> void:
	_panel.toggle()
	assert_eq(_sent[-1], {"type": "wardrobe_list"})


func test_apply_sends_ids_only_and_preview_reflects_selection() -> void:
	_panel.receive(_state())
	_panel._select_for_test("weapon", "", "")
	var appearance := _panel.get_node("Frame/List/Appearance") as OptionButton
	assert_eq(appearance.item_count, 2, "equipped look + the one unlocked appearance")
	assert_eq(str(appearance.get_selected_metadata()), "", "empty override is an honest selection")
	_panel._select_for_test("weapon", "cos_gilded_blade", "dye_crimson")
	_panel._apply_selected()
	assert_eq(
		_sent[-1],
		{
			"type": "wardrobe_apply",
			"slot": "weapon",
			"appearance_id": "cos_gilded_blade",
			"dye_id": "dye_crimson",
		},
		"client sends desire ids only"
	)
	assert_string_contains(_panel.get_preview_text(), "Gilded Blade")
	assert_string_contains(_panel.get_preview_text(), "Crimson")


# T-557: an equipped row with no server display name must never leak its raw "itm_*" id into the
# paper-doll preview — the id is humanized into a readable label.
func test_equipped_item_id_is_humanized_never_raw() -> void:
	(
		_panel
		. receive(
			{
				"type": "wardrobe_state",
				"appearances": [],
				"dyes": [],
				"looks": {},
				"slots": [{"slot_type": "weapon", "item_id": "itm_starter_sword"}],
			}
		)
	)
	_panel._select_for_test("weapon", "", "")
	var preview: String = _panel.get_preview_text()
	assert_string_contains(preview, "Starter Sword")
	assert_false(preview.contains("itm_"), "the raw item id never surfaces in the preview")


# T-557: a server-supplied display name is preferred verbatim over the humanized id.
func test_equipped_display_name_is_used_when_present() -> void:
	(
		_panel
		. receive(
			{
				"type": "wardrobe_state",
				"appearances": [],
				"dyes": [],
				"looks": {},
				"slots":
				[
					{
						"slot_type": "weapon",
						"item_id": "itm_starter_sword",
						"name": "Recruit's Sword"
					}
				],
			}
		)
	)
	_panel._select_for_test("weapon", "", "")
	assert_string_contains(_panel.get_preview_text(), "Recruit's Sword")


func test_clear_and_hide_helm_send_no_state_or_power_fields() -> void:
	_panel._clear_selected()
	assert_eq(_sent[-1], {"type": "wardrobe_clear", "slot": "head"})
	_panel._toggle_hide_helm()
	assert_eq(_sent[-1], {"type": "wardrobe_hide_helm"}, "master toggles; client sends no bool")


# T-571: mount() now returns the instance so main.gd can fold it into the centralized Esc panel
# set (report #28).
func test_mount_returns_the_mounted_instance() -> void:
	var hud := Node.new()
	add_child_autofree(hud)
	var router := ReplyRouter.new()
	var mounted := WardrobePanel.mount(hud, func(_m): pass, func(): return false, router)
	assert_not_null(mounted)
	assert_same(mounted, hud.get_node_or_null("WardrobePanel"))
	assert_true(mounted is WardrobePanel)


func _key_event(code: int) -> InputEventKey:
	var ev := InputEventKey.new()
	ev.keycode = code
	ev.physical_keycode = code  # T-761: the panel dispatches on the PHYSICAL code
	ev.pressed = true
	return ev


# T-571 (report #28): Esc used to close the panel locally AND race main.gd's own Esc handling
# (which didn't know this panel existed), sometimes leaving Options opening on top of it. Esc
# precedence is now main.gd's alone (SettingsEscGate) — this panel must no longer react to it.
func test_escape_does_not_close_the_wardrobe_locally_anymore() -> void:
	_panel._input(_key_event(KEY_V))
	assert_true(_panel.visible)
	_panel._input(_key_event(KEY_ESCAPE))
	assert_true(_panel.visible, "Esc is main.gd's call now, not this panel's own")
