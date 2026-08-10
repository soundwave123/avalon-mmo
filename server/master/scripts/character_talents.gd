extends RefCounted
# T-763 carve: the T-064 talent persistence tail, lifted out of character_manager.gd (1000-line
# cap, zero headroom after T-754). Spend VALIDATION stays pure in talent_logic; this module only
# persists ranks. The _test_skip_db flag and the _test_talents store ride in as params, and the DB
# path goes through db_bridge (the same seam character_manager's _query/_execute forward to), so
# character_manager.reset_for_test() stays the single reset seam and behavior is byte-identical.

const _TL = preload("res://scripts/talent_logic.gd")
const _DB = preload("res://scripts/db_bridge.gd")


static func get_talents(
	character_id: int, test_skip_db: bool, test_talents: Dictionary
) -> Dictionary:
	if test_skip_db:
		return test_talents.get(character_id, {})
	var out: Dictionary = {}
	var rows: Array = _DB.query(
		"SELECT talent_id, ranks FROM chars.character_talents WHERE character_id = $1",
		[character_id]
	)
	for row: Dictionary in rows:
		out[str(row.get("talent_id", ""))] = int(row.get("ranks", 0))
	return out


# Spend ONE point in `talent` (def supplied by the world, the content authority). `character` is
# the already-fetched row. Returns {ok, reason, ranks, points_left}.
static func spend(
	character_id: int,
	talent: Dictionary,
	talent_defs: Dictionary,
	character: Dictionary,
	test_skip_db: bool,
	test_talents: Dictionary
) -> Dictionary:
	if character.is_empty():
		return {"ok": false, "reason": "unknown_character", "ranks": 0, "points_left": 0}
	var spent: Dictionary = get_talents(character_id, test_skip_db, test_talents)
	var level: int = int(character.get("level", 1))
	var verdict: Dictionary = _TL.validate_spend(
		talent, spent, talent_defs, str(character.get("class", "")), level
	)
	var talent_id: String = str(talent.get("id", ""))
	if not verdict["ok"]:
		return {
			"ok": false,
			"reason": verdict["reason"],
			"ranks": int(spent.get(talent_id, 0)),
			"points_left": _TL.points_available(level) - _TL.points_spent(spent),
		}
	var new_ranks: int = int(spent.get(talent_id, 0)) + 1
	if test_skip_db:
		spent[talent_id] = new_ranks
		test_talents[character_id] = spent
	else:
		_DB.execute(
			(
				"INSERT INTO chars.character_talents (character_id, talent_id, ranks) "
				+ "VALUES ($1,$2,1) ON CONFLICT (character_id, talent_id) "
				+ "DO UPDATE SET ranks = chars.character_talents.ranks + 1"
			),
			[character_id, talent_id]
		)
		spent[talent_id] = new_ranks
	return {
		"ok": true,
		"reason": "",
		"ranks": new_ranks,
		"points_left": _TL.points_available(level) - _TL.points_spent(spent),
	}


# T-064: reroll path — talents die with the old build (no respec; delete wholesale).
static func clear(character_id: int, test_skip_db: bool, test_talents: Dictionary) -> bool:
	if test_skip_db:
		test_talents.erase(character_id)
		return true
	return _DB.execute(
		"DELETE FROM chars.character_talents WHERE character_id = $1", [character_id]
	)
