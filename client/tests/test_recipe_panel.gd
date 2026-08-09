extends "res://addons/gut/test.gd"
# T-414 (slice 3): RecipePanel — renders the learned/teachable recipes from recipe_catalog, emits
# craft/learn INTENTS on click, and folds craft/gather/learn results into the panel + combat log.
# Headless, mirroring test_pvp_panel / test_inventory_panel.

const RecipePanel = preload("res://scripts/ui/recipe_panel.gd")
const ReplyRouter = preload("res://scripts/net/reply_router.gd")


class FakeLog:
	extends RefCounted
	var lines: Array = []

	func add_entry(msg: String, _color) -> void:
		lines.append(msg)


var _panel: RecipePanel = null
var _sent: Array = []
var _router = null
var _log: FakeLog = null


func before_each() -> void:
	_panel = RecipePanel.new()
	add_child(_panel)
	await get_tree().process_frame
	_sent = []
	_router = ReplyRouter.new()
	_log = FakeLog.new()
	_panel.setup(func(m: Dictionary): _sent.append(m), func(): return false, _router, _log)


func after_each() -> void:
	_panel.queue_free()


func _catalog() -> Dictionary:
	return {
		"type": "recipe_catalog",
		"ok": true,
		"npc_id": "npc_alchemist",
		"recipes":
		[
			{
				"id": "rec_minor_healing",
				"name": "Minor Healing Potion",
				"trainer_id": "npc_alchemist",
				"coin_cost": 40,
				"inputs": [{"item": "itm_herb_bloodthorn", "count": 2}],
				"output": {"item": "itm_potion_minor_healing", "count": 1},
			},
			{
				"id": "rec_travelers_ration",
				"name": "Traveler's Ration",
				"trainer_id": "npc_alchemist",
				"coin_cost": 40,
				"inputs": [{"item": "itm_herb_marshmint", "count": 2}],
				"output": {"item": "itm_ration_travelers", "count": 1},
			},
		],
		"known": ["rec_minor_healing"],
	}


func test_starts_hidden() -> void:
	assert_false(_panel.visible)


func test_catalog_renders_names_inputs_and_output() -> void:
	_panel.receive(_catalog())
	var t := _panel.get_text()
	assert_true(t.contains("Minor Healing Potion"), "recipe name shown")
	assert_true(
		t.contains("2x Herb Bloodthorn"), "input qty + display name (title-cased, no raw id)"
	)
	assert_true(t.contains("Potion Minor Healing"), "output item shown by display name")
	assert_false(t.contains("itm_"), "no raw item id leaks into the recipe list")


func test_known_recipe_shows_craft_and_teachable_shows_learn() -> void:
	_panel.receive(_catalog())
	var t := _panel.get_text()
	assert_string_contains(t, "url=craft|rec_minor_healing")  # known → craft
	assert_string_contains(t, "url=learn|rec_travelers_ration")  # taught here, not known → learn
	assert_false(t.contains("url=learn|rec_minor_healing"), "a known recipe offers no learn link")


func test_craft_click_sends_craft_intent_with_recipe_id() -> void:
	_panel.receive(_catalog())
	_panel._on_meta("craft|rec_minor_healing")
	assert_eq(_sent.size(), 1)
	assert_eq(str(_sent[0]["type"]), "craft")
	assert_eq(str(_sent[0]["recipe_id"]), "rec_minor_healing")
	assert_false(_sent[0].has("output"), "the client never names the output — server-resolved")


func test_learn_click_sends_learn_intent_with_trainer_npc() -> void:
	_panel.receive(_catalog())  # sets _trainer_npc = npc_alchemist
	_panel._on_meta("learn|rec_travelers_ration")
	assert_eq(_sent.size(), 1)
	assert_eq(str(_sent[0]["type"]), "learn_recipe")
	assert_eq(str(_sent[0]["npc_id"]), "npc_alchemist", "npc resolved from the last catalog seen")
	assert_eq(str(_sent[0]["recipe_id"]), "rec_travelers_ration")


func test_craft_result_ok_logs_a_line() -> void:
	_panel.receive(_catalog())
	(
		_panel
		. receive(
			{
				"type": "craft_result",
				"ok": true,
				"recipe_id": "rec_minor_healing",
				"output": {"item": "itm_potion_minor_healing", "count": 1},
			}
		)
	)
	assert_eq(_log.lines.size(), 1, "a craft outcome is a combat-log line")
	assert_true(str(_log.lines[0]).contains("Crafted"))
	# T-687: the crafted item names by display name, never a raw id.
	assert_true(
		str(_log.lines[0]).contains("Potion Minor Healing"), "craft toast uses display name"
	)
	assert_false(str(_log.lines[0]).contains("itm_"), "no raw item id in the craft toast")


func test_craft_result_failure_logs_reason() -> void:
	_panel.receive({"type": "craft_result", "ok": false, "reason": "missing_materials"})
	assert_true(str(_log.lines[0]).contains("missing_materials"))


func test_learn_result_updates_known_so_recipe_becomes_craftable() -> void:
	_panel.receive(_catalog())  # ration is learnable, not known
	assert_false(_panel.get_text().contains("url=craft|rec_travelers_ration"))
	(
		_panel
		. receive(
			{
				"type": "learn_recipe_result",
				"ok": true,
				"recipe_id": "rec_travelers_ration",
				"known": ["rec_minor_healing", "rec_travelers_ration"],
			}
		)
	)
	assert_string_contains(_panel.get_text(), "url=craft|rec_travelers_ration")


func test_gather_result_ok_logs_a_line() -> void:
	_panel.receive(
		{"type": "gather_result", "ok": true, "item_id": "itm_herb_bloodthorn", "count": 1}
	)
	assert_true(str(_log.lines[0]).contains("Gathered"))


func test_gather_result_uses_display_name_not_raw_id() -> void:
	# T-687 defect 2: the primary yield names by display name, never the raw itm_/underscored id.
	_panel.receive({"type": "gather_result", "ok": true, "item_id": "itm_ore_iron", "count": 2})
	assert_eq(_log.lines.size(), 1, "no bonus proc → exactly one line")
	assert_true(
		str(_log.lines[0]).contains("2x Ore Iron"), "display name (title-cased), not raw id"
	)
	assert_false(str(_log.lines[0]).contains("itm_"), "no raw prefix leaks")
	assert_false(str(_log.lines[0]).contains("_"), "no underscored id leaks")


func test_gather_result_bonus_surfaces_a_distinct_rare_find_toast() -> void:
	# T-687 defect 1 / T-677: a rare cross-find lands as its OWN loud line, on top of the primary.
	(
		_panel
		. receive(
			{
				"type": "gather_result",
				"ok": true,
				"item_id": "itm_herb_bloodthorn",
				"count": 1,
				"bonus_item_id": "itm_herb_emberbloom",
				"bonus_count": 1,
			}
		)
	)
	assert_eq(_log.lines.size(), 2, "primary yield AND a separate rare-find line")
	assert_true(str(_log.lines[0]).contains("Gathered"), "line 0 = the normal yield")
	assert_true(str(_log.lines[1]).contains("Rare find!"), "line 1 = the distinct rare spike")
	assert_true(str(_log.lines[1]).contains("Herb Emberbloom"), "rare toast names the bonus item")
	assert_false(str(_log.lines[1]).contains("itm_"), "rare toast carries no raw id")


func test_gather_result_no_bonus_shows_no_phantom_rare_toast() -> void:
	# Empty/absent bonus fields (the no-proc case) must NOT emit a bonus line.
	(
		_panel
		. receive(
			{
				"type": "gather_result",
				"ok": true,
				"item_id": "itm_herb_bloodthorn",
				"count": 1,
				"bonus_item_id": "",
				"bonus_count": 0,
			}
		)
	)
	assert_eq(_log.lines.size(), 1, "no proc → only the primary yield, no phantom rare toast")
	assert_false(str(_log.lines[0]).contains("Rare find!"), "no rare line when bonus is empty")


func test_replies_route_through_the_reply_router() -> void:
	# The live path: client_net dispatches the crafting reply set → ReplyRouter → the panel's
	# self-registered handler. Prove recipe_catalog reaches render via the router (no direct call).
	_router.route(_catalog())
	assert_true(_panel.get_text().contains("Minor Healing Potion"), "router fanned the catalog in")


func test_uses_solidwindow_frame_not_colorrect() -> void:
	assert_not_null(_panel.theme, "carries the shared UiTheme so SolidWindow resolves")
	var frame := _panel.get_node_or_null("Frame") as PanelContainer
	assert_not_null(frame, "a PanelContainer frame roots the window")
	assert_eq(frame.theme_type_variation, &"SolidWindow", "opaque deliberate-window variation")
	for child in _panel.get_children():
		assert_false(child is ColorRect, "no hand-rolled ColorRect box (T-400 idiom)")
