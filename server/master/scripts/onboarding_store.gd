extends RefCounted

# T-550: ACCOUNT-level onboarding state — the server-authoritative memory that makes the two halves
# of the T-426 teaching layer agree in the multi-character era (T-507).
#
#   * tutorial_done — set ONCE, when any character on the account turns in the graduation quest
#     (q_tut_03). A new alt on a graduated account is not force-fed the chain (still OFFERED by
#     Drillmaster Hale — availability is unchanged); the account's first-ever character still gets
#     the full guided onboarding. should_force_tutorial() is the pure gate.
#   * hint_seen — the fire-once control-hint memory, keyed by (account, hint_id). Once the account
#     has seen a hint on any character/device, alts don't re-nag; the first character still gets
#     every hint. Moved here from the per-DEVICE user://onboarding.cfg so a new-device alt is also
#     correctly suppressed.
#
# Server authority (the T-482/AccountMastery idiom): the ONLY writer of tutorial_done is the
# server-observed turn-in path (note_graduation, below) — there is NO client op that sets it, so a
# client cannot forge "tutorial done". Hint sightings are client-reported but only ever SET a row
# (never clear), and the account is resolved from the authenticated character server-side, never
# from client input — a forged report suppresses the caller's own nag and nothing else.
#
# DB seam mirrors AccountMastery: CharacterManager owns the one connection idiom; this store
# branches on _CM._test_skip_db to in-memory dicts so the logic unit-tests headless.

const _CM := preload("res://scripts/character_manager.gd")

# The tutorial chain's final quest — turning it in graduates the account.
const GRADUATION_QUEST := "q_tut_03"

static var _test_tutorial: Dictionary = {}  # account -> true (tutorial_done)
static var _test_hints: Dictionary = {}  # account -> {hint_id: true}


static func reset_for_test() -> void:
	_test_tutorial.clear()
	_test_hints.clear()


# ---- pure decisions (headless-testable, no DB) --------------------------------


# The tutorial chain is FORCED (auto-guided) only until the account graduates one character. After
# that it is merely offered — a returning player's alt starts free to play. Availability (the ! on
# Hale) is decided elsewhere by npc_interaction and is deliberately NOT changed here: an alt can
# always still pick the chain up by choice.
static func should_force_tutorial(tutorial_done: bool) -> bool:
	return not tutorial_done


# ---- tutorial graduation (account-level) --------------------------------------


static func is_tutorial_done(account: String) -> bool:
	if account == "":
		return false
	if _CM._test_skip_db:
		return bool(_test_tutorial.get(account, false))
	var rows: Variant = _CM.db_query(
		"SELECT tutorial_done FROM onboarding.account_progress WHERE account = $1", [account]
	)
	if rows is Array and not (rows as Array).is_empty():
		return _is_db_true((rows[0] as Dictionary).get("tutorial_done", false))
	return false


# Idempotent: the account is graduated forever after the first call (ON CONFLICT no-op keeps the
# original updated_at meaningful only on the first write; re-graduating is harmless).
static func mark_tutorial_done(account: String) -> void:
	if account == "":
		return
	if _CM._test_skip_db:
		_test_tutorial[account] = true
		return
	_CM.db_execute(
		(
			"INSERT INTO onboarding.account_progress (account, tutorial_done) VALUES ($1, true) "
			+ "ON CONFLICT (account) DO UPDATE SET tutorial_done = true, updated_at = now()"
		),
		[account]
	)


# ---- control-hint fire-once memory (account-level) ----------------------------


static func has_seen_hint(account: String, hint_id: String) -> bool:
	if account == "" or hint_id == "":
		return false
	if _CM._test_skip_db:
		return bool((_test_hints.get(account, {}) as Dictionary).get(hint_id, false))
	var rows: Variant = _CM.db_query(
		"SELECT 1 FROM onboarding.hint_seen WHERE account = $1 AND hint_id = $2", [account, hint_id]
	)
	return rows is Array and not (rows as Array).is_empty()


static func mark_hint_seen(account: String, hint_id: String) -> void:
	if account == "" or hint_id == "":
		return
	if _CM._test_skip_db:
		var seen: Dictionary = _test_hints.get(account, {})
		seen[hint_id] = true
		_test_hints[account] = seen
		return
	_CM.db_execute(
		(
			"INSERT INTO onboarding.hint_seen (account, hint_id) VALUES ($1, $2) "
			+ "ON CONFLICT (account, hint_id) DO NOTHING"
		),
		[account, hint_id]
	)


# Every hint id the account has already seen — the bulk read the world folds into the handshake so
# a fresh alt suppresses them all up front (no per-hint round trip at spawn).
static func seen_hints(account: String) -> Array:
	if account == "":
		return []
	if _CM._test_skip_db:
		return (_test_hints.get(account, {}) as Dictionary).keys()
	var rows: Variant = _CM.db_query(
		"SELECT hint_id FROM onboarding.hint_seen WHERE account = $1", [account]
	)
	var out: Array = []
	if rows is Array:
		for row: Dictionary in rows:
			out.append(str(row.get("hint_id", "")))
	return out


# The account onboarding bundle for the handshake: {tutorial_done, force_tutorial, hints_seen}.
# T-710: force_tutorial wires should_force_tutorial into the LIVE payload — the world reads it to
# push the first-entry tutorial offer (never for a graduated account's alts); the client uses
# tutorial_done to stop auto-driving the chain, hints_seen to suppress already-seen nags.
static func account_state(account: String) -> Dictionary:
	var done := is_tutorial_done(account)
	return {
		"tutorial_done": done,
		"force_tutorial": should_force_tutorial(done),
		"hints_seen": seen_hints(account),
	}


# The handshake bundle for a CHARACTER name — resolves the login account server-side (the combat
# payload is keyed by character name, so the master folds this in for the world at spawn).
static func account_state_for_character(character_name: String) -> Dictionary:
	return account_state(str(_CM.get_character(character_name).get("username", "")))


# T-550 master op: record a client-reported hint sighting at ACCOUNT scope. `params.username` is the
# authenticated character name; the account is resolved here server-side (never from client input),
# and the row is only ever SET — a forged report suppresses only the caller's own nag.
static func record_hint_seen(params: Dictionary) -> Dictionary:
	var hint_id := str(params.get("hint_id", ""))
	var account := str(_CM.get_character(str(params.get("username", ""))).get("username", ""))
	if account == "" or hint_id == "":
		return {"ok": false, "hint_id": hint_id}
	mark_hint_seen(account, hint_id)
	return {"ok": true, "hint_id": hint_id}


# T-563: a hydrated DB row carries boolean columns as "t"/"f" STRINGS. bool(<String>) is an
# "Invalid call. Nonexistent 'bool' constructor" crash — live-only, because the _test_skip_db
# mock path supplies real bools (which is why a green suite never caught it). Convert through this
# codebase-standard truthy reader (mirrors ops_store._db_bool / inventory_persist._is_db_true).
static func _is_db_true(v: Variant) -> bool:
	return v if v is bool else str(v).to_lower() in ["t", "true", "1"]
