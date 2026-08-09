extends GutTest

# T-475 (T-525 fold-in): the talent reroll coin sink. The debit, the wholesale talent clear,
# and the reroll-counter bump are ONE atomic commit (ServicesStore.commit_talent_reroll); a
# purse that cannot cover the scaling cost is rejected with nothing changed. Cost curve is
# TalentLogic.reroll_cost; the ledger sees every paid reroll as the 'talent_reroll' sink.

const CharacterManager = preload("res://scripts/character_manager.gd")
const CoinLedger = preload("res://scripts/coin_ledger.gd")
const TalentLogic = preload("res://scripts/talent_logic.gd")

const TALENT := {
	"id": "tal_x",
	"class": "warrior",
	"tree": "arms",
	"tier": 1,
	"max_ranks": 2,
	"prereq": null,
	"effect": {"kind": "stat_add", "stat": "str", "per_rank": 2},
}


func before_each() -> void:
	CharacterManager.reset_for_test()


func _spent_char(coins_extra: int = 0) -> int:
	CharacterManager.ensure_character("reroller")
	var cid: int = int(CharacterManager.get_character("reroller").get("id", -1))
	CharacterManager.award_xp_to_character(cid, 1000)  # points to spend
	if coins_extra != 0:
		ServicesStore.adjust_coins(cid, coins_extra)
	var spent: Dictionary = CharacterManager.spend_talent(cid, TALENT, {"tal_x": TALENT})
	assert_true(bool(spent.get("ok", false)), str(spent))
	return cid


func test_paid_reroll_debits_clears_and_ledgers_the_sink() -> void:
	var cid := _spent_char(100)  # 100 seed + 100 = 200 covers the 150 first cost
	var cost := TalentLogic.reroll_cost(ServicesStore.get_talent_rerolls(cid))
	assert_eq(cost, 150, "first reroll prices at the base")
	assert_true(ServicesStore.commit_talent_reroll(cid, cost))
	assert_eq(ServicesStore.get_coins(cid), 50, "cost debited exactly")
	assert_eq(CharacterManager.get_talents(cid).size(), 0, "sheet wiped with the debit")
	assert_eq(ServicesStore.get_talent_rerolls(cid), 1, "counter advances the curve")
	var rows := CoinLedger.test_move_rows()
	assert_eq(rows.size(), 1)
	assert_eq(str(rows[0]["reason"]), CoinLedger.REASON_TALENT_REROLL)
	assert_eq(int(rows[0]["delta"]), -150)


func test_cost_scales_across_successive_rerolls() -> void:
	var cid := _spent_char(5000)
	var expected := [150, 300, 600, 1000, 1000]
	for step in range(expected.size()):
		var cost := TalentLogic.reroll_cost(ServicesStore.get_talent_rerolls(cid))
		assert_eq(cost, int(expected[step]), "reroll %d prices per the curve" % (step + 1))
		assert_true(ServicesStore.commit_talent_reroll(cid, cost))
	assert_eq(ServicesStore.get_talent_rerolls(cid), expected.size())


func test_insufficient_coins_rejects_with_no_partial_state() -> void:
	var cid := _spent_char()  # only the 100-coin test seed; first reroll costs 150
	var cost := TalentLogic.reroll_cost(ServicesStore.get_talent_rerolls(cid))
	assert_false(ServicesStore.commit_talent_reroll(cid, cost), "poor purse rejected")
	assert_eq(ServicesStore.get_coins(cid), 100, "no debit on rejection")
	assert_eq(CharacterManager.get_talents(cid).size(), 1, "talents survive rejection")
	assert_eq(ServicesStore.get_talent_rerolls(cid), 0, "counter untouched")
	assert_eq(CoinLedger.test_move_rows().size(), 0, "rejections never reach the ledger")


func test_negative_cost_is_refused() -> void:
	var cid := _spent_char()
	assert_false(
		ServicesStore.commit_talent_reroll(cid, -50), "a negative cost can never mint coin"
	)
	assert_eq(ServicesStore.get_coins(cid), 100)
