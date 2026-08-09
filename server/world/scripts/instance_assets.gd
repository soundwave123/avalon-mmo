# T-719 (carve): the instance layer's lazy JSON reads, lifted verbatim out of instance_service.gd so
# that file had room under the gdlint 1000-line cap for the Shallow Graves routing. Three read-once,
# cache-forever loaders over static content files — no game logic, no state beyond the caches, so
# they are static with static caches (the leveling.gd _ensure_loaded idiom) instead of instance
# members. Behaviour is byte-identical to the pre-carve methods, including the fail-quiet posture: a
# missing/malformed file yields an empty dict rather than throwing, because every consumer treats
# "no data" as "skip the optional enrichment".
extends RefCounted

const RARITY_PATH := "res://data/items/items.json"
const RIFT_SCHEDULE_PATH := "res://data/loot/rift_schedule.json"

static var _rarities: Dictionary = {}
static var _schedule: Dictionary = {}
static var _registry: Dictionary = {}


# T-353: {item_id -> rarity} for the era gear-carry. Rarities live world-side; master cannot preload
# them cross-project, so the crossing ships them along.
static func rarity_map() -> Dictionary:
	if _rarities.is_empty():
		for it: Dictionary in _items():
			_rarities[str(it.get("id", ""))] = str(it.get("rarity", ""))
	return _rarities


# T-393: the published rift reward odds + pool.
static func rift_schedule() -> Dictionary:
	if _schedule.is_empty():
		var parsed: Variant = _parse(RIFT_SCHEDULE_PATH)
		if parsed is Dictionary:
			_schedule = parsed
	return _schedule


# Raw {item_id -> def} registry for master's grant validation (stack/slot fields ride the raw
# authored dict — the same fields content_query.item_registry projects).
static func item_registry() -> Dictionary:
	if _registry.is_empty():
		for it: Dictionary in _items():
			_registry[str(it.get("id", ""))] = it
	return _registry


# Test seam: drop the caches so a suite can re-read after swapping content on disk.
static func reset_cache() -> void:
	_rarities = {}
	_schedule = {}
	_registry = {}


static func _items() -> Array:
	var parsed: Variant = _parse(RARITY_PATH)
	if parsed is Dictionary and (parsed as Dictionary).get("items", null) is Array:
		return (parsed as Dictionary)["items"]
	return []


static func _parse(path: String) -> Variant:
	if not FileAccess.file_exists(path):
		return null
	return JSON.parse_string(FileAccess.get_file_as_string(path))
