extends GutTest

# T-390: PvP rating persistence + the full authority surface, on the test-mode fakes (no live
# Postgres). Covers every ticket assertion:
#   - a rated match updates BOTH participants server-side by the Elo curve (upset pays more)
#   - a season boundary snapshots (prior rows persist) and soft-resets the seed toward the mean
#   - the leaderboard returns correct top-N; record_match fail-closes on forged/bad inputs

const CharacterManager = preload("res://scripts/character_manager.gd")
const PvpStore = preload("res://scripts/pvp_store.gd")
const PvpSeason = preload("res://scripts/pvp_season.gd")
const EloRating = preload("res://scripts/elo_rating.gd")

# A `now` inside season 1 and season 2 (the pure season math is already unit-tested).
var _s1_now := PvpSeason.EPOCH_UNIX + 10
var _s2_now := PvpSeason.EPOCH_UNIX + PvpSeason.SEASON_SECS + 10


func before_each() -> void:
	CharacterManager.reset_for_test()
	PvpStore.reset_for_test()


func _mk(username: String) -> int:
	CharacterManager.ensure_character(username)
	return int(CharacterManager.get_character(username)["id"])


func test_match_updates_both_ratings_and_records_win_loss() -> void:
	_mk("alice")
	_mk("bob")
	var r := PvpStore.record_match({"winner": "alice", "loser": "bob", "now": _s1_now})
	assert_true(bool(r.get("ok", false)))
	assert_eq(int(r["season"]), 1)
	assert_gt(int(r["winner"]["rating"]), EloRating.DEFAULT_RATING, "winner climbs")
	assert_lt(int(r["loser"]["rating"]), EloRating.DEFAULT_RATING, "loser drops")
	assert_eq(int(r["winner"]["wins"]), 1)
	assert_eq(int(r["loser"]["losses"]), 1)


func test_upset_pays_more_end_to_end() -> void:
	# Seed a rating gap by having the favourite win several games, then let the underdog upset them.
	_mk("fav")
	_mk("dog")
	_mk("filler")
	for i in range(6):
		PvpStore.record_match({"winner": "fav", "loser": "filler", "now": _s1_now})
	var before := int(
		PvpStore.op({"action": "rating", "username": "dog", "now": _s1_now})["rating"]["rating"]
	)
	var r := PvpStore.record_match({"winner": "dog", "loser": "fav", "now": _s1_now})
	# The underdog gains a big chunk for beating a much higher-rated favourite.
	assert_gt(int(r["winner"]["delta"]), 20, "an upset pays a large delta")
	assert_gt(int(r["winner"]["rating"]), before)


func test_forged_and_bad_inputs_fail_closed() -> void:
	_mk("alice")
	# Unknown character (a forged winner/loser name) — rejected, nothing written.
	assert_eq(
		str(
			PvpStore.record_match({"winner": "ghost", "loser": "alice", "now": _s1_now}).get(
				"error"
			)
		),
		"unknown_character"
	)
	# Self-match — rejected.
	assert_eq(
		str(
			PvpStore.record_match({"winner": "alice", "loser": "alice", "now": _s1_now}).get(
				"error"
			)
		),
		"self_match"
	)
	# Bad bracket — rejected.
	_mk("bob")
	assert_eq(
		str(
			(
				PvpStore
				. record_match(
					{"winner": "alice", "loser": "bob", "bracket": "raid50", "now": _s1_now}
				)
				. get("error")
			)
		),
		"bad_bracket"
	)


func test_season_rollover_snapshots_and_soft_resets() -> void:
	_mk("alice")
	_mk("bob")
	# Alice climbs in season 1.
	for i in range(6):
		PvpStore.record_match({"winner": "alice", "loser": "bob", "now": _s1_now})
	var s1 := int(
		(
			PvpStore
			. op({"action": "rating", "username": "alice", "season": 1, "now": _s1_now})["rating"]["rating"]
		)
	)
	assert_gt(s1, EloRating.DEFAULT_RATING)
	# In season 2 (before any new match) her seed is the SOFT RESET of the season-1 rating.
	var seed := int(
		PvpStore.op({"action": "rating", "username": "alice", "now": _s2_now})["rating"]["rating"]
	)
	assert_eq(seed, EloRating.soft_reset(s1), "season-2 seed regresses toward the mean")
	assert_lt(seed, s1)
	assert_gt(seed, EloRating.DEFAULT_RATING, "but keeps a head-start (not a wipe)")
	# The season-1 standing is untouched — the prior season is the snapshot.
	assert_eq(
		int(
			(
				PvpStore
				. op({"action": "rating", "username": "alice", "season": 1, "now": _s2_now})["rating"]["rating"]
			)
		),
		s1
	)


func test_leaderboard_returns_ranked_top_n() -> void:
	for name in ["alice", "bob", "carol", "dave"]:
		_mk(name)
	# alice > bob > carol by win count; dave never plays (stays off the board).
	PvpStore.record_match({"winner": "alice", "loser": "carol", "now": _s1_now})
	PvpStore.record_match({"winner": "alice", "loser": "bob", "now": _s1_now})
	PvpStore.record_match({"winner": "bob", "loser": "carol", "now": _s1_now})
	var lb := PvpStore.op({"action": "leaderboard", "limit": 2, "now": _s1_now})
	var entries: Array = lb["entries"]
	assert_eq(entries.size(), 2, "top-N limit honored")
	assert_eq(str(entries[0]["name"]), "alice", "highest rating ranks first")
	assert_eq(int(entries[0]["rank"]), 1)
	assert_eq(int(entries[1]["rank"]), 2)
	assert_gt(int(entries[0]["rating"]), int(entries[1]["rating"]))
	assert_true(entries[0].has("tier"))


func test_read_op_never_creates_a_rating() -> void:
	_mk("alice")
	# An unranked read reports the seeded default but must NOT persist a row.
	var r := PvpStore.op({"action": "rating", "username": "alice", "now": _s1_now})
	assert_false(bool(r["ranked"]), "an unplayed character is not ranked")
	assert_eq(int(r["rating"]["rating"]), EloRating.DEFAULT_RATING)
	assert_eq(PvpStore.op({"action": "leaderboard", "now": _s1_now})["entries"].size(), 0)


func test_unknown_action_rejected() -> void:
	assert_eq(
		str(PvpStore.op({"action": "set_rating", "now": _s1_now}).get("error")), "unknown_action"
	)


# ---- T-413: the "bg" bracket is a separate ladder on the same spine ----------


func test_bg_bracket_records_its_own_ladder() -> void:
	_mk("alice")
	_mk("bob")
	var r := PvpStore.record_match(
		{"winner": "alice", "loser": "bob", "bracket": "bg", "now": _s1_now}
	)
	assert_true(bool(r.get("ok", false)), "bg is a valid bracket")
	assert_eq(str(r["bracket"]), "bg")
	assert_gt(int(r["winner"]["rating"]), EloRating.DEFAULT_RATING)
	# The bg ladder is independent — alice holds NO duel rating row from a bg match.
	var duel := PvpStore.op(
		{"action": "rating", "username": "alice", "bracket": "duel", "now": _s1_now}
	)
	assert_false(bool(duel["ranked"]), "a bg match never writes the duel ladder")
	var bg := PvpStore.op(
		{"action": "rating", "username": "alice", "bracket": "bg", "now": _s1_now}
	)
	assert_true(bool(bg["ranked"]), "the bg ladder holds the row")
	# The read surface accepts the bg bracket for leaderboards too.
	var lb := PvpStore.op({"action": "leaderboard", "bracket": "bg", "now": _s1_now})
	assert_eq((lb["entries"] as Array).size(), 2, "bg leaderboard lists both participants")


# ---- T-392: matchmaking call-in + loss-shield guardrails ---------------------


func test_matchmake_resolves_mmr_server_side_and_pairs() -> void:
	# Two near-peers queue; the matcher pairs them. The world passes only names + its own wait
	# clock — the MMR is read server-side (no client MMR).
	_mk("alice")
	_mk("bob")
	var res := (
		PvpStore
		. matchmake(
			{
				"bracket": "duel",
				"players": [{"name": "alice", "wait": 0}, {"name": "bob", "wait": 0}],
				"now": _s1_now,
			}
		)
	)
	assert_true(bool(res.get("ok", false)))
	assert_eq((res["pairs"] as Array).size(), 1, "two fresh peers at 1500 pair immediately")


func test_matchmake_drops_forged_and_unknown_names() -> void:
	# A forged/unknown queuer never enters the pool (fail-closed, no default-rating pairing).
	_mk("alice")
	var res := (
		PvpStore
		. matchmake(
			{
				"players": [{"name": "alice", "wait": 0}, {"name": "ghost", "wait": 0}],
				"now": _s1_now,
			}
		)
	)
	assert_eq((res["pairs"] as Array).size(), 0, "one real + one forged name -> no pair")
	assert_eq(res["unmatched"] as Array, ["alice"], "only the real queuer remains")


func test_record_match_ignores_a_forged_shield_param() -> void:
	# A client can neither grant itself a shield nor set a charge count: record_match reads the
	# shield from server state, never from the params.
	_mk("alice")
	_mk("bob")
	PvpStore.record_match(
		{"winner": "alice", "loser": "bob", "shield": 999, "rating": 9999, "now": _s1_now}
	)
	var a := PvpStore.op({"action": "rating", "username": "alice", "now": _s1_now})
	# Rating moved by the Elo curve only — the forged 9999 was ignored.
	assert_lt(int(a["rating"]["rating"]), 1600, "forged rating/shield had no effect")


func test_loss_shield_buffers_a_boundary_demotion() -> void:
	# Seed a post-placement loser sitting JUST above the Silver boundary (1410, Silver floor 1400)
	# with a full shield, so the wiring is deterministic. A loss that would cross below 1400 must be
	# HELD at the floor while a charge remains, and the charge is spent.
	var alice_id := _mk("alice")
	var bob_id := _mk("bob")
	# alice is a near-peer favourite so bob's raw Elo loss (~-14) clearly crosses below 1400.
	PvpStore._test_ratings["%d|1|duel" % alice_id] = {
		"rating": 1450, "wins": 20, "losses": 8, "shield": 3
	}
	PvpStore._test_ratings["%d|1|duel" % bob_id] = {
		"rating": 1410, "wins": 5, "losses": 12, "shield": 3
	}
	PvpStore.record_match({"winner": "alice", "loser": "bob", "now": _s1_now})
	var bob_row: Dictionary = PvpStore._test_ratings["%d|1|duel" % bob_id]
	assert_eq(int(bob_row["rating"]), 1400, "the rank shield holds bob AT the Silver boundary")
	assert_eq(int(bob_row["shield"]), 2, "the hold spent exactly one shield charge")
	# And with the buffer exhausted, the same loss demotes and re-seeds a fresh buffer.
	bob_row["shield"] = 0
	PvpStore.record_match({"winner": "alice", "loser": "bob", "now": _s1_now})
	var demoted: Dictionary = PvpStore._test_ratings["%d|1|duel" % bob_id]
	assert_lt(int(demoted["rating"]), 1400, "an empty shield lets the demotion fire")
	assert_eq(str(EloRating.tier_for(int(demoted["rating"]))), "Bronze", "bob drops to Bronze")
