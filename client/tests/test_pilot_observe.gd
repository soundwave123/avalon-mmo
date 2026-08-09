extends GutTest

# T-562: unit-tests for the PURE observe serializer (PilotObserve.build). The live gather() reads a
# running client and is orchestrator-pilot-verified after merge; build() takes a mock game-state, so
# the JSON shape + hp_delta + nearby sort + log tail are all provable headlessly here.

const PilotObserve = preload("res://scripts/dev/pilot_observe.gd")


# Mock character_sheet_panel for testing _live_player's authoritative stats source (T-581).
class MockCharacterSheetPanel:
	var _last: Dictionary

	func _init(stats: Dictionary) -> void:
		_last = stats

	func get_last() -> Dictionary:
		return _last


# Mock main Node for testing _live_player (T-581).
class MockMainNode:
	extends Node

	var _my_peer_id: int
	var last_positions: Dictionary
	var character_sheet_panel: Variant

	func _init(peer_id: int, positions: Dictionary, panel: Variant = null) -> void:
		_my_peer_id = peer_id
		last_positions = positions
		character_sheet_panel = panel


func _mock_raw() -> Dictionary:
	return {
		"player":
		{
			"hp": 80,
			"max_hp": 120,
			"mana": 30,
			"max_mana": 50,
			"resource_kind": "mana",
			"class": "mage",
			"level": 7,
			"position": {"x": 12.34, "z": -5.06},
		},
		"active_quest":
		{
			"name": "Wolves at the Gate",
			"objectives":
			[{"text": "Slay 3 wolves", "done": false}, {"text": "Report back", "done": true}],
		},
		"inventory":
		[
			{"name": "Iron Sword", "count": 1},
			{"name": "Health Potion", "count": 5},
			{"name": "", "count": 9},  # empty-name slot: dropped by the serializer
		],
		"nearby":
		[
			{"name": "Wolf", "kind": "mob", "distance": 12.5, "hostile": true},
			{"name": "Guard", "kind": "npc", "distance": 3.2, "hostile": false},
			{"name": "Ally", "kind": "player", "distance": 8.0, "hostile": false},
		],
		"recent_log": ["l1", "l2", "l3", "l4", "l5", "l6", "l7", "l8", "l9", "l10"],
		"ui_panel": "inventory",
	}


func test_shape_has_all_top_level_keys() -> void:
	var snap := PilotObserve.build(_mock_raw(), {})
	for key in ["player", "active_quest", "inventory", "nearby", "recent_log", "ui_panel"]:
		assert_has(snap, key, "snapshot exposes %s" % key)
	assert_eq(snap["ui_panel"], "inventory", "open panel passes through")


func test_player_fields_normalized_and_alive_derived() -> void:
	var p: Dictionary = PilotObserve.build(_mock_raw(), {})["player"]
	assert_eq(p["hp"], 80, "hp coerced")
	assert_eq(p["max_hp"], 120, "max_hp coerced")
	assert_eq(p["mana"], 30, "mana coerced")
	assert_eq(p["class"], "mage", "class passes through")
	assert_eq(p["level"], 7, "level coerced")
	assert_true(p["alive"], "alive derived from hp > 0")
	assert_almost_eq(float(p["position"]["x"]), 12.3, 0.001, "position x snapped to 0.1")
	assert_almost_eq(float(p["position"]["z"]), -5.1, 0.001, "position z snapped to 0.1")


func test_alive_false_when_hp_zero() -> void:
	var raw := _mock_raw()
	raw["player"]["hp"] = 0
	assert_false(PilotObserve.build(raw, {})["player"]["alive"], "hp 0 -> dead")


func test_hp_delta_is_zero_on_first_observe() -> void:
	assert_eq(PilotObserve.build(_mock_raw(), {})["player"]["hp_delta"], 0, "no prev -> delta 0")


func test_hp_delta_drops_and_rises_vs_prev() -> void:
	var prev := PilotObserve.build(_mock_raw(), {})  # hp 80
	var falling := _mock_raw()
	falling["player"]["hp"] = 60
	assert_eq(PilotObserve.build(falling, prev)["player"]["hp_delta"], -20, "took 20 damage -> -20")
	var healing := _mock_raw()
	healing["player"]["hp"] = 95
	assert_eq(PilotObserve.build(healing, prev)["player"]["hp_delta"], 15, "healed 15 -> +15")


func test_nearby_sorted_by_distance_ascending() -> void:
	var nearby: Array = PilotObserve.build(_mock_raw(), {})["nearby"]
	assert_eq(nearby.size(), 3, "all three entities kept")
	assert_eq(nearby[0]["name"], "Guard", "nearest first (3.2)")
	assert_eq(nearby[1]["name"], "Ally", "middle (8.0)")
	assert_eq(nearby[2]["name"], "Wolf", "farthest last (12.5)")
	assert_true(nearby[2]["hostile"], "hostile flag preserved")


func test_nearby_defaults_missing_fields() -> void:
	var snap := PilotObserve.build({"nearby": [{"name": "Mystery"}]}, {})
	var e: Dictionary = snap["nearby"][0]
	assert_eq(e["kind"], "", "missing kind -> empty")
	assert_eq(e["distance"], 0.0, "missing distance -> 0")
	assert_false(e["hostile"], "missing hostile -> false")


func test_recent_log_keeps_last_eight() -> void:
	var log: Array = PilotObserve.build(_mock_raw(), {})["recent_log"]
	assert_eq(log.size(), 8, "capped to the last 8 lines")
	assert_eq(log[0], "l3", "oldest kept is l3 (l1/l2 dropped)")
	assert_eq(log[7], "l10", "newest kept is l10")


func test_recent_log_shorter_than_cap_is_untouched() -> void:
	var snap := PilotObserve.build({"recent_log": ["a", "b"]}, {})
	assert_eq(snap["recent_log"], ["a", "b"], "fewer than 8 lines pass through whole")


func test_inventory_drops_empty_named_slots() -> void:
	var inv: Array = PilotObserve.build(_mock_raw(), {})["inventory"]
	assert_eq(inv.size(), 2, "empty-name slot dropped")
	assert_eq(inv[0], {"name": "Iron Sword", "count": 1}, "first item normalized")
	assert_eq(inv[1]["count"], 5, "stack count preserved")


# T-566: the observe serializer's inventory contract is DATA-driven, not UI-driven — build() must
# list real bag items regardless of which panel (if any) happens to be open. This locks the pure-
# layer half of the T-566 fix at the unit-test level; the live half (gather()'s _live_inventory()
# now force-requests fresh slots via ClientNet.get_inventory() on every call instead of relying on
# the panel's I-keypress-only fetch, and inventory_panel.gd's cells persist off the last server push
# regardless of Control.visible) is orchestrator-pilot-verified after merge, per this file's header.
func test_inventory_present_with_panel_closed() -> void:
	var raw := _mock_raw()
	raw["ui_panel"] = "none"  # no panel open at all — build() must not care
	var snap := PilotObserve.build(raw, {})
	assert_eq(snap["ui_panel"], "none", "no panel open")
	var inv: Array = snap["inventory"]
	assert_eq(inv.size(), 2, "bag items still listed with every panel closed")
	assert_eq(inv[0], {"name": "Iron Sword", "count": 1}, "item shape unaffected by ui_panel")


func test_inventory_present_with_a_different_panel_open() -> void:
	var raw := _mock_raw()
	raw["ui_panel"] = "quest_log"  # some OTHER panel open, not inventory
	var inv: Array = PilotObserve.build(raw, {})["inventory"]
	assert_eq(inv.size(), 2, "bag items listed even when a different panel is the one open")


func test_active_quest_objectives_shape() -> void:
	var q: Dictionary = PilotObserve.build(_mock_raw(), {})["active_quest"]
	assert_eq(q["name"], "Wolves at the Gate", "quest name")
	assert_eq(q["objectives"].size(), 2, "both objectives kept")
	assert_false(q["objectives"][0]["done"], "first objective open")
	assert_true(q["objectives"][1]["done"], "second objective done")


func test_no_active_quest_is_empty_dict() -> void:
	assert_eq(PilotObserve.build({}, {})["active_quest"], {}, "no quest -> {}")


# T-581: _live_player sources level and max_mana from character_sheet_panel's player_stats
# (server authority) rather than the positions broadcast. The gather() is orchestrator-
# pilot-verified after merge; we unit-test the fallback paths here.
func test_live_player_uses_character_sheet_panel_stats_when_available() -> void:
	var positions: Dictionary = {
		"players":
		[
			{
				"peer_id": 123,
				"hp": 80,
				"max_hp": 120,
				"resource": 30,
				"max_resource": 100,
				"resource_kind": "mana",
				"char_class": "mage",
				"level": 0,
				"x": 10.0,
				"z": 20.0
			}
		]
	}
	var panel = MockCharacterSheetPanel.new({"level": 2, "derived": {"max_mana": 150}})
	var main = MockMainNode.new(123, positions, panel)

	var player := PilotObserve._live_player(main)
	assert_eq(player["level"], 2, "level from character_sheet_panel stats (2 not 0)")
	assert_eq(player["max_mana"], 150, "max_mana from derived stats (150 not 100)")
	main.queue_free()


func test_live_player_falls_back_to_entry_when_no_stats() -> void:
	var positions: Dictionary = {
		"players":
		[
			{
				"peer_id": 456,
				"hp": 60,
				"max_hp": 100,
				"resource": 20,
				"max_resource": 75,
				"resource_kind": "stamina",
				"char_class": "warrior",
				"level": 5,
				"x": 30.0,
				"z": 40.0
			}
		]
	}
	var main = MockMainNode.new(456, positions, null)

	var player := PilotObserve._live_player(main)
	assert_eq(player["level"], 5, "level from positions broadcast entry (no panel)")
	assert_eq(player["max_mana"], 75, "max_mana from entry max_resource (no panel)")
	main.queue_free()


func test_live_player_falls_back_when_panel_has_no_stats_yet() -> void:
	var positions: Dictionary = {
		"players":
		[
			{
				"peer_id": 789,
				"hp": 40,
				"max_hp": 80,
				"resource": 15,
				"max_resource": 50,
				"resource_kind": "mana",
				"char_class": "rogue",
				"level": 3,
				"x": 50.0,
				"z": 60.0
			}
		]
	}
	var panel = MockCharacterSheetPanel.new({})
	var main = MockMainNode.new(789, positions, panel)

	var player := PilotObserve._live_player(main)
	assert_eq(player["level"], 3, "level from entry when panel stats empty")
	assert_eq(player["max_mana"], 50, "max_mana from entry when panel stats empty")
	main.queue_free()


# ---- T-730/T-738: the map key ----


func test_build_passes_map_state_through() -> void:
	var raw := _mock_raw()
	raw["map"] = {
		"world_map": {"open": true, "zone": "heartwold", "marker_kinds": {"hub": 2}},
		"minimap": {"visible": true, "rotate": false, "zoom": 1, "counts": {"quest": 3}},
	}
	var snap := PilotObserve.build(raw, {})
	assert_eq(snap["map"]["world_map"]["zone"], "heartwold")
	assert_eq(int(snap["map"]["minimap"]["counts"]["quest"]), 3)


func test_build_defaults_map_to_empty_dict() -> void:
	assert_eq(PilotObserve.build(_mock_raw(), {})["map"], {}, "no map raw -> {}")
