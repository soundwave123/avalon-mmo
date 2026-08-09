extends "res://addons/gut/test.gd"

# T-507: multi-character accounts — MASTER-side resolution + the one-time migration contract.
#
# Covers: the 044 migration equivalence (a pre-existing single character resolves at slot 0
# with all its data intact), auto-resolution (0 chars -> bootstrap, 1 -> auto, 2+ -> select
# required), the cid-claim path the handshake rides, and the ADVERSARIAL ownership gates
# (a session can never resolve to — i.e. act as — another account's character).

const CharacterManager = preload("res://scripts/character_manager.gd")
const CharacterRoster = preload("res://scripts/character_roster.gd")
const SessionManager = preload("res://scripts/session_manager.gd")
const JwtUtilScript = preload("res://scripts/jwt.gd")

const SECRET := "this_is_a_valid_secret_key_32chars!"
const MIGRATION := "044_add_multi_character.sql"

var jwt: Object


func before_each() -> void:
	CharacterManager.reset_for_test()
	SessionManager.reset_for_test()
	SessionManager.set_test_secret(SECRET)
	jwt = JwtUtilScript.new()


# Inject an alt into the shared test store (an account's 2nd+ character; the gateway's
# create path writes the same shape into Postgres).
func _add_alt(account: String, name: String, slot: int) -> int:
	var rows: Dictionary = CharacterManager.test_characters_ref()
	var cid := 1000 + rows.size()
	rows[name] = {
		"id": cid,
		"username": account,
		"name": name,
		"slot": slot,
		"class": "warrior",
		"class_locked": false,
		"gender": "",
		"xp": 0,
		"level": 1,
	}
	return cid


# ---- auto-resolution ----


func test_fresh_account_bootstraps_slot0_character() -> void:
	var result := CharacterRoster.resolve_session_character("newbie", 0)
	assert_true(bool(result["ok"]), "fresh account must bootstrap its first character")
	assert_eq(str(result["character_name"]), "newbie", "bootstrap character is named after account")
	var roster := CharacterRoster.list_characters("newbie")
	assert_eq(roster.size(), 1, "exactly one character after bootstrap")
	assert_eq(int(roster[0]["slot"]), 0, "bootstrap character sits at slot 0")


func test_single_character_account_auto_selects() -> void:
	CharacterManager.ensure_character("solo")
	var cid := int(CharacterManager.get_character("solo")["id"])
	var result := CharacterRoster.resolve_session_character("solo", 0)
	assert_true(bool(result["ok"]), "single-character account must drop straight in")
	assert_eq(int(result["character_id"]), cid, "auto-selected the sole character")


func test_multi_character_account_requires_selection() -> void:
	CharacterManager.ensure_character("fixture_alt")
	_add_alt("fixture_alt", "shrekmage", 1)
	var result := CharacterRoster.resolve_session_character("fixture_alt", 0)
	assert_false(bool(result["ok"]), "2+ characters without a claim must not auto-resolve")
	assert_eq(str(result["reason"]), "character_select_required", "reason names the fix")


# ---- the one-time migration contract (044): slot 0, same id, data intact ----


func test_migrated_single_character_keeps_id_slot0_and_data() -> void:
	# A pre-T-507 character with real progress (xp, an item, a quest) ...
	CharacterManager.ensure_character("veteran")
	var cid := int(CharacterManager.get_character("veteran")["id"])
	CharacterManager.award_xp("veteran", 250)
	CharacterManager.add_item_to_bag(cid, "iron_sword", 1, 0)
	CharacterManager.accept_quest(cid, "q_intro")
	# ... resolves post-migration to the SAME character_id at slot 0 ...
	var result := CharacterRoster.resolve_session_character("veteran", 0)
	assert_true(bool(result["ok"]), "migrated account must resolve")
	assert_eq(int(result["character_id"]), cid, "character id survives the migration")
	assert_eq(str(result["character_name"]), "veteran", "name backfills from username")
	assert_eq(int(CharacterRoster.list_characters("veteran")[0]["slot"]), 0, "lands at slot 0")
	# ... with every character_id-keyed table untouched.
	assert_eq(int(CharacterManager.get_character("veteran")["xp"]), 250, "xp intact")
	assert_eq(CharacterManager.get_inventory(cid).size(), 1, "inventory intact")
	assert_eq(CharacterManager.get_quests(cid).size(), 1, "quest log intact")


func test_migration_file_is_numbered_044_and_non_destructive() -> void:
	var dir := ProjectSettings.globalize_path("res://").path_join("../../infra/postgres/migrations")
	var sql_file := FileAccess.open(dir.path_join(MIGRATION), FileAccess.READ)
	assert_not_null(sql_file, "migration %s must exist" % MIGRATION)
	if sql_file == null:
		return
	var sql := sql_file.get_as_text()
	assert_true(
		sql.contains("SET name = username WHERE name IS NULL"),
		"existing characters must backfill name from username"
	)
	assert_true(sql.contains("slot SMALLINT NOT NULL DEFAULT 0"), "existing rows land at slot 0")
	for destructive in ["DROP TABLE", "TRUNCATE", "DELETE FROM"]:
		assert_false(
			sql.to_upper().contains(destructive), "migration must not wipe: " + destructive
		)
	assert_false(
		FileAccess.file_exists(dir.path_join("044_add_account_mastery.sql")),
		"044 must not collide with another migration"
	)


# ---- the cid claim (handshake selection) + adversarial ownership ----


func test_cid_claim_resolves_selected_alt() -> void:
	CharacterManager.ensure_character("fixture_alt")
	var alt_cid := _add_alt("fixture_alt", "shrekmage", 1)
	var result := CharacterRoster.resolve_session_character("fixture_alt", alt_cid)
	assert_true(bool(result["ok"]), "own character claim must resolve")
	assert_eq(str(result["character_name"]), "shrekmage", "resolved to the SELECTED alt")


func test_cid_claim_for_another_accounts_character_is_rejected() -> void:
	CharacterManager.ensure_character("alice")
	var alice_cid := int(CharacterManager.get_character("alice")["id"])
	var result := CharacterRoster.resolve_session_character("mallory", alice_cid)
	assert_false(bool(result["ok"]), "cross-account character claim MUST be rejected")
	assert_eq(str(result["reason"]), "character_not_owned", "ownership failure is explicit")


func test_cid_claim_for_deleted_character_is_rejected() -> void:
	CharacterManager.ensure_character("alice")
	var cid := int(CharacterManager.get_character("alice")["id"])
	CharacterManager.test_characters_ref()["alice"]["deleted"] = true
	var result := CharacterRoster.resolve_session_character("alice", cid)
	assert_false(bool(result["ok"]), "a deleted character must not resolve")


func test_unknown_cid_claim_is_rejected() -> void:
	CharacterManager.ensure_character("alice")
	var result := CharacterRoster.resolve_session_character("alice", 99999)
	assert_false(bool(result["ok"]), "an unknown character id must be rejected")
	assert_eq(str(result["reason"]), "unknown_character", "unknown id is explicit")


# ---- validate_session carries the resolved character (the world-handshake contract) ----


func test_validate_session_returns_selected_character() -> void:
	CharacterManager.ensure_character("fixture_alt")
	var alt_cid := _add_alt("fixture_alt", "shrekmage", 1)
	var token: String = jwt.sign(
		{"sub": "fixture_alt", "cid": alt_cid, "cname": "shrekmage"}, SECRET, 3600
	)
	var result: Dictionary = CharacterRoster.validate_and_resolve(token)
	assert_true(bool(result.get("success", false)), "claimed session must validate")
	assert_eq(int(result.get("character_id", 0)), alt_cid, "handshake carries the character id")
	assert_eq(str(result.get("character_name", "")), "shrekmage", "and the character name")


func test_validate_session_rejects_forged_cross_account_claim() -> void:
	CharacterManager.ensure_character("alice")
	var alice_cid := int(CharacterManager.get_character("alice")["id"])
	# Even a correctly SIGNED token (e.g. a gateway bug) naming another account's character
	# dies at the master's re-validation — the token is never the last word on ownership.
	var token: String = jwt.sign({"sub": "mallory", "cid": alice_cid}, SECRET, 3600)
	var result: Dictionary = CharacterRoster.validate_and_resolve(token)
	assert_false(bool(result.get("success", true)), "cross-account claim MUST fail validation")
	assert_eq(str(result.get("reason", "")), "character_not_owned", "with the ownership reason")


func test_validate_session_multi_char_account_without_claim_requires_select() -> void:
	CharacterManager.ensure_character("fixture_alt")
	_add_alt("fixture_alt", "shrekmage", 1)
	var token: String = jwt.sign({"sub": "fixture_alt"}, SECRET, 3600)
	var result: Dictionary = CharacterRoster.validate_and_resolve(token)
	assert_false(bool(result.get("success", true)), "claimless multi-char session must not enter")
	assert_eq(str(result.get("reason", "")), "character_select_required", "explicit reason")
