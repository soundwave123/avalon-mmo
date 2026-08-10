extends "res://addons/gut/test.gd"

# T-507: gateway character roster — create/list/delete, the slot cap, name rules, and the
# ADVERSARIAL ownership gates (delete/select can never touch another account's character).
# Also covers the cid/cname token claims char_select stamps and refresh rotation carrying them.

const CharacterRoster = preload("res://scripts/character_roster.gd")
const Auth = preload("res://scripts/auth.gd")
const JwtUtilScript = preload("res://scripts/jwt.gd")

const SECRET := "this_is_a_valid_secret_key_32chars!"
const REFRESH_SECRET := "this_is_a_refresh_secret_32chars!!"


func before_each() -> void:
	CharacterRoster.reset_for_test()
	Auth.reset_for_test()
	Auth.set_test_secret(SECRET)
	Auth.set_test_refresh_secret(REFRESH_SECRET)


# ---- create/list ----


func test_create_and_list_orders_by_slot() -> void:
	assert_true(_b(CharacterRoster.create_character("shrek", "shrekwar")["ok"]))
	assert_true(_b(CharacterRoster.create_character("shrek", "shrekmage")["ok"]))
	var roster := CharacterRoster.list_characters("shrek")
	assert_eq(roster.size(), 2, "both characters listed")
	assert_eq(str(roster[0]["name"]), "shrekwar", "slot 0 first")
	assert_eq(_i(roster[1]["slot"]), 1, "second character takes the next free slot")


func test_created_character_has_unchosen_class_and_gender() -> void:
	var created := CharacterRoster.create_character("shrek", "shrekwar")
	var character: Dictionary = created["character"]
	assert_false(_b(character["class_locked"]), "class stays unchosen (T-065 in-world flow)")
	assert_eq(str(character["gender"]), "", "gender stays unchosen (T-520 in-world flow)")


func test_slot_cap_enforced_at_three() -> void:
	for name: String in ["alt_one", "alt_two", "alt_three"]:
		assert_true(_b(CharacterRoster.create_character("shrek", str(name))["ok"]))
	var fourth := CharacterRoster.create_character("shrek", "alt_four")
	assert_false(_b(fourth["ok"]), "a 4th character must be refused")
	assert_eq(str(fourth["reason"]), "no_free_slots", "cap failure is explicit")
	assert_eq(CharacterRoster.list_characters("shrek").size(), 3, "roster stays at the cap")


func test_deleted_slot_is_reusable() -> void:
	CharacterRoster.create_character("shrek", "alt_one")
	var second: Dictionary = CharacterRoster.create_character("shrek", "alt_two")["character"]
	CharacterRoster.create_character("shrek", "alt_three")
	CharacterRoster.delete_character("shrek", _i(second["id"]))
	var replacement := CharacterRoster.create_character("shrek", "alt_new")
	assert_true(_b(replacement["ok"]), "a freed slot admits a new character")
	assert_eq(_i(replacement["character"]["slot"]), 1, "and it reuses the freed slot")


# ---- name rules ----


func test_invalid_names_rejected() -> void:
	for bad: String in ["ab", "UPPER", "with space", 'quote"inject', "tab\there", "x".repeat(21)]:
		var result := CharacterRoster.create_character("shrek", str(bad))
		assert_false(_b(result["ok"]), "invalid name must be refused: %s" % bad)
		assert_eq(str(result["reason"]), "invalid_name")


func test_duplicate_name_rejected_across_accounts() -> void:
	CharacterRoster.create_character("shrek", "unique_hero")
	var stolen := CharacterRoster.create_character("donkey", "unique_hero")
	assert_false(_b(stolen["ok"]), "a live character name is globally unique")
	assert_eq(str(stolen["reason"]), "name_taken")


func test_other_accounts_username_is_reserved() -> void:
	CharacterRoster.set_test_reserved_account("fiona")
	var squatted := CharacterRoster.create_character("shrek", "fiona")
	assert_false(_b(squatted["ok"]), "another account's username cannot be squatted")
	assert_eq(str(squatted["reason"]), "name_taken")
	# ... but an account may name its first character after ITSELF (the bootstrap shape).
	CharacterRoster.set_test_reserved_account("shrek")
	assert_true(
		_b(CharacterRoster.create_character("shrek", "shrek")["ok"]),
		"own username stays available to its owner"
	)


# ---- adversarial ownership ----


func test_cannot_delete_another_accounts_character() -> void:
	var victim: Dictionary = CharacterRoster.create_character("alice", "heroine")["character"]
	var attack := CharacterRoster.delete_character("mallory", _i(victim["id"]))
	assert_false(_b(attack["ok"]), "cross-account delete MUST be refused")
	assert_eq(str(attack["reason"]), "not_owned")
	assert_eq(CharacterRoster.list_characters("alice").size(), 1, "victim's roster is untouched")


func test_cannot_select_another_accounts_character() -> void:
	var victim: Dictionary = CharacterRoster.create_character("alice", "heroine")["character"]
	assert_true(
		CharacterRoster.owned_character("mallory", _i(victim["id"])).is_empty(),
		"the char_select ownership gate must not yield another account's character"
	)
	assert_false(
		CharacterRoster.owned_character("alice", _i(victim["id"])).is_empty(),
		"while the real owner passes"
	)


# ---- token claims (the handshake carries the SELECTED character) ----


func test_selected_tokens_carry_cid_and_cname_claims() -> void:
	var tokens: Dictionary = Auth.issue_tokens("shrek", 42, "shrekmage")
	var jwt := JwtUtilScript.new()
	var access: Dictionary = jwt.verify(str(tokens["access_token"]), SECRET)
	assert_true(_b(access["valid"]))
	assert_eq(_i(access["payload"]["cid"]), 42, "access token carries the character id")
	assert_eq(str(access["payload"]["cname"]), "shrekmage", "and the character name")
	var refresh: Dictionary = jwt.verify(str(tokens["refresh_token"]), REFRESH_SECRET)
	assert_eq(_i(refresh["payload"]["cid"]), 42, "refresh token carries the claim too")


func test_account_tokens_have_no_character_claim() -> void:
	var tokens: Dictionary = Auth.issue_tokens("shrek")
	var jwt := JwtUtilScript.new()
	var access: Dictionary = jwt.verify(str(tokens["access_token"]), SECRET)
	var payload: Dictionary = access["payload"]
	assert_false(
		payload.has("cid"),
		"login tokens stay account-scoped (master auto-resolves 0/1-char accounts)"
	)


func test_refresh_rotation_preserves_character_claim() -> void:
	var tokens: Dictionary = Auth.issue_tokens("shrek", 42, "shrekmage")
	var rotated: Dictionary = Auth.rotate_refresh_token(str(tokens["refresh_token"]))
	assert_true(_b(rotated.get("success", false)), "rotation must succeed")
	var jwt := JwtUtilScript.new()
	var access: Dictionary = jwt.verify(str(rotated["access_token"]), SECRET)
	assert_eq(_i(access["payload"]["cid"]), 42, "the selection survives token rotation")
	assert_eq(str(access["payload"]["cname"]), "shrekmage")


# T-757: typed pass-throughs. bool()/int() constructor calls and GUT's untyped assert
# parameters both flag hard-Variant arguments under the unsafe_call_argument=2 gate;
# a typed assignment through an explicit Variant parameter is the warning-clean
# equivalent (and now also asserts the value's runtime type).
static func _b(v: Variant) -> bool:
	var typed: bool = v
	return typed


static func _i(v: Variant) -> int:
	var typed: int = v
	return typed
