extends GutTest

# T-392: the PURE derank / loss-aversion guardrails — placement grace, bottom-of-ladder loss
# damping, the tier-boundary shield buffer, and the gift-framed session nudge. No I/O; every case
# injects its own shield params.

const RankShield = preload("res://scripts/rank_shield.gd")

var _cfg := {
	"charges": 3,
	"placement_games": 5,
	"damp_below_rating": 1300,
	"loss_damp_factor": 0.5,
	"min_rating": 100,
	"nudge_after_games": 8,
}


func test_tier_floor_matches_the_rating_tier() -> void:
	assert_eq(RankShield.tier_floor(1410), 1400, "Silver floor")
	assert_eq(RankShield.tier_floor(1610), 1600, "Gold floor")
	assert_eq(RankShield.tier_floor(1200), 0, "Bronze floor")


func test_placement_grace_never_deranks_below_the_tier() -> void:
	# A provisional player (games < placement_games) whose loss would drop below the tier floor is
	# held AT the floor, and the shield buffer is NOT spent (grace, not a charge).
	var r := RankShield.resolve_loss(1410, 1380, 2, 3, _cfg)
	assert_eq(int(r["rating"]), 1400, "held at the tier floor during placement")
	assert_eq(int(r["shield"]), 3, "placement grace spends no shield charge")


func test_bottom_of_ladder_damps_the_loss() -> void:
	# Below damp_below_rating a loss only sheds loss_damp_factor of the raw drop.
	var r := RankShield.resolve_loss(1200, 1150, 10, 3, _cfg)  # raw drop 50 -> damped 25
	assert_eq(int(r["rating"]), 1175, "the floor of the ladder keeps somewhere to climb from")


func test_shield_buffers_a_demotion_then_lets_it_fire() -> void:
	# Post-placement, a boundary-crossing loss is held at the floor while charges remain...
	var hold := RankShield.resolve_loss(1410, 1380, 10, 2, _cfg)
	assert_eq(int(hold["rating"]), 1400, "held at the boundary")
	assert_eq(int(hold["shield"]), 1, "one charge spent")
	# ...and only demotes once the buffer is empty, seeding a fresh buffer for the lower tier.
	var demote := RankShield.resolve_loss(1410, 1380, 10, 0, _cfg)
	assert_eq(int(demote["rating"]), 1380, "demotion fires when the shield is exhausted")
	assert_eq(int(demote["shield"]), 3, "a fresh buffer seeds the lower tier")


func test_within_tier_loss_leaves_the_shield_intact() -> void:
	# A loss that stays inside the current tier spends no charge and isn't floored.
	var r := RankShield.resolve_loss(1700, 1660, 10, 2, _cfg)
	assert_eq(int(r["rating"]), 1660)
	assert_eq(int(r["shield"]), 2)


func test_win_promotion_refills_the_shield() -> void:
	var promo := RankShield.resolve_win(1590, 1610, 0, _cfg)  # Silver -> Gold
	assert_eq(int(promo["rating"]), 1610)
	assert_eq(int(promo["shield"]), 3, "a new tier gets a full protection buffer")
	var within := RankShield.resolve_win(1610, 1630, 1, _cfg)  # stays Gold
	assert_eq(int(within["shield"]), 1, "a within-tier win doesn't touch the buffer")


func test_session_nudge_is_a_gift_not_a_trap() -> void:
	assert_true(RankShield.good_stopping_point(true, 8, _cfg), "after a win, long session -> nudge")
	assert_false(RankShield.good_stopping_point(true, 7, _cfg), "short session -> no nudge")
	# NEVER on a loss (no FOMO / streak-break pressure).
	assert_false(RankShield.good_stopping_point(false, 20, _cfg), "never fires on a loss")
