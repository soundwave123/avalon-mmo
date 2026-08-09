extends "res://addons/gut/test.gd"
# T-364 live-E2E regression: hydrate must handle the LIVE psql TSV shape (every value a String,
# SQL NULL = "") exactly like the typed test-mode shape. bool(<String>) crashed every live
# inventory read; "" never matched the == null checks, leaking era/cosmetic marks on live rows.

const _IP = preload("res://scripts/inventory_persist.gd")


func _row(overrides: Dictionary) -> Dictionary:
	var base := {
		"slot_type": "weapon",
		"slot_index": "0",
		"item_id": "itm_worn_sword",
		"item_count": "1",
		"era_scaled_to": "",
		"era_index": "",
		"retired": "f",
		"appearance_override": "",
		"tint": "",
	}
	base.merge(overrides, true)
	return base


func test_live_tsv_untouched_row_drops_all_marks() -> void:
	var rows := _IP.hydrate([_row({})])
	var r: Dictionary = rows[0]
	assert_false(r.has("era_scaled_to"), "TSV NULL ('') era mark dropped")
	assert_false(r.has("era_index"))
	assert_false(r.has("retired"), "TSV 'f' retired dropped")
	assert_false(r.has("appearance_override"), "TSV NULL cosmetic dropped")
	assert_false(r.has("tint"))
	assert_eq(str(r["item_id"]), "itm_worn_sword", "real fields untouched")


func test_live_tsv_marked_row_keeps_marks() -> void:
	var rows := _IP.hydrate([_row({"era_scaled_to": "2", "era_index": "1", "retired": "t"})])
	var r: Dictionary = rows[0]
	assert_true(r.has("era_scaled_to"), "a real era carry mark survives")
	assert_true(r.has("retired"), "TSV 't' retired survives")


func test_typed_testmode_rows_hydrate_identically() -> void:
	var typed := {
		"slot_type": "weapon",
		"slot_index": 0,
		"item_id": "x",
		"item_count": 1,
		"era_scaled_to": null,
		"era_index": null,
		"retired": false,
		"appearance_override": null,
		"tint": null
	}
	var rows := _IP.hydrate([typed])
	var r: Dictionary = rows[0]
	assert_false(r.has("era_scaled_to"))
	assert_false(r.has("retired"))
	assert_false(r.has("appearance_override"))


# T-414 live E2E regression: the FIRST live gather crashed append_persist — a hydrated row
# carries retired as the DB string "f"/"t" and bool("f") is an invalid-constructor crash.
# The round-trip (hydrate -> mutate -> persist) must run and bind a real boolean.
func test_build_persist_survives_hydrated_string_retired() -> void:
	var entry := {
		"slot_type": "bag",
		"slot_index": 0,
		"item_id": "itm_herb_bloodthorn",
		"item_count": 2,
		"retired": "f",
	}
	var out: Dictionary = _IP.build_persist(7, [entry])
	assert_true(out["sql"].contains("INSERT"), "persist SQL built")
	assert_true(out["params"].has(false), "string 'f' retired bound as boolean false")
	var hot := entry.duplicate()
	hot["retired"] = "t"
	var out2: Dictionary = _IP.build_persist(7, [hot])
	assert_true(out2["params"].has(true), "string 't' retired bound as boolean true")


func test_build_persist_grants_first_acquired_wearable_appearance_in_same_transaction() -> void:
	var out: Dictionary = _IP.build_persist(
		7,
		[{"slot_type": "bag", "slot_index": 0, "item_id": "itm_hat", "item_count": 1}],
		["itm_hat"]
	)
	assert_string_contains(out["sql"], "inventory.cosmetic_unlocks")
	assert_string_contains(out["sql"], "ON CONFLICT DO NOTHING")
	assert_true(out["params"].has("itm_hat"), "appearance id is bound, never interpolated")


# ---- T-700 Stage 1: per-slot UPSERT/DELETE delta ------------------------------


func _slot(st: String, idx: int, item: String, count: int) -> Dictionary:
	return {"slot_type": st, "slot_index": idx, "item_id": item, "item_count": count}


# Apply a delta plan to the previous slot set (in-memory) and return the resulting slot set keyed by
# (slot_type, slot_index) — the simulator the parity property leans on.
func _apply_delta(previous: Array, plan: Dictionary) -> Dictionary:
	var table: Dictionary = {}
	for e: Dictionary in previous:
		table["%s:%d" % [str(e["slot_type"]), int(e["slot_index"])]] = e
	for d: Dictionary in plan["deletes"]:
		table.erase("%s:%d" % [str(d["slot_type"]), int(d["slot_index"])])
	for u: Dictionary in plan["upserts"]:
		table["%s:%d" % [str(u["slot_type"]), int(u["slot_index"])]] = u
	return table


func _as_table(slots: Array) -> Dictionary:
	var t: Dictionary = {}
	for e: Dictionary in slots:
		t["%s:%d" % [str(e["slot_type"]), int(e["slot_index"])]] = e
	return t


# THE parity property: applying deletes-then-upserts to `previous` reproduces `new` EXACTLY, for
# adds, removes, moves, count changes, no-ops, and a combined churn — i.e. the delta is a drop-in
# for the full DELETE + reinsert.
func test_delta_reproduces_new_set_over_add_remove_move_sequences() -> void:
	var base := [
		_slot("bag", 0, "herb", 1), _slot("bag", 1, "ore", 2), _slot("weapon", 0, "sword", 1)
	]
	var scenarios := [
		base.duplicate(true),  # no-op
		base + [_slot("bag", 2, "gem", 1)],  # add
		[base[0], base[2]],  # remove (bag,1)
		[_slot("bag", 0, "herb", 5), base[1], base[2]],  # count change on (bag,0)
		[_slot("bag", 1, "herb", 1), _slot("bag", 0, "ore", 2), base[2]],  # swap items across two slots
		[_slot("bag", 0, "herb", 1)],  # mass removal
		[],  # empty everything
		[_slot("head", 0, "helm", 1)],  # full replace with a brand-new slot
	]
	for new_slots: Array in scenarios:
		var plan := _IP.delta_plan(base, new_slots)
		var got := _apply_delta(base, plan)
		var want := _as_table(new_slots)
		assert_eq(got.keys().size(), want.keys().size(), "same slot count after delta")
		for key: String in want:
			assert_true(got.has(key), "slot %s present after delta" % key)
			assert_true(
				_IP._row_values_equal(got[key], want[key]),
				"slot %s columns match full reinsert" % key
			)


# The delta writes ONLY the touched rows — an unchanged slot set writes nothing but BEGIN/COMMIT.
func test_delta_write_amplification_is_bounded_to_touched_slots() -> void:
	var prev := [_slot("bag", 0, "a", 1), _slot("bag", 1, "b", 1), _slot("bag", 2, "c", 1)]
	# Only (bag,1)'s count changed: one UPSERT, no DELETE (full reinsert would be 1 DEL + 3 INS).
	var one_change := [prev[0], _slot("bag", 1, "b", 9), prev[2]]
	var plan := _IP.delta_plan(prev, one_change)
	assert_eq(plan["upserts"].size(), 1, "one changed slot -> one UPSERT")
	assert_eq(plan["deletes"].size(), 0, "nothing removed -> no DELETE")
	# A true no-op touches nothing.
	var noop_plan := _IP.delta_plan(prev, prev.duplicate(true))
	assert_eq(noop_plan["upserts"].size(), 0, "unchanged set -> no UPSERT")
	assert_eq(noop_plan["deletes"].size(), 0, "unchanged set -> no DELETE")
	var out: Dictionary = _IP.build_persist_delta(7, prev, prev.duplicate(true))
	assert_false(out["sql"].contains("character_items"), "a no-op delta issues no item statements")


# Atomicity (T-609): the delta is one BEGIN..COMMIT script (ON_ERROR_STOP rolls the whole thing back
# on any failed leg — nothing moves), and it binds a real UPSERT with the UNIQUE conflict target.
func test_delta_is_one_atomic_transaction_with_upsert_target() -> void:
	var prev := [_slot("bag", 0, "a", 1), _slot("bag", 1, "b", 1)]
	var next := [_slot("bag", 0, "a", 3), _slot("head", 0, "helm", 1)]  # change + add + remove (bag,1)
	var out: Dictionary = _IP.build_persist_delta(7, prev, next)
	var sql: String = out["sql"]
	assert_true(sql.begins_with("BEGIN;"), "opens a transaction")
	assert_true(sql.strip_edges().ends_with("COMMIT;"), "commits the transaction")
	assert_string_contains(sql, "ON CONFLICT (character_id, slot_type, slot_index) DO UPDATE SET")
	assert_string_contains(sql, "DELETE FROM inventory.character_items")
	assert_true(int(out["params"].count(7)) >= 1, "character_id is bound, never interpolated")


# The delta binds the same era/cosmetic/retired normalization the full reinsert does (one binder).
func test_delta_upsert_binds_hydrated_string_retired_as_boolean() -> void:
	var prev := [_slot("bag", 0, "sword", 1)]
	var hot := _slot("bag", 0, "sword", 1)
	hot["retired"] = "t"  # a hydrated live row carries the DB string, not a bool
	var out: Dictionary = _IP.build_persist_delta(7, prev, [hot])
	assert_true(out["params"].has(true), "string 't' retired bound as boolean true, not text")
