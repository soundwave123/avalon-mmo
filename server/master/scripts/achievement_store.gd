class_name AchievementStore
extends RefCounted

# T-367: per-character achievement progress + earned set, persisted on master (chars.character_*,
# migration 014). Same test-mode discipline as SocialStore/ServicesStore: fakes when
# CharacterManager._test_skip_db, real DB via character_manager's db_query/db_execute otherwise.
#
# SERVER-AUTHORITY: this is a SERVER-OBSERVED path only. observe() is driven by the master's
# credit_kill / turn_in / credit_reach handlers (events the server already validated) — there is NO
# client verb that reaches it, and the client-facing surface is the read-only list() (achievement_op
# action "list"). A cheat client can never assert an achievement or a reward.
#
# Completion fires exactly ONCE and grants its reward atomically: AchievementProgress derives
# newly-earned from the counters, we persist the earned rows (idempotent INSERT), and grant each
# reward exactly for the ids that were newly added.
#
# T-700 STAGE 1 — in-memory per-cid state cache + write-only-the-delta. The master is the SINGLE
# writer of this state, so each character's counter set + earned set is cached on first touch and
# served from memory thereafter: observe()/list() no longer read-modify-rewrite the WHOLE set per
# event (the old path did 2 SELECTs + get_character_by_id per observe, then UPSERTed every counter
# key the character owns). Now a persist writes ONLY the 1-2 counters that actually changed, in ONE
# batched BEGIN..COMMIT psql invocation. The DB stays the truth; on logout/eviction the cache is
# dropped and re-hydrated from the DB on next touch. Parity: the same achievements earn at the same
# moments, and the cache always equals a fresh DB read after each event (proved in tests).

const _CM := preload("res://scripts/character_manager.gd")
const _AP := preload("res://scripts/achievement_progress.gd")
const _REG := preload("res://scripts/achievement_registry.gd")
const _SERVICES := preload("res://scripts/services_store.gd")
const _MASTERY := preload("res://scripts/account_mastery.gd")  # T-676: achievements feed T-395

static var _test_counters: Dictionary = {}  # cid -> {counter_key: int}
static var _test_earned: Dictionary = {}  # cid -> {achievement_id: true}

# T-700: the live per-cid cache. _cache_loaded[cid] distinguishes "hydrated, legitimately empty"
# from "cold" so an empty character never re-reads the DB on every event.
static var _cache_counters: Dictionary = {}  # cid -> {counter_key: int}   (authoritative in-memory)
static var _cache_earned: Dictionary = {}  # cid -> {achievement_id: true}
static var _cache_loaded: Dictionary = {}  # cid -> true

# T-700 test instrumentation: counts batched counter-write invocations and records the last key set
# written, so query-count / write-amplification assertions can prove "one invocation, changed keys
# only" without a live DB. Never read by gameplay.
static var _persist_invocations: int = 0
static var _last_persisted_keys: Array = []


static func reset_for_test() -> void:
	_test_counters.clear()
	_test_earned.clear()
	_evict_all()
	_persist_invocations = 0
	_last_persisted_keys = []


# T-700: warm the cache from the DB on character load (optional — observe()/list() also lazy-load).
# Idempotent while the cid stays resident.
static func prime(cid: int) -> void:
	if cid > 0:
		_ensure_loaded(cid)


# T-700: drop a character's cache on logout/eviction. The DB is the truth; next touch re-hydrates.
static func evict(cid: int) -> void:
	_cache_counters.erase(cid)
	_cache_earned.erase(cid)
	_cache_loaded.erase(cid)


static func _evict_all() -> void:
	_cache_counters.clear()
	_cache_earned.clear()
	_cache_loaded.clear()


# Server-observed event → advance counters, persist, grant rewards for anything newly completed.
# Returns {"newly_earned": [def, ...]} where each def is the full registry row (name/desc/reward)
# so the world can toast the earner. A cheap no-op when nothing advances or no def matches.
static func observe(cid: int, event: String, key: String, value: int = 0) -> Dictionary:
	if cid <= 0:
		return {"newly_earned": []}
	_ensure_loaded(cid)
	var prev: Dictionary = _cache_counters[cid]
	# _AP.apply never mutates its inputs; feed it a copy of the cached state and take the fresh return.
	var state := {
		"counters": prev.duplicate(true), "earned": (_cache_earned[cid] as Dictionary).keys()
	}
	var result := _AP.apply(_REG.defs(), state, event, key, value)
	var new_counters: Dictionary = result["counters"]
	_persist_changed_counters(cid, prev, new_counters)  # writes ONLY changed keys, one invocation
	_cache_counters[cid] = new_counters
	var newly: Array = result["newly_earned"]
	var earned_defs: Array = []
	# T-700: get_character_by_id is now fetched lazily — only when something actually earns (it feeds
	# the mastery credit below); the common "advanced a counter, earned nothing" event skips the read.
	var username := ""
	for aid: String in newly:
		if _record_earned(cid, aid):  # idempotent once-only gate (cache + DB write-through)
			var def: Dictionary = _REG.by_id(aid)
			_grant_reward(cid, def.get("reward", {}))
			# T-395/T-676: a completion is server-observed play, so it feeds the permanent
			# account-mastery floor (achievements are a NAMED feeder into the T-395 track). Idempotent
			# by construction — _record_earned already gated this to a once-ever fresh grant.
			if username == "":
				username = str(_CM.get_character_by_id(cid).get("username", ""))
			if username != "":
				_MASTERY.observe(username, cid, "achievement", 1)
			earned_defs.append(def)
	return {"newly_earned": earned_defs}


# The client panel view: every def with its earned flag + completion fraction. Read-only.
static func list(cid: int) -> Dictionary:
	var counters: Dictionary = {}
	var earned: Dictionary = {}
	if cid > 0:
		_ensure_loaded(cid)
		counters = _cache_counters[cid]
		earned = _cache_earned[cid]
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
	return {"achievements": out}


# ---- persistence (test fakes ↔ Postgres) ------------------------------------


# T-700: hydrate the cache from the store (DB or the test fakes) exactly ONCE per resident cid.
static func _ensure_loaded(cid: int) -> void:
	if _cache_loaded.get(cid, false):
		return
	var st := _read_state(cid)
	_cache_counters[cid] = st["counters"]
	var earned_map: Dictionary = {}
	for aid in st["earned"]:
		earned_map[str(aid)] = true
	_cache_earned[cid] = earned_map
	_cache_loaded[cid] = true


# The authoritative read: the character's full counter + earned set from the store. Only ever called
# on a cold cache (cache miss) — the hot path serves from memory.
static func _read_state(cid: int) -> Dictionary:
	if _CM._test_skip_db:
		return {
			"counters": (_test_counters.get(cid, {}) as Dictionary).duplicate(true),
			"earned": (_test_earned.get(cid, {}) as Dictionary).keys(),
		}
	var counters: Dictionary = {}
	for row in (
		_CM
		. db_query(
			"SELECT counter_key, value FROM chars.character_achievement_counter WHERE character_id = $1",
			[cid]
		)
	):
		counters[str(row.get("counter_key", ""))] = int(row.get("value", 0))
	var earned: Array = []
	for row in _CM.db_query(
		"SELECT achievement_id FROM chars.character_achievement WHERE character_id = $1", [cid]
	):
		earned.append(str(row.get("achievement_id", "")))
	return {"counters": counters, "earned": earned}


# T-700: persist ONLY the counter keys whose value actually changed (was: every key, one subprocess
# each). Counters in _AP.apply only ever appear or increase — never erase — so there are no deletes
# to mirror. All changed keys ride ONE BEGIN..COMMIT invocation (mirrors inventory_persist's proven
# multi-statement transaction shape); an all-or-nothing write keeps the counter set self-consistent.
static func _persist_changed_counters(cid: int, prev: Dictionary, new_counters: Dictionary) -> void:
	var changed: Array = []
	for ckey: String in new_counters:
		if not prev.has(ckey) or int(prev[ckey]) != int(new_counters[ckey]):
			changed.append(ckey)
	if changed.is_empty():
		return
	_persist_invocations += 1
	_last_persisted_keys = changed.duplicate()
	if _CM._test_skip_db:
		var store: Dictionary = _test_counters.get(cid, {})
		for ckey: String in changed:
			store[ckey] = int(new_counters[ckey])
		_test_counters[cid] = store
		return
	var stmts: Array = ["BEGIN;"]
	var params: Array = []
	for ckey: String in changed:
		var base: int = params.size()
		params.append_array([cid, ckey, int(new_counters[ckey])])
		(
			stmts
			. append(
				(
					(
						"INSERT INTO chars.character_achievement_counter (character_id, counter_key, value) "
						+ "VALUES ($%d,$%d,$%d) "
						+ "ON CONFLICT (character_id, counter_key) DO UPDATE SET value = EXCLUDED.value;"
					)
					% [base + 1, base + 2, base + 3]
				)
			)
		)
	stmts.append("COMMIT;")
	_CM.db_execute("\n".join(stmts), params)


# Persist the earned row idempotently; returns true iff this call is the fresh, once-only grant.
# T-700: freshness is gated on the cache (the master is the single writer, so the cached earned set
# is authoritative); the DB write stays an idempotent ON CONFLICT DO NOTHING so a replay is safe.
static func _record_earned(cid: int, aid: String) -> bool:
	var earned_cache: Dictionary = _cache_earned[cid]
	if earned_cache.has(aid):
		return false
	earned_cache[aid] = true
	if _CM._test_skip_db:
		var mine: Dictionary = _test_earned.get(cid, {})
		mine[aid] = true
		_test_earned[cid] = mine
		return true
	_CM.db_execute(
		(
			"INSERT INTO chars.character_achievement (character_id, achievement_id) "
			+ "VALUES ($1, $2) ON CONFLICT DO NOTHING"
		),
		[cid, aid]
	)
	return true


static func _grant_reward(cid: int, reward: Dictionary) -> void:
	# Title/cosmetic unlocks ARE the earned row (the client reads them off list()); only coin needs
	# a side effect. Coins ride the same authoritative ServicesStore path the quests/auction use.
	var coin := int(reward.get("coin", 0))
	if coin > 0:
		_SERVICES.adjust_coins(cid, coin, "achievement_reward")  # T-366: coin faucet
