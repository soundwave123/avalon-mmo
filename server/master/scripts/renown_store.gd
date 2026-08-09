class_name RenownStore
extends RefCounted

# T-678 v1: per-character, per-hub renown — the all-levels, per-place Arc clock. Follows the
# AchievementStore per-cid pattern exactly (owner decision 2026-08-08): chars.character_renown
# persistence (migration 054) + a T-700-style in-memory per-cid cache, same test-mode discipline
# (fakes when CharacterManager._test_skip_db, real DB via character_manager otherwise).
#
# SERVER-AUTHORITY: observe() is driven ONLY by server-validated seams (the master's _turn_in
# handler today) — there is NO client verb that grants renown. The client-facing surface is the
# read-only list() (renown_op action "list"). Points are monotonic: observe only ever adds.
#
# PACING (ticket DoD): FFXIV-like duration comes from the data-file point curve, NOT a throttle —
# there is deliberately NO daily cap/lockout in this store, so repeatable play always accrues.
# Hubs, source rates, and rank thresholds are DATA (res://data/renown_ranks.json), never code:
# adding a hub or retuning the curve is a JSON edit with no schema change. The schema stays clean
# for a possible LATER account-wide migration (one row per character+hub); do not build that here.

const _CM := preload("res://scripts/character_manager.gd")

const _CFG_PATH := "res://data/renown_ranks.json"

static var _cfg: Dictionary = {}  # loaded config; empty = not loaded (fail-soft: renown no-ops)
static var _test_points: Dictionary = {}  # cid -> {hub_id: points} (test fakes)
static var _cache_points: Dictionary = {}  # cid -> {hub_id: points} (authoritative in-memory)
static var _cache_loaded: Dictionary = {}  # cid -> true (hydrated, possibly legitimately empty)
static var _persist_invocations: int = 0  # test instrumentation only, never read by gameplay


static func reset_for_test() -> void:
	_test_points.clear()
	_cache_points.clear()
	_cache_loaded.clear()
	_persist_invocations = 0


static func _override_for_test(cfg: Dictionary) -> void:
	_cfg = cfg


static func _reload_for_test() -> void:
	_cfg = {}


# Lazy config load; fails soft to {} (a missing/broken file disables renown, never crashes boot).
static func config() -> Dictionary:
	if _cfg.is_empty():
		var f := FileAccess.open(_CFG_PATH, FileAccess.READ)
		if f != null:
			var parsed: Variant = JSON.parse_string(f.get_as_text())
			if parsed is Dictionary:
				_cfg = parsed
	return _cfg


# Rank row for a point total: the highest configured rank whose threshold is <= points.
static func rank_for(points: int) -> Dictionary:
	var best: Dictionary = {}
	for row: Dictionary in config().get("ranks", []):
		if points >= int(row.get("points", 0)):
			best = row
	return best


# Threshold of the NEXT rank above this total, or -1 at the track's top (feeds the client bar).
static func next_rank_points(points: int) -> int:
	for row: Dictionary in config().get("ranks", []):
		if int(row.get("points", 0)) > points:
			return int(row.get("points", 0))
	return -1


# Hub attribution: quests carry no zone field, so the turn-in NPC's id prefix is the hub signal
# ("npc_hk_*" -> highkeep, "npc_ashmoor_*" -> ashmoor), data-driven per hub. "" = not a hub quest.
static func hub_for_quest(quest: Dictionary) -> String:
	var npc_id := str(quest.get("turnin_npc", ""))
	if npc_id == "":
		return ""
	var hubs: Dictionary = config().get("hubs", {})
	for hub_id: String in hubs:
		for prefix in (hubs[hub_id] as Dictionary).get("npc_prefixes", []):
			if npc_id.begins_with(str(prefix)):
				return hub_id
	return ""


# Server-observed event -> add the configured source points to (cid, hub). Returns {} when nothing
# accrues (unknown hub/event, bad cid); else the grant + new standing so callers can surface it.
static func observe(cid: int, event: String, hub_id: String) -> Dictionary:
	if cid <= 0 or hub_id == "" or not (config().get("hubs", {}) as Dictionary).has(hub_id):
		return {}
	var gained := int((config().get("sources", {}) as Dictionary).get(event, 0))
	if gained <= 0:
		return {}
	_ensure_loaded(cid)
	var mine: Dictionary = _cache_points[cid]
	var prev := int(mine.get(hub_id, 0))
	var total := prev + gained
	mine[hub_id] = total
	_persist_hub(cid, hub_id, total)
	var rank := rank_for(total)
	return {
		"hub": hub_id,
		"gained": gained,
		"points": total,
		"rank": int(rank.get("rank", 0)),
		"rank_name": str(rank.get("name", "")),
		"rank_up": int(rank.get("rank", 0)) != int(rank_for(prev).get("rank", 0)),
	}


# The client panel view: one row per configured hub — 0-point hubs included on purpose (the
# visible-but-unfilled track IS the goal-gradient hook the ticket cites). Read-only.
static func list(cid: int) -> Dictionary:
	var mine: Dictionary = {}
	if cid > 0:
		_ensure_loaded(cid)
		mine = _cache_points[cid]
	var out: Array = []
	var hubs: Dictionary = config().get("hubs", {})
	for hub_id: String in hubs:
		var points := int(mine.get(hub_id, 0))
		var rank := rank_for(points)
		(
			out
			. append(
				{
					"hub": hub_id,
					"name": str((hubs[hub_id] as Dictionary).get("name", hub_id)),
					"points": points,
					"rank": int(rank.get("rank", 0)),
					"rank_name": str(rank.get("name", "")),
					"next_points": next_rank_points(points),
				}
			)
		)
	return {"renown": out}


# The master's renown_op dispatch arm body (lives here — main.gd sits at the gdlint file cap;
# precedent: SocialStore.op). Read-only "list" for the resolved character; grants never ride it.
static func op(params: Dictionary) -> Dictionary:
	if str(params.get("action", "list")) != "list":
		return {"error": "unknown_action"}
	var character: Dictionary = _CM.get_character(str(params.get("username", "")))
	if character.is_empty():
		return {"error": "unknown_character"}
	return list(int(character.get("id", -1)))


# ---- persistence (test fakes <-> Postgres; mirrors AchievementStore's cache lifecycle) --------


# Warm the cache on character load (optional — observe()/list() also lazy-load). Idempotent.
static func prime(cid: int) -> void:
	if cid > 0:
		_ensure_loaded(cid)


# Drop a character's cache on logout/eviction. The DB is the truth; next touch re-hydrates.
static func evict(cid: int) -> void:
	_cache_points.erase(cid)
	_cache_loaded.erase(cid)


static func _ensure_loaded(cid: int) -> void:
	if _cache_loaded.get(cid, false):
		return
	var points: Dictionary = {}
	if _CM._test_skip_db:
		points = (_test_points.get(cid, {}) as Dictionary).duplicate(true)
	else:
		for row in _CM.db_query(
			"SELECT hub_id, points FROM chars.character_renown WHERE character_id = $1", [cid]
		):
			points[str(row.get("hub_id", ""))] = int(row.get("points", 0))
	_cache_points[cid] = points
	_cache_loaded[cid] = true


# One hub's total changed -> one idempotent upsert. Grants are per-turn-in (low rate), so the
# single-row write already IS the delta — no batching needed at this event cadence.
static func _persist_hub(cid: int, hub_id: String, points: int) -> void:
	_persist_invocations += 1
	if _CM._test_skip_db:
		var store: Dictionary = _test_points.get(cid, {})
		store[hub_id] = points
		_test_points[cid] = store
		return
	_CM.db_execute(
		(
			"INSERT INTO chars.character_renown (character_id, hub_id, points) "
			+ "VALUES ($1, $2, $3) ON CONFLICT (character_id, hub_id) "
			+ "DO UPDATE SET points = EXCLUDED.points"
		),
		[cid, hub_id, points]
	)
