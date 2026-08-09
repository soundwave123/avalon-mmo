extends "res://addons/gut/test.gd"
# T-678: RenownStore — per-cid per-hub points, data-driven rank thresholds, hub attribution by
# turn-in-NPC prefix, the NO-daily-cap invariant (every grant lands, however many per day), the
# read-only op surface, and the REAL master dispatch path (turn_in -> renown grant), mirroring
# test_master_dispatch's Main._dispatch pattern. Shipped-config integrity rides at the bottom.

const Main = preload("res://scripts/main.gd")
const CharacterManager = preload("res://scripts/character_manager.gd")
const RenownStore = preload("res://scripts/renown_store.gd")

const _CFG := {
	"sources": {"quest_turnin": 50},
	"hubs":
	{
		"highkeep": {"name": "Highkeep", "npc_prefixes": ["npc_hk_"]},
		"ashmoor": {"name": "Ashmoor", "npc_prefixes": ["npc_ashmoor_"]},
	},
	"ranks":
	[
		{"rank": 1, "name": "Stranger", "points": 0},
		{"rank": 2, "name": "Newcomer", "points": 100},
		{"rank": 3, "name": "Exalted", "points": 250},
	],
}

var _main: Node


func before_each() -> void:
	CharacterManager.reset_for_test()  # also resets RenownStore (character_manager.gd hook)
	RenownStore._override_for_test(_CFG.duplicate(true))
	_main = Main.new()


func after_each() -> void:
	RenownStore._reload_for_test()
	if _main != null:
		_main.free()
		_main = null


func _cid(username: String) -> int:
	CharacterManager.ensure_character(username)
	return int(CharacterManager.get_character(username)["id"])


func _points(cid: int, hub: String) -> int:
	for row: Dictionary in RenownStore.list(cid)["renown"]:
		if str(row["hub"]) == hub:
			return int(row["points"])
	return -1


func test_observe_accrues_per_hub_and_per_character() -> void:
	var alice := _cid("alice")
	var bob := _cid("bob")
	var grant: Dictionary = RenownStore.observe(alice, "quest_turnin", "highkeep")
	assert_eq(int(grant["gained"]), 50, "source rate comes from data")
	assert_eq(int(grant["points"]), 50)
	RenownStore.observe(alice, "quest_turnin", "ashmoor")
	assert_eq(_points(alice, "highkeep"), 50, "hubs accrue independently (parallel tracks)")
	assert_eq(_points(alice, "ashmoor"), 50)
	assert_eq(_points(bob, "highkeep"), 0, "renown is per-character (owner decision)")


func test_observe_unknown_hub_or_event_is_noop() -> void:
	var cid := _cid("alice")
	assert_eq(RenownStore.observe(cid, "quest_turnin", "atlantis"), {}, "unknown hub no-ops")
	assert_eq(RenownStore.observe(cid, "spellcast", "highkeep"), {}, "unconfigured source no-ops")
	assert_eq(RenownStore.observe(-1, "quest_turnin", "highkeep"), {}, "bad cid no-ops")
	assert_eq(_points(cid, "highkeep"), 0)


func test_rank_thresholds_come_from_data() -> void:
	assert_eq(int(RenownStore.rank_for(0)["rank"]), 1)
	assert_eq(int(RenownStore.rank_for(99)["rank"]), 1)
	assert_eq(int(RenownStore.rank_for(100)["rank"]), 2, "threshold crossing is inclusive")
	assert_eq(str(RenownStore.rank_for(250)["name"]), "Exalted")
	assert_eq(RenownStore.next_rank_points(0), 100)
	assert_eq(RenownStore.next_rank_points(100), 250)
	assert_eq(RenownStore.next_rank_points(250), -1, "top of the track has no next threshold")


func test_no_daily_cap_every_grant_lands() -> void:
	# The ticket's anti-FOMO DoD: N grants in one session ALL accrue — no throttle path exists.
	var cid := _cid("alice")
	var rank_ups := 0
	for _i in range(10):
		var grant: Dictionary = RenownStore.observe(cid, "quest_turnin", "highkeep")
		if bool(grant["rank_up"]):
			rank_ups += 1
	assert_eq(_points(cid, "highkeep"), 500, "10 x 50 all landed, no daily cap")
	assert_eq(rank_ups, 2, "rank-ups fired exactly at the 100 and 250 crossings")


func test_hub_for_quest_resolves_by_turnin_npc_prefix() -> void:
	assert_eq(RenownStore.hub_for_quest({"turnin_npc": "npc_hk_bounty_board"}), "highkeep")
	assert_eq(RenownStore.hub_for_quest({"turnin_npc": "npc_ashmoor_sergeant"}), "ashmoor")
	assert_eq(RenownStore.hub_for_quest({"turnin_npc": "npc_village_parson"}), "")
	assert_eq(RenownStore.hub_for_quest({}), "")


func test_list_shows_every_hub_including_zero_progress() -> void:
	# Visible-but-unfilled is the goal-gradient hook — both hubs must render from day one.
	var rows: Array = RenownStore.list(_cid("alice"))["renown"]
	assert_eq(rows.size(), 2)
	for row: Dictionary in rows:
		assert_eq(int(row["points"]), 0)
		assert_eq(int(row["rank"]), 1)
		assert_eq(str(row["rank_name"]), "Stranger")
		assert_eq(int(row["next_points"]), 100)


func test_cache_parity_after_evict_matches_persisted_state() -> void:
	# T-700 discipline: the cache always equals a fresh store read after each event.
	var cid := _cid("alice")
	RenownStore.observe(cid, "quest_turnin", "highkeep")
	RenownStore.observe(cid, "quest_turnin", "highkeep")
	RenownStore.evict(cid)
	assert_eq(_points(cid, "highkeep"), 100, "re-hydrated points match the persisted total")
	assert_eq(RenownStore._persist_invocations, 2, "one single-row write per grant")


func test_op_is_a_read_only_surface() -> void:
	_cid("alice")
	var listing: Dictionary = _main._dispatch("renown_op", {"username": "alice", "action": "list"})
	assert_eq((listing["renown"] as Array).size(), 2)
	var forged: Dictionary = _main._dispatch(
		"renown_op", {"username": "alice", "action": "grant", "hub": "highkeep", "points": 9999}
	)
	assert_eq(str(forged["error"]), "unknown_action", "no client-reachable grant verb exists")
	var ghost: Dictionary = _main._dispatch("renown_op", {"username": "ghost", "action": "list"})
	assert_eq(str(ghost["error"]), "unknown_character")


func _hub_quest() -> Dictionary:
	return {
		"id": "q_hk_test",
		"min_level": 1,
		"prerequisite_quest": "",
		"giver_npc": "npc_hk_warrior_trainer",
		"turnin_npc": "npc_hk_warrior_trainer",
		"objectives": [{"type": "kill", "target": "mob_wolf", "count": 1}],
		"rewards": {"xp": 10, "items": []},
	}


func test_dispatch_turn_in_grants_renown_for_hub_quest() -> void:
	var cid := _cid("alice")
	CharacterManager.try_accept(cid, _hub_quest(), 5, true)
	CharacterManager.credit_objective(cid, _hub_quest(), "kill", "mob_wolf")
	var resp: Dictionary = _main._dispatch(
		"turn_in",
		{"username": "alice", "quest": _hub_quest(), "at_turnin_npc": true, "item_registry": {}}
	)
	assert_true(resp["ok"])
	assert_eq(_points(cid, "highkeep"), 50, "a Highkeep turn-in banked Highkeep renown")
	assert_eq(_points(cid, "ashmoor"), 0)


func test_dispatch_turn_in_non_hub_quest_grants_nothing() -> void:
	var cid := _cid("alice")
	var quest := _hub_quest()
	quest["id"] = "q_village_test"
	quest["giver_npc"] = "npc_village_parson"
	quest["turnin_npc"] = "npc_village_parson"
	CharacterManager.try_accept(cid, quest, 5, true)
	CharacterManager.credit_objective(cid, quest, "kill", "mob_wolf")
	var resp: Dictionary = _main._dispatch(
		"turn_in", {"username": "alice", "quest": quest, "at_turnin_npc": true, "item_registry": {}}
	)
	assert_true(resp["ok"])
	assert_eq(_points(cid, "highkeep"), 0, "village quests are not hub renown sources")


func test_shipped_config_integrity() -> void:
	# The catalog check: the REAL data file must keep the invariants the store derives from.
	RenownStore._reload_for_test()
	var cfg: Dictionary = RenownStore.config()
	assert_true((cfg.get("hubs", {}) as Dictionary).has("highkeep"), "shipped hub: highkeep")
	assert_true((cfg.get("hubs", {}) as Dictionary).has("ashmoor"), "shipped hub: ashmoor")
	assert_gt(int((cfg.get("sources", {}) as Dictionary).get("quest_turnin", 0)), 0)
	var ranks: Array = cfg.get("ranks", [])
	assert_gt(ranks.size(), 1, "at least two ranks so a bar exists")
	assert_eq(int((ranks[0] as Dictionary).get("points", -1)), 0, "rank 1 starts at 0 points")
	for i in range(1, ranks.size()):
		assert_gt(
			int((ranks[i] as Dictionary).get("points", 0)),
			int((ranks[i - 1] as Dictionary).get("points", 0)),
			"rank thresholds are strictly ascending"
		)
		assert_eq(int((ranks[i] as Dictionary).get("rank", 0)), i + 1, "rank numbers are 1..N")
