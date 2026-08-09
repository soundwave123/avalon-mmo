class_name WeeklyVault
extends RefCounted

# T-480 pure weekly-vault rules. The caller injects the UTC YYYY-MM-DD key; the ISO-week Monday
# window rides the T-473 `window_key("weekly", ...)` arithmetic. This module never reads OS time,
# a database, or global RNG. Ethics shape (FFXIV Challenge Log / Great Vault CHOOSE half): the
# player picks a KNOWN reward from a short offered list — never a random roll, never a loot box.
# Rewards are power-neutral only (the T-450 allow-list); a missed week costs only that week's
# bonus, never banked progress or power.

const _DA := preload("res://scripts/daily_appointment.gd")
const _LOCKOUT := preload("res://scripts/dungeon_daily_lockout.gd")

# The objective tracks. Each reads an EXISTING server-observed event stream — no new client verb
# can forge progress. Goals are one-sitting sized (catch-up guarantee: a weekend player clears
# any track in a single session; there is no per-day attendance sub-gate anywhere).
const TRACKS := {
	"quests": {"title": "Quests turned in", "goal": 5},
	"dungeons": {"title": "Dungeon bosses felled", "goal": 2},
	"battlegrounds": {"title": "Rated matches fought", "goal": 3},
	"discoveries": {"title": "Places discovered", "goal": 3},
}

# The full offer board, in the order choices unlock. Every reward passes the T-450 power-neutral
# allow-list (xp/coins/cosmetic_currency); the T-375 cosmetic-unlock seam is the extension point.
const _OFFERS := [
	{"id": "xp", "title": "A tale well told (XP)", "reward": {"xp": 400}},
	{"id": "coins", "title": "A purse of coins", "reward": {"coins": 150}},
	{"id": "mixed", "title": "A little of both", "reward": {"xp": 200, "coins": 75}},
]


# The vault week a date belongs to: the Monday of its ISO week (T-473 window, byte-for-byte).
static func week_key(date_key: String) -> String:
	return _LOCKOUT.window_key("weekly", date_key)


# The week BEFORE the date's week — the vault a player opens after rollover reads this window.
static func previous_week_key(date_key: String) -> String:
	var monday := week_key(date_key)
	if monday == "":
		return ""
	var unix := Time.get_unix_time_from_datetime_string(monday + "T00:00:00")
	return Time.get_datetime_string_from_unix_time(int(unix) - 7 * 86400).substr(0, 10)


static func tracks_completed(progress: Dictionary) -> int:
	var completed := 0
	for track: String in TRACKS:
		if int(progress.get(track, 0)) >= int((TRACKS[track] as Dictionary)["goal"]):
			completed += 1
	return completed


# Choice scaling: each completed track unlocks one more offer to pick from (agency grows with
# effort); one completed track already guarantees a choice. Never zero-for-something.
static func choice_count(completed: int) -> int:
	return clampi(completed, 0, _OFFERS.size())


static func offers_for(completed: int) -> Array:
	var out: Array = []
	for index in range(choice_count(completed)):
		out.append((_OFFERS[index] as Dictionary).duplicate(true))
	return out


# Deterministic given the pick: the chosen offer's reward, or {} for an id not on the board.
# The allow-list check is defense in depth — a non-neutral offer can never leave this module.
static func resolve_choice(offers: Array, choice_id: String) -> Dictionary:
	for offer: Dictionary in offers:
		if str(offer.get("id", "")) == choice_id:
			var reward: Dictionary = (offer.get("reward", {}) as Dictionary).duplicate(true)
			return reward if _DA.reward_is_power_neutral(reward) else {}
	return {}
