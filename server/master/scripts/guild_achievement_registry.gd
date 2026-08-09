class_name GuildAchievementRegistry
extends RefCounted

# T-679: the authored GUILD-collective achievement definitions (data/guild_achievements.json).
# Mirrors AchievementRegistry (T-367/T-676) exactly — load-once + cache, deterministic (static file,
# no OS time), never throws (a missing/garbled file yields an empty registry so observe is a safe
# no-op). Kept a separate loader from the per-character catalog so the two ladders stay independent
# data files; both feed the SAME pure AchievementProgress evaluator.
#
# Data-only contract: adding a guild achievement is a new JSON row, NO code change — as long as
# criteria.event is a guild-scoped event in AchievementProgress.SUPPORTED_EVENTS and the reward is
# cosmetic-only (the T-482 charter, guarded by test_guild_achievement_catalog).
# Each row: {id, name, desc, category, criteria:{event, key, count}, reward:{cosmetic}}.

const _PATH := "res://data/guild_achievements.json"

static var _defs: Array = []
static var _by_id: Dictionary = {}
static var _loaded: bool = false


static func _ensure_loaded() -> void:
	if _loaded:
		return
	_loaded = true
	_defs = []
	_by_id = {}
	if not FileAccess.file_exists(_PATH):
		return
	var file := FileAccess.open(_PATH, FileAccess.READ)
	if file == null:
		return
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	if not (parsed is Dictionary) or not (parsed.get("achievements") is Array):
		return
	for row: Variant in parsed["achievements"]:
		if row is Dictionary and str(row.get("id", "")) != "":
			_defs.append(row)
			_by_id[str(row["id"])] = row


# The full ordered def list (for the guild trophy-wall panel + the progress evaluator).
static func defs() -> Array:
	_ensure_loaded()
	return _defs


static func by_id(aid: String) -> Dictionary:
	_ensure_loaded()
	return _by_id.get(aid, {})


# The cosmetic ids a guild earns by unlocking each achievement — WardrobeOps unions these into a
# member's wearable set (eligibility follows current guild membership; see T-679 identity rule).
static func cosmetic_rewards() -> Array:
	var out: Array = []
	for def: Dictionary in defs():
		var cid := str((def.get("reward", {}) as Dictionary).get("cosmetic", ""))
		if cid != "" and not cid in out:
			out.append(cid)
	return out


# Test-only override so store/observe tests don't depend on the shipped file.
static func _override_for_test(rows: Array) -> void:
	_loaded = true
	_defs = rows
	_by_id = {}
	for row: Dictionary in rows:
		_by_id[str(row.get("id", ""))] = row


# Test-only: drop the cache so the NEXT defs() re-reads the shipped file (undoes the override).
static func _reload_for_test() -> void:
	_loaded = false
	_defs = []
	_by_id = {}
