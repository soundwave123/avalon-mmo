class_name WeeklyVaultStore
extends RefCounted

# T-480 master authority: per-ACCOUNT per-ISO-week track progress + the once-per-week vault
# claim. Mirrors daily_appointment_store's discipline: client data never reaches this module —
# the world stamps the UTC date key and resolves identity from the live session; every credit
# rides an EXISTING server-observed event (turn_in / dungeon grant / record_match / discover).
# Grants are additive and pass the T-450 power-neutral allow-list; claims are idempotent.
#
# T-549: the weekly vault is an ACCOUNT-level retention ritual. T-507 alts must not each claim their
# own vault (up to 3x the T-475-modelled weekly coin into the shared market), so progress AND the
# once-per-week claim key on the ACCOUNT username: all of an account's characters build toward one
# shared weekly set, and whichever character claims first spends the account's vault (coin/XP land
# on that character). Only the once-per-period GATE is account-scoped.

const _WV := preload("res://scripts/weekly_vault.gd")
const _DA := preload("res://scripts/daily_appointment.gd")
const _CM := preload("res://scripts/character_manager.gd")
const _SS := preload("res://scripts/services_store.gd")
const _TS := preload("res://scripts/telemetry_store.gd")

static var _test_progress: Dictionary = {}  # account -> "week|track" -> int  (T-549)
static var _test_claims: Dictionary = {}  # account -> week -> choice  (T-549)


static func reset_for_test() -> void:
	_test_progress.clear()
	_test_claims.clear()


# The world-facing surface (master main.gd "weekly_op" arm): status browse + the claim intent.
static func op(params: Dictionary) -> Dictionary:
	var username := str(params.get("username", ""))
	var date_key := str(params.get("date_key", ""))
	if str(params.get("action", "status")) == "claim":
		return claim(username, date_key, str(params.get("choice", "")))
	return status(username, date_key)


# One tick on a track from a server-observed event. Progress caps at the goal (no chore surplus);
# unknown tracks/characters/dates are silent no-ops so hooks never disturb their host result.
static func credit(username: String, track: String, date_key: String) -> Dictionary:
	if not _WV.TRACKS.has(track):
		return {}
	var character: Dictionary = _CM.get_character(username)
	var week := _WV.week_key(date_key)
	if character.is_empty() or week == "":
		return {}
	var account := str(character.get("username", ""))  # T-549: progress is shared per account
	var goal := int((_WV.TRACKS[track] as Dictionary)["goal"])
	var bumped := _bump(account, week, track, goal)
	var progress := int(bumped["progress"])
	if bool(bumped["changed"]) and progress == goal:
		_emit(
			username,
			"weekly_progress",
			{"week_key": week, "track": track, "progress": progress, "goal": goal}
		)
	return {"week_key": week, "track": track, "progress": progress, "goal": goal}


# The weekly panel feed: this week's tracks (the build-toward) + the vault the LAST week earned
# (the choose-your-reward at rollover). No countdown anywhere — the week key is a fact, not FOMO.
static func status(username: String, date_key: String) -> Dictionary:
	var character: Dictionary = _CM.get_character(username)
	var week := _WV.week_key(date_key)
	if character.is_empty() or week == "":
		return {"ok": false, "reason": "invalid_weekly_status"}
	var account := str(character.get("username", ""))  # T-549: account-shared progress + vault
	var progress := _progress(account, week)
	var tracks: Array = []
	for track: String in _WV.TRACKS:
		var def: Dictionary = _WV.TRACKS[track]
		var value := int(progress.get(track, 0))
		(
			tracks
			. append(
				{
					"track": track,
					"title": str(def["title"]),
					"progress": value,
					"goal": int(def["goal"]),
					"complete": value >= int(def["goal"]),
				}
			)
		)
	var vault_week := _WV.previous_week_key(date_key)
	var vault_completed := _WV.tracks_completed(_progress(account, vault_week))
	var chosen := _chosen(account, vault_week)
	_emit(username, "weekly_open", {"week_key": week, "completed": _WV.tracks_completed(progress)})
	return {
		"ok": true,
		"week_key": week,
		"tracks": tracks,
		"completed": _WV.tracks_completed(progress),
		"vault":
		{
			"week_key": vault_week,
			"completed": vault_completed,
			"offers": _WV.offers_for(vault_completed),
			"claimed": chosen != "",
			"choice": chosen,
		},
	}


# Claim ONE chosen reward from the vault the previous week earned. Idempotent (once per week per
# character, enforced by the claims PK) and deterministic given the pick — never a random roll.
static func claim(username: String, date_key: String, choice_id: String) -> Dictionary:
	var character: Dictionary = _CM.get_character(username)
	var vault_week := _WV.previous_week_key(date_key)
	if character.is_empty() or vault_week == "":
		return {"ok": false, "reason": "invalid_weekly_claim"}
	var cid := int(character.get("id", -1))
	var account := str(character.get("username", ""))  # T-549: one vault claim per account per week
	var completed := _WV.tracks_completed(_progress(account, vault_week))
	var reward := _WV.resolve_choice(_WV.offers_for(completed), choice_id)
	if reward.is_empty():
		return {"ok": false, "reason": "invalid_choice"}
	if not _claim(account, vault_week, choice_id):
		return {"ok": false, "reason": "already_claimed"}
	_grant(cid, reward)  # coin/XP land on the character that spent the account's vault
	_emit(
		username, "weekly_claim", {"week_key": vault_week, "completed": completed, "reward": reward}
	)
	_emit(username, "weekly_reward_chosen", {"week_key": vault_week, "choice": choice_id})
	return {"ok": true, "week_key": vault_week, "choice": choice_id, "reward": reward}


# The T-483 end-of-session cue rides the daily payload: a warm "n/4 tracks" fact, nothing more.
static func summary(username: String, date_key: String) -> Dictionary:
	var character: Dictionary = _CM.get_character(username)
	var week := _WV.week_key(date_key)
	if character.is_empty() or week == "":
		return {}
	var account := str(character.get("username", ""))  # T-549: account-shared weekly summary
	return {"progress": _WV.tracks_completed(_progress(account, week)), "goal": _WV.TRACKS.size()}


# One capped increment. `changed` is false once the goal is reached, so telemetry emits exactly
# once per completed track per week (the capped over-play credit is a silent no-op).
static func _bump(account: String, week: String, track: String, goal: int) -> Dictionary:
	if _CM._test_skip_db:
		var claims: Dictionary = _test_progress.get(account, {})
		var key := "%s|%s" % [week, track]
		var previous := int(claims.get(key, 0))
		var next_value: int = mini(previous + 1, goal)
		claims[key] = next_value
		_test_progress[account] = claims
		return {"progress": next_value, "changed": next_value != previous}
	var rows := _CM.db_query(
		(
			"INSERT INTO chars.character_weekly_progress (account,week_key,track,progress) "
			+ "VALUES ($1,$2::date,$3,LEAST(1,$4)) "
			+ "ON CONFLICT (account,week_key,track) DO UPDATE SET "
			+ "progress = LEAST(chars.character_weekly_progress.progress + 1, $4) "
			+ "WHERE chars.character_weekly_progress.progress < $4 "
			+ "RETURNING progress"
		),
		[account, week, track, goal]
	)
	if rows.is_empty():  # the WHERE guard skipped a capped row — already at goal, nothing changed
		return {"progress": goal, "changed": false}
	return {"progress": int(rows[0].get("progress", 0)), "changed": true}


static func _progress(account: String, week: String) -> Dictionary:
	var out: Dictionary = {}
	if _CM._test_skip_db:
		var claims: Dictionary = _test_progress.get(account, {})
		for key: String in claims:
			var parts: PackedStringArray = key.split("|")
			if parts.size() == 2 and parts[0] == week:
				out[parts[1]] = int(claims[key])
		return out
	var rows := _CM.db_query(
		(
			"SELECT track, progress FROM chars.character_weekly_progress "
			+ "WHERE account = $1 AND week_key = $2::date"
		),
		[account, week]
	)
	for row: Dictionary in rows:
		out[str(row.get("track", ""))] = int(row.get("progress", 0))
	return out


static func _claim(account: String, week: String, choice_id: String) -> bool:
	if _CM._test_skip_db:
		var claims: Dictionary = _test_claims.get(account, {})
		if claims.has(week):
			return false
		claims[week] = choice_id
		_test_claims[account] = claims
		return true
	var rows := _CM.db_query(
		(
			"INSERT INTO chars.character_weekly_claims (account,week_key,choice) "
			+ "VALUES ($1,$2::date,$3) ON CONFLICT DO NOTHING RETURNING choice"
		),
		[account, week, choice_id]
	)
	return not rows.is_empty()


static func _chosen(account: String, week: String) -> String:
	if _CM._test_skip_db:
		return str((_test_claims.get(account, {}) as Dictionary).get(week, ""))
	var rows := _CM.db_query(
		(
			"SELECT choice FROM chars.character_weekly_claims "
			+ "WHERE account = $1 AND week_key = $2::date"
		),
		[account, week]
	)
	return str(rows[0].get("choice", "")) if not rows.is_empty() else ""


# Additive, allow-list-guarded grant: coins ride the canonical ledger faucet; XP follows the
# quest rule (no rested drain). Nothing here can grant gear, stats, or any combat power.
static func _grant(cid: int, reward: Dictionary) -> void:
	if not _DA.reward_is_power_neutral(reward):
		return
	var coins := int(reward.get("coins", 0))
	if coins > 0:
		_SS.adjust_coins(cid, coins, "weekly_vault")
	var xp := int(reward.get("xp", 0))
	if xp > 0:
		_CM.award_xp_to_character(cid, xp, false)


static func _emit(username: String, event_type: String, payload: Dictionary) -> void:
	_TS.record_events(
		[{"event_type": event_type, "account": username, "character": username, "payload": payload}]
	)
