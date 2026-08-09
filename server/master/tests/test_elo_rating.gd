extends GutTest

# T-390: the PURE Elo/MMR curve. No I/O — just the win/loss/upset/soft-reset math the ticket names.

const EloRating = preload("res://scripts/elo_rating.gd")


func test_equal_ratings_expect_half() -> void:
	assert_almost_eq(EloRating.expected_score(1500, 1500), 0.5, 0.0001)


func test_higher_rating_expects_more() -> void:
	assert_gt(EloRating.expected_score(1700, 1500), 0.5)
	assert_lt(EloRating.expected_score(1300, 1500), 0.5)


func test_match_is_zero_sum_between_equals() -> void:
	# Two equal-rated peers, standard K: the winner gains exactly what the loser sheds.
	var r := EloRating.resolve_match(1500, 1500, 10, 10)
	assert_eq(int(r["winner"]), 1516)  # 1500 + 32*0.5
	assert_eq(int(r["loser"]), 1484)  # 1500 - 32*0.5
	assert_eq(int(r["winner_delta"]), -int(r["loser_delta"]))


func test_upset_pays_more_than_expected_win() -> void:
	# Beating a HIGHER-rated opponent (the upset) must gain MORE than beating a peer.
	var upset := EloRating.resolve_match(1400, 1800, 10, 10)  # underdog wins
	var expected_win := EloRating.resolve_match(1500, 1500, 10, 10)  # peer wins
	assert_gt(int(upset["winner_delta"]), int(expected_win["winner_delta"]))
	# And the favourite who got upset loses more than a peer does.
	assert_lt(int(upset["loser_delta"]), int(expected_win["loser_delta"]))


func test_placement_k_boost_swings_harder() -> void:
	# A provisional (games < PLACEMENT_GAMES) rating moves on the bigger K.
	var placing := EloRating.resolve_match(1500, 1500, 0, 0)
	var placed := EloRating.resolve_match(1500, 1500, 10, 10)
	assert_gt(int(placing["winner_delta"]), int(placed["winner_delta"]))
	assert_eq(EloRating.k_for(0), EloRating.K_PLACEMENT)
	assert_eq(EloRating.k_for(EloRating.PLACEMENT_GAMES), EloRating.K_FACTOR)


func test_soft_reset_regresses_toward_mean_not_wipe() -> void:
	# A climber keeps HALF the earned gap (soft reset, not a wipe back to default).
	assert_eq(EloRating.soft_reset(2000), 1750)  # 1500 + 0.5*(2000-1500)
	assert_eq(EloRating.soft_reset(1000), 1250)
	assert_eq(EloRating.soft_reset(1500), 1500)  # a mean rating is unchanged


func test_rating_floor_holds() -> void:
	# A near-floor rating losing to a peer (a real, non-trivial loss delta) can't go below the floor.
	assert_eq(EloRating.updated(110, 100, 0.0, EloRating.K_FACTOR), EloRating.MIN_RATING)


func test_named_tiers_ascend() -> void:
	assert_eq(EloRating.tier_for(0), "Bronze")
	assert_eq(EloRating.tier_for(EloRating.DEFAULT_RATING), "Silver")
	assert_eq(EloRating.tier_for(2500), "Champion")
