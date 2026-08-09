class_name PvpStore
extends RefCounted

# T-390: persisted PvP ratings + season lifecycle (pvp.seasons + pvp.ratings, migration 017). Same
# test-mode discipline as GuildStore/SocialStore — the in-memory fakes mirror the DB paths so the
# suite needs no live Postgres; DB plumbing rides character_manager's db_query / db_execute.
#
# Server-authority (the whole point):
#   - record_match is SERVER-OBSERVED. The world calls it via the secret-gated master RPC AFTER it
#     adjudicates a consensual rated match (combat is authoritative). There is NO client intent that
#     reaches it — a client can neither report a win nor set a rating (adversarial test). winner /
#     loser are USERNAMES the world resolved from live sessions, never a client-asserted id.
#   - The season id + window are DERIVED from the master clock (PvpSeason); no client names one.
#   - op() is the READ-ONLY ladder surface (leaderboard + own rating); it never mutates.

const _CM := preload("res://scripts/character_manager.gd")
const EloRating := preload("res://scripts/elo_rating.gd")
const PvpSeason := preload("res://scripts/pvp_season.gd")
const PvpHonor := preload("res://scripts/pvp_honor.gd")
const RankShield := preload("res://scripts/rank_shield.gd")  # T-392 derank/loss-shield guards
const MmrMatchmaker := preload("res://scripts/mmr_matchmaker.gd")  # T-392 band matcher + params
const AccountMastery := preload("res://scripts/account_mastery.gd")  # T-536 mastery feed
const AchievementStore := preload("res://scripts/achievement_store.gd")  # T-676 PvP achievements

# "duel" = the T-381 consensual 1v1; "bg" = the T-413 Crownfield battleground (own ladder + its
# own published honor_bg rates). WvW-scale stays deferred.
const BRACKETS := ["duel", "bg"]
const DEFAULT_BRACKET := "duel"
const LEADERBOARD_MAX := 100  # hard cap on a top-N read (abuse bound)

static var _test_seasons: Dictionary = {}  # id -> {id, starts_at, ends_at}
static var _test_ratings: Dictionary = {}  # "cid|season|bracket" -> {rating, wins, losses}


static func reset_for_test() -> void:
	_test_seasons.clear()
	_test_ratings.clear()


# ---- season lifecycle (server clock only) -----------------------------------


# Ensure the season covering `now` exists (idempotent upsert) and return {id, starts_at, ends_at}.
# The id/window are DERIVED from the clock (PvpSeason); a client can never name or move a season.
static func ensure_season(now: int) -> Dictionary:
	var s := PvpSeason.season_for(now)
	var sid := int(s["id"])
	if _CM._test_skip_db:
		if not _test_seasons.has(sid):
			_test_seasons[sid] = s
			_run_season_payout(sid - 1)  # T-391: first sight of a new season settles the old one
	else:
		_CM.db_execute(
			(
				"INSERT INTO pvp.seasons (id, starts_at, ends_at) "
				+ "VALUES ($1, to_timestamp($2), to_timestamp($3)) ON CONFLICT (id) DO NOTHING"
			),
			[sid, int(s["starts_at"]), int(s["ends_at"])]
		)
		# T-391: settle the previous season on every boundary sighting — pvp.season_grants makes
		# re-entry a per-character no-op, so this is safe to run redundantly.
		_run_season_payout(sid - 1)
	return s


# T-391: everyone who holds a rating row in `sid` (any bracket; best rating wins the tier call).
static func _season_participants(sid: int) -> Array:
	var best: Dictionary = {}  # cid -> rating
	if _CM._test_skip_db:
		for key: String in _test_ratings:
			var parts := key.split("|")
			if int(parts[1]) != sid:
				continue
			var cid := int(parts[0])
			var r := int((_test_ratings[key] as Dictionary)["rating"])
			best[cid] = maxi(int(best.get(cid, 0)), r)
	else:
		var rows: Variant = _CM.db_query(
			(
				"SELECT character_id, MAX(rating) AS rating FROM pvp.ratings "
				+ "WHERE season_id = $1 GROUP BY character_id"
			),
			[sid]
		)
		if rows is Array:
			for row: Dictionary in rows:
				best[int(row["character_id"])] = int(row["rating"])
	var out: Array = []
	for cid: int in best:
		out.append({"character_id": cid, "rating": int(best[cid])})
	return out


static func _run_season_payout(prev_sid: int) -> void:
	if prev_sid <= 0:
		return
	PvpHonor.season_payout(_season_participants(prev_sid), prev_sid)


# ---- server-only match ingestion --------------------------------------------


# SERVER-OBSERVED match result. params: {winner (username), loser (username), bracket?, now}.
# Fail-closed on bad bracket / unknown character / self-match. Both ratings update by the tested Elo
# curve (upset pays more); the winner's row gains a win, the loser's a loss.
static func record_match(params: Dictionary) -> Dictionary:
	var bracket := str(params.get("bracket", DEFAULT_BRACKET))
	if not BRACKETS.has(bracket):
		return {"error": "bad_bracket"}
	var w := _CM.get_character(str(params.get("winner", "")))
	var l := _CM.get_character(str(params.get("loser", "")))
	if w.is_empty() or l.is_empty():
		return {"error": "unknown_character"}
	var wid := int(w["id"])
	var lid := int(l["id"])
	if wid == lid:
		return {"error": "self_match"}
	var season := ensure_season(int(params.get("now", 0)))
	var sid := int(season["id"])
	var wr := _rating_row(wid, sid, bracket)
	var lr := _rating_row(lid, sid, bracket)
	var l_games := int(lr["wins"]) + int(lr["losses"])
	var res := EloRating.resolve_match(
		int(wr["rating"]), int(lr["rating"]), int(wr["wins"]) + int(wr["losses"]), l_games
	)
	# T-392: the raw Elo result passes through the derank/loss-shield guards — a promotion refills
	# the winner's shield; the loser's drop is damped/placement-graced/boundary-buffered. The honor
	# grant below still keys off the PRE-match ratings (wr/lr), unaffected by the shield.
	var scfg: Dictionary = MmrMatchmaker.config().get("shield", {})
	var w_guard := RankShield.resolve_win(
		int(wr["rating"]), int(res["winner"]), int(wr["shield"]), scfg
	)
	var l_guard := RankShield.resolve_loss(
		int(lr["rating"]), int(res["loser"]), l_games, int(lr["shield"]), scfg
	)
	var w_rating := int(w_guard["rating"])
	var l_rating := int(l_guard["rating"])
	var w_wins := int(wr["wins"]) + 1
	var l_losses := int(lr["losses"]) + 1
	_write_rating(wid, sid, bracket, w_rating, w_wins, int(wr["losses"]), int(w_guard["shield"]))
	_write_rating(lid, sid, bracket, l_rating, int(lr["wins"]), l_losses, int(l_guard["shield"]))
	# T-391: honor rides the same server-observed event — published rates, pre-match ratings.
	# T-413: the bracket picks the rate block + ledger reason (duel->"match", bg->"bg_match").
	var honor := PvpHonor.grant_for_match(
		wid, lid, sid, int(wr["rating"]), int(lr["rating"]), bracket
	)
	# T-536: a fought match feeds the permanent account-mastery floor for BOTH participants, win or
	# lose (reward-for-effort, consistent with T-391 participation honor). One credit per settled
	# match per participant, on this server-observed seam only — never client-routable.
	AccountMastery.observe(str(w["username"]), wid, "pvp_match", 1)
	AccountMastery.observe(str(l["username"]), lid, "pvp_match", 1)
	# T-676: PvP achievements ride the SAME server-observed seam (never client-routable). The winner
	# banks a bracket win (duel/bg -> first duel win, first Crownfield win, win-count tiers); BOTH
	# bank their new rating as a monotonic high-water mark (the named-tier "rank" milestones). The
	# earned defs fold into the result so the world can toast the earner.
	var ach: Array = AchievementStore.observe(wid, "pvp_win", bracket).get("newly_earned", [])
	ach += AchievementStore.observe(wid, "pvp_rating", "*", w_rating).get("newly_earned", [])
	ach += AchievementStore.observe(lid, "pvp_rating", "*", l_rating).get("newly_earned", [])
	return {
		"honor": honor,
		"ok": true,
		"season": sid,
		"bracket": bracket,
		"achievements": ach,
		"winner":
		_standing(
			str(w["username"]), w_rating, w_rating - int(wr["rating"]), w_wins, int(wr["losses"])
		),
		"loser":
		_standing(
			str(l["username"]), l_rating, l_rating - int(lr["rating"]), int(lr["wins"]), l_losses
		),
	}


# ---- matchmaking call-in (server-resolved MMR; T-392) -----------------------


# The queue call-in: params {bracket?, players: [{name, wait}], now}. The world passes the usernames
# it resolved from live sessions + its own wait clock; the MMR for each is read SERVER-SIDE (a
# client
# supplies neither an MMR nor an opponent). Returns {pairs: [[nameA, nameB]], unmatched: [name]}.
# Unknown names are dropped (fail-closed) rather than paired on a default rating.
static func matchmake(params: Dictionary) -> Dictionary:
	var bracket := str(params.get("bracket", DEFAULT_BRACKET))
	if not BRACKETS.has(bracket):
		return {"error": "bad_bracket"}
	var now := int(params.get("now", 0))
	var players: Array = params.get("players", [])
	var entries: Array = []
	for p: Variant in players:
		if typeof(p) != TYPE_DICTIONARY:
			continue
		var pd: Dictionary = p
		var name := str(pd.get("name", ""))
		if _CM.get_character(name).is_empty():
			continue  # a forged/unknown name never enters the pool
		entries.append(
			{"id": name, "mmr": mmr_for(name, bracket, now), "wait": int(pd.get("wait", 0))}
		)
	var band: Dictionary = MmrMatchmaker.config().get("band", {})
	var res := MmrMatchmaker.pair_queue(entries, band)
	res["ok"] = true
	res["bracket"] = bracket
	return res


# ---- read-only ladder surface (client-triggered via the world) --------------


# READ-ONLY. action "leaderboard": {bracket?, season?, limit?} -> top-N. action "rating": the
# caller's OWN standing ({username, bracket?, season?}). Never mutates. Unranked callers get the
# seeded default (so a fresh player sees where they'd start), flagged `ranked: false`.
static func op(params: Dictionary) -> Dictionary:
	var action := str(params.get("action", "leaderboard"))
	var bracket := str(params.get("bracket", DEFAULT_BRACKET))
	if not BRACKETS.has(bracket):
		return {"error": "bad_bracket"}
	var sid := int(params.get("season", 0))
	if sid <= 0:
		sid = int(PvpSeason.season_for(int(params.get("now", 0)))["id"])  # default: the live season
	match action:
		"leaderboard":
			var limit := clampi(int(params.get("limit", 10)), 1, LEADERBOARD_MAX)
			return {
				"ok": true,
				"season": sid,
				"bracket": bracket,
				"entries": _leaderboard(sid, bracket, limit),
			}
		"rating":
			var c := _CM.get_character(str(params.get("username", "")))
			if c.is_empty():
				return {"error": "unknown_character"}
			var cid := int(c["id"])
			var row := _rating_row(cid, sid, bracket)
			var hon := PvpHonor.balance(cid, sid)  # T-391: honor + active track ride the read
			return {
				"ok": true,
				"season": sid,
				"bracket": bracket,
				"honor": int(hon["balance"]),
				"active_track": str(hon["active_track"]),
				"ranked": not _read_rating(cid, sid, bracket).is_empty(),
				"rating":
				_standing(
					str(c["username"]), int(row["rating"]), 0, int(row["wins"]), int(row["losses"])
				),
			}
		_:
			return {"error": "unknown_action"}


# ---- helpers ----------------------------------------------------------------


static func _standing(name: String, rating: int, delta: int, wins: int, losses: int) -> Dictionary:
	return {
		"name": name,
		"rating": rating,
		"delta": delta,
		"wins": wins,
		"losses": losses,
		"tier": EloRating.tier_for(rating),
	}


# The current (or seeded) rating row for a character this season: the stored row if any, else a SOFT
# RESET of the most-recent prior-season rating (regress toward the mean), else the default. games=0
# on a seeded row so placement (higher K) applies. Does NOT persist — only record_match writes.
static func _rating_row(cid: int, sid: int, bracket: String) -> Dictionary:
	var existing := _read_rating(cid, sid, bracket)
	if not existing.is_empty():
		return existing
	var prior := _latest_prior_rating(cid, sid, bracket)
	var seed := EloRating.soft_reset(prior) if prior >= 0 else EloRating.DEFAULT_RATING
	# T-392: a seeded (unplayed-this-season) row starts with a full shield buffer.
	return {"rating": seed, "wins": 0, "losses": 0, "shield": _default_shield()}


# T-392: the published starting shield charge count (data/pvp_matchmaking.json), fail-safe to 3.
static func _default_shield() -> int:
	return int(MmrMatchmaker.config().get("shield", {}).get("charges", 3))


# T-392: a character's server-authoritative MMR for a bracket this season (seeded/stored rating).
# The matchmaker call-in reads this — a client never supplies its own MMR.
static func mmr_for(username: String, bracket: String, now: int) -> int:
	if not BRACKETS.has(bracket):
		return EloRating.DEFAULT_RATING
	var c := _CM.get_character(username)
	if c.is_empty():
		return EloRating.DEFAULT_RATING
	var sid := int(PvpSeason.season_for(now)["id"])
	return int(_rating_row(int(c["id"]), sid, bracket)["rating"])


static func _read_rating(cid: int, sid: int, bracket: String) -> Dictionary:
	if _CM._test_skip_db:
		return _test_ratings.get(_key(cid, sid, bracket), {})
	var rows := _CM.db_query(
		(
			"SELECT rating, wins, losses, shield FROM pvp.ratings "
			+ "WHERE character_id = $1 AND season_id = $2 AND bracket = $3"
		),
		[cid, sid, bracket]
	)
	if rows.is_empty():
		return {}
	var r0: Dictionary = rows[0]
	return {
		"rating": int(r0["rating"]),
		"wins": int(r0["wins"]),
		"losses": int(r0["losses"]),
		"shield": int(r0.get("shield", _default_shield())),
	}


# The character's rating in the most recent season BEFORE `sid` for this bracket, or -1 if none.
static func _latest_prior_rating(cid: int, sid: int, bracket: String) -> int:
	if _CM._test_skip_db:
		var best_season := -1
		var best_rating := -1
		for key in _test_ratings:
			var parts: PackedStringArray = str(key).split("|")
			if int(parts[0]) == cid and str(parts[2]) == bracket and int(parts[1]) < sid:
				if int(parts[1]) > best_season:
					best_season = int(parts[1])
					best_rating = int(_test_ratings[key]["rating"])
		return best_rating
	var rows := _CM.db_query(
		(
			"SELECT rating FROM pvp.ratings "
			+ "WHERE character_id = $1 AND bracket = $2 AND season_id < $3 "
			+ "ORDER BY season_id DESC LIMIT 1"
		),
		[cid, bracket, sid]
	)
	return int(rows[0]["rating"]) if not rows.is_empty() else -1


static func _write_rating(
	cid: int, sid: int, bracket: String, rating: int, wins: int, losses: int, shield: int
) -> void:
	if _CM._test_skip_db:
		_test_ratings[_key(cid, sid, bracket)] = {
			"rating": rating, "wins": wins, "losses": losses, "shield": shield
		}
		return
	(
		_CM
		. db_execute(
			(
				"INSERT INTO pvp.ratings (character_id, season_id, bracket, rating, wins, losses, shield) "
				+ "VALUES ($1, $2, $3, $4, $5, $6, $7) "
				+ "ON CONFLICT (character_id, season_id, bracket) DO UPDATE SET "
				+ "rating = $4, wins = $5, losses = $6, shield = $7, updated_at = now()"
			),
			[cid, sid, bracket, rating, wins, losses, shield]
		)
	)


# Top-N standings for a season+bracket, rating DESC then name; each carries its 1-based rank + tier.
static func _leaderboard(sid: int, bracket: String, limit: int) -> Array:
	var rows: Array = []
	if _CM._test_skip_db:
		for key in _test_ratings:
			var parts: PackedStringArray = str(key).split("|")
			if int(parts[1]) == sid and str(parts[2]) == bracket:
				var r: Dictionary = _test_ratings[key]
				var uname := str(_CM.get_character_by_id(int(parts[0])).get("username", ""))
				(
					rows
					. append(
						{
							"username": uname,
							"rating": int(r["rating"]),
							"wins": int(r["wins"]),
							"losses": int(r["losses"]),
						}
					)
				)
		rows.sort_custom(
			func(a, b):
				return (
					int(a["rating"]) > int(b["rating"])
					or (
						int(a["rating"]) == int(b["rating"])
						and str(a["username"]) < str(b["username"])
					)
				)
		)
		if rows.size() > limit:
			rows = rows.slice(0, limit)
	else:
		rows = _CM.db_query(
			(
				"SELECT c.name AS username, r.rating, r.wins, r.losses FROM pvp.ratings r "
				+ "JOIN chars.characters c ON c.id = r.character_id "
				+ "WHERE r.season_id = $1 AND r.bracket = $2 "
				+ "ORDER BY r.rating DESC, c.name LIMIT $3"
			),
			[sid, bracket, limit]
		)
	var out: Array = []
	var rank := 1
	for row in rows:
		(
			out
			. append(
				{
					"rank": rank,
					"name": str(row["username"]),
					"rating": int(row["rating"]),
					"wins": int(row["wins"]),
					"losses": int(row["losses"]),
					"tier": EloRating.tier_for(int(row["rating"])),
				}
			)
		)
		rank += 1
	return out


static func _key(cid: int, sid: int, bracket: String) -> String:
	return "%d|%d|%s" % [cid, sid, bracket]
