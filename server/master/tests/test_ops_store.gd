extends GutTest

const OpsStore = preload("res://scripts/ops_store.gd")
# T-546: a fake DB that models the name->account seam. `chars.characters` maps a CHARACTER NAME
# (what a GM sees in /who) to its OWNING account username. An alt has name != username; a migrated
# main has name == username. The ban CTE resolves $2 (the typed name) against this table, disables
# the resolved account, and reports account_exists from whether the name resolved at all.
const _CHARACTERS := {
	"AltRogue": "shrek",  # alt: character name != owning account login
	"Shrek": "Shrek",  # migrated main: name == username (legacy 1:1 shape)
}

var _queries: Array = []


func before_each() -> void:
	_queries.clear()


func _query(sql: String, params: Array) -> Array:
	_queries.append([sql, params.duplicate(true)])
	if sql.contains("UPDATE auth.accounts"):
		return [{"audit_id": 9, "account_exists": true, "disabled": true}]
	if sql.contains("SELECT id"):
		return [{"id": 9, "actor": "gm", "action": "kick"}]
	return [{"audit_id": 8}]


func test_all_public_verbs_are_allowlisted_and_append_audit() -> void:
	for action in OpsStore.ACTIONS:
		var result := OpsStore.apply(
			{"actor": "gm", "action": action, "target": "", "reason": "", "details": {}}, _query
		)
		assert_true(result["ok"], action)
		assert_string_contains(_queries.back()[0], "INSERT INTO ops.audit_log")


func test_ban_disables_account_and_audits_in_one_statement() -> void:
	var result := (
		OpsStore
		. apply(
			{
				"actor": "gm",
				"action": "ban",
				"target": "Alice",
				"reason": "confirmed exploit",
				"details": {},
			},
			_query
		)
	)
	assert_true(result["ok"])
	assert_true(result["account_exists"])
	assert_string_contains(_queries[0][0], "UPDATE auth.accounts SET is_active = false")
	assert_string_contains(_queries[0][0], "UPDATE auth.sessions SET revoked = true")
	assert_string_contains(_queries[0][0], "auth.session_tokens")
	assert_string_contains(_queries[0][0], "INSERT INTO ops.audit_log")


func test_invalid_action_and_missing_actor_fail_without_database_write() -> void:
	assert_false(OpsStore.apply({"actor": "gm", "action": "grant_gold"}, _query)["ok"])
	assert_false(OpsStore.apply({"actor": "", "action": "who"}, _query)["ok"])
	assert_true(_queries.is_empty())


func test_details_param_handed_to_db_is_valid_json() -> void:
	# T-517: the details value bound to $5::jsonb must round-trip as JSON even when the
	# dict came through the world→master JSON RPC (ints arrive as floats) and the reason
	# contains spaces.
	var details: Variant = JSON.parse_string(
		JSON.stringify({"minutes": 1, "reason": "stderr capture test"})
	)
	var result := (
		OpsStore
		. apply(
			{
				"actor": "gm",
				"action": "kick",
				"target": "Alice",
				"reason": "stderr capture test",
				"details": details,
			},
			_query
		)
	)
	assert_true(result["ok"])
	var bound: Variant = _queries[0][1][4]
	assert_true(bound is String, "details is bound as a serialized string")
	var parsed: Variant = JSON.parse_string(str(bound))
	assert_true(parsed is Dictionary, "bound details must be valid JSON")
	if parsed is Dictionary:
		assert_eq(str(parsed.get("reason", "")), "stderr capture test")


func _resolving_query(sql: String, params: Array) -> Array:
	_queries.append([sql, params.duplicate(true)])
	if sql.contains("WITH resolved AS"):
		var typed_name := str(params[1])  # $2 = the character name the GM typed
		var owner: String = _CHARACTERS.get(typed_name, "")
		var resolved := owner != ""
		return [{"audit_id": 42, "account_exists": resolved, "disabled": resolved}]
	return [{"audit_id": 8}]


func _ban(target: String) -> Dictionary:
	return OpsStore.apply(
		{"actor": "gm", "action": "ban", "target": target, "reason": "grief", "details": {}},
		_resolving_query
	)


func test_ban_resolves_character_name_via_chars_characters_not_accounts() -> void:
	# The regression: the disable must key off the resolved account, and the resolution must read
	# chars.characters by NAME — never `auth.accounts WHERE username = <charname>` (T-507 hole).
	_ban("AltRogue")
	var sql: String = _queries[0][0]
	assert_string_contains(sql, "FROM chars.characters WHERE name = $2")
	assert_string_contains(sql, "username IN (SELECT username FROM resolved)")
	assert_false(
		sql.contains("auth.accounts WHERE username = $2"),
		"must not match accounts by the raw character name"
	)


func test_ban_by_alt_character_name_disables_owning_account() -> void:
	# name != username: banning the alt's character name still resolves + disables the account,
	# so every session of that account is revoked and account_exists is honestly true.
	var result := _ban("AltRogue")
	assert_true(result["ok"])
	assert_true(result["account_exists"], "the alt's character name resolved to an account")
	assert_true(result["disabled"], "the owning account was disabled")
	assert_eq(
		str(_queries[0][1][1]), "AltRogue", "audit stays keyed on the character name acted on"
	)


func test_ban_by_migrated_main_name_equals_username_still_works() -> void:
	# Regression: legacy/migrated char where name == username bans exactly as before.
	var result := _ban("Shrek")
	assert_true(result["ok"])
	assert_true(result["account_exists"])
	assert_true(result["disabled"])


func test_ban_unknown_character_name_is_honest_failure_not_false_ok() -> void:
	# The sharp bug: a name that resolves to no character must report account_exists = false
	# (real "no such player"), still write the audit row, and disable nothing.
	var result := _ban("GhostName")
	assert_true(result["ok"], "the audit write itself succeeds")
	assert_false(result["account_exists"], "unknown character name is an honest failure")
	assert_false(result["disabled"], "nothing was disabled")
	assert_string_contains(_queries[0][0], "INSERT INTO ops.audit_log")


func test_tail_is_bounded_and_returns_rows() -> void:
	var result := OpsStore.tail({"limit": 9999}, _query)
	assert_true(result["ok"])
	assert_eq(result["rows"].size(), 1)
	assert_eq(_queries[0][1], [200])
