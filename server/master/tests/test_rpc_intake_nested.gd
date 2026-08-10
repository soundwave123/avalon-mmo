extends "res://addons/gut/test.gd"
# T-754 (part 2): NESTED shape hardening on the master's post-auth dispatch surface.
#
# Split from test_rpc_intake.gd purely to stay under gdlint's max-public-methods; part 1
# covers the untrusted ENVELOPE (params/id/method/secret), this file covers what lives
# INSIDE an authenticated params bag.
#
# The distinction that matters: a Dictionary params bag says nothing about its MEMBERS.
# {"quest": []} still fed a typed Dictionary parameter and aborted the frame, so the
# envelope guard alone is not enough. The dispatch arms read through RpcIntake.shaped(),
# whose fallback type IS the schema (params.get("quest", {}) wants a Dictionary,
# params.get("items", []) wants an Array).

const Main = preload("res://scripts/main.gd")
const CharacterManager = preload("res://scripts/character_manager.gd")
const DiscoveryStore = preload("res://scripts/discovery_store.gd")
const TelemetryStore = preload("res://scripts/telemetry_store.gd")
const QuestStateMachine = preload("res://scripts/quest_state_machine.gd")

var _main: Node


func before_each() -> void:
	CharacterManager.reset_for_test()
	DiscoveryStore.reset_for_test()
	TelemetryStore.reset_for_test()
	_main = Main.new()


func after_each() -> void:
	if _main != null:
		_main.free()
		_main = null


# ------------------------------------------------------- nested (post-auth) shapes

# A Dictionary params bag says nothing about its MEMBERS. `{"quest": []}` still fed a typed
# Dictionary parameter and aborted the frame, so the envelope guard alone is not enough —
# the dispatch arms read through RpcIntake.shaped(), whose fallback type IS the schema.


func _nested_shapes() -> Array:
	"""Wrong-typed values for a nested params member."""
	return ["[]", "5", '"s"', "null", "true", "[[]]", "[null]", '{"k":1}']


func test_nested_quest_of_the_wrong_shape_is_survivable() -> void:
	CharacterManager.ensure_character("alice")
	for fragment: String in _nested_shapes():
		var raw: String = (
			'{"method":"accept_quest","params":{"username":"alice","quest":%s},"id":1}' % fragment
		)
		var out: String = _main._handle_message(raw)
		assert_false(out.is_empty(), "quest=%s aborted the handler" % fragment)
	assert_engine_error_count(0, "a wrong-shaped nested quest must not raise an engine error")


func test_nested_rewards_of_the_wrong_shape_is_survivable() -> void:
	# quest_state_machine.gd + character_manager.gd both read quest["rewards"] into a typed
	# Dictionary on the turn-in path — the two sites the ticket names.
	CharacterManager.ensure_character("alice")
	for fragment: String in _nested_shapes():
		var raw: String = (
			'{"method":"turn_in","params":{"username":"alice","quest":{"id":"q1","rewards":%s}},"id":1}'
			% fragment
		)
		var out: String = _main._handle_message(raw)
		assert_false(out.is_empty(), "rewards=%s aborted the handler" % fragment)
	assert_engine_error_count(0, "wrong-shaped rewards must not raise an engine error")


func test_reward_items_with_non_dictionary_entries_are_skipped() -> void:
	# `for it: Dictionary in rewards.get("items", [])` aborted on a scalar entry.
	var evaluated: Variant = QuestStateMachine.evaluate_turn_in(
		{"id": "q1", "rewards": {"xp": 5, "items": [1, "two", null, {"item": "sword"}]}},
		"active",
		true,
		true
	)
	assert_not_null(evaluated, "evaluate_turn_in aborted on mixed reward items")
	assert_engine_error_count(0, "mixed-type reward items must not raise an engine error")


func test_quest_state_machine_tolerates_every_rewards_shape() -> void:
	for rewards: Variant in [[], 5, "s", null, true, {"xp": 1}]:
		var res: Variant = QuestStateMachine.evaluate_turn_in(
			{"id": "q1", "rewards": rewards}, "active", true, true
		)
		assert_not_null(res, "evaluate_turn_in aborted on rewards=%s" % str(rewards))
	assert_engine_error_count(0, "no rewards shape may raise an engine error")


func test_nested_objectives_of_the_wrong_shape_is_survivable() -> void:
	CharacterManager.ensure_character("alice")
	for fragment: String in _nested_shapes():
		var raw: String = (
			'{"method":"accept_quest","params":{"username":"alice",'
			+ '"quest":{"id":"q1","objectives":%s}},"id":1}' % fragment
		)
		var out: String = _main._handle_message(raw)
		assert_false(out.is_empty(), "objectives=%s aborted the handler" % fragment)
	assert_engine_error_count(0, "wrong-shaped objectives must not raise an engine error")


func test_nested_quest_defs_with_non_dictionary_values_is_survivable() -> void:
	# quest_defs[quest_id] was indexed straight into a typed Dictionary.
	CharacterManager.ensure_character("alice")
	for fragment: String in _nested_shapes():
		var raw: String = (
			'{"method":"credit_kill","params":{"username":"alice","mob_id":"m1",'
			+ '"quest_defs":{"q1":%s}},"id":1}' % fragment
		)
		var out: String = _main._handle_message(raw)
		assert_false(out.is_empty(), "quest_defs.q1=%s aborted the handler" % fragment)
	assert_engine_error_count(0, "wrong-shaped quest_defs values must not raise engine errors")


func test_npc_indicator_list_with_non_dictionary_entries_is_survivable() -> void:
	# `for npc: Dictionary in npcs` aborted on a scalar entry.
	CharacterManager.ensure_character("alice")
	var raw: String = (
		'{"method":"npc_indicators","params":'
		+ '{"username":"alice","npcs":[1,"two",null,{"id":"npc_geld"}]},"id":1}'
	)
	var out: String = _main._handle_message(raw)
	assert_false(out.is_empty(), "a mixed npcs array aborted the handler")
	assert_engine_error_count(0, "mixed-type npc entries must not raise an engine error")


func test_fuzz_nested_members_across_the_quest_surface() -> void:
	# Sweep wrong shapes through every nested member the quest/turn-in path reads.
	CharacterManager.ensure_character("alice")
	var members: Array[String] = [
		"quest", "quest_defs", "item_registry", "npc", "npcs", "talent", "talent_defs", "rarities"
	]
	var checked: int = 0
	for member: String in members:
		for fragment: String in _nested_shapes():
			for method: String in ["accept_quest", "turn_in", "talk", "spend_talent", "equip"]:
				var raw: String = (
					'{"method":"%s","params":{"username":"alice","%s":%s},"id":1}'
					% [method, member, fragment]
				)
				var out: String = _main._handle_message(raw)
				assert_false(
					out.is_empty(),
					"method=%s %s=%s aborted the handler" % [method, member, fragment]
				)
				checked += 1
	assert_eq(checked, members.size() * _nested_shapes().size() * 5)
	assert_true(checked >= 300, "nested fuzz corpus shrank below its floor")
	assert_engine_error_count(0, "no nested member shape may raise an engine error")


# ------------------------------------------------ the ops-module surface (A-3/A-4)

# The *_ops / *_store modules receive the whole params bag and do their OWN nested reads
# (loot_ops' usernames/items, craft_ops' recipe/bonus, vendor_ops' wares, rift_ladder's
# reward, ...). Those are post-auth, but they are still typed assigns from wire data, so
# they read through _RI.shaped() too. This sweep drives every op arm with wrong shapes in
# the members those modules read.


func test_fuzz_ops_module_surface_survives_wrong_shapes() -> void:
	CharacterManager.ensure_character("alice")
	var ops_methods: Array[String] = [
		"grant_loot",
		"grant_dungeon_loot",
		"craft_op",
		"gather_op",
		"recipe_op",
		"use_item_op",
		"vendor_op",
		"mail_op",
		"guild_op",
		"matchmake_op",
		"rift_op",
		"auction_op",
		"trade_op",
		"wardrobe_op",
		"repair_op",
		"ops_apply",
		"record_events",
	]
	var members: Array[String] = [
		"item_registry",
		"items",
		"usernames",
		"recipe",
		"bonus",
		"wares",
		"reward",
		"players",
		"guaranteed_items",
		"appearance",
		"dye",
		"events",
		"details",
		"quest_defs",
	]
	var checked: int = 0
	for method: String in ops_methods:
		for member: String in members:
			for fragment: String in _nested_shapes():
				var raw: String = (
					'{"method":"%s","params":{"username":"alice","%s":%s},"id":1}'
					% [method, member, fragment]
				)
				var out: String = _main._handle_message(raw)
				assert_false(
					out.is_empty(),
					"method=%s %s=%s aborted the handler" % [method, member, fragment]
				)
				checked += 1
	assert_eq(checked, ops_methods.size() * members.size() * _nested_shapes().size())
	assert_true(checked >= 1900, "ops fuzz corpus shrank below its floor")
	assert_engine_error_count(0, "no ops-module nested shape may raise an engine error")
