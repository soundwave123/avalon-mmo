class_name RankShield
extends RefCounted

# T-392: the PURE derank / loss-aversion guardrails on the T-390 rating spine (mirrors EloRating
# purity — no I/O, no state; the caller injects the pre/post ratings + the shield charges + the
# published shield params). PvpStore.record_match calls in here so one bad night can't erase a
# hard-won rank. Cited designs: Valorant-style rank shield (buffer a demotion), a new-player
# placement grace, and a bottom-of-ladder loss-streak damp so the floor of the ladder keeps playing.
#
# Server-authority: a client never reaches this. The shield charge count is server state on the
# rating row; there is NO client verb that grants a shield or sets a charge count (adversarial-
# in test_pvp_store). Params are PUBLISHED (data/pvp_matchmaking.json shield block).

const EloRating := preload("res://scripts/elo_rating.gd")


# The rating floor of the tier `rating` currently sits in (the demotion threshold to protect).
static func tier_floor(rating: int) -> int:
	var fl := 0
	for t: Dictionary in EloRating.TIERS:
		if rating >= int(t["floor"]):
			fl = int(t["floor"])
	return fl


# One LOSS through the guardrails. rating = pre-match; raw_new = post-Elo rating (already floored
# at EloRating.MIN by the curve); games = matches decided this season BEFORE this one; shield =
# charges left at the current tier. Returns {rating, shield}.
#   1. Bottom-of-ladder damping — below damp_below_rating a loss only sheds loss_damp_factor of the
#      raw drop, so a losing streak at the floor still leaves the player somewhere to climb from.
#   2. Placement grace — a provisional player (games < placement_games) never deranks below the tier
#      they are still calibrating in; their shield is untouched.
#   3. Tier-boundary shield — a loss that would cross below the current tier floor is HELD at the
#      floor while charges remain (each hold spends one); once the buffer is empty the demotion
#      fires and a fresh buffer is seeded for the lower tier.
static func resolve_loss(
	rating: int, raw_new: int, games: int, shield: int, cfg: Dictionary
) -> Dictionary:
	var min_rating := int(cfg.get("min_rating", EloRating.MIN_RATING))
	var new_r := raw_new
	# 1. bottom-of-ladder damping
	if rating < int(cfg.get("damp_below_rating", 1300)) and raw_new < rating:
		var drop := rating - raw_new
		new_r = rating - int(round(float(drop) * float(cfg.get("loss_damp_factor", 0.5))))
	new_r = maxi(new_r, min_rating)
	var tfloor := tier_floor(rating)
	# 2. placement grace
	if games < int(cfg.get("placement_games", 5)):
		return {"rating": maxi(new_r, tfloor), "shield": shield}
	# 3. tier-boundary shield
	if new_r < tfloor:
		if shield > 0:
			return {"rating": tfloor, "shield": shield - 1}
		return {"rating": new_r, "shield": int(cfg.get("charges", 3))}
	return {"rating": new_r, "shield": shield}


# One WIN through the guardrails. A promotion into a HIGHER tier restores a full shield buffer for
# the new rank (so the climber immediately gets the loss-aversion protection at their new tier);
# a within-tier win leaves the buffer as-is. Returns {rating, shield}.
static func resolve_win(rating: int, raw_new: int, shield: int, cfg: Dictionary) -> Dictionary:
	if tier_floor(raw_new) > tier_floor(rating):
		return {"rating": raw_new, "shield": int(cfg.get("charges", 3))}
	return {"rating": raw_new, "shield": shield}


# The gift-framed healthy-session signal (ethical-engagement, NOT compulsion): TRUE only right after
# a WIN once the session has reached nudge_after_games — a suggestion to stop on a high note. It
# never fires on a loss (no "your streak will break" FOMO) and never gates play (no energy timer,
# no lockout); the caller surfaces it as an opt-out nudge.
static func good_stopping_point(just_won: bool, games_this_session: int, cfg: Dictionary) -> bool:
	if not just_won:
		return false
	return games_this_session >= int(cfg.get("nudge_after_games", 8))
