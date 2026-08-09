class_name DailyAppointmentStore
extends RefCounted

# T-450 master authority: persistent streak + idempotent daily claims. Client data never reaches
# this module; the world injects its content registry and UTC key, while identity resolves from the
# validated username. Every grant is additive coin only and passes through the canonical ledger.
#
# T-549: the daily GIFT + STREAK are an ACCOUNT-level retention ritual, not a per-character grind
# reward — T-507 alts must not mint up to 3x the T-475-modelled daily faucet into the shared market.
# The streak state (and thus the once-per-day gift lockout, which IS last_login_date) keys on the
# ACCOUNT username; the first character to log in each day spends the account's gift, and the coin
# lands on that character. Daily QUEST claims (objective / first_completion) stay per-character —
# they reward playing that character, are one-shot, and are deliberately left untouched here.

const _DA := preload("res://scripts/daily_appointment.gd")
const _CM := preload("res://scripts/character_manager.gd")
const _SS := preload("res://scripts/services_store.gd")
const _TS := preload("res://scripts/telemetry_store.gd")
const _CCL := preload("res://scripts/cosmetic_ledger.gd")  # T-476: cosmetic-currency mint reasons

static var _test_state: Dictionary = {}  # account -> {last_login_date, streak}  (T-549)
static var _test_claims: Dictionary = {}  # cid -> "date|kind|content" -> true  (per-char quests)


static func reset_for_test() -> void:
	_test_state.clear()
	_test_claims.clear()


static func login(username: String, date_key: String) -> Dictionary:
	var character: Dictionary = _CM.get_character(username)
	if character.is_empty() or _DA.date_ordinal(date_key) < 0:
		return {"ok": false, "reason": "invalid_daily_login"}
	var cid := int(character.get("id", -1))
	# T-549: the gift/streak are ACCOUNT-scoped; last_login_date on the account row is the
	# once-per-account-per-day lockout, so a second alt logging in today mints nothing.
	var account := str(character.get("username", ""))
	var state := _state(account)
	var update := _DA.next_streak(
		str(state.get("last_login_date", "")), int(state.get("streak", 0)), date_key
	)
	var claimed := false
	var reward: Dictionary = {}
	if bool(update.get("changed", false)):
		claimed = true
		state = {"last_login_date": date_key, "streak": int(update["streak"])}
		_persist_state(account, state)
		reward = _DA.login_reward(int(update["streak"]))
		_grant_coins(cid, reward)  # coin lands on the character that spent the account's gift
		_emit(
			account,
			username,
			"daily_streak",
			{
				"date_key": date_key,
				"streak": int(update["streak"]),
				"missed_days": int(update["missed_days"]),
				"reward": reward,
			}
		)
		_emit(
			account,
			username,
			"daily_claim",
			{
				"date_key": date_key,
				"claim_kind": "login",
				"content_id": "",
				"reward": reward,
			}
		)
	return {
		"ok": true,
		"date_key": date_key,
		"streak": int(update.get("streak", state.get("streak", 0))),
		"missed_days": int(update.get("missed_days", 0)),
		"claimed": claimed,
		"reward": reward,
	}


static func status(username: String, date_key: String, quest_defs: Dictionary) -> Dictionary:
	var character: Dictionary = _CM.get_character(username)
	if character.is_empty() or _DA.date_ordinal(date_key) < 0:
		return {"ok": false, "reason": "invalid_daily_status", "objectives": []}
	var cid := int(character.get("id", -1))
	var account := str(character.get("username", ""))  # T-549: streak reads the account row
	# Selection is date/content-stable. Level is display eligibility only, so leveling mid-session
	# cannot silently reshuffle today's clear goals.
	var objectives := _DA.select_objectives(quest_defs, date_key, 1 << 30)
	var level := int(character.get("level", 1))
	var claimed_today: Array = []
	for objective: Dictionary in objectives:
		var quest_id := str(objective.get("quest_id", ""))
		var claimed := _claimed(cid, date_key, "objective", quest_id)
		objective["claimed"] = claimed
		objective["eligible"] = int(objective.get("min_level", 1)) <= level
		if claimed:
			claimed_today.append(quest_id)
	var state := _state(account)
	return {
		"ok": true,
		"date_key": date_key,
		"objectives": objectives,
		"claimed_today": claimed_today,
		"first_bonus_available": not _claimed(cid, date_key, "first_completion", "bounty"),
		"streak": int(state.get("streak", 0)),
	}


static func complete_quest(
	cid: int, username: String, date_key: String, quest: Dictionary, quest_defs: Dictionary
) -> Dictionary:
	if (
		cid <= 0
		or username == ""
		or _DA.date_ordinal(date_key) < 0
		or not _DA.is_daily_quest(quest)
	):
		return {"bonus_granted": false, "objective_claimed": false, "reward": {}}
	var selected := _DA.select_objectives(quest_defs, date_key, 1 << 30)
	var quest_id := str(quest.get("id", ""))
	var is_selected := selected.any(
		func(objective: Dictionary) -> bool: return str(objective.get("quest_id", "")) == quest_id
	)
	var level := int(_CM.get_character_by_id(cid).get("level", 1))
	var eligible := int(quest.get("min_level", 1)) <= level
	var objective_claimed := (
		is_selected and eligible and _claim(cid, date_key, "objective", quest_id)
	)
	return _complete_content(cid, username, date_key, "bounty", quest_id, objective_claimed)


static func complete_content(
	cid: int, username: String, date_key: String, kind: String, content_id: String
) -> Dictionary:
	if kind not in ["bounty", "dungeon"]:
		return {"bonus_granted": false, "objective_claimed": false, "reward": {}}
	return _complete_content(cid, username, date_key, kind, content_id, false)


static func _complete_content(
	cid: int,
	username: String,
	date_key: String,
	kind: String,
	content_id: String,
	objective_claimed: bool
) -> Dictionary:
	if cid <= 0 or username == "" or content_id == "" or _DA.date_ordinal(date_key) < 0:
		return {"bonus_granted": false, "objective_claimed": objective_claimed, "reward": {}}
	var bonus_granted := _claim(cid, date_key, "first_completion", kind)
	var reward := _DA.completion_reward() if bonus_granted else {}
	if bonus_granted:
		_grant_coins(cid, reward)
	if bonus_granted or objective_claimed:
		# Per-character quest completion: account/character are the same session identity string.
		_emit(
			username,
			username,
			"daily_claim",
			{
				"date_key": date_key,
				"claim_kind": kind,
				"content_id": content_id,
				"objective_claimed": objective_claimed,
				"reward": reward,
			}
		)
	return {
		"bonus_granted": bonus_granted,
		"objective_claimed": objective_claimed,
		"reward": reward,
	}


# T-549: the streak state — and thus the daily gift's once-per-day lockout — keys on the ACCOUNT.
static func _state(account: String) -> Dictionary:
	if _CM._test_skip_db:
		return (_test_state.get(account, {}) as Dictionary).duplicate(true)
	var rows := _CM.db_query(
		"SELECT last_login_date, streak FROM chars.character_daily_state WHERE account = $1",
		[account]
	)
	return rows[0] if not rows.is_empty() else {}


static func _persist_state(account: String, state: Dictionary) -> void:
	if _CM._test_skip_db:
		_test_state[account] = state.duplicate(true)
		return
	_CM.db_execute(
		(
			"INSERT INTO chars.character_daily_state (account,last_login_date,streak) "
			+ "VALUES ($1,$2::date,$3) ON CONFLICT (account) DO UPDATE SET "
			+ "last_login_date=EXCLUDED.last_login_date, streak=EXCLUDED.streak"
		),
		[account, state["last_login_date"], state["streak"]]
	)


static func _claim(cid: int, date_key: String, kind: String, content_id: String) -> bool:
	if _CM._test_skip_db:
		var claims: Dictionary = _test_claims.get(cid, {})
		var key := "%s|%s|%s" % [date_key, kind, content_id]
		if claims.has(key):
			return false
		claims[key] = true
		_test_claims[cid] = claims
		return true
	var rows := _CM.db_query(
		(
			"INSERT INTO chars.character_daily_claims "
			+ "(character_id,date_key,claim_kind,content_id) VALUES ($1,$2::date,$3,$4) "
			+ "ON CONFLICT DO NOTHING RETURNING claim_kind"
		),
		[cid, date_key, kind, content_id]
	)
	return not rows.is_empty()


static func _claimed(cid: int, date_key: String, kind: String, content_id: String) -> bool:
	if _CM._test_skip_db:
		return (_test_claims.get(cid, {}) as Dictionary).has(
			"%s|%s|%s" % [date_key, kind, content_id]
		)
	var rows := _CM.db_query(
		(
			"SELECT 1 AS claimed FROM chars.character_daily_claims "
			+ "WHERE character_id=$1 AND date_key=$2::date AND claim_kind=$3 AND content_id=$4"
		),
		[cid, date_key, kind, content_id]
	)
	return not rows.is_empty()


static func _grant_coins(cid: int, reward: Dictionary) -> void:
	if not _DA.reward_is_power_neutral(reward):
		return
	var coins := int(reward.get("coins", 0))
	if coins > 0:
		_SS.adjust_coins(cid, coins, "daily_reward")
	# T-476: back the phantom key — mint the earned cosmetic currency into the persisted balance.
	var cosmetic := int(reward.get("cosmetic_currency", 0))
	if cosmetic > 0:
		_SS.adjust_cosmetic_currency(cid, cosmetic, _CCL.REASON_DAILY)


static func _emit(
	account: String, character: String, event_type: String, payload: Dictionary
) -> void:
	_TS.record_events(
		[{"event_type": event_type, "account": account, "character": character, "payload": payload}]
	)
