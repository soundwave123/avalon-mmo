extends GutTest

# T-367: per-character achievement persistence (test-mode fakes). Progress advances on observed
# events, completion fires once and grants its reward atomically, and list() feeds the client panel.

const CharacterManager = preload("res://scripts/character_manager.gd")
const AchievementStore = preload("res://scripts/achievement_store.gd")
const AchievementRegistry = preload("res://scripts/achievement_registry.gd")
const ServicesStore = preload("res://scripts/services_store.gd")

const _DEFS := [
	{
		"id": "first_blood",
		"name": "First Blood",
		"criteria": {"event": "kill", "key": "*", "count": 1},
		"reward": {"title": "the Blooded"}
	},
	{
		"id": "slayer",
		"name": "Slayer",
		"criteria": {"event": "kill", "key": "*", "count": 3},
		"reward": {"coin": 100}
	},
]


func before_each() -> void:
	CharacterManager.reset_for_test()
	AchievementRegistry._override_for_test(_DEFS)


func _mk(username: String) -> int:
	CharacterManager.ensure_character(username)
	return int(CharacterManager.get_character(username)["id"])


func test_observe_earns_and_returns_full_def() -> void:
	var cid := _mk("alice")
	var r := AchievementStore.observe(cid, "kill", "wolf")
	assert_eq(r["newly_earned"].size(), 1)
	assert_eq(str(r["newly_earned"][0]["id"]), "first_blood")
	assert_eq(
		str(r["newly_earned"][0]["name"]), "First Blood", "the full row rides back for the toast"
	)


func test_completion_fires_once_and_grants_coin_atomically() -> void:
	var cid := _mk("alice")
	var before := ServicesStore.get_coins(cid)
	AchievementStore.observe(cid, "kill", "a")
	AchievementStore.observe(cid, "kill", "b")
	var r := AchievementStore.observe(cid, "kill", "c")  # 3rd kill clears slayer (coin 100)
	assert_eq(str(r["newly_earned"][0]["id"]), "slayer")
	assert_eq(ServicesStore.get_coins(cid), before + 100, "slayer's coin reward granted once")
	# Further kills never re-earn slayer nor re-grant the coin.
	AchievementStore.observe(cid, "kill", "d")
	assert_eq(ServicesStore.get_coins(cid), before + 100, "no double grant on re-counted kills")


func test_list_reports_earned_and_fraction() -> void:
	var cid := _mk("alice")
	AchievementStore.observe(cid, "kill", "a")
	var view: Array = AchievementStore.list(cid)["achievements"]
	assert_eq(view.size(), 2, "every def appears in the panel feed")
	var by_id := {}
	for a in view:
		by_id[str(a["id"])] = a
	assert_true(bool(by_id["first_blood"]["earned"]), "cleared def is flagged earned")
	assert_false(bool(by_id["slayer"]["earned"]))
	assert_almost_eq(
		float(by_id["slayer"]["fraction"]), 1.0 / 3.0, 0.01, "in-progress fraction shown"
	)


func test_unknown_character_is_a_safe_noop() -> void:
	var r := AchievementStore.observe(-1, "kill", "x")
	assert_eq(r["newly_earned"].size(), 0)


# ---- T-700 Stage 1: cache + batched-delta write ------------------------------


# One observe = ONE batched counter-write invocation (was: one psql subprocess per counter key).
func test_observe_writes_a_single_batched_invocation() -> void:
	var cid := _mk("alice")
	AchievementStore._persist_invocations = 0  # reset the instrument after ensure_character churn
	AchievementStore.observe(cid, "kill", "wolf")
	assert_eq(AchievementStore._persist_invocations, 1, "a single batched write, not one per key")


# The delta writes ONLY the counters that changed this event — NOT the whole owned set (the write-
# amplification cure). After the character owns many counters, one more kill persists just two keys.
func test_observe_persists_only_changed_keys_not_the_whole_set() -> void:
	var cid := _mk("alice")
	for m in ["a", "b", "c", "d", "e"]:  # builds up kill:* + 5 per-mob keys (+ earn-derived metas)
		AchievementStore.observe(cid, "kill", m)
	assert_gt(
		AchievementStore._cache_counters[cid].size(), 3, "the character now owns many counters"
	)
	AchievementStore._persist_invocations = 0
	AchievementStore.observe(cid, "kill", "f")  # a new mob, no new achievement earns at this point
	assert_eq(AchievementStore._persist_invocations, 1, "still one batched invocation")
	var keys: Array = AchievementStore._last_persisted_keys
	assert_eq(keys.size(), 2, "only the running total + the new per-mob tally, not every owned key")
	assert_true("kill:*" in keys and "kill:f" in keys)


# A re-observed MAX event that does not advance the high-water mark writes NOTHING.
func test_noop_event_writes_no_invocation() -> void:
	var cid := _mk("alice")
	AchievementStore.observe(cid, "level", "*", 5)
	AchievementStore._persist_invocations = 0
	AchievementStore.observe(cid, "level", "*", 5)  # 5 is not > 5 → no counter changes
	assert_eq(AchievementStore._persist_invocations, 0, "an unchanged event never touches the DB")


# The cache is authoritative and always equals a fresh store read after each event (parity guard).
func test_cache_equals_fresh_read_after_each_event() -> void:
	var cid := _mk("alice")
	for target in ["a", "b", "a", "c"]:  # includes a repeat (a) so the per-mob tally advances twice
		AchievementStore.observe(cid, "kill", target)
		assert_eq(
			AchievementStore._cache_counters[cid],
			AchievementStore._test_counters[cid],
			"cached counters match the persisted (DB) counters"
		)
	assert_eq(
		AchievementStore._cache_counters[cid].get("kill:*", 0), 4, "four kills counted in total"
	)
	assert_eq(AchievementStore._cache_counters[cid].get("kill:a", 0), 2, "mob a killed twice")


# evict() drops the cache; the next observe re-hydrates from the store and keeps counting correctly.
func test_evict_rehydrates_from_store_without_losing_progress() -> void:
	var cid := _mk("alice")
	AchievementStore.observe(cid, "kill", "a")
	AchievementStore.observe(cid, "kill", "b")  # kill:* == 2
	AchievementStore.evict(cid)
	assert_false(AchievementStore._cache_counters.has(cid), "cache dropped on eviction")
	AchievementStore.observe(cid, "kill", "c")  # must resume from the persisted 2, not 0
	assert_eq(
		AchievementStore._cache_counters[cid].get("kill:*", 0), 3, "progress survived eviction"
	)


# Cross-check earn parity under the cache: the 3rd kill still clears slayer exactly once.
func test_earn_parity_under_cache_with_eviction_between_kills() -> void:
	var cid := _mk("alice")
	var before := ServicesStore.get_coins(cid)
	AchievementStore.observe(cid, "kill", "a")
	AchievementStore.evict(cid)
	AchievementStore.observe(cid, "kill", "b")
	AchievementStore.evict(cid)
	var r := AchievementStore.observe(cid, "kill", "c")  # 3rd kill clears slayer even across evictions
	assert_eq(str(r["newly_earned"][0]["id"]), "slayer", "earn fires at the same moment as before")
	assert_eq(ServicesStore.get_coins(cid), before + 100, "reward granted exactly once")
