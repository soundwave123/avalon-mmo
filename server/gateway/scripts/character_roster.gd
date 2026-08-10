extends RefCounted

# T-716: shared module — preloaded, never class_name (its copies would collide).
const CharacterName = preload("res://scripts/character_name.gd")

# T-507: multi-character accounts — the GATEWAY half (roster CRUD over the login socket).
#
# The gateway owns pre-world roster mutation: list / create / soft-delete / ownership checks
# for char_select. Every operation takes the AUTHENTICATED username from the socket's login
# state (never from the message body) and touches only rows WHERE username = that account —
# a client can never list, delete, or select another account's character.
#
# Character names are a gameplay identity that flows through jwt.gd's hand-rolled JSON and
# database.gd's TSV layers (exactly like usernames, T-074), so they obey the same charset
# allowlist. Names equal to some OTHER account's username are reserved: that account's own
# bootstrap character (ensure_character names it after the account) must never be squatted.
#
# Delete is SOFT (deleted_at stamp): per-character data survives for support/undelete, while
# the partial unique indexes (044) free the name and slot for reuse.

# T-716: the allowlist moved to the shared CharacterName module (byte-identical in the gateway,
# the master and the client — see scripts/check_shared_files_sync.sh), so the name a player types
# at char-select and the name they type at the in-world creation step obey ONE rule. Unchanged
# semantics: same regex, still strict about case (this validates raw input, not normalised input).
const NAME_PATTERN := CharacterName.PATTERN  # same allowlist as gateway usernames (T-074)
const MAX_SLOTS := 3  # playtest cap (T-507 owner row)

static var _test_enabled: bool = false
static var _test_rows: Dictionary = {}  # id -> {id, username, name, slot, class, level, gender}
static var _test_reserved: Dictionary = {}  # username -> true (fake auth.accounts)
static var _test_next_id: int = 1


static func reset_for_test() -> void:
	_test_enabled = true
	_test_rows.clear()
	_test_reserved.clear()
	_test_next_id = 1


static func set_test_reserved_account(username: String) -> void:
	_test_reserved[username] = true


static func valid_name(name: String) -> bool:
	return CharacterName.is_valid(name)


# Live characters of the account, ordered by slot — the char-select payload.
static func list_characters(username: String) -> Array:
	if _test_enabled:
		var out: Array = []
		for id: Variant in _test_rows:
			if str(_test_rows[id]["username"]) == username:
				var row: Dictionary = _test_rows[id]
				out.append(row.duplicate())
		out.sort_custom(
			func(a: Dictionary, b: Dictionary) -> bool:
				var slot_a: int = a["slot"]
				var slot_b: int = b["slot"]
				return slot_a < slot_b
		)
		return out
	return _query(
		(
			"SELECT id, name, slot, class, class_locked, gender, level "
			+ "FROM chars.characters WHERE username = $1 AND deleted_at IS NULL ORDER BY slot"
		),
		[username]
	)


# The account's live character by id, or {} — the ownership gate for select/delete.
static func owned_character(username: String, character_id: int) -> Dictionary:
	if _test_enabled:
		var row: Dictionary = _test_rows.get(character_id, {})
		return row.duplicate() if str(row.get("username", "")) == username else {}
	var rows := _query(
		(
			"SELECT id, name, slot, class, level FROM chars.characters "
			+ "WHERE id = $1 AND username = $2 AND deleted_at IS NULL"
		),
		[character_id, username]
	)
	return rows[0] if not rows.is_empty() else {}


# Create a character in the lowest free slot. Returns {ok, reason, character}.
# Class/gender stay unchosen — the in-world T-520 gender + T-065 class flow (the fold-in).
static func create_character(username: String, name: String) -> Dictionary:
	if not valid_name(name):
		return {"ok": false, "reason": "invalid_name"}
	var roster := list_characters(username)
	if roster.size() >= MAX_SLOTS:
		return {"ok": false, "reason": "no_free_slots"}
	if _name_reserved(username, name):
		return {"ok": false, "reason": "name_taken"}
	var slot := _lowest_free_slot(roster)
	if _test_enabled:
		var row := {
			"id": _test_next_id,
			"username": username,
			"name": name,
			"slot": slot,
			"class": "warrior",
			"class_locked": false,
			"gender": "",
			"level": 1,
		}
		_test_rows[_test_next_id] = row
		_test_next_id += 1
		return {"ok": true, "reason": "", "character": row.duplicate()}
	# The 044 partial unique index on live names is the race arbiter; a lost race inserts 0 rows.
	# T-610: the seed CTE ledgers the starting balance (schema DEFAULT 100) into econ.coin_ledger
	# in the same statement, so the faucet audit reconciles for alts too (mirrors the master's
	# ensure_character; migration 050 backfilled history and registered the reason).
	var rows := _query(
		(
			"WITH ins AS ("
			+ "INSERT INTO chars.characters (username, name, slot) "
			+ "SELECT $1, $2, $3 WHERE NOT EXISTS (SELECT 1 FROM chars.characters "
			+ "WHERE name = $2 AND deleted_at IS NULL) "
			+ "RETURNING id, name, slot, class, class_locked, gender, level, coins), "
			+ "seed AS ("
			+ "INSERT INTO econ.coin_ledger (character_id, delta, reason) "
			+ "SELECT id, coins, 'starting_grant' FROM ins WHERE coins > 0) "
			+ "SELECT id, name, slot, class, class_locked, gender, level FROM ins"
		),
		[username, name, slot]
	)
	if rows.is_empty():
		return {"ok": false, "reason": "name_taken"}
	return {"ok": true, "reason": "", "character": rows[0]}


# Soft-delete an OWNED character. Returns {ok, reason}.
static func delete_character(username: String, character_id: int) -> Dictionary:
	if owned_character(username, character_id).is_empty():
		return {"ok": false, "reason": "not_owned"}
	if _test_enabled:
		_test_rows.erase(character_id)
		return {"ok": true, "reason": ""}
	var ok := _execute(
		(
			"UPDATE chars.characters SET deleted_at = NOW() "
			+ "WHERE id = $1 AND username = $2 AND deleted_at IS NULL"
		),
		[character_id, username]
	)
	return {"ok": ok, "reason": "" if ok else "database_error"}


static func _lowest_free_slot(roster: Array) -> int:
	var used: Dictionary = {}
	for row: Dictionary in roster:
		var slot: int = row.get("slot", 0)
		used[slot] = true
	for slot in range(MAX_SLOTS):
		if not used.has(slot):
			return slot
	return MAX_SLOTS  # unreachable behind the cap check; the 044 slot index would reject it


# A name is reserved when it is live in chars.characters or is ANOTHER account's username.
static func _name_reserved(username: String, name: String) -> bool:
	if _test_enabled:
		for id: Variant in _test_rows:
			if str(_test_rows[id]["name"]) == name:
				return true
		return _test_reserved.has(name) and name != username
	var live := _query(
		"SELECT 1 AS hit FROM chars.characters WHERE name = $1 AND deleted_at IS NULL", [name]
	)
	if not live.is_empty():
		return true
	if name == username:
		return false
	return not _query("SELECT 1 AS hit FROM auth.accounts WHERE username = $1", [name]).is_empty()


static func _execute(sql: String, parameters: Array) -> bool:
	var db: Database = _get_db()
	if db == null:
		return false
	var err: int = db.execute_query(sql, parameters)
	db.close_db()
	return err == OK


static func _query(sql: String, parameters: Array) -> Array:
	var db: Database = _get_db()
	if db == null:
		return []
	if db.execute_query(sql, parameters) != OK:
		db.close_db()
		return []
	var result: Variant = db.query_result()
	db.close_db()
	return result if result is Array else []


static func _get_db() -> Database:
	# T-757: typed via the addon's class_name; load() kept so a broken addon script
	# degrades to null at runtime instead of failing this file's parse.
	var database_script: GDScript = load("res://addons/database/database.gd")
	if database_script == null:
		return null
	var db: Database = database_script.new()
	if db.open_db("") != OK:
		return null
	return db
