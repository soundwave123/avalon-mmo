extends GutTest

# T-683: the guild BANK — a rank-gated, ledgered, atomic shared coin/item vault. Runs against the
# test-mode fakes (no live Postgres), driven through GuildStore.op() so the whole master surface is
# exercised: the actor's PERSISTED rank is resolved server-side (never client-asserted), the coin
# moves are net-zero + ledger-classified, every move is atomic (a failed leg moves NOTHING), and
# disband resolves the vault deterministically. No bank op touches a stat/xp/entry field.

const CharacterManager = preload("res://scripts/character_manager.gd")
const ServicesStore = preload("res://scripts/services_store.gd")
const CoinLedger = preload("res://scripts/coin_ledger.gd")
const GuildBank = preload("res://scripts/guild_bank_store.gd")
const _GS = preload("res://scripts/guild_store.gd")
const GuildLogic = preload("res://scripts/guild_logic.gd")

# A minimal item registry (content lives world-side; the master injects it, exactly as trade does).
const _REG := {
	"itm_wolf_pelt": {"slot": "none", "stackable": true, "max_stack": 20},
	"itm_leather_cap": {"slot": "head", "stackable": false, "max_stack": 1},
}


func before_each() -> void:
	CharacterManager.reset_for_test()  # chains ServicesStore + CoinLedger + GuildStore + GuildBank


func _mk(username: String, coins: int = 5000) -> int:
	CharacterManager.ensure_character(username)
	var cid := int(CharacterManager.get_character(username)["id"])
	ServicesStore.adjust_coins(cid, coins - ServicesStore.get_coins(cid))
	return cid


# Found a guild led by `leader`, add `officer` (promoted to Officer) and `member` (plain Member).
func _guild_of_three(leader: String, officer: String, member: String) -> int:
	var g := _GS.op({"username": leader, "action": "create", "name": "Bankers"})
	var gid := int(g["guild_id"])
	_GS.op({"username": leader, "action": "invite", "target_name": officer})
	_GS.op({"username": officer, "action": "accept"})
	_GS.op({"username": leader, "action": "promote", "target_name": officer})
	_GS.op({"username": leader, "action": "invite", "target_name": member})
	_GS.op({"username": member, "action": "accept"})
	return gid


func _bank(user: String, action: String, extra: Dictionary = {}) -> Dictionary:
	var op := {"username": user, "action": action}
	op.merge(extra)
	return _GS.op(op)


# ---- coin: deposit ---------------------------------------------------------------


func test_deposit_debits_wallet_credits_bank_and_ledgers_sink() -> void:
	var lid := _mk("alice", 5000)
	var gid := _guild_of_three("alice", "bob", "carol")
	var before := ServicesStore.get_coins(lid)
	var r := _bank("alice", "bank_deposit", {"amount": 1000})
	assert_true(bool(r.get("ok", false)), "deposit ok")
	assert_eq(ServicesStore.get_coins(lid), before - 1000, "wallet debited")
	assert_eq(GuildBank.get_coins(gid), 1000, "bank credited")
	# ledgered as a sink-side move on the depositor's character row (net-zero, not new money).
	var deposit_rows := CoinLedger.test_move_rows().filter(
		func(row): return str(row["reason"]) == GuildBank.REASON_DEPOSIT
	)
	assert_eq(deposit_rows.size(), 1, "one deposit ledger row")
	assert_eq(int(deposit_rows[0]["delta"]), -1000, "deposit ledgers a negative (sink-side) delta")


func test_deposit_open_to_plain_member() -> void:
	_mk("alice")
	_mk("bob")
	_mk("carol", 3000)
	var gid := _guild_of_three("alice", "bob", "carol")
	var r := _bank("carol", "bank_deposit", {"amount": 500})  # carol is a plain Member
	assert_true(bool(r.get("ok", false)), "member may deposit")
	assert_eq(GuildBank.get_coins(gid), 500)


func test_deposit_rejects_bad_amount_and_overdraw_leaving_balances_intact() -> void:
	_mk("alice", 5000)  # 5000 funded; create spends CREATE_COST, leaving 4000
	var gid := _guild_of_three("alice", "bob", "carol")
	assert_eq(str(_bank("alice", "bank_deposit", {"amount": 0}).get("error")), "bad_amount")
	assert_eq(
		str(_bank("alice", "bank_deposit", {"amount": 999999}).get("error")), "insufficient_coins"
	)
	assert_eq(GuildBank.get_coins(gid), 0, "no coin entered the bank on a failed deposit")


# ---- coin: withdraw + rank gate + cap --------------------------------------------


func test_withdraw_refused_below_officer_rank() -> void:
	_mk("alice")
	_mk("bob")
	var cid := _mk("carol", 3000)
	var gid := _guild_of_three("alice", "bob", "carol")
	_bank("carol", "bank_deposit", {"amount": 1000})
	var before := ServicesStore.get_coins(cid)
	var r := _bank("carol", "bank_withdraw", {"amount": 100})  # carol is a Member
	assert_eq(str(r.get("error")), "no_permission", "member cannot withdraw")
	assert_eq(GuildBank.get_coins(gid), 1000, "bank untouched")
	assert_eq(ServicesStore.get_coins(cid), before, "wallet untouched")


func test_officer_withdraw_ledgers_faucet_and_respects_cap() -> void:
	_mk("alice")
	var bob := _mk("bob", 2000)
	_mk("carol")
	var gid := _guild_of_three("alice", "bob", "carol")
	_bank("bob", "bank_deposit", {"amount": 2000})
	var before := ServicesStore.get_coins(bob)
	# Officer cap is 5000/withdrawal; 3000 is within it.
	var r := _bank("bob", "bank_withdraw", {"amount": 2000})
	assert_true(bool(r.get("ok", false)), "officer within cap may withdraw")
	assert_eq(ServicesStore.get_coins(bob), before + 2000, "wallet credited")
	assert_eq(GuildBank.get_coins(gid), 0, "bank debited")
	var faucet_rows := CoinLedger.test_move_rows().filter(
		func(row): return str(row["reason"]) == GuildBank.REASON_WITHDRAW
	)
	assert_eq(int(faucet_rows[0]["delta"]), 2000, "withdraw ledgers a positive (faucet-side) delta")


func test_officer_withdraw_over_cap_refused() -> void:
	_mk("alice")
	_mk("bob", 20000)
	_mk("carol")
	var gid := _guild_of_three("alice", "bob", "carol")
	_bank("bob", "bank_deposit", {"amount": 10000})
	var r := _bank("bob", "bank_withdraw", {"amount": GuildLogic.bank_withdraw_cap(1) + 1})
	assert_eq(str(r.get("error")), "over_cap", "officer capped per withdrawal")
	assert_eq(GuildBank.get_coins(gid), 10000, "nothing left the bank")


func test_leader_withdraw_uncapped() -> void:
	var alice := _mk("alice", 30000)
	var gid := _guild_of_three("alice", "bob", "carol")
	_bank("alice", "bank_deposit", {"amount": 20000})  # > officer cap
	var r := _bank("alice", "bank_withdraw", {"amount": 20000})
	assert_true(bool(r.get("ok", false)), "leader draws without a cap")
	assert_eq(GuildBank.get_coins(gid), 0)


func test_over_withdraw_moves_nothing_and_is_net_zero() -> void:
	var alice := _mk("alice", 30000)
	var gid := _guild_of_three("alice", "bob", "carol")
	_bank("alice", "bank_deposit", {"amount": 1000})
	var wallet_before := ServicesStore.get_coins(alice)
	var r := _bank("alice", "bank_withdraw", {"amount": 5000})  # bank only holds 1000
	assert_eq(str(r.get("error")), "insufficient_bank_coins")
	assert_eq(GuildBank.get_coins(gid), 1000, "bank intact on over-withdraw")
	assert_eq(ServicesStore.get_coins(alice), wallet_before, "wallet intact on over-withdraw")
	# Net-zero invariant: every bank ledger row across the account sums to exactly the parked balance.
	var net := 0
	for row in CoinLedger.test_move_rows():
		if str(row["reason"]) in [GuildBank.REASON_DEPOSIT, GuildBank.REASON_WITHDRAW]:
			net += int(row["delta"])
	assert_eq(-net, GuildBank.get_coins(gid), "player-ledger delta mirrors the parked bank balance")


# ---- items -----------------------------------------------------------------------


func _give(cid: int, item_id: String, count: int) -> void:
	CharacterManager.try_add_items(cid, [{"item_id": item_id, "count": count}], _REG)


func _bag_slot_of(cid: int, item_id: String) -> int:
	for e in CharacterManager.get_inventory(cid):
		if str(e.get("slot_type", "")) == "bag" and str(e.get("item_id", "")) == item_id:
			return int(e["slot_index"])
	return -1


func test_item_deposit_moves_stack_from_inventory_to_vault() -> void:
	var alice := _mk("alice", 5000)
	var gid := _guild_of_three("alice", "bob", "carol")
	_give(alice, "itm_wolf_pelt", 10)
	var slot := _bag_slot_of(alice, "itm_wolf_pelt")
	var r := _bank(
		"alice", "bank_deposit_item", {"slot_index": slot, "count": 6, "item_registry": _REG}
	)
	assert_true(bool(r.get("ok", false)), "item deposit ok")
	assert_eq(GuildBank.view(gid)["items"], [{"item_id": "itm_wolf_pelt", "item_count": 6}])
	# 4 pelts remain in the player's bag (10 - 6), no dupe.
	var counts := 0
	for e in CharacterManager.get_inventory(alice):
		if str(e.get("item_id", "")) == "itm_wolf_pelt":
			counts += int(e["item_count"])
	assert_eq(counts, 4, "remainder stays in the bag, none duplicated")


func test_item_withdraw_rank_gated_and_over_withdraw_moves_nothing() -> void:
	var alice := _mk("alice", 5000)
	var carol := _mk("carol", 3000)
	var gid := _guild_of_three("alice", "bob", "carol")
	_give(alice, "itm_wolf_pelt", 10)
	_bank(
		"alice",
		"bank_deposit_item",
		{"slot_index": _bag_slot_of(alice, "itm_wolf_pelt"), "count": 10, "item_registry": _REG}
	)
	# Member carol cannot withdraw items.
	assert_eq(
		str(
			(
				_bank(
					"carol",
					"bank_withdraw_item",
					{"item_id": "itm_wolf_pelt", "count": 1, "item_registry": _REG}
				)
				. get("error")
			)
		),
		"no_permission"
	)
	# Over-withdraw (vault has 10) moves nothing.
	assert_eq(
		str(
			(
				_bank(
					"alice",
					"bank_withdraw_item",
					{"item_id": "itm_wolf_pelt", "count": 99, "item_registry": _REG}
				)
				. get("error")
			)
		),
		"insufficient_bank_items"
	)
	assert_eq(
		int(GuildBank.view(gid)["items"][0]["item_count"]), 10, "vault intact on over-withdraw"
	)
	# A valid officer withdraw of the whole stack empties the vault row (no lingering zero row).
	var r := _bank(
		"alice",
		"bank_withdraw_item",
		{"item_id": "itm_wolf_pelt", "count": 10, "item_registry": _REG}
	)
	assert_true(bool(r.get("ok", false)))
	assert_true(
		(GuildBank.view(gid)["items"] as Array).is_empty(), "fully-withdrawn stack deletes its row"
	)


func test_item_deposit_atomic_reject_leaves_both_sides_intact() -> void:
	var alice := _mk("alice", 5000)
	var gid := _guild_of_three("alice", "bob", "carol")
	_give(alice, "itm_wolf_pelt", 10)
	var slot := _bag_slot_of(alice, "itm_wolf_pelt")
	CharacterManager._test_fail_persist = true  # T-567: force the inventory persist to roll back
	var r := _bank(
		"alice", "bank_deposit_item", {"slot_index": slot, "count": 6, "item_registry": _REG}
	)
	CharacterManager._test_fail_persist = false
	assert_eq(str(r.get("error")), "move_failed", "a failed persist leg fails the whole move")
	assert_true(
		(GuildBank.view(gid)["items"] as Array).is_empty(), "vault untouched — no phantom item"
	)


# ---- disband resolution ----------------------------------------------------------


func test_disband_returns_coin_and_items_to_leader() -> void:
	var alice := _mk("alice", 30000)
	var gid := _guild_of_three("alice", "bob", "carol")
	_bank("alice", "bank_deposit", {"amount": 5000})
	_give(alice, "itm_wolf_pelt", 8)
	_bank(
		"alice",
		"bank_deposit_item",
		{"slot_index": _bag_slot_of(alice, "itm_wolf_pelt"), "count": 8, "item_registry": _REG}
	)
	var wallet_before := ServicesStore.get_coins(alice)
	var r := _GS.op({"username": "alice", "action": "disband", "item_registry": _REG})
	assert_true(bool(r.get("disbanded", false)))
	assert_eq(int(r["bank"]["coins_returned"]), 5000, "coin returned to leader")
	assert_eq(
		ServicesStore.get_coins(alice), wallet_before + 5000, "leader wallet credited on disband"
	)
	# The 8 deposited pelts are back in the (now guildless) leader's bag — no orphan, no dupe.
	var pelts := 0
	for e in CharacterManager.get_inventory(alice):
		if str(e.get("item_id", "")) == "itm_wolf_pelt":
			pelts += int(e["item_count"])
	assert_eq(pelts, 8, "items returned to the leader on disband")


# ---- charter guard: identity/utility, never power --------------------------------


func test_no_bank_result_carries_a_power_field() -> void:
	var alice := _mk("alice", 5000)
	var gid := _guild_of_three("alice", "bob", "carol")
	_bank("alice", "bank_deposit", {"amount": 1000})
	var forbidden := [
		"stat", "stats", "xp", "experience", "rested", "power", "entry", "level", "buff"
	]
	for payload in [GuildBank.view(gid), _bank("alice", "bank_withdraw", {"amount": 100})]:
		for key in (payload as Dictionary).keys():
			assert_false(
				str(key).to_lower() in forbidden,
				"bank payload must carry no power/stat/xp/entry field (found %s)" % str(key)
			)
