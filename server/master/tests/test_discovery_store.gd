extends GutTest

# T-427: first-entry discovery persistence + rewards. The store is the master-owned gate: a
# server-observed node pays once per character, survives repeat entry, and feeds achievements.

const CharacterManager = preload("res://scripts/character_manager.gd")
const DiscoveryStore = preload("res://scripts/discovery_store.gd")
const AchievementRegistry = preload("res://scripts/achievement_registry.gd")
const ServicesStore = preload("res://scripts/services_store.gd")
const TelemetryStore = preload("res://scripts/telemetry_store.gd")
const Leveling = preload("res://scripts/leveling.gd")

const _ACHIEVEMENTS := [
	{
		"id": "first_footfall",
		"name": "First Footfall",
		"criteria": {"event": "discovery", "key": "*", "count": 1},
		"reward": {}
	}
]


func before_each() -> void:
	CharacterManager.reset_for_test()
	DiscoveryStore.reset_for_test()
	TelemetryStore.reset_for_test()
	AchievementRegistry._override_for_test(_ACHIEVEMENTS)


func _node(id: String = "hamlet_churchyard") -> Dictionary:
	return {
		"id": id,
		"name": "The Hamlet Churchyard",
		"zone": "era_1_hamlet",
		"level": 1,
		"xp": 40,
		"coins": 15,
		"lore": "Old stones remember every bell."
	}


func _character(username: String) -> Dictionary:
	CharacterManager.ensure_character(username)
	return CharacterManager.get_character(username)


func test_first_discovery_grants_once_and_persists_across_reentry() -> void:
	var character := _character("alice")
	character["rested_pool"] = 20
	var cid := int(character["id"])
	var coins_before := ServicesStore.get_coins(cid)
	var first: Dictionary = DiscoveryStore.discover(cid, "alice", _node())
	assert_true(first["discovered"])
	assert_eq(int(first["xp"]), 40, "authored base XP granted")
	assert_eq(int(first["rested_bonus"]), 20, "discovery uses the rested-aware XP path")
	assert_eq(int(CharacterManager.get_character("alice")["xp"]), 60, "base + rested persisted")
	assert_eq(ServicesStore.get_coins(cid), coins_before + 15, "optional coin reward granted")
	assert_eq(first["achievements"][0]["id"], "first_footfall")

	var again: Dictionary = DiscoveryStore.discover(cid, "alice", _node())
	assert_false(again["discovered"], "the persisted character/node gate rejects re-entry")
	assert_eq(int(CharacterManager.get_character("alice")["xp"]), 60, "no duplicate XP")
	assert_eq(ServicesStore.get_coins(cid), coins_before + 15, "no duplicate coin")
	assert_eq(
		TelemetryStore.test_events().size(), 1, "only the first entry emits discovery telemetry"
	)


func test_discovery_is_once_per_character_not_global() -> void:
	var alice := _character("alice")
	var bob := _character("bob")
	assert_true(DiscoveryStore.discover(int(alice["id"]), "alice", _node())["discovered"])
	assert_true(DiscoveryStore.discover(int(bob["id"]), "bob", _node())["discovered"])


func test_gray_discovery_grants_no_xp_and_does_not_spend_rested() -> void:
	var character := _character("veteran")
	character["level"] = 10
	character["xp"] = Leveling.total_xp_for_level(10)
	character["rested_pool"] = 25
	var low_node := _node("old_well")
	low_node["level"] = 2  # exactly 8 below: mob_xp's gray cutoff
	var result: Dictionary = DiscoveryStore.discover(int(character["id"]), "veteran", low_node)
	assert_true(result["discovered"], "the landmark is still learned")
	assert_eq(int(result["xp"]), 0, "gray landmark pays no XP")
	assert_eq(int(result["rested_bonus"]), 0)
	assert_eq(int(character["rested_pool"]), 25, "zero award cannot drain rested")


func test_invalid_definition_fails_closed_without_claiming() -> void:
	var character := _character("alice")
	var result: Dictionary = DiscoveryStore.discover(
		int(character["id"]), "alice", {"id": "", "xp": 999}
	)
	assert_false(result["discovered"])
	assert_eq(str(result["reason"]), "invalid_node")
	assert_eq(int(character["xp"]), 0)
