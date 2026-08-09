extends "res://addons/gut/test.gd"
# T-393: the Rift Trials keystone ladder — keystone up/downgrade on server-observed verdicts,
# per-season best-tier credit feeding the leaderboard read, the honest scaled reward roll with
# the bad-luck floor (pure fairness, never purchasable), ledger discipline, and the adversarial
# guarantee that the op surface rejects any forged set-tier/grant action.

const _CM = preload("res://scripts/character_manager.gd")
const RiftLadder = preload("res://scripts/rift_ladder.gd")

# A registry the grant path accepts; the pool item is a plain non-stackable drop.
const _REGISTRY := {"itm_test_riftblade": {"slot": "main_hand", "stackable": false}}
const _REWARD := {"pool": ["itm_test_riftblade"], "base_chance": 0.12, "weight": 1.0}
const _NOW := 1_750_000_000  # a fixed master clock -> a deterministic season id

var _cid := 0


func before_each() -> void:
	_CM._test_skip_db = true
	_CM.reset_for_test()
	RiftLadder.reset_for_test()
	_CM.ensure_character("runner")
	_CM.ensure_character("mate")
	_cid = int(_CM.get_character("runner")["id"])


func _result(
	cleared: bool, members: Array = ["runner"], reward: Dictionary = _REWARD
) -> Dictionary:
	return (
		RiftLadder
		. op(
			{
				"action": "result",
				"holder": "runner",
				"members": members,
				"cleared": cleared,
				"reward": reward,
				"item_registry": _REGISTRY,
				"now": _NOW,
			}
		)
	)


func test_keystone_defaults_to_tier_one() -> void:
	assert_eq(int(RiftLadder.keystone(_cid)["tier"]), 1, "a fresh character holds a tier-1 key")
	var read := RiftLadder.op({"action": "keystone", "username": "runner", "now": _NOW})
	assert_true(bool(read["ok"]))
	assert_eq(int(read["tier"]), 1)


func test_timed_clear_upgrades_the_keystone_and_ledgers_it() -> void:
	RiftLadder._test_randf = 0.99  # force reward misses; this test is about the tier
	var res := _result(true)
	assert_true(bool(res["ok"]))
	assert_eq(int(res["tier"]), 1, "the run's tier is the PERSISTED keystone")
	assert_eq(int(res["new_tier"]), 2, "a clear upgrades")
	assert_eq(int(RiftLadder.keystone(_cid)["tier"]), 2)
	var row: Dictionary = RiftLadder.test_ledger()[0]
	assert_eq(str(row["verdict"]), "clear")
	assert_eq(int(row["tier_before"]), 1)
	assert_eq(int(row["tier_after"]), 2)


func test_fail_downgrades_with_a_floor_of_one() -> void:
	RiftLadder._test_randf = 0.99
	assert_eq(int(_result(false)["new_tier"]), 1, "tier 1 fail floors at 1, never 0")
	_result(true)
	_result(true)  # -> tier 3
	assert_eq(int(_result(false)["new_tier"]), 2, "a fail steps one tier back down")
	assert_eq(int(RiftLadder.keystone(_cid)["tier"]), 2)


func test_clear_credits_every_members_season_best_and_keeps_the_max() -> void:
	RiftLadder._test_randf = 0.99
	_result(true, ["runner", "mate"])  # both clear tier 1
	_result(true, ["runner"])  # runner alone clears tier 2
	var lb: Array = RiftLadder.op({"action": "leaderboard", "now": _NOW})["entries"]
	assert_eq(lb.size(), 2)
	assert_eq(str(lb[0]["username"]), "runner", "runner leads on best tier")
	assert_eq(int(lb[0]["tier"]), 2)
	assert_eq(int(lb[0]["rank"]), 1)
	assert_eq(str(lb[1]["username"]), "mate")
	assert_eq(int(lb[1]["tier"]), 1)
	# a later LOWER clear never regresses the best
	_result(false)  # runner drops to tier 2 key... clears tier 2 again below
	_result(true, ["runner"])
	lb = RiftLadder.op({"action": "leaderboard", "now": _NOW})["entries"]
	assert_eq(int(lb[0]["tier"]), 2, "best tier keeps the MAX")


func test_higher_tiers_pay_better_on_honest_odds() -> void:
	# The chance curve itself: monotonic in tier weight, capped at certainty, floor-boosted.
	var t1 := RiftLadder.reward_chance(0.12, 1.0, 0)
	var t10 := RiftLadder.reward_chance(0.12, 3.52, 0)
	assert_gt(t10, t1, "a higher tier's reward weight raises the honest odds")
	assert_eq(RiftLadder.reward_chance(0.12, 1_000_000.0, 0), 1.0, "capped at certainty")
	assert_gt(RiftLadder.reward_chance(0.12, 1.0, 3), t1, "bad-luck misses raise the next roll")


func test_reward_hit_grants_the_item_and_resets_the_bad_luck_floor() -> void:
	RiftLadder._test_randf = 0.0  # forced hit
	var res := _result(true)
	var reward: Dictionary = (res["rewards"] as Array)[0]
	assert_eq(str(reward["item"]), "itm_test_riftblade", "the scaled roll landed")
	assert_eq(int(RiftLadder.keystone(_cid)["bad_luck"]), 0, "a hit resets the floor")


func test_bad_luck_floor_climbs_to_a_guarantee_on_misses() -> void:
	RiftLadder._test_randf = 0.995  # roll always at the top: only a floored chance of 1.0 hits
	var last_chance := 0.0
	var granted := ""
	for i in range(0, 16):
		var res := _result(true)
		var reward: Dictionary = (res["rewards"] as Array)[0]
		var chance := float(reward["chance"])
		assert_true(chance >= last_chance, "the floor never regresses while missing")
		last_chance = chance
		granted = str(reward["item"])
		if granted != "":
			break
	assert_eq(granted, "itm_test_riftblade", "pure bad luck ends in a guaranteed hit")
	assert_eq(int(RiftLadder.keystone(_cid)["bad_luck"]), 0, "the guarantee reset the floor")


func test_adversarial_forged_actions_are_rejected() -> void:
	# A forged "set my keystone to tier N" has no vocabulary: there is no such action, and the
	# result path reads the tier from the persisted keystone — params cannot name one.
	for forged in ["set_tier", "set_keystone", "grant", "upgrade", ""]:
		var res := RiftLadder.op({"action": forged, "username": "runner", "tier": 99, "now": _NOW})
		assert_eq(str(res.get("error", "")), "unknown_action", "forged '%s' rejected" % forged)
	assert_eq(int(RiftLadder.keystone(_cid)["tier"]), 1, "the keystone never moved")
	# a "result" for an unknown holder dies before any write
	var bad := RiftLadder.op({"action": "result", "holder": "nobody", "cleared": true, "now": _NOW})
	assert_eq(str(bad.get("error", "")), "unknown_character")
	assert_eq(RiftLadder.test_ledger().size(), 0, "no ledger row from a rejected verdict")


func test_result_ignores_any_tier_named_in_params() -> void:
	RiftLadder._test_randf = 0.99
	var res := (
		RiftLadder
		. op(
			{
				"action": "result",
				"holder": "runner",
				"members": ["runner"],
				"cleared": true,
				"tier": 99,  # forged — must be ignored
				"new_tier": 500,  # forged — must be ignored
				"reward": _REWARD,
				"item_registry": _REGISTRY,
				"now": _NOW,
			}
		)
	)
	assert_eq(int(res["tier"]), 1, "the adjudicated tier is the persisted keystone")
	assert_eq(int(res["new_tier"]), 2, "one honest step, not a forged leap")
	assert_eq(int(RiftLadder.keystone(_cid)["tier"]), 2)
