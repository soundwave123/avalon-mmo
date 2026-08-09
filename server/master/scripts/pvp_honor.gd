class_name PvpHonor
extends RefCounted

# T-391: the PvP honor economy on the T-390 spine (owner-blessed HYBRID model — honor buys a
# rare-capped chase, prestige cosmetics are the real reward; power is never for sale).
#
# Server-authority (the whole point):
#   - Honor is GRANTED only from grant_for_match, which pvp_store.record_match calls after it
#     adjudicates a server-observed match. There is NO client verb that credits honor, sets a track
#     tier, or grants a cosmetic (adversarial-tested).
#   - Spends are master-side and overdraft-guarded (mirror of ServicesStore.adjust_coins).
#   - Every mutation writes pvp.honor_ledger with a reason (T-366 ledger discipline).
#   - Season payouts are idempotent via pvp.season_grants (character+season+kind unique).
# Rates/tracks are PUBLISHED data (data/pvp_rewards.json) — the server enforces exactly what the
# player can read; no hidden multipliers (honest-economy guardrail).

const _CM := preload("res://scripts/character_manager.gd")
const EloRating := preload("res://scripts/elo_rating.gd")
const AccountMastery := preload("res://scripts/account_mastery.gd")  # T-395 mastery feed

const _REWARDS_PATH := "res://data/pvp_rewards.json"
const RARITY_ORDER := ["common", "uncommon", "rare"]  # rare is the HARD cap (charter)

static var _cfg: Dictionary = {}
static var _test_honor: Dictionary = {}  # "cid|season" -> {balance, active_track}
static var _test_ledger: Array = []
static var _test_grants: Dictionary = {}  # "cid|season|kind" -> true
static var _test_tracks: Dictionary = {}  # "cid|track" -> tier
static var _test_unlocks: Dictionary = {}  # cid -> Array[appearance_id]


static func reset_for_test() -> void:
	_test_honor.clear()
	_test_ledger.clear()
	_test_grants.clear()
	_test_tracks.clear()
	_test_unlocks.clear()


# ---- published config --------------------------------------------------------


static func config() -> Dictionary:
	if _cfg.is_empty():
		var f := FileAccess.open(_REWARDS_PATH, FileAccess.READ)
		if f != null:
			var doc: Variant = JSON.parse_string(f.get_as_text())
			if typeof(doc) == TYPE_DICTIONARY:
				_cfg = doc
	return _cfg


# ---- match grant (called ONLY from pvp_store.record_match) -------------------


# T-413: the published rate block for a bracket. "bg" reads honor_bg; anything else (or a missing
# honor_bg) falls back to the base duel rates — fail-safe to PUBLISHED numbers, never hidden ones.
static func rates_for(bracket: String) -> Dictionary:
	if bracket == "bg":
		var hb: Dictionary = config().get("honor_bg", {})
		if not hb.is_empty():
			return hb
	return config().get("honor", {})


# Pure math: the honor a participant earns for one rated match. `rating` is their PRE-match rating
# (the published rates key off where you fought from, not where you landed).
static func match_honor(won: bool, rating: int, opponent_rating: int, bracket := "duel") -> int:
	var h := rates_for(bracket)
	var total := int(h.get("participation_base", 10))
	if won:
		total += int(h.get("win_bonus", 8))
		var over := maxi(rating - 1000, 0) / 100
		total += mini(
			over * int(h.get("rating_bonus_per_100_over_1000", 1)),
			int(h.get("rating_bonus_cap", 10))
		)
		if opponent_rating > rating:
			total += int(h.get("upset_bonus", 5))
	elif rating < int(h.get("catchup_below_rating", 900)):
		total = int(roundf(total * float(h.get("catchup_multiplier", 1.5))))
	return total


# Grant both participants their match honor (server-observed). T-413: the bracket picks the
# published rate block AND the ledger reason — duels write "match", battlegrounds "bg_match", so
# the two vessels stay separately auditable in pvp.honor_ledger.
static func grant_for_match(
	wid: int, lid: int, sid: int, w_rating_before: int, l_rating_before: int, bracket := "duel"
) -> Dictionary:
	var reason := "bg_match" if bracket == "bg" else "match"
	var w_gain := match_honor(true, w_rating_before, l_rating_before, bracket)
	var l_gain := match_honor(false, l_rating_before, w_rating_before, bracket)
	_adjust(wid, sid, w_gain, reason)
	_adjust(lid, sid, l_gain, reason)
	return {"winner_honor": w_gain, "loser_honor": l_gain}


# ---- balance + ledger ---------------------------------------------------------


static func balance(cid: int, sid: int) -> Dictionary:
	if _CM._test_skip_db:
		var row: Dictionary = _test_honor.get("%d|%d" % [cid, sid], {})
		return {
			"balance": int(row.get("balance", 0)), "active_track": str(row.get("active_track", ""))
		}
	var rows: Variant = _CM.db_query(
		"SELECT balance, active_track FROM pvp.honor WHERE character_id = $1 AND season_id = $2",
		[cid, sid]
	)
	if rows is Array and (rows as Array).size() > 0:
		var r: Dictionary = rows[0]
		return {"balance": int(r.get("balance", 0)), "active_track": str(r.get("active_track", ""))}
	return {"balance": 0, "active_track": ""}


# Overdraft-guarded honor mutation + ledger row. Returns false (and writes nothing) on overdraft.
static func _adjust(cid: int, sid: int, delta: int, reason: String) -> bool:
	var key := "%d|%d" % [cid, sid]
	var now_bal := int(balance(cid, sid)["balance"])
	if now_bal + delta < 0:
		return false
	if _CM._test_skip_db:
		var row: Dictionary = _test_honor.get(key, {"balance": 0, "active_track": ""})
		row["balance"] = now_bal + delta
		_test_honor[key] = row
		_test_ledger.append(
			{"character_id": cid, "season_id": sid, "delta": delta, "reason": reason}
		)
	else:
		_CM.db_execute(
			(
				"INSERT INTO pvp.honor (character_id, season_id, balance) VALUES ($1, $2, $3) "
				+ "ON CONFLICT (character_id, season_id) "
				+ "DO UPDATE SET balance = pvp.honor.balance + $4 WHERE pvp.honor.balance + $4 >= 0"
			),
			[cid, sid, maxi(delta, 0), delta]
		)
		_CM.db_execute(
			(
				"INSERT INTO pvp.honor_ledger (character_id, season_id, delta, reason) "
				+ "VALUES ($1, $2, $3, $4)"
			),
			[cid, sid, delta, reason]
		)
	return true


# ---- reward tracks -------------------------------------------------------------


static func track_def(track_id: String) -> Dictionary:
	for t: Dictionary in config().get("tracks", []):
		if str(t.get("id", "")) == track_id:
			return t
	return {}


static func track_tier(cid: int, track_id: String) -> int:
	if _CM._test_skip_db:
		return int(_test_tracks.get("%d|%s" % [cid, track_id], -1))
	var rows: Variant = _CM.db_query(
		"SELECT tier FROM pvp.track_progress WHERE character_id = $1 AND track_id = $2",
		[cid, track_id]
	)
	if rows is Array and (rows as Array).size() > 0:
		return int((rows[0] as Dictionary).get("tier", -1))
	return -1


# Track op surface, routed from the world's session-identified intent. Actions:
#   browse   -> the published tracks + the caller's progress (read-only)
#   activate -> set the active track (must exist; no cost)
#   spend    -> buy the NEXT tier of the ACTIVE track (overdraft-guarded; unlock lands on the
#               T-375 cosmetic seam; ledger reason "track_spend")
static func track_op(params: Dictionary) -> Dictionary:
	var c := _CM.get_character(str(params.get("username", "")))
	if c.is_empty():
		return {"error": "unknown_character"}
	var cid := int(c["id"])
	var sid := int(params.get("season", 0))
	match str(params.get("action", "")):
		"browse":
			var out: Array = []
			for t: Dictionary in config().get("tracks", []):
				var tid := str(t["id"])
				(
					out
					. append(
						{
							"id": tid,
							"name": str(t.get("name", tid)),
							"tiers": t.get("tiers", []),
							"tier": track_tier(cid, tid),
						}
					)
				)
			var bal := balance(cid, sid)
			return {
				"ok": true, "tracks": out, "honor": bal["balance"], "active": bal["active_track"]
			}
		"activate":
			var tid := str(params.get("track", ""))
			if track_def(tid).is_empty():
				return {"error": "unknown_track"}
			_set_active(cid, sid, tid)
			return {"ok": true, "active": tid}
		"spend":
			return _spend_next_tier(cid, sid)
		"commend":
			# T-410: the TERMINAL, repeatable honor sink. Mirrors spend exactly — overdraft-guarded,
			# ledgered (reason "commendation") — but it never completes/exhausts and grants no
			# cosmetic. Surplus honor always advances the seasonal-commendation count the T-395
			# account-mastery floor will consume, so honor is never inert once the tracks are done.
			return _buy_commendation(cid, sid)
		"set_title":
			# T-401: wear a `title:` unlock. FAILS CLOSED — the id must be a title the character
			# already owns (in cosmetic_unlocks); "" clears the worn title. A forged/unowned title
			# is rejected here, server-side, so a client can never wear a title it has not earned.
			return _set_title(cid, str(params.get("title", "")))
	return {"error": "bad_action"}


# T-401: the character's cosmetic unlock ids (skins + `title:` ids). The read half of the seam
# PvpHonor.grant_unlock writes; used only to validate a title choice against real ownership.
static func unlocks_for(cid: int) -> Array:
	if _CM._test_skip_db:
		return _test_unlocks.get(cid, [])
	var rows: Variant = _CM.db_query(
		"SELECT appearance_id FROM inventory.cosmetic_unlocks WHERE character_id = $1", [cid]
	)
	var out: Array = []
	if rows is Array:
		for r: Dictionary in rows:
			out.append(str((r as Dictionary).get("appearance_id", "")))
	return out


static func _set_title(cid: int, title: String) -> Dictionary:
	if title != "":
		if not title.begins_with("title:"):
			return {"error": "not_a_title"}
		if not unlocks_for(cid).has(title):
			return {"error": "not_unlocked"}
	# Storage-only tail (ownership already validated). character_manager sits AT its file cap, so the
	# chosen_title write lands here directly: the DB UPDATE via _CM's handle, the test fake in-place.
	if _CM._test_skip_db:
		var c := _CM.get_character_by_id(cid)
		if not c.is_empty():
			c["chosen_title"] = title  # _test_characters entries are shared dicts (mutate in place)
	else:
		_CM.db_execute("UPDATE chars.characters SET chosen_title = $1 WHERE id = $2", [title, cid])
	return {"ok": true, "title": title}


static func _set_active(cid: int, sid: int, tid: String) -> void:
	if _CM._test_skip_db:
		var row: Dictionary = _test_honor.get("%d|%d" % [cid, sid], {"balance": 0})
		row["active_track"] = tid
		_test_honor["%d|%d" % [cid, sid]] = row
		return
	_CM.db_execute(
		(
			"INSERT INTO pvp.honor (character_id, season_id, balance, active_track) "
			+ "VALUES ($1, $2, 0, $3) ON CONFLICT (character_id, season_id) "
			+ "DO UPDATE SET active_track = $3"
		),
		[cid, sid, tid]
	)


static func _spend_next_tier(cid: int, sid: int) -> Dictionary:
	var bal := balance(cid, sid)
	var tid := str(bal["active_track"])
	var t := track_def(tid)
	if t.is_empty():
		return {"error": "no_active_track"}
	var tiers: Array = t.get("tiers", [])
	var next := track_tier(cid, tid) + 1
	if next >= tiers.size():
		return {"error": "track_complete"}
	var tier: Dictionary = tiers[next]
	var cost := int(tier.get("cost", 0))
	if not _adjust(cid, sid, -cost, "track_spend"):
		return {"error": "insufficient_honor", "cost": cost, "honor": bal["balance"]}
	_write_tier(cid, tid, next)
	grant_unlock(cid, str(tier.get("unlock", "")))
	return {
		"ok": true,
		"track": tid,
		"tier": next,
		"unlock": str(tier.get("unlock", "")),
		"honor": int(balance(cid, sid)["balance"]),
	}


static func _write_tier(cid: int, tid: String, tier: int) -> void:
	if _CM._test_skip_db:
		_test_tracks["%d|%s" % [cid, tid]] = tier
		return
	_CM.db_execute(
		(
			"INSERT INTO pvp.track_progress (character_id, track_id, tier) VALUES ($1, $2, $3) "
			+ "ON CONFLICT (character_id, track_id) DO UPDATE SET tier = $3"
		),
		[cid, tid, tier]
	)


# ---- terminal honor sink: seasonal commendations (T-410, T-395 seam) -----------


# The published, data-tunable commendation cost. Fail-closed to a positive default if unauthored so
# the sink can never be made free (a 0 cost would be an infinite mastery pump).
static func commendation_cost() -> int:
	return maxi(int(config().get("commendation", {}).get("cost", 250)), 1)


# How many seasonal commendations this character has bought this season. The ledger IS the record
# (reason "commendation") — no extra table; T-395 will sum the same rows to seed the mastery floor.
static func commendation_count(cid: int, sid: int) -> int:
	if _CM._test_skip_db:
		var n := 0
		for e: Dictionary in _test_ledger:
			if (
				int(e.get("character_id", 0)) == cid
				and int(e.get("season_id", 0)) == sid
				and str(e.get("reason", "")) == "commendation"
			):
				n += 1
		return n
	var rows: Variant = _CM.db_query(
		(
			"SELECT count(*) AS n FROM pvp.honor_ledger "
			+ "WHERE character_id = $1 AND season_id = $2 AND reason = 'commendation'"
		),
		[cid, sid]
	)
	if rows is Array and (rows as Array).size() > 0:
		return int((rows[0] as Dictionary).get("n", 0))
	return 0


# Buy ONE seasonal commendation. Overdraft-guarded identically to a track spend (fail-closed, writes
# nothing on insufficient honor). Repeatable forever — there is no completion state — so honor never
# becomes inert. Each purchase is a LIVE T-395 mastery feed (server-observed: the overdraft guard
# already adjudicated the spend, so this is play the server witnessed, never a client claim).
static func _buy_commendation(cid: int, sid: int) -> Dictionary:
	var cost := commendation_cost()
	var bal := int(balance(cid, sid)["balance"])
	if not _adjust(cid, sid, -cost, "commendation"):
		return {"error": "insufficient_honor", "cost": cost, "honor": bal}
	var uname := str(_CM.get_character_by_id(cid).get("username", ""))
	AccountMastery.observe(uname, cid, "commendation", 1)
	return {
		"ok": true,
		"commendation": true,
		"cost": cost,
		"count": commendation_count(cid, sid),
		"honor": int(balance(cid, sid)["balance"]),
	}


# ---- cosmetic/title landing (T-375 seam) ---------------------------------------


static func grant_unlock(cid: int, appearance_id: String) -> void:
	if appearance_id == "":
		return
	if _CM._test_skip_db:
		var arr: Array = _test_unlocks.get(cid, [])
		if not appearance_id in arr:
			arr.append(appearance_id)
		_test_unlocks[cid] = arr
		return
	_CM.db_execute(
		(
			"INSERT INTO inventory.cosmetic_unlocks (character_id, appearance_id) "
			+ "VALUES ($1, $2) ON CONFLICT DO NOTHING"
		),
		[cid, appearance_id]
	)


# ---- idempotent season payout ---------------------------------------------------


# Grant every participant of `prev_sid` their best-tier prestige unlock, exactly once ever
# (pvp.season_grants is the idempotency spine). Called when a season transition is observed;
# re-entry is a no-op per character. participants: [{character_id, rating}] from pvp.ratings.
static func season_payout(participants: Array, prev_sid: int) -> int:
	var payouts: Dictionary = config().get("season_payout", {})
	var granted := 0
	for p: Dictionary in participants:
		var cid := int(p.get("character_id", 0))
		var tier_name := EloRating.tier_for(int(p.get("rating", 0)))
		var grant: Dictionary = payouts.get(tier_name, {})
		if cid <= 0 or grant.is_empty():
			continue
		if not _claim_grant(cid, prev_sid, "season_cosmetic"):
			continue  # already paid — idempotent
		grant_unlock(cid, str(grant.get("unlock", "")))
		_record_ledger_only(cid, prev_sid, 0, "season_payout:" + tier_name)
		granted += 1
	return granted


static func _claim_grant(cid: int, sid: int, kind: String) -> bool:
	var key := "%d|%d|%s" % [cid, sid, kind]
	if _CM._test_skip_db:
		if _test_grants.has(key):
			return false
		_test_grants[key] = true
		return true
	# RETURNING makes the conflict observable: an already-claimed grant returns zero rows
	# (db_execute's boolean ok would read success either way and break idempotency).
	var rows: Variant = _CM.db_query(
		(
			"INSERT INTO pvp.season_grants (character_id, season_id, grant_kind) "
			+ "VALUES ($1, $2, $3) ON CONFLICT DO NOTHING RETURNING character_id"
		),
		[cid, sid, kind]
	)
	return rows is Array and (rows as Array).size() > 0


static func _record_ledger_only(cid: int, sid: int, delta: int, reason: String) -> void:
	if _CM._test_skip_db:
		_test_ledger.append(
			{"character_id": cid, "season_id": sid, "delta": delta, "reason": reason}
		)
		return
	(
		_CM
		. db_execute(
			"INSERT INTO pvp.honor_ledger (character_id, season_id, delta, reason) VALUES ($1, $2, $3, $4)",
			[cid, sid, delta, reason]
		)
	)


# ---- test accessors --------------------------------------------------------------


static func test_ledger() -> Array:
	return _test_ledger


static func test_unlocks(cid: int) -> Array:
	return _test_unlocks.get(cid, [])
