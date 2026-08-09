class_name DailyAppointment
extends RefCounted

# T-450 pure daily rules. The caller injects the UTC YYYY-MM-DD key, quest definitions, persisted
# streak facts, and player level. This module never reads OS time, a database, or global RNG.

const OBJECTIVE_COUNT := 2
const COMPLETION_BONUS_COINS := 50
const _LOGIN_BASE_COINS := 5
const _LOGIN_STEP_COINS := 5
const _LOGIN_STEP_CAP := 7
# T-476: the daily login also mints the earned cosmetic currency, giving the streak a power-neutral
# cosmetic payoff (game-direction.md §1.6/§4) — the earn faucet the store spends against.
const _LOGIN_STEP_COSMETIC := 2
const _ALLOWED_REWARD_KEYS := ["xp", "coins", "cosmetic_currency"]
const _DAYS_BEFORE_MONTH := [0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334]


static func date_ordinal(date_key: String) -> int:
	var parts := date_key.split("-")
	if (
		parts.size() != 3
		or parts[0].length() != 4
		or parts[1].length() != 2
		or parts[2].length() != 2
	):
		return -1
	if not parts[0].is_valid_int() or not parts[1].is_valid_int() or not parts[2].is_valid_int():
		return -1
	var year := int(parts[0])
	var month := int(parts[1])
	var day := int(parts[2])
	if year < 1 or month < 1 or month > 12 or day < 1 or day > _days_in_month(year, month):
		return -1
	var prior_year := year - 1
	var ordinal := (
		prior_year * 365
		+ floori(float(prior_year) / 4.0)
		- floori(float(prior_year) / 100.0)
		+ floori(float(prior_year) / 400.0)
		+ int(_DAYS_BEFORE_MONTH[month - 1])
		+ day
	)
	if month > 2 and _is_leap_year(year):
		ordinal += 1
	return ordinal


static func select_objectives(
	quest_defs: Dictionary, date_key: String, player_level: int, count: int = OBJECTIVE_COUNT
) -> Array:
	var ordinal := date_ordinal(date_key)
	if ordinal < 0 or count <= 0:
		return []
	var ids: Array[String] = []
	for quest_id: String in quest_defs:
		var quest: Dictionary = quest_defs[quest_id]
		if not is_daily_quest(quest) or int(quest.get("min_level", 1)) > player_level:
			continue
		ids.append(quest_id)
	ids.sort()
	var out: Array = []
	if ids.is_empty():
		return out
	var take := mini(count, ids.size())
	var offset := ordinal % ids.size()
	for index in range(take):
		var quest_id := ids[(offset + index) % ids.size()]
		var quest: Dictionary = quest_defs[quest_id]
		(
			out
			. append(
				{
					"quest_id": quest_id,
					"title": str(quest.get("title", quest_id)),
					"min_level": int(quest.get("min_level", 1)),
					"rewards": (quest.get("rewards", {}) as Dictionary).duplicate(true),
				}
			)
		)
	return out


static func next_streak(
	previous_date: String, previous_streak: int, date_key: String
) -> Dictionary:
	var today := date_ordinal(date_key)
	if today < 0:
		return {"changed": false, "streak": maxi(previous_streak, 0), "missed_days": 0}
	var prior := date_ordinal(previous_date)
	if prior < 0:
		return {"changed": true, "streak": 1, "missed_days": 0}
	var elapsed := today - prior
	if elapsed <= 0:
		return {"changed": false, "streak": maxi(previous_streak, 1), "missed_days": 0}
	if elapsed == 1:
		return {"changed": true, "streak": maxi(previous_streak, 0) + 1, "missed_days": 0}
	var missed := elapsed - 1
	return {
		"changed": true,
		"streak": maxi(1, previous_streak - missed),
		"missed_days": missed,
	}


static func login_reward(streak: int) -> Dictionary:
	var step := clampi(streak, 1, _LOGIN_STEP_CAP)
	return {
		"coins": _LOGIN_BASE_COINS + step * _LOGIN_STEP_COINS,
		"cosmetic_currency": step * _LOGIN_STEP_COSMETIC,
	}


static func completion_reward() -> Dictionary:
	return {"coins": COMPLETION_BONUS_COINS}


static func reward_is_power_neutral(reward: Dictionary) -> bool:
	for key in reward:
		if str(key) not in _ALLOWED_REWARD_KEYS:
			return false
		var value: Variant = reward[key]
		if not (value is int or value is float) or float(value) < 0.0:
			return false
	return true


static func is_daily_quest(quest: Dictionary) -> bool:
	return bool(quest.get("repeatable", false)) or bool(quest.get("bounty", false))


static func _is_leap_year(year: int) -> bool:
	return year % 4 == 0 and (year % 100 != 0 or year % 400 == 0)


static func _days_in_month(year: int, month: int) -> int:
	if month == 2:
		return 29 if _is_leap_year(year) else 28
	return 30 if month in [4, 6, 9, 11] else 31
