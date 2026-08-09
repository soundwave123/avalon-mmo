extends GutTest

# T-701 commit 4: the inventory per-slot delta (T-700) wired into the hot callers must produce
# EXACTLY the stored state the full DELETE+reinsert produces — proven here against the REAL
# Postgres (fixture char pair: one persisted via delta, one via full write, rows byte-diffed
# through the same TSV read path). Also proves the T-069 rollback contract holds for a failed
# delta script, and that the wired callers actually take the delta path (untouched-row BIGSERIAL
# ids survive, which a full rewrite would churn).
const CharacterManager = preload("res://scripts/character_manager.gd")
const _IP = preload("res://scripts/inventory_persist.gd")

# Dev-container password (POSTGRES_PASSWORD in avalon-postgres; dev-only by construction).
const _DEV_PG_PASSWORD := "avalon_dev_only_not_for_prod"

const _REG := {
	"itm_t701_herb": {"stackable": true, "max_stack": 10},
	"itm_t701_sword": {"slot": "weapon"},
}

var _had_test_mode := false


func before_all() -> void:
	# Real-DB suite: statics leak across gut scripts, so force live mode and restore after.
	_had_test_mode = CharacterManager._test_skip_db
	CharacterManager._test_skip_db = false


func after_all() -> void:
	CharacterManager._test_skip_db = _had_test_mode


func _db_available() -> bool:
	if OS.get_environment("AVALON_PG_PASSWORD") == "":
		OS.set_environment("AVALON_PG_PASSWORD", _DEV_PG_PASSWORD)
	var rows: Array = CharacterManager.db_query("SELECT 1 AS one", [])
	return not rows.is_empty()


func _seed_char() -> int:
	var uname := "t701_delta_%d_%d" % [Time.get_ticks_usec(), randi() % 1000000]
	var rows: Array = CharacterManager.db_query(
		"INSERT INTO chars.characters (username, name) VALUES ($1, $1) RETURNING id", [uname]
	)
	return int(rows[0].get("id", -1)) if not rows.is_empty() else -1


func _reap(character_id: int) -> void:
	# ON DELETE CASCADE reaps character_items + cosmetic_unlocks with the row.
	CharacterManager.db_execute("DELETE FROM chars.characters WHERE id = $1", [character_id])


# The persisted slot columns as stored (no id/character_id) — the diffable read.
func _read(character_id: int) -> Array:
	return CharacterManager.db_query(_IP.select_sql(), [character_id])


func _slot(st: String, idx: int, item: String, count: int) -> Dictionary:
	return {"slot_type": st, "slot_index": idx, "item_id": item, "item_count": count}


func _fixture_a() -> Array:
	var sword := _slot("weapon", 0, "itm_t701_sword", 1)
	sword["era_scaled_to"] = 2
	sword["era_index"] = 1
	sword["retired"] = "t"
	return [
		_slot("bag", 0, "itm_t701_herb", 2),
		_slot("bag", 1, "itm_t701_ore", 5),
		_slot("bag", 2, "itm_t701_potion", 1),
		sword,
		_slot("bag", 6, "itm_t701_resin", 4),
		_slot("bag", 7, "itm_t701_hide", 2),
	]


# THE equivalence proof: same pre-image A, same target B — char X persisted with the full
# DELETE+reinsert, char Y with the delta; the stored rows must be identical, while the delta
# script touches strictly fewer rows (the write-amplification cure).
func test_delta_and_full_write_store_identical_state() -> void:
	if not _db_available():
		pending("Postgres not reachable — delta-vs-full-write equivalence not exercised")
		return
	var x := _seed_char()
	var y := _seed_char()
	assert_gt(x, 0, "fixture char (full write) seeded")
	assert_gt(y, 0, "fixture char (delta) seeded")
	var a := _fixture_a()
	# B: count change (bag0), untouched (bag1), remove (bag2), add (bag3), move w/ marks kept
	# (weapon0 -> bag5), add with the cosmetic channel set (chest0).
	var moved_sword := _slot("bag", 5, "itm_t701_sword", 1)
	moved_sword["era_scaled_to"] = 2
	moved_sword["era_index"] = 1
	moved_sword["retired"] = "t"
	var tunic := _slot("chest", 0, "itm_t701_tunic", 1)
	tunic["appearance_override"] = "itm_t701_fancy"
	tunic["tint"] = "crimson"
	var b := [
		_slot("bag", 0, "itm_t701_herb", 7),
		_slot("bag", 1, "itm_t701_ore", 5),
		_slot("bag", 3, "itm_t701_gem", 1),
		moved_sword,
		tunic,
		a[4],
		a[5],
	]
	for cid: int in [x, y]:
		var seed: Dictionary = _IP.build_persist(cid, a)
		assert_true(CharacterManager.db_execute(seed["sql"], seed["params"]), "pre-image A seeded")
	var full: Dictionary = _IP.build_persist(x, b)
	var delta: Dictionary = _IP.build_persist_delta(y, a, b)
	assert_true(CharacterManager.db_execute(full["sql"], full["params"]), "full write applied")
	assert_true(CharacterManager.db_execute(delta["sql"], delta["params"]), "delta applied")
	var rows_full := _read(x)
	var rows_delta := _read(y)
	assert_eq(rows_full.size(), 7, "full write landed the whole set")
	assert_eq(rows_delta, rows_full, "delta stored state byte-identical to the full write")
	var full_stmts: int = str(full["sql"]).count("character_items")
	var delta_stmts: int = str(delta["sql"]).count("character_items")
	assert_lt(delta_stmts, full_stmts, "delta touches fewer rows than delete-all + reinsert")
	_reap(x)
	_reap(y)


# T-069 intact on the delta path: one failing leg (CHECK item_count >= 1) rolls the WHOLE script
# back — the pre-image survives untouched.
func test_failed_delta_rolls_back_whole_script() -> void:
	if not _db_available():
		pending("Postgres not reachable — delta rollback not exercised")
		return
	var x := _seed_char()
	var a := _fixture_a()
	var seed: Dictionary = _IP.build_persist(x, a)
	assert_true(CharacterManager.db_execute(seed["sql"], seed["params"]), "pre-image A seeded")
	var before := _read(x)
	var bad := [
		_slot("bag", 0, "itm_t701_herb", 0),  # violates CHECK (item_count >= 1)
		a[1],
		a[3],  # bag2 removed -> a DELETE leg that must also roll back
	]
	var delta: Dictionary = _IP.build_persist_delta(x, a, bad)
	assert_false(
		CharacterManager.db_execute(delta["sql"], delta["params"]), "bad delta reports failure"
	)
	# The failed write's push_error is THE expected outcome here — consume it so gut
	# doesn't flag it as an unexpected engine error.
	assert_push_error("query failed", "the driver reports the rolled-back script loudly")
	assert_eq(_read(x), before, "failed delta left every pre-image row in place")
	_reap(x)


# The wired hot callers (try_add_items / try_equip / try_unequip / try_remove_item) against the
# real DB: after every op the stored state equals a full write of the op's result (mirror char),
# AND an untouched row's BIGSERIAL id never moves — the tell that the delta path really ran
# (a full rewrite reinserts every row, churning ids).
func test_hot_callers_delta_matches_full_write_mirror() -> void:
	if not _db_available():
		pending("Postgres not reachable — wired-caller delta not exercised")
		return
	var x := _seed_char()
	var m := _seed_char()
	var add := CharacterManager.try_add_items(
		x,
		[{"item_id": "itm_t701_herb", "count": 3}, {"item_id": "itm_t701_sword", "count": 1}],
		_REG
	)
	assert_true(bool(add["ok"]), "add_items committed")
	_assert_mirror_match(x, m, add["slots"], "try_add_items")
	var herb_id := _row_surrogate_id(x, "bag", 0)
	assert_gt(herb_id, 0, "herb row exists")
	var equip := CharacterManager.try_equip(x, 1, _REG)
	assert_true(bool(equip["ok"]), "try_equip committed")
	_assert_mirror_match(x, m, equip["slots"], "try_equip")
	var top_up := CharacterManager.try_add_items(
		x, [{"item_id": "itm_t701_herb", "count": 4}], _REG
	)
	assert_true(bool(top_up["ok"]), "stack top-up committed")
	_assert_mirror_match(x, m, top_up["slots"], "try_add_items (stack top-up)")
	var removed := CharacterManager.try_remove_item(x, "bag", 0, 2)
	assert_true(bool(removed["ok"]), "try_remove_item committed")
	_assert_mirror_match(x, m, removed["slots"], "try_remove_item")
	var unequip := CharacterManager.try_unequip(x, "weapon")
	assert_true(bool(unequip["ok"]), "try_unequip committed")
	_assert_mirror_match(x, m, unequip["slots"], "try_unequip")
	# bag0 was only ever count-changed (UPSERT) or untouched — its surrogate id must survive.
	assert_eq(
		_row_surrogate_id(x, "bag", 0),
		herb_id,
		"untouched/upserted row id stable => delta path ran"
	)
	_reap(x)
	_reap(m)


func _assert_mirror_match(x: int, m: int, slots: Array, label: String) -> void:
	var full: Dictionary = _IP.build_persist(m, slots)
	assert_true(CharacterManager.db_execute(full["sql"], full["params"]), "%s mirror write" % label)
	assert_eq(_read(x), _read(m), "%s: delta-persisted state == full-write state" % label)


func _row_surrogate_id(character_id: int, slot_type: String, slot_index: int) -> int:
	var rows: Array = CharacterManager.db_query(
		(
			"SELECT id FROM inventory.character_items "
			+ "WHERE character_id = $1 AND slot_type = $2 AND slot_index = $3"
		),
		[character_id, slot_type, slot_index]
	)
	return int(rows[0].get("id", -1)) if not rows.is_empty() else -1
