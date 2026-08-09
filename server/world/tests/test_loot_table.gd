# T-073: pure loot roll — data-driven drops with injected RNG.

extends GutTest

const _LOOT = preload("res://scripts/combat/loot_table.gd")

# T-709 fixtures (see the quest-critical section at the bottom): the shipped dummy/wolf tables.
const _DUMMY_LOOT := [
	{"item_id": "itm_practice_token", "chance": 1.0, "count_min": 1, "count_max": 1}
]
const _WOLF_LOOT := [
	{"item_id": "itm_wolf_pelt", "chance": 0.6, "count_min": 1, "count_max": 1},
	{"item_id": "itm_wolf_fang", "chance": 0.55, "count_min": 1, "count_max": 1},
]
const _RARITIES := {
	"itm_practice_token": "common", "itm_wolf_pelt": "common", "itm_wolf_fang": "common"
}


func _rng(seed_val: int = 42) -> RandomNumberGenerator:
	var r := RandomNumberGenerator.new()
	r.seed = seed_val
	return r


func test_chance_one_always_drops() -> void:
	var loot := [{"item_id": "itm_wolf_pelt", "chance": 1.0, "count_min": 1, "count_max": 1}]
	for i in range(20):
		var out := _LOOT.roll(loot, _rng(i))
		assert_eq(out.size(), 1, "chance 1.0 must always drop")
		assert_eq(out[0]["item"], "itm_wolf_pelt")
		assert_eq(int(out[0]["count"]), 1)


func test_chance_zero_never_drops() -> void:
	var loot := [{"item_id": "itm_wolf_pelt", "chance": 0.0}]
	for i in range(20):
		assert_eq(_LOOT.roll(loot, _rng(i)).size(), 0, "chance 0 must never drop")


func test_count_range_respected() -> void:
	var loot := [{"item_id": "itm_copper_ore", "chance": 1.0, "count_min": 1, "count_max": 2}]
	for i in range(30):
		var out := _LOOT.roll(loot, _rng(i))
		var c: int = int(out[0]["count"])
		assert_between(c, 1, 2, "count must stay inside [count_min, count_max]")


func test_multiple_entries_roll_independently() -> void:
	var loot := [
		{"item_id": "itm_copper_ore", "chance": 1.0},
		{"item_id": "itm_rugged_fiber", "chance": 1.0},
	]
	var out := _LOOT.roll(loot, _rng())
	assert_eq(out.size(), 2, "both guaranteed entries drop")


func test_empty_and_malformed_entries_are_safe() -> void:
	assert_eq(_LOOT.roll([], _rng()).size(), 0)
	assert_eq(_LOOT.roll([{"chance": 1.0}, "junk", 42], _rng()).size(), 0)


# --- T-709: quest-critical drops bypass the tier roll + bad-luck protection -------------------
# The dummy repro: difficulty 1 rolls ONE tier (junk5/common90/uncommon5); the token is the sole
# common row at chance 1.0, so P(first kill drops it) was 0.90 — 1-in-10 brand-new players saw
# nothing for "Recover a practice token". With the quest bypass it must be 1000/1000.


func _weights() -> Dictionary:
	var w: Dictionary = _LOOT.load_rarity_weights()
	assert_false(w.is_empty(), "shipped rarity_weights.json loads")
	return w


func _drop_count(out: Array, item_id: String) -> int:
	var n := 0
	for d: Dictionary in out:
		if str(d["item"]) == item_id:
			n += int(d["count"])
	return n


func test_quest_bypass_dummy_token_drops_on_every_kill() -> void:
	# Acceptance: 1000 simulated dummy kills with q_tut_01 active -> 1000 tokens.
	var weights := _weights()
	var needs := {"itm_practice_token": true}
	var pity := {}
	var rng := _rng()
	var tokens := 0
	for i in range(1000):
		var out: Array = _LOOT.roll_weighted_quest_bypass(
			_DUMMY_LOOT, _RARITIES, weights, 1, needs, pity, rng
		)
		tokens += _drop_count(out, "itm_practice_token")
	assert_eq(tokens, 1000, "a chance-1.0 quest-critical item drops on EVERY kill (was 90%)")


func test_quest_bypass_pelt_guaranteed_by_third_kill() -> void:
	# BLP: 0.6 -> 0.8 -> 1.0. No pelt drought may ever reach 3 misses.
	var weights := _weights()
	var needs := {"itm_wolf_pelt": true}
	var pity := {}
	var rng := _rng(7)
	var drought := 0
	for i in range(2000):
		var out: Array = _LOOT.roll_weighted_quest_bypass(
			_WOLF_LOOT, _RARITIES, weights, 2, needs, pity, rng
		)
		if _drop_count(out, "itm_wolf_pelt") > 0:
			drought = 0
		else:
			drought += 1
		assert_lt(drought, 3, "the bad-luck floor guarantees a pelt by the 3rd qualifying kill")


func test_quest_bypass_pelt_expected_kills_for_five_pelts() -> void:
	# Acceptance: expected kills to finish the 5-pelt objective <= 8 with BLP.
	var weights := _weights()
	var rng := _rng(11)
	var total_kills := 0
	var trials := 300
	for t in range(trials):
		var pity := {}
		var pelts := 0
		var kills := 0
		while pelts < 5:
			kills += 1
			var out: Array = _LOOT.roll_weighted_quest_bypass(
				_WOLF_LOOT, _RARITIES, weights, 2, {"itm_wolf_pelt": true}, pity, rng
			)
			pelts += _drop_count(out, "itm_wolf_pelt")
		total_kills += kills
	var mean := float(total_kills) / float(trials)
	assert_lte(mean, 8.0, "5 pelts should take <= 8 expected kills with BLP (got %.2f)" % mean)


func test_quest_bypass_without_needs_matches_plain_weighted_roll() -> void:
	# Rarity-behaviour regression: an empty needs set must reproduce roll_weighted EXACTLY
	# (same rng consumption, same drops) so non-quest loot keeps the T-232 schedule bit-for-bit.
	var weights := _weights()
	for i in range(50):
		var a: Array = _LOOT.roll_weighted(_WOLF_LOOT, _RARITIES, weights, 2, _rng(i))
		var b: Array = _LOOT.roll_weighted_quest_bypass(
			_WOLF_LOOT, _RARITIES, weights, 2, {}, {}, _rng(i)
		)
		assert_eq(str(a), str(b), "no quest needs -> byte-identical to the plain weighted roll")


func test_blp_chance_curve() -> void:
	assert_almost_eq(_LOOT.blp_chance(0.6, 0), 0.6, 0.0001, "kill 1: authored chance")
	assert_almost_eq(_LOOT.blp_chance(0.6, 1), 0.8, 0.0001, "kill 2: floor rises")
	assert_almost_eq(_LOOT.blp_chance(0.6, 2), 1.0, 0.0001, "kill 3: guaranteed")
	assert_almost_eq(_LOOT.blp_chance(1.0, 0), 1.0, 0.0001, "chance-1.0 guarantees on kill 1")
	assert_almost_eq(_LOOT.blp_chance(0.0, 5), 1.0, 0.0001, "the floor is capped at certainty")


func test_quest_collect_needs_reads_active_incomplete_objectives_only() -> void:
	var defs := {
		"q_tut_01":
		{
			"objectives":
			[
				{"type": "kill", "target": "mob_dummy", "count": 1},
				{"type": "collect", "target": "itm_practice_token", "count": 1},
			]
		},
		"q001": {"objectives": [{"type": "collect", "target": "itm_wolf_pelt", "count": 5}]},
	}
	var raw := [
		{"quest_id": "q_tut_01", "state": "active", "progress": [0, 0]},
		{"quest_id": "q001", "state": "active", "progress": [5]},  # objective already complete
	]
	var needs: Dictionary = _LOOT.quest_collect_needs(raw, defs)
	assert_true(needs.has("itm_practice_token"), "active + incomplete collect is quest-critical")
	assert_false(needs.has("itm_wolf_pelt"), "a completed objective drops back to the tier roll")
	assert_false(needs.has("mob_dummy"), "kill objectives never enter the collect set")
	var done := [{"quest_id": "q_tut_01", "state": "completed", "progress": [1, 1]}]
	assert_true(
		_LOOT.quest_collect_needs(done, defs).is_empty(), "non-active quests contribute nothing"
	)


func test_collect_item_index_covers_every_quest_collect_target() -> void:
	var defs := {
		"a": {"objectives": [{"type": "collect", "target": "itm_x", "count": 1}]},
		"b": {"objectives": [{"type": "kill", "target": "mob_y", "count": 3}]},
	}
	var index: Dictionary = _LOOT.collect_item_index(defs)
	assert_true(index.has("itm_x"))
	assert_false(index.has("mob_y"))
