extends GutTest
# T-538: the bespoke, tier-banded Rift Trials loot pool. Proves the QUALITY curve alongside the
# shipped CHANCE curve (rift_scaling.reward_weight): a deeper climber's eligible pool GROWS and
# enriches with rarer bands instead of flatting out at the same six items ("runs dry"), every
# authored id resolves to a real item, and the band selection is pure/server-authoritative (a
# corrupt tier clamps UP to the baseline band, never to a richer free pool).

const _RL = preload("res://scripts/combat/rift_loot.gd")
const _RS = preload("res://scripts/combat/rift_scaling.gd")
const _SCHEDULE_PATH := "res://data/loot/rift_schedule.json"
const _ITEMS_PATH := "res://data/items/items.json"

var _sched: Dictionary = {}
var _item_ids: Dictionary = {}  # id -> true, the authored registry


func before_all() -> void:
	var f := FileAccess.open(_SCHEDULE_PATH, FileAccess.READ)
	assert_not_null(f, "the rift schedule loads")
	_sched = JSON.parse_string(f.get_as_text())
	var g := FileAccess.open(_ITEMS_PATH, FileAccess.READ)
	for it: Dictionary in (JSON.parse_string(g.get_as_text()) as Dictionary).get("items", []):
		_item_ids[str(it.get("id", ""))] = true


func test_the_schedule_is_banded_not_a_flat_six() -> void:
	var bands: Array = _sched.get("bands", [])
	assert_gt(bands.size(), 1, "the bespoke pool is banded (the borrowed flat six is gone)")
	assert_false(_sched.has("pool"), "no leftover flat crypt pool on the rift schedule")
	var total := 0
	for b: Dictionary in bands:
		total += (b.get("pool", []) as Array).size()
	assert_gt(total, 6, "the bespoke set is richer than the six borrowed crypt blues")


func test_every_pool_id_resolves_to_a_real_item() -> void:
	# A drop id the registry can't grant would silently no-op (item="" — the floor keeps building),
	# so an unauthored id is a dead reward. Every banded id must exist in items.json.
	for tier in [1, 5, 10]:
		for id: String in _RL.eligible_pool(_sched, tier):
			assert_true(_item_ids.has(id), "pool id '%s' is authored in items.json" % id)


func test_pool_grows_with_tier_never_runs_dry() -> void:
	# The core T-538 fix: a deeper climber draws from a strictly richer eligible pool, so owning the
	# entry band never collapses the roll to dupes-only the way the flat six did.
	var t1 := _RL.eligible_pool(_sched, 1).size()
	var t5 := _RL.eligible_pool(_sched, 5).size()
	var t10 := _RL.eligible_pool(_sched, 10).size()
	assert_gt(t5, t1, "reaching band riftbound widens the pool")
	assert_gt(t10, t5, "reaching band riftforged widens it again")
	assert_eq(_RL.bands_unlocked(_sched, 1), 1, "tier 1 has only the entry band")
	assert_gt(_RL.bands_unlocked(_sched, 12), _RL.bands_unlocked(_sched, 1), "tiers unlock bands")
	# and the top pool stays full at arbitrarily deep tiers — it never shrinks back
	assert_eq(_RL.eligible_pool(_sched, 999).size(), t10, "the deep pool holds every band, forever")


func test_higher_tiers_unlock_strictly_rarer_bands() -> void:
	# Quality, not just quantity: the ids that ONLY appear at high tier are the rarer bands.
	var only_deep := _RL.eligible_pool(_sched, 10).filter(
		func(id): return not (id in _RL.eligible_pool(_sched, 1))
	)
	assert_gt(only_deep.size(), 0, "a tier-10 climber rolls ids a tier-1 climber cannot")
	assert_has(only_deep, "itm_rift_reaver", "the epic riftforged edge is deep-tier only")
	assert_false("itm_rift_reaver" in _RL.eligible_pool(_sched, 9), "band riftforged gates at 10")


func test_corrupt_tier_clamps_up_to_the_baseline_band() -> void:
	for bad in [0, -1, -999]:
		var pool := _RL.eligible_pool(_sched, bad)
		assert_eq(
			pool, _RL.eligible_pool(_sched, 1), "tier %d clamps UP to band 1, no free loot" % bad
		)


func test_reward_payload_wires_chance_and_quality_from_one_tier() -> void:
	# The world hands the master {pool, base_chance, weight}; pool (quality) and weight (chance) must
	# derive from the SAME tier so the two curves can never drift apart.
	var tier := 12
	var weight := _RS.reward_weight(tier)
	var payload := _RL.reward_payload(_sched, tier, weight)
	assert_eq(
		payload["pool"], _RL.eligible_pool(_sched, tier), "the payload pool is the tier's pool"
	)
	assert_eq(float(payload["weight"]), weight, "the payload weight is the tier's reward weight")
	assert_eq(
		float(payload["base_chance"]),
		float(_sched.get("base_chance", -1.0)),
		"the published base odds ride along"
	)


func test_deep_tiers_keep_paying_strictly_better_odds() -> void:
	# The unbounded-feel guarantee at the reward seam: reward_weight climbs without a cap, so a
	# high-tier climber's honest chance keeps rising even where the pool has plateaued at the top band.
	assert_gt(_RS.reward_weight(50), _RS.reward_weight(40), "tier 50 out-pays tier 40")
	assert_gt(_RS.reward_weight(120), _RS.reward_weight(50) * 10.0, "still compounding, no plateau")
