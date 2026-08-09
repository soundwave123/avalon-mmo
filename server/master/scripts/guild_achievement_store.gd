class_name GuildAchievementStore
extends RefCounted

# T-679: per-GUILD collective achievement progress + earned set, persisted on master
# (chars.guild_achievement_counter / chars.guild_achievement, migration 051). Mirrors the
# per-character AchievementStore (T-367/T-676) exactly, but the SUBJECT is the guild id, so a
# milestone is credited ONCE to the guild — never double-counted per member, and a member joining a
# guild that ALREADY earned a milestone never re-fires it (history lives on the guild row, not the
# joiner).
#
# SERVER-AUTHORITY: observe() is driven only by master handlers behind already-validated events
# (kill/gather/quest credit, dungeon/raid clears, cap on login, the world's online-snapshot presence
# tick). There is NO client verb that reaches it; the client-facing surface is the read-only list().
#
# REWARD MODEL (identity-only by construction — the ticket's anti-guild-hopping + no-power-creep
# guardrail): a guild achievement's ONLY reward is a `cosmetic` id (or nothing). The earned row IS
# the guild's unlock — guild_cosmetic_unlocks() derives the wearable set from it, and WardrobeOps
# unions that into a member's eligibility for the guild they are CURRENTLY in. Leaving/being kicked
# drops the member from the guild, so the guild-earned look's eligibility vanishes for them
# (identity is the guild's) while their individually-owned unlocks are untouched. There is NO coin,
# title, stat, xp, or content-entry reward here — those are impossible to author (guarded by
# test_guild_achievement_catalog against the T-482 charter).

const _CM := preload("res://scripts/character_manager.gd")
const _AP := preload("res://scripts/achievement_progress.gd")
const _REG := preload("res://scripts/guild_achievement_registry.gd")

static var _test_counters: Dictionary = {}  # gid -> {counter_key: int}
static var _test_earned: Dictionary = {}  # gid -> {achievement_id: true}

# T-700 test instrumentation: counts batched counter-write invocations + the last key set written,
# so a write-amplification assertion proves "one invocation, changed keys only". Never read by play.
static var _persist_invocations: int = 0
static var _last_persisted_keys: Array = []


static func reset_for_test() -> void:
	_test_counters.clear()
	_test_earned.clear()
	_persist_invocations = 0
	_last_persisted_keys = []


# Server-observed collective event → advance the guild's counters, persist, record anything newly
# completed. Returns {"newly_earned": [def, ...]} (full registry rows) so the world can broadcast a
# "our guild earned X" toast to the roster. A cheap no-op for gid <= 0 or when nothing advances.
static func observe(gid: int, event: String, key: String, value: int = 0) -> Dictionary:
	if gid <= 0:
		return {"newly_earned": []}
	var state := _get_state(gid)
	var result := _AP.apply(_REG.defs(), state, event, key, value)
	# T-700: write ONLY the counters that changed this event, in one batched invocation (state's
	# counters are the pre-image the freshly-read _get_state returned).
	_persist_changed_counters(gid, state["counters"], result["counters"])
	var earned_defs: Array = []
	for aid: String in result["newly_earned"]:
		if _record_earned(gid, aid):  # idempotent guard — true only for a fresh, once-only grant
			earned_defs.append(_REG.by_id(aid))
	return {"newly_earned": earned_defs}


# The guild trophy-wall view: every def with its earned flag + completion fraction. Read-only.
static func list(gid: int) -> Dictionary:
	var state := _get_state(gid)
	var counters: Dictionary = state["counters"]
	var earned: Dictionary = {}
	for aid in state["earned"]:
		earned[str(aid)] = true
	var out: Array = []
	for def: Dictionary in _REG.defs():
		var aid := str(def.get("id", ""))
		(
			out
			. append(
				{
					"id": aid,
					"name": str(def.get("name", aid)),
					"desc": str(def.get("desc", "")),
					"category": str(def.get("category", "")),
					"reward": def.get("reward", {}),
					"earned": earned.has(aid),
					"fraction": _AP.fraction(def.get("criteria", {}), counters),
				}
			)
		)
	return {"guild_id": gid, "achievements": out}


# The guild-earned cosmetic ids a member of THIS guild may wear — derived from the earned set (the
# earned row IS the unlock). WardrobeOps.unlocks_for unions this in for the character's CURRENT
# guild, so eligibility follows membership: leave the guild and the look is no longer wearable, but
# no individually-owned unlock is touched.
static func guild_cosmetic_unlocks(gid: int) -> Array:
	if gid <= 0:
		return []
	var out: Array = []
	for aid in _get_state(gid)["earned"]:
		var cid := str((_REG.by_id(str(aid)).get("reward", {}) as Dictionary).get("cosmetic", ""))
		if cid != "" and not cid in out:
			out.append(cid)
	return out


# ---- persistence (test fakes ↔ Postgres) ------------------------------------


static func _get_state(gid: int) -> Dictionary:
	if _CM._test_skip_db:
		return {
			"counters": (_test_counters.get(gid, {}) as Dictionary).duplicate(true),
			"earned": (_test_earned.get(gid, {}) as Dictionary).keys(),
		}
	var counters: Dictionary = {}
	for row in _CM.db_query(
		"SELECT counter_key, value FROM chars.guild_achievement_counter WHERE guild_id = $1", [gid]
	):
		counters[str(row.get("counter_key", ""))] = int(row.get("value", 0))
	var earned: Array = []
	for row in _CM.db_query(
		"SELECT achievement_id FROM chars.guild_achievement WHERE guild_id = $1", [gid]
	):
		earned.append(str(row.get("achievement_id", "")))
	return {"counters": counters, "earned": earned}


# T-700: persist ONLY the counter keys whose value changed this event (was: every key, one
# subprocess each), all in ONE BEGIN..COMMIT invocation. Guild counters only ever appear or increase
# in _AP.apply — never erase — so there are no deletes to mirror.
static func _persist_changed_counters(gid: int, prev: Dictionary, new_counters: Dictionary) -> void:
	var changed: Array = []
	for ckey: String in new_counters:
		if not prev.has(ckey) or int(prev[ckey]) != int(new_counters[ckey]):
			changed.append(ckey)
	if changed.is_empty():
		return
	_persist_invocations += 1
	_last_persisted_keys = changed.duplicate()
	if _CM._test_skip_db:
		var store: Dictionary = _test_counters.get(gid, {})
		for ckey: String in changed:
			store[ckey] = int(new_counters[ckey])
		_test_counters[gid] = store
		return
	var stmts: Array = ["BEGIN;"]
	var params: Array = []
	for ckey: String in changed:
		var base: int = params.size()
		params.append_array([gid, ckey, int(new_counters[ckey])])
		stmts.append(
			(
				(
					"INSERT INTO chars.guild_achievement_counter (guild_id, counter_key, value) "
					+ "VALUES ($%d,$%d,$%d) "
					+ "ON CONFLICT (guild_id, counter_key) DO UPDATE SET value = EXCLUDED.value;"
				)
				% [base + 1, base + 2, base + 3]
			)
		)
	stmts.append("COMMIT;")
	_CM.db_execute("\n".join(stmts), params)


# Insert the earned row; returns true iff this call created it (the once-only, no-refire gate).
static func _record_earned(gid: int, aid: String) -> bool:
	if _CM._test_skip_db:
		var mine: Dictionary = _test_earned.get(gid, {})
		if mine.has(aid):
			return false
		mine[aid] = true
		_test_earned[gid] = mine
		return true
	var rows: Array = _CM.db_query(
		(
			"INSERT INTO chars.guild_achievement (guild_id, achievement_id) "
			+ "VALUES ($1, $2) ON CONFLICT DO NOTHING RETURNING achievement_id"
		),
		[gid, aid]
	)
	return not rows.is_empty()
