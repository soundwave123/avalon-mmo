extends GutTest

# T-366: the coin sink/faucet ledger. Proves (a) adjust_coins records a classified movement only
# when given a reason, (b) the ledger is SERVER-OBSERVED — no client verb reaches it through the
# master dispatch, and (c) a realistic faucet+sink+transfer mix nets out the way the inflation
# guard expects (transfers cancel; net creation = faucet + sink).

const CharacterManager = preload("res://scripts/character_manager.gd")
const ServicesStore = preload("res://scripts/services_store.gd")
const CoinLedger = preload("res://scripts/coin_ledger.gd")
const Main = preload("res://scripts/main.gd")


func before_each() -> void:
	CharacterManager.reset_for_test()  # chains into ServicesStore + CoinLedger reset


func _char(username: String) -> int:
	CharacterManager.ensure_character(username)
	return int(CharacterManager.get_character(username)["id"])


# ---- adjust_coins records only when a reason is supplied ----------------------


func test_reasoned_credit_records_a_faucet_row() -> void:
	var cid := _char("alice")
	assert_true(ServicesStore.adjust_coins(cid, 250, "quest_reward"))
	var rows := CoinLedger.test_move_rows()
	assert_eq(rows.size(), 1, "one ledger row written")
	assert_eq(int(rows[0]["delta"]), 250)
	assert_eq(str(rows[0]["reason"]), "quest_reward")
	assert_eq(int(rows[0]["character_id"]), cid)


func test_reasonless_adjust_leaves_no_row() -> void:
	# Balance-only helpers (tests, internal fixups) pass no reason and stay OUT of the ledger.
	var cid := _char("bob")
	assert_true(ServicesStore.adjust_coins(cid, 100))
	assert_eq(CoinLedger.test_move_rows().size(), 0, "reasonless move is not ledgered")


func test_rejected_overdraft_records_nothing() -> void:
	var cid := _char("carol")
	assert_false(ServicesStore.adjust_coins(cid, -1000, "trainer"), "overdraft rejected")
	assert_eq(CoinLedger.test_move_rows().size(), 0, "a rejected move never touches the ledger")


func test_zero_delta_is_dropped() -> void:
	CoinLedger.record(1, 0, "quest_reward")
	assert_eq(CoinLedger.test_move_rows().size(), 0, "zero-delta accounting no-op is not recorded")


# ---- net-creation accounting: transfers cancel, faucets/sinks don't -----------


func test_faucet_sink_transfer_mix_nets_out() -> void:
	var a := _char("giver")
	var b := _char("taker")
	ServicesStore.adjust_coins(a, 500, "quest_reward")  # faucet +500
	ServicesStore.adjust_coins(a, -80, "trainer")  # sink   -80
	ServicesStore.adjust_coins(a, -120, "trade")  # transfer leg
	ServicesStore.adjust_coins(b, 120, "trade")  # transfer leg
	var faucet := 0
	var sink := 0
	var transfer := 0
	for r in CoinLedger.test_move_rows():
		match str(r["reason"]):
			"quest_reward":
				faucet += int(r["delta"])
			"trainer":
				sink += int(r["delta"])
			"trade":
				transfer += int(r["delta"])
	assert_eq(faucet, 500)
	assert_eq(sink, -80)
	assert_eq(transfer, 0, "the two trade legs cancel — no net coin created")
	assert_eq(faucet + sink, 420, "net creation = faucet + sink only")


# ---- server-observed: no client verb writes the ledger ------------------------


func test_ledger_has_no_client_dispatch_verb() -> void:
	# The ledger is written ONLY inside master coin paths; there is no @rpc / dispatch method a
	# client could call to append to it. Forge the obvious verb names and confirm the master
	# treats them as unknown (never routes them anywhere near CoinLedger.record).
	var m: Node = Main.new()
	for forged in ["record_coin", "coin_ledger", "record", "adjust_coin_ledger"]:
		var raw := JSON.stringify({"id": 1, "method": forged, "params": {}})
		var resp: Dictionary = JSON.parse_string(m._handle_message(raw))
		assert_eq(
			str(resp["result"].get("error", "")),
			"unknown_method",
			"forged ledger verb '%s' is not a dispatch surface" % forged
		)
	m.free()
