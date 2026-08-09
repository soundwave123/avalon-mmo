extends RefCounted

const CharacterManager = preload("res://scripts/character_manager.gd")
const DailyAppointment = preload("res://scripts/daily_appointment.gd")
const DailyAppointmentStore = preload("res://scripts/daily_appointment_store.gd")
const AchievementStore = preload("res://scripts/achievement_store.gd")  # T-676: clear achievements
const KillCreditOps = preload("res://scripts/kill_credit_ops.gd")  # T-679: shared credit_guild seam

static var _test_mode := false
static var _test_claims: Dictionary = {}


# Pure date-key comparison. The netcode supplies YYYY-MM-DD; this module never reads OS time.
static func can_claim(stamps: Dictionary, boss_id: String, date_key: String) -> bool:
	return boss_id != "" and date_key != "" and str(stamps.get(boss_id, "")) != date_key


# T-473: per-instance lockout cadence. Maps the netcode-supplied YYYY-MM-DD date key to the reset
# WINDOW key the claim is stamped with: "daily" is the date itself (the T-333 behaviour, byte-for-
# byte), "weekly" is the Monday of the date's ISO week — still a plain YYYY-MM-DD, so the existing
# chars.dungeon_blue_claims date column stores it unchanged (no migration). Pure date arithmetic on
# the supplied key (T-450 discipline: this module never reads OS time): daily_appointment's
# date_ordinal mirrors the proleptic-Gregorian toordinal, where ordinal 1 = 0001-01-01, a Monday,
# so weekday = (ordinal - 1) % 7 and the week's Monday is `offset` days back. Invalid input -> ""
# (which can_claim/_claim already reject).
static func window_key(cadence: String, date_key: String) -> String:
	if cadence != "weekly":
		return date_key
	var ordinal := DailyAppointment.date_ordinal(date_key)
	if ordinal < 0:
		return ""
	var offset := (ordinal - 1) % 7  # 0 = Monday .. 6 = Sunday
	var unix := Time.get_unix_time_from_datetime_string(date_key + "T00:00:00")
	return Time.get_datetime_string_from_unix_time(int(unix) - offset * 86400).substr(0, 10)


static func reset_for_test() -> void:
	_test_mode = true
	_test_claims.clear()


static func _claim(character_id: int, boss_id: String, date_key: String) -> bool:
	if boss_id == "" or date_key == "":
		return false
	if _test_mode:
		var stamps: Dictionary = _test_claims.get(character_id, {})
		if not can_claim(stamps, boss_id, date_key):
			return false
		stamps[boss_id] = date_key
		_test_claims[character_id] = stamps
		return true
	var rows := CharacterManager._query(
		(
			"INSERT INTO chars.dungeon_blue_claims (character_id,boss_id,last_blue_date) "
			+ "VALUES ($1,$2,$3::date) ON CONFLICT (character_id,boss_id) DO UPDATE "
			+ "SET last_blue_date=EXCLUDED.last_blue_date "
			+ "WHERE chars.dungeon_blue_claims.last_blue_date <> EXCLUDED.last_blue_date "
			+ "RETURNING boss_id"
		),
		[character_id, boss_id, date_key]
	)
	return not rows.is_empty()


static func grant(params: Dictionary) -> Dictionary:
	var username := str(params.get("username", ""))
	var character: Dictionary = CharacterManager.get_character(username)
	if character.is_empty():
		return {"ok": false, "reason": "unknown_character", "blue_granted": false}
	var cid := int(character.get("id", -1))
	var items: Array = params.get("guaranteed_items", []).duplicate(true)
	var blue_item := str(params.get("blue_item", ""))
	var blue_granted := false
	if blue_item != "":
		# T-473: the gated drop claims against its CADENCE window (daily = the date, weekly = the
		# ISO-week Monday), so a raid boss's loot re-locks for the whole week. The daily-appointment
		# gift below stays on the raw date key — clearing content is still a today thing.
		var window := window_key(
			str(params.get("cadence", "daily")), str(params.get("date_key", ""))
		)
		blue_granted = _claim(cid, str(params.get("boss_id", "")), window)
		if blue_granted:
			items.append({"item": blue_item, "count": 1})
	var result := CharacterManager.try_add_items(cid, items, params.get("item_registry", {}))
	if bool(result.get("ok", false)):
		result["credited"] = CharacterManager.refresh_collect_for_character(
			cid, params.get("quest_defs", {})
		)
		var daily := DailyAppointmentStore.complete_content(
			cid,
			username,
			str(params.get("date_key", "")),
			"dungeon",
			str(params.get("boss_id", ""))
		)
		result["daily"] = daily
		result["coins"] = int(daily.get("reward", {}).get("coins", 0))
		# T-676: a felled boss is a server-observed clear. dungeon_boss is a per-boss FLAG (+ unique
		# total) — powers "first Hollowed Crypt clear" (dungeon_boss:* >= 1) and "fell each named boss".
		# A weekly-cadence boss is a RAID boss; on a FRESH weekly lock (blue_granted) it also advances
		# raid_clear:* — the Vault-clear + "cleared across N weekly locks" tier (re-kills inside the
		# same locked week don't re-count, so the tier tracks distinct weekly clears).
		var boss_id := str(params.get("boss_id", ""))
		var earned: Array = AchievementStore.observe(cid, "dungeon_boss", boss_id).get(
			"newly_earned", []
		)
		# T-679: a felled boss is a collective clear credited to the actor's guild — the "first
		# Hollowed Crypt clear" (guild_dungeon_clear:* >= 1) and, on a fresh weekly lock, the
		# "first Vault clear together" (guild_raid_clear). Distinct-boss FLAG, so re-kills inside the
		# same locked week never re-count. No-op for a guildless clearer.
		KillCreditOps.credit_guild(result, cid, "guild_dungeon_clear", boss_id)
		if str(params.get("cadence", "daily")) == "weekly" and blue_granted:
			earned += AchievementStore.observe(cid, "raid_clear", boss_id).get("newly_earned", [])
			KillCreditOps.credit_guild(result, cid, "guild_raid_clear", boss_id)
		if not earned.is_empty():
			result["achievements"] = (result.get("achievements", []) as Array) + earned
	result["blue_granted"] = blue_granted and bool(result.get("ok", false))
	return result
