class_name EloRating
extends RefCounted

# T-390: the PURE Elo/MMR brain for the PvP rating spine (mirrors guild_logic / npc_wander purity —
# no I/O, no state, no OS time; the caller injects the two ratings + the outcome). PvpStore owns the
# durable ratings; every rating change routes through here so the curve is unit-testable headlessly.
#
# MODEL-AGNOSTIC (owner-input-queue row A): this computes the rating NUMBER only. What a rating ever
# PAYS OUT (T-391) is deliberately NOT decided here — the spine measures skill; the reward is a
# separate, owner-blessed ticket. This also touches no PvP combat surface (T-381 is owner-gated).

const DEFAULT_RATING := 1500  # everyone starts here (unplaced)
const MEAN_RATING := 1500  # the regression target on a season soft-reset
const K_FACTOR := 32  # standard chess/arena K — larger swings for fewer games
const K_PLACEMENT := 64  # provisional K during the placement window (ratings settle faster)
const PLACEMENT_GAMES := 5  # games at K_PLACEMENT before a rating is "placed"
const SOFT_RESET_FACTOR := 0.5  # fraction of the distance-to-mean KEPT on rollover (0.5 = half gap)
const MIN_RATING := 100  # a floor so a losing streak can't run a rating negative

# Named tiers (Bronze → a top ladder), lowest floor first. The ticket's "ratings roll into named
# tiers" — a pure lookup so the leaderboard/panel and any future reward gate agree on the band.
const TIERS := [
	{"name": "Bronze", "floor": 0},
	{"name": "Silver", "floor": 1400},
	{"name": "Gold", "floor": 1600},
	{"name": "Platinum", "floor": 1800},
	{"name": "Diamond", "floor": 2000},
	{"name": "Champion", "floor": 2200},
]


# The expected score of A vs B (the logistic Elo curve): 0..1, exactly 0.5 at equal rating.
static func expected_score(rating_a: int, rating_b: int) -> float:
	return 1.0 / (1.0 + pow(10.0, float(rating_b - rating_a) / 400.0))


# The K-factor for a rating with `games_played` decided this season — a placement boost that then
# settles to the standard K (the ticket's "short placement period").
static func k_for(games_played: int) -> int:
	return K_PLACEMENT if games_played < PLACEMENT_GAMES else K_FACTOR


# The new rating after scoring `actual` (1.0 win / 0.0 loss / 0.5 draw) against `opponent`.
static func updated(rating: int, opponent: int, actual: float, k: int) -> int:
	var expected := expected_score(rating, opponent)
	var delta := int(round(float(k) * (actual - expected)))
	return maxi(MIN_RATING, rating + delta)


# One decided match → both new ratings. "Upset pays more" falls straight out of the curve: beating a
# HIGHER-rated opponent (low expected score) yields a bigger positive delta than beating a peer.
# Returns {winner, loser, winner_delta, loser_delta}.
static func resolve_match(
	winner: int, loser: int, winner_games: int, loser_games: int
) -> Dictionary:
	var w_new := updated(winner, loser, 1.0, k_for(winner_games))
	var l_new := updated(loser, winner, 0.0, k_for(loser_games))
	return {
		"winner": w_new,
		"loser": l_new,
		"winner_delta": w_new - winner,
		"loser_delta": l_new - loser,
	}


# Regress a rating toward the mean on a season rollover — a SOFT reset, not a wipe: keep a fraction
# of last season's earned gap so a climber still starts the new season ahead of a fresh account.
static func soft_reset(rating: int) -> int:
	var kept := int(round(float(MEAN_RATING) + SOFT_RESET_FACTOR * float(rating - MEAN_RATING)))
	return maxi(MIN_RATING, kept)


# The named tier a rating sits in.
static func tier_for(rating: int) -> String:
	var name := "Bronze"
	for t in TIERS:
		if rating >= int(t["floor"]):
			name = str(t["name"])
	return name
