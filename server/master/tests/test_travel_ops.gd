extends GutTest

# T-431: master-owned travel persistence and coin authority. The world supplies a graph-validated
# hop descriptor; this layer proves discovery persists, unknown nodes and overdrafts fail closed,
# and only a successful flight writes the canonical reason="flight" sink.

const CharacterManager = preload("res://scripts/character_manager.gd")
const ServicesStore = preload("res://scripts/services_store.gd")
const TravelOps = preload("res://scripts/travel_ops.gd")
const CoinLedger = preload("res://scripts/coin_ledger.gd")
const PvpHonor = preload("res://scripts/pvp_honor.gd")


func before_each() -> void:
	CharacterManager.reset_for_test()
	TravelOps.reset_for_test()
	PvpHonor.reset_for_test()
	CharacterManager.ensure_character("traveller")


func _cid() -> int:
	return int(CharacterManager.get_character("traveller")["id"])


func test_discovery_is_persisted_and_idempotent() -> void:
	assert_true(
		TravelOps.op({"username": "traveller", "action": "discover", "node": "village"})["ok"]
	)
	assert_true(
		TravelOps.op({"username": "traveller", "action": "discover", "node": "village"})["ok"]
	)
	var listed: Dictionary = TravelOps.op({"username": "traveller", "action": "list"})
	assert_eq(listed["known_nodes"], ["village"], "a learned roost persists exactly once")


func test_known_flight_debits_server_balance_and_writes_flight_sink() -> void:
	TravelOps.op({"username": "traveller", "action": "discover", "node": "village"})
	TravelOps.op({"username": "traveller", "action": "discover", "node": "highkeep"})
	var before := ServicesStore.get_coins(_cid())
	var result: Dictionary = TravelOps.op(
		{
			"username": "traveller",
			"action": "fly",
			"source": "village",
			"dest": "highkeep",
			"cost": 25
		}
	)
	assert_true(result["ok"], "both-known, funded hop is committed")
	assert_eq(int(result["coins"]), before - 25)
	assert_eq(ServicesStore.get_coins(_cid()), before - 25)
	assert_eq(CoinLedger.test_move_rows().size(), 1, "one successful hop writes one ledger row")
	assert_eq(str(CoinLedger.test_move_rows()[0]["reason"]), "flight")
	assert_eq(int(CoinLedger.test_move_rows()[0]["delta"]), -25)


func test_unknown_destination_and_underfunded_hop_do_not_move_coins_or_ledger() -> void:
	TravelOps.op({"username": "traveller", "action": "discover", "node": "village"})
	var before := ServicesStore.get_coins(_cid())
	var unknown: Dictionary = TravelOps.op(
		{
			"username": "traveller",
			"action": "fly",
			"source": "village",
			"dest": "ashmoor",
			"cost": 10
		}
	)
	assert_eq(str(unknown.get("error", "")), "unknown_roost")
	TravelOps.op({"username": "traveller", "action": "discover", "node": "ashmoor"})
	var poor: Dictionary = TravelOps.op(
		{
			"username": "traveller",
			"action": "fly",
			"source": "village",
			"dest": "ashmoor",
			"cost": before + 1
		}
	)
	assert_eq(str(poor.get("error", "")), "insufficient_coins")
	assert_eq(ServicesStore.get_coins(_cid()), before, "rejected hops never debit")
	assert_eq(CoinLedger.test_move_rows(), [], "rejected hops never ledger")


func test_mount_profile_is_persisted_but_carries_no_speed_value() -> void:
	var profile: Dictionary = TravelOps.mount_profile(_cid())
	# T-658: a fresh character now starts UNLEARNED (migration 048 flips the DB default to false);
	# only characters that existed before the migration were grandfathered to learned=true.
	assert_false(bool(profile["learned"]), "a fresh character must train before riding")
	assert_eq(str(profile["mount_id"]), "mount_common_gryphon")
	assert_false(profile.has("speed"), "power is not stored in or selected by the cosmetic profile")


func test_mount_skin_must_ride_t375_cosmetic_unlock_seam() -> void:
	TravelOps.test_set_mount_profile(
		_cid(), {"learned": true, "mount_id": "mount_common_gryphon", "skin": "skin_storm_gryphon"}
	)
	assert_eq(str(TravelOps.mount_profile(_cid())["skin"]), "", "unowned skin fails closed")
	PvpHonor.grant_unlock(_cid(), "skin_storm_gryphon")
	assert_eq(
		str(TravelOps.mount_profile(_cid())["skin"]),
		"skin_storm_gryphon",
		"owned skin crosses the shared cosmetic seam"
	)


# T-563 regression: mount_profile's DB path hydrates learned_mount as a Postgres "t"/"f" STRING and
# fed it to bool(<String>) -> the live "Nonexistent 'bool' constructor" crash (portal report #17).
# The mock path supplies real bools, so the suite stayed green while every real login crashed.
# Unit-test the truthy reader against the "t"/"f" path the mock skipped, so it can't regress.
func test_is_db_true_reads_postgres_tf_strings_without_crashing() -> void:
	assert_true(TravelOps._is_db_true("t"), '"t" (a learned mount) reads true')
	assert_false(TravelOps._is_db_true("f"), '"f" reads false -- and does NOT crash')
	assert_true(TravelOps._is_db_true("true"))
	assert_false(TravelOps._is_db_true("false"))
	assert_true(TravelOps._is_db_true("1"))
	assert_false(TravelOps._is_db_true("0"))
	# Native bools (the mock path + already-parsed JSON) still pass straight through.
	assert_true(TravelOps._is_db_true(true))
	assert_false(TravelOps._is_db_true(false))
	# A stale/empty string fails closed rather than reading truthy (the correctness half of the bug).
	assert_false(TravelOps._is_db_true(""))


# T-658: the riding-trainer purchase — a funded, high-enough-level character debits EXACTLY once
# via the ledger under the canonical reason, and the learned flag flips immediately (no relog).
func test_learn_mount_debits_once_under_the_mount_training_reason_and_flips_learned() -> void:
	var cid := _cid()
	CharacterManager.get_character("traveller")["level"] = TravelOps.MOUNT_TRAIN_LEVEL
	# Fund the purse only (empty reason -> CoinLedger.record drops it), so the ledger under
	# test holds ONLY the purchase row, never a setup credit.
	ServicesStore.adjust_coins(cid, TravelOps.MOUNT_TRAIN_COST, "")
	var before := ServicesStore.get_coins(cid)
	assert_false(bool(TravelOps.mount_profile(cid)["learned"]), "starts unlearned")

	var result: Dictionary = TravelOps.op({"username": "traveller", "action": "learn_mount"})

	assert_true(result["ok"], "a funded, high-enough-level purchase succeeds")
	assert_true(bool(TravelOps.mount_profile(cid)["learned"]), "learned flips immediately")
	assert_eq(ServicesStore.get_coins(cid), before - TravelOps.MOUNT_TRAIN_COST)
	assert_eq(CoinLedger.test_move_rows().size(), 1, "exactly one ledger row for one purchase")
	assert_eq(str(CoinLedger.test_move_rows()[0]["reason"]), "mount_training")
	assert_eq(int(CoinLedger.test_move_rows()[0]["delta"]), -TravelOps.MOUNT_TRAIN_COST)

	# A second attempt (already learned) is rejected and must NEVER charge a second time.
	var again: Dictionary = TravelOps.op({"username": "traveller", "action": "learn_mount"})
	assert_eq(str(again.get("error", "")), "already_learned")
	assert_eq(ServicesStore.get_coins(cid), before - TravelOps.MOUNT_TRAIN_COST, "no double charge")
	assert_eq(CoinLedger.test_move_rows().size(), 1, "still exactly one ledger row")


# T-658: under the level gate — an honest rejection that never touches coins or the ledger.
func test_learn_mount_under_level_is_rejected_without_touching_coins() -> void:
	var cid := _cid()
	CharacterManager.get_character("traveller")["level"] = TravelOps.MOUNT_TRAIN_LEVEL - 1
	# Fund the purse only (empty reason -> CoinLedger.record drops it), so the ledger under
	# test holds ONLY the purchase row, never a setup credit.
	ServicesStore.adjust_coins(cid, TravelOps.MOUNT_TRAIN_COST, "")
	var before := ServicesStore.get_coins(cid)

	var result: Dictionary = TravelOps.op({"username": "traveller", "action": "learn_mount"})

	assert_eq(str(result.get("error", "")), "level_too_low")
	assert_false(bool(TravelOps.mount_profile(cid)["learned"]), "stays unlearned")
	assert_eq(ServicesStore.get_coins(cid), before, "an under-level attempt never debits")
	assert_eq(CoinLedger.test_move_rows(), [], "an under-level attempt never ledgers")


# T-658: broke at the right level — an honest rejection, no debit, learned stays false.
func test_learn_mount_when_broke_is_rejected_without_touching_coins() -> void:
	var cid := _cid()
	CharacterManager.get_character("traveller")["level"] = TravelOps.MOUNT_TRAIN_LEVEL
	var before := ServicesStore.get_coins(cid)
	assert_true(before < TravelOps.MOUNT_TRAIN_COST, "test assumes the default purse is short")

	var result: Dictionary = TravelOps.op({"username": "traveller", "action": "learn_mount"})

	assert_eq(str(result.get("error", "")), "insufficient_coins")
	assert_false(bool(TravelOps.mount_profile(cid)["learned"]), "stays unlearned")
	assert_eq(ServicesStore.get_coins(cid), before, "a poor purse never debits")
	assert_eq(CoinLedger.test_move_rows(), [], "a poor purse never ledgers")


# T-658: price and level are a single tunable knob, not scattered magic numbers — moving the level
# constant moves the exact boundary where a purchase starts succeeding.
func test_learn_mount_level_gate_boundary_tracks_the_tunable_constant() -> void:
	var cid := _cid()
	# Fund the purse only (empty reason -> CoinLedger.record drops it), so the ledger under
	# test holds ONLY the purchase row, never a setup credit.
	ServicesStore.adjust_coins(cid, TravelOps.MOUNT_TRAIN_COST, "")
	CharacterManager.get_character("traveller")["level"] = TravelOps.MOUNT_TRAIN_LEVEL - 1
	assert_eq(
		str(TravelOps.op({"username": "traveller", "action": "learn_mount"}).get("error", "")),
		"level_too_low",
		"one level short of the tunable constant still fails"
	)
	CharacterManager.get_character("traveller")["level"] = TravelOps.MOUNT_TRAIN_LEVEL
	assert_true(
		bool(TravelOps.op({"username": "traveller", "action": "learn_mount"}).get("ok", false)),
		"exactly at the tunable constant succeeds"
	)
