# T-353: inventory row <-> Postgres serialization for character_manager.
#
# Extracted from character_manager (at the gdlint 1000-line cap) when the rift gear-carry added the
# era_scaled_to / era_index / retired columns (migration 011): the SELECT hydration and the
# delete-all + reinsert statement builder are one cohesive responsibility. character_manager keeps
# the transaction execution (`_execute`) and the _test_skip_db in-memory path; this module is the
# pure SQL/row shape. No DB handle, no OS time, no global state.

extends RefCounted

const _IL = preload("res://scripts/inventory_logic.gd")

# The persisted inventory columns, in order — the single source of truth both statements share.
# T-375: appearance_override + tint are the cosmetic APPEARANCE channel (migration 018); NULL on
# every untouched row, hydrated away below so pre-transmog rows read exactly as before.
const _COLS := (
	"slot_type, slot_index, item_id, item_count, era_scaled_to, era_index, retired, "
	+ "appearance_override, tint"
)

# T-700: the UNIQUE (character_id, slot_type, slot_index) row is the delta's conflict target; on a
# hit every non-key persisted column is overwritten from the incoming row — so an UPSERT lands the
# exact same values a fresh INSERT would.
const _UPSERT_SET := (
	"item_id = EXCLUDED.item_id, item_count = EXCLUDED.item_count, "
	+ "era_scaled_to = EXCLUDED.era_scaled_to, era_index = EXCLUDED.era_index, "
	+ "retired = EXCLUDED.retired, appearance_override = EXCLUDED.appearance_override, "
	+ "tint = EXCLUDED.tint"
)


# T-353/T-567: item ids whose definitions name a real equip slot — persisted as wardrobe unlocks
# (never stats/display). Moved here from character_manager (at the line cap) so the reward-grant
# path can gate its persist on the result; `items` entries carry `item_id` (or legacy `item`).
static func wearable_appearance_ids(items: Array, item_registry: Dictionary) -> Array:
	var out: Array = []
	for entry: Dictionary in items:
		var item_id := str(entry.get("item_id", entry.get("item", "")))
		if item_registry.has(item_id):
			var slot := str((item_registry[item_id] as Dictionary).get("slot", "none"))
			if slot in _IL.EQUIP_SLOTS and not item_id in out:
				out.append(item_id)
	return out


# The SELECT for one character's inventory (character_id is $1).
static func select_sql() -> String:
	return (
		(
			"SELECT %s FROM inventory.character_items WHERE character_id = $1 "
			+ "ORDER BY slot_type, slot_index"
		)
		% _COLS
	)


# T-353: normalize DB rows in place — a NULL era_scaled_to is an untouched item, so drop the carry
# marks entirely (the one-hop guard reads `has("era_scaled_to")`, and untouched rows must look
# exactly as they did before the column existed). Returns the same array for call chaining.
static func hydrate(rows: Array) -> Array:
	# LIVE-DB REALITY (database.gd parses psql TSV): every value is a STRING and SQL NULL arrives
	# as "". Typed values still appear in test mode (_test_skip_db fake rows). Both shapes must
	# hydrate identically — bool(<String>) is not a constructor in Godot 4 (it crashed every live
	# inventory read carrying `retired`), and `== null` never matched a live NULL ("").
	for row: Dictionary in rows:
		if _is_db_null(row.get("era_scaled_to", null)):
			row.erase("era_scaled_to")
			row.erase("era_index")
		if not _is_db_true(row.get("retired", false)):
			row.erase("retired")
		# T-375: a NULL cosmetic channel is an item worn as itself — drop the marks so the row (and
		# equipped_from_slots) behaves exactly as it did before the columns existed.
		if _is_db_null(row.get("appearance_override", null)):
			row.erase("appearance_override")
		if _is_db_null(row.get("tint", null)):
			row.erase("tint")
	return rows


# SQL NULL over the TSV wire is "" (typed null in test mode).
static func _is_db_null(v: Variant) -> bool:
	return v == null or (v is String and str(v) == "")


# Postgres boolean over the TSV wire is "t"/"f" (typed bool in test mode).
static func _is_db_true(v: Variant) -> bool:
	if v is bool:
		return v
	return str(v).to_lower() in ["t", "true", "1"]


# Build the transactional persist for a character's whole slot set (T-069: one BEGIN..COMMIT script;
# a mid-persist failure rolls the whole thing back and the original rows survive). Returns
# { sql, params } — character_manager runs it through _execute. Untouched rows persist era_scaled_to
# / era_index as NULL and retired as FALSE (a plain item, unchanged).
static func build_persist(
	character_id: int, slots: Array, appearance_unlocks: Array = []
) -> Dictionary:
	var params: Array = []
	var stmts: Array = ["BEGIN;"]
	append_persist(character_id, slots, stmts, params, appearance_unlocks)
	stmts.append("COMMIT;")
	return {"sql": "\n".join(stmts), "params": params}


# T-363: the composable body of the persist — DELETE + reinsert for ONE character, appended to a
# caller-owned statement/param list. build_persist wraps it for the single-character case; the
# trade commit splices TWO characters' bodies (+ the coin moves) into ONE transaction so a
# player-to-player swap is all-or-nothing across both inventories.
static func append_persist(
	character_id: int, slots: Array, stmts: Array, params: Array, appearance_unlocks: Array = []
) -> void:
	params.append(character_id)
	stmts.append("DELETE FROM inventory.character_items WHERE character_id = $%d;" % params.size())
	for entry: Dictionary in slots:
		stmts.append(
			(
				"INSERT INTO inventory.character_items (character_id, %s) VALUES %s;"
				% [_COLS, _bind_row_values(character_id, entry, params)]
			)
		)
	_append_appearance_unlocks(character_id, appearance_unlocks, stmts, params)


# T-700: per-slot UPSERT/DELETE delta — the write-amplification cure for the DELETE-all + reinsert
# above. Given the PRE-IMAGE (the slots currently persisted, which the read-modify-write caller
# already holds) plus the NEW slot set, emit ONLY the touched rows: a DELETE for each removed slot
# and an UPSERT for each added-or-changed slot (byte-identical untouched rows are skipped). The
# OBSERVABLE slot set is identical to a full reinsert (proved by property test); the sole difference
# is the never-read BIGSERIAL `id` surrogate, which stays put for untouched rows instead of churning
# Atomicity (T-609) is unchanged — one BEGIN..COMMIT, all-or-nothing.
static func build_persist_delta(
	character_id: int, previous_slots: Array, slots: Array, appearance_unlocks: Array = []
) -> Dictionary:
	var params: Array = []
	var stmts: Array = ["BEGIN;"]
	append_persist_delta(character_id, previous_slots, slots, stmts, params, appearance_unlocks)
	stmts.append("COMMIT;")
	return {"sql": "\n".join(stmts), "params": params}


# The composable delta body (mirrors append_persist's role for the multi-character splice case).
static func append_persist_delta(
	character_id: int,
	previous_slots: Array,
	slots: Array,
	stmts: Array,
	params: Array,
	appearance_unlocks: Array = []
) -> void:
	var plan := delta_plan(previous_slots, slots)
	# DELETE rows present before but absent now (a removed / moved-away slot).
	for entry: Dictionary in plan["deletes"]:
		var base: int = params.size()
		params.append_array([character_id, str(entry["slot_type"]), int(entry["slot_index"])])
		stmts.append(
			(
				(
					"DELETE FROM inventory.character_items "
					+ "WHERE character_id = $%d AND slot_type = $%d AND slot_index = $%d;"
				)
				% [base + 1, base + 2, base + 3]
			)
		)
	# UPSERT rows that are new or whose persisted columns changed (untouched rows are not in the plan).
	for entry: Dictionary in plan["upserts"]:
		stmts.append(
			(
				(
					"INSERT INTO inventory.character_items (character_id, %s) VALUES %s "
					+ "ON CONFLICT (character_id, slot_type, slot_index) DO UPDATE SET %s;"
				)
				% [_COLS, _bind_row_values(character_id, entry, params), _UPSERT_SET]
			)
		)
	_append_appearance_unlocks(character_id, appearance_unlocks, stmts, params)


# T-700: the pure diff behind the delta — {"deletes": [row,...], "upserts": [row,...]}. deletes are
# the previous slots whose (slot_type, slot_index) key is gone from the new set; upserts are new
# slots that are added or whose persisted columns changed (byte-identical untouched slots are in
# neither). Applying deletes-then-upserts to the previous set reproduces the new set EXACTLY — that
# is what makes the delta a drop-in for the full reinsert (property-tested).
static func delta_plan(previous_slots: Array, slots: Array) -> Dictionary:
	var prev_by_key: Dictionary = {}
	for entry: Dictionary in previous_slots:
		prev_by_key[_slot_key(entry)] = entry
	var new_keys: Dictionary = {}
	for entry: Dictionary in slots:
		new_keys[_slot_key(entry)] = true
	var deletes: Array = []
	for entry: Dictionary in previous_slots:
		if not new_keys.has(_slot_key(entry)):
			deletes.append(entry)
	var upserts: Array = []
	for entry: Dictionary in slots:
		var key := _slot_key(entry)
		if prev_by_key.has(key) and _row_values_equal(prev_by_key[key], entry):
			continue
		upserts.append(entry)
	return {"deletes": deletes, "upserts": upserts}


# Bind one slot's 10 persisted columns as params (in _COLS order) and return the "($a,...,$j)"
# placeholder tuple. Shared by the full-reinsert INSERT and the per-slot UPSERT so both bind
# IDENTICALLY — the T-353 era-null, T-375 cosmetic-null, and _is_db_true retired handling live here
# in ONE place (a hydrated row carries "t"/"f"/"" strings; bool("f") is an invalid-constructor bug).
static func _bind_row_values(character_id: int, entry: Dictionary, params: Array) -> String:
	var base: int = params.size()
	var era_scaled_to: Variant = entry.get("era_scaled_to", null)
	var era_index: Variant = entry.get("era_index", null)
	var appearance: Variant = entry.get("appearance_override", null)
	if appearance != null and str(appearance) == "":
		appearance = null
	var tint: Variant = entry.get("tint", null)
	if tint != null and str(tint) == "":
		tint = null
	(
		params
		. append_array(
			[
				character_id,
				str(entry["slot_type"]),
				int(entry["slot_index"]),
				str(entry["item_id"]),
				int(entry["item_count"]),
				era_scaled_to if era_scaled_to == null else int(era_scaled_to),
				era_index if era_index == null else int(era_index),
				_is_db_true(entry.get("retired", false)),
				appearance if appearance == null else str(appearance),
				tint if tint == null else str(tint),
			]
		)
	)
	return (
		"($%d,$%d,$%d,$%d,$%d,$%d,$%d,$%d,$%d,$%d)"
		% [
			base + 1,
			base + 2,
			base + 3,
			base + 4,
			base + 5,
			base + 6,
			base + 7,
			base + 8,
			base + 9,
			base + 10
		]
	)


# T-428: acquiring a wearable and persisting the inventory unlocks its appearance in the SAME
# transaction. A crash cannot land the item without its look (or vice versa); conflicts are the
# idempotent "already learned" path. IDs are bound parameters, never interpolated SQL.
static func _append_appearance_unlocks(
	character_id: int, appearance_unlocks: Array, stmts: Array, params: Array
) -> void:
	for appearance_id: String in appearance_unlocks:
		if appearance_id == "":
			continue
		params.append_array([character_id, appearance_id])
		stmts.append(
			(
				(
					"INSERT INTO inventory.cosmetic_unlocks (character_id, appearance_id) "
					+ "VALUES ($%d,$%d) ON CONFLICT DO NOTHING;"
				)
				% [params.size() - 1, params.size()]
			)
		)


# The delta's slot identity — the UNIQUE key columns, normalized (a live slot_index is the TSV
# string "0", a test-mode one is the int 0; both must key the same).
static func _slot_key(entry: Dictionary) -> String:
	return "%s:%d" % [str(entry.get("slot_type", "")), int(entry.get("slot_index", 0))]


# True when two slot rows persist byte-identical column values — compared through the SAME binding
# normalization _bind_row_values applies, so a hydrated-string row and a typed row match correctly.
# character_id is fixed (0) for both so only the slot columns are compared.
static func _row_values_equal(a: Dictionary, b: Dictionary) -> bool:
	var pa: Array = []
	var pb: Array = []
	_bind_row_values(0, a, pa)
	_bind_row_values(0, b, pb)
	return pa == pb
