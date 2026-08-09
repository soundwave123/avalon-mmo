class_name AchievementRegistry
extends RefCounted

# T-367: the authored achievement/collection definitions (data/achievements.json). Load-once +
# cache, exactly like leveling.gd's growth-curve loader — deterministic (static file, no OS time),
# never throws (a missing/garbled file yields an empty registry so observe is a safe no-op).
#
# Data-only contract: adding an achievement is a new JSON row, NO code change (T-367 assertion).
# Each row: {id, name, desc, category, criteria:{event, key, count}, reward:{title|coin|cosmetic}}.

const _PATH := "res://data/achievements.json"

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


# The full ordered def list (for the client panel + the progress evaluator).
static func defs() -> Array:
	_ensure_loaded()
	return _defs


static func by_id(aid: String) -> Dictionary:
	_ensure_loaded()
	return _by_id.get(aid, {})


# Test-only override so store/observe tests don't depend on the shipped file.
static func _override_for_test(rows: Array) -> void:
	_loaded = true
	_defs = rows
	_by_id = {}
	for row: Dictionary in rows:
		_by_id[str(row.get("id", ""))] = row


# Test-only: drop the cache so the NEXT defs() re-reads the shipped file (undoes an earlier
# _override_for_test so the T-676 catalog-integrity/charter tests see the real achievements.json).
static func _reload_for_test() -> void:
	_loaded = false
	_defs = []
	_by_id = {}
