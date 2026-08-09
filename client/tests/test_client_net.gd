extends GutTest

# T-048: the client network layer's router/intent brain (RefCounted, transport-injected) must be
# unit-testable without a live peer — inject a fake send + fake handlers, assert intents + routing.

const ClientNet = preload("res://scripts/net/client_net.gd")
const HudHandlers = preload("res://scripts/net/hud_handlers.gd")
const QuestLogPanel = preload("res://scripts/ui/quest_log_panel.gd")
const InventoryPanel = preload("res://scripts/ui/inventory_panel.gd")

var _sent: Array = []
var _routed: Dictionary = {}


class _FakeCombat:
	extends RefCounted
	var events: Array = []

	func process_event(d: Dictionary) -> void:
		events.append(d)


func before_each() -> void:
	_sent = []
	_routed = {}


func _net():
	var n = ClientNet.new()
	n.setup(
		func(m): _sent.append(m),
		{
			"quest_log": func(p): _routed["quest_log"] = p,
			"inventory": func(p): _routed["inventory"] = p,
			"npc_indicators": func(p): _routed["npc_indicators"] = p,
			"result": func(p): _routed["result"] = p,
			"combat": func(p): _routed["combat"] = p,
			"positions": func(p): _routed["positions"] = p,
		}
	)
	return n


# ---- intents: client sends INTENT only, exact server-expected shapes ----


func test_quest_intents_build_correct_messages() -> void:
	var n = _net()
	n.request_quest_log()
	n.accept_quest("q007")
	n.turn_in("q007")
	n.talk("npc_drillmaster")
	n.abandon("q002")
	n.request_npc_indicators()
	assert_eq(_sent[0], {"type": "request_quest_log"})
	assert_eq(_sent[1], {"type": "accept_quest", "quest_id": "q007"})
	assert_eq(_sent[2], {"type": "turn_in", "quest_id": "q007"})
	assert_eq(_sent[3], {"type": "talk", "npc_id": "npc_drillmaster"})
	assert_eq(_sent[4], {"type": "abandon", "quest_id": "q002"})
	assert_eq(_sent[5], {"type": "request_npc_indicators"})


func test_inventory_intents_build_correct_messages() -> void:
	var n = _net()
	n.get_inventory()
	n.equip(3)
	n.unequip("head")
	n.drop("bag", 0, 2)
	assert_eq(_sent[0], {"type": "get_inventory"})
	assert_eq(_sent[1], {"type": "equip", "bag_slot": 3})
	assert_eq(_sent[2], {"type": "unequip", "equip_slot": "head"})
	assert_eq(_sent[3], {"type": "drop", "slot_type": "bag", "slot_index": 0, "count": 2})


# ---- server → client routing (whole dict to the right handler) ----


func test_routes_quest_log() -> void:
	_net().handle_server_message({"type": "quest_log", "result": {"quests": [1, 2]}})
	assert_eq(_routed["quest_log"], {"type": "quest_log", "result": {"quests": [1, 2]}})


func test_routes_inventory_family() -> void:
	for t in ["inventory", "equip_result", "unequip_result", "drop_result"]:
		_routed = {}
		_net().handle_server_message({"type": t, "slots": []})
		assert_eq(_routed["inventory"]["type"], t, "%s → inventory handler" % t)


func test_routes_social_discovery_and_help_subscription() -> void:
	var n = ClientNet.new()
	n.setup(
		func(_m): pass,
		{
			"social": func(p): _routed["social"] = p,
			"chat": func(p): _routed["chat"] = p,
		}
	)
	for t in ["guild_discovery", "guild_seek_board", "guild_who", "mentor_board", "mentor_result"]:
		_routed = {}
		n.handle_server_message({"type": t})
		assert_eq(str(_routed["social"]["type"]), t)
	_routed = {}
	n.handle_server_message({"type": "help_subscription", "subscribed": false})
	assert_eq(str(_routed["chat"]["type"]), "help_subscription")


func test_routes_wardrobe_replies_through_shared_reply_hub() -> void:
	var n = ClientNet.new()
	n.setup(func(_m): pass, {"pvp": func(p): _routed["pvp"] = p})
	for t in ["wardrobe_state", "wardrobe_result"]:
		_routed = {}
		n.handle_server_message({"type": t})
		assert_eq(str(_routed["pvp"]["type"]), t)


func test_routes_npc_indicators_and_quest_results() -> void:
	var n = _net()
	n.handle_server_message({"type": "npc_indicators", "npcs": [{"npc_id": "x"}]})
	assert_eq(_routed["npc_indicators"]["npcs"], [{"npc_id": "x"}])
	for t in ["accept_quest_result", "turn_in_result", "talk_result", "abandon_result"]:
		_routed = {}
		n.handle_server_message({"type": t, "ok": true})
		assert_eq(_routed["result"]["type"], t, "%s → result handler" % t)


func test_routes_combat_broadcasts() -> void:
	var n = _net()
	for t in ["ability_result", "ability_rejected", "cast_started", "mob_death"]:
		_routed = {}
		n.handle_server_message({"type": t})
		assert_eq(_routed["combat"]["type"], t, "%s → combat handler" % t)


func test_request_move_intent() -> void:
	_net().request_move(1.5, -2.0)
	assert_eq(_sent[0], {"type": "request_move", "dx": 1.5, "dy": -2.0})


func test_use_ability_intent() -> void:
	_net().request_use_ability(1, 1001)  # Strike on the dummy mob
	assert_eq(_sent[0], {"type": "use_ability", "ability_id": 1, "target_id": 1001})


func test_mount_toggle_sends_desire_only_and_routes_server_state() -> void:
	var n = _net()
	# T-572: mounting was a no-op because nothing ever cached the confirmed mount state for
	# LocalPlayer's speed prediction to read — _is_mounted() is that cache, fed ONLY by the
	# server's own mount_state reply (never asserted from the client's own toggle intent).
	assert_false(n._is_mounted(), "starts unmounted")
	n._toggle_mount()
	assert_eq(_sent[0], {"type": "mount_intent", "action": "toggle"})
	assert_false(n._is_mounted(), "the client never asserts mount state from its own intent")
	n.handle_server_message({"type": "mount_state", "ok": true, "mounted": true})
	assert_eq(str(_routed["result"]["type"]), "mount_state")
	assert_true(n._is_mounted(), "confirmed by the server")
	n.handle_server_message(
		{"type": "mount_state", "ok": true, "mounted": false, "reason": "damage"}
	)
	assert_false(n._is_mounted(), "server-forced dismount (e.g. taking damage) clears it")


func test_routes_positions_to_its_own_handler() -> void:
	# T-054: positions drives movement (local reconcile + remote entities), not combat feedback.
	_net().handle_server_message({"type": "positions", "players": [{"peer_id": 7}]})
	assert_eq(_routed["positions"]["players"], [{"peer_id": 7}])
	assert_false(_routed.has("combat"), "positions no longer routes to combat")


func test_unknown_type_is_ignored_no_crash() -> void:
	_net().handle_server_message({"type": "totally_unknown"})
	assert_eq(_routed, {}, "no handler fired for unknown type")


func test_missing_handler_does_not_crash() -> void:
	var n = ClientNet.new()
	n.setup(func(_m): pass, {})  # no handlers wired
	n.handle_server_message({"type": "quest_log", "result": {}})
	pass_test("routing with no handlers wired must not crash")


# ---- end-to-end: router → the real HUD widgets (via the shared wiring helper) ----


func test_router_feeds_hud_panels_end_to_end() -> void:
	var quest_panel = QuestLogPanel.new()
	var inv_panel = InventoryPanel.new()
	add_child_autofree(quest_panel)
	add_child_autofree(inv_panel)
	var combat = _FakeCombat.new()
	var n = ClientNet.new()
	n.setup(func(_m): pass, HudHandlers.build(quest_panel, inv_panel, combat))

	(
		n
		. handle_server_message(
			{
				"type": "quest_log",
				"result":
				{
					"quests":
					[
						{
							"quest_id": "q007",
							"title": "Proving Grounds",
							"state": "active",
							"objectives":
							[{"desc": "Defeat the dummy", "current": 1, "required": 1}],
						}
					]
				},
			}
		)
	)
	assert_true(quest_panel.get_text().contains("Proving Grounds"), "quest_log → panel render")

	(
		n
		. handle_server_message(
			{
				"type": "inventory",
				"slots":
				[
					{
						"slot_type": "bag",
						"slot_index": 0,
						"item_id": "itm_copper",
						"name": "Copper",
						"count": 5
					}
				],
			}
		)
	)
	var inv_text: String = inv_panel.get_text()
	assert_true(inv_text.contains("Copper") and inv_text.contains("x5"), "inventory → panel render")

	n.handle_server_message({"type": "mob_death", "mob_id": 1001})
	assert_eq(combat.events[0]["type"], "mob_death", "combat → feedback.process_event")


# ---- T-072: routing contract — every world-emitted type must reach a handler ----

# Every client-bound message type the world server emits (enumerated from _send_to_peer /
# _broadcast / world_rpc reply call sites). handshake_ok and pong are consumed by the
# transport layer before the router reaches them, so they are exempt here.
const WORLD_EMITTED_TYPES: Array = [
	"quest_log",
	"accept_quest_result",
	"turn_in_result",
	"talk_result",
	"abandon_result",
	"npc_indicators",
	"inventory",
	"equip_result",
	"unequip_result",
	"drop_result",
	"ability_result",
	"ability_rejected",
	"cast_started",
	"cast_cancelled",
	"mob_death",
	"mob_respawn",
	"player_death",
	"player_respawn",
	"class_kit",
	"positions",
	"spend_talent_result",
	"set_class_result",
	"set_gender_result",
	"talents",
	"player_stats",
	"quest_delta",
	"npc_indicator_delta",
	"mount_state",
	"discovery_earned",
	"instance_denied",  # T-648: used to fall through the router (_: pass) — now routed
	"rift_sealed",  # T-662 (#69): used to fall through the router (_: pass) — now routed
]


func _net_with_kit():
	var n = ClientNet.new()
	n.setup(
		func(m): _sent.append(m),
		{
			"quest_log": func(p): _routed["quest_log"] = p,
			"inventory": func(p): _routed["inventory"] = p,
			"npc_indicators": func(p): _routed["npc_indicators"] = p,
			"result": func(p): _routed["result"] = p,
			"combat": func(p): _routed["combat"] = p,
			"positions": func(p): _routed["positions"] = p,
			"class_kit": func(p): _routed["class_kit"] = p,
			"talents": func(p): _routed["talents"] = p,
			"player_stats": func(p): _routed["player_stats"] = p,
			"quest_delta": func(p): _routed["quest_delta"] = p,
			"achievements": func(p): _routed["achievements"] = p,
		}
	)
	return n


func test_class_kit_routes_to_its_handler() -> void:
	var n = _net_with_kit()
	n.handle_server_message(
		{"type": "class_kit", "char_class": "warrior", "abilities": [{"id": 101}]}
	)
	assert_true(_routed.has("class_kit"), "class_kit must reach the registered handler")
	assert_eq((_routed["class_kit"] as Dictionary).get("abilities", []).size(), 1)


func test_death_respawn_and_cast_cancel_route_to_combat() -> void:
	var n = _net_with_kit()
	for t in ["cast_cancelled", "player_death", "player_respawn", "mob_respawn"]:
		_routed = {}
		n.handle_server_message({"type": t})
		assert_true(_routed.has("combat"), "'%s' must route to the combat handler" % t)


func test_discovery_confirmation_routes_to_achievement_toast_layer() -> void:
	var n = _net_with_kit()
	n.handle_server_message({"type": "discovery_earned", "node": {"name": "Old Well"}, "xp": 40})
	assert_eq(str(_routed["achievements"]["node"]["name"]), "Old Well")


func test_contract_every_world_emitted_type_routes() -> void:
	var n = _net_with_kit()
	for t in WORLD_EMITTED_TYPES:
		_routed = {}
		n.handle_server_message({"type": t})
		assert_false(_routed.is_empty(), "world-emitted '%s' fell through the router (_: pass)" % t)
