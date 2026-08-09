extends "res://addons/gut/test.gd"
# T-716: the in-world NAME step — the master half. A fresh account's bootstrap character is named
# after the ACCOUNT (ensure_character), and this is the one-shot step that lets the player replace
# that with a name they chose. Existing characters keep theirs and are never re-asked.

const CharacterManager = preload("res://scripts/character_manager.gd")


func before_each() -> void:
	CharacterManager.enable_test_mode()


func _fresh(account: String) -> int:
	CharacterManager.ensure_character(account)
	return int(CharacterManager.get_character(account).get("id", -1))


# The gap this closes: the bootstrap character IS named after the account, and it is the only
# character that still owes the step.
func test_bootstrap_character_is_account_named_and_owes_the_step() -> void:
	_fresh("steamfresh")
	var row: Dictionary = CharacterManager.get_character("steamfresh")
	assert_eq(str(row.get("name", "")), "steamfresh", "silently named after the account (the gap)")
	assert_false(bool(row.get("name_chosen", true)), "so the in-world name step is owed")
	assert_false(
		bool(CharacterManager.get_character_combat("steamfresh").get("name_chosen", true)),
		"and the client learns that from the combat payload",
	)


func test_naming_renames_the_character_and_closes_the_step() -> void:
	var cid := _fresh("steamfresh")
	var result: Dictionary = CharacterManager.set_character_name(cid, "aldric")
	assert_true(result["ok"], str(result))
	assert_eq(str(result.get("name", "")), "aldric")
	assert_eq(str(result.get("previous_name", "")), "steamfresh", "the world rebinds off this")
	# The row is now addressable by the NEW name (T-507: the character name IS the lookup key).
	var row: Dictionary = CharacterManager.get_character("aldric")
	assert_eq(int(row.get("id", -1)), cid, "same character, new identity string")
	assert_true(bool(row.get("name_chosen", false)), "the step is closed for good")
	assert_eq(CharacterManager.get_character("steamfresh"), {}, "the old name is gone")


func test_the_step_is_one_shot() -> void:
	var cid := _fresh("steamfresh")
	assert_true(CharacterManager.set_character_name(cid, "aldric")["ok"])
	var second: Dictionary = CharacterManager.set_character_name(cid, "aldric2")
	assert_false(second["ok"], "naming is permanent, like class and gender")
	assert_eq(second["reason"], "name_chosen")
	assert_eq(str(CharacterManager.get_character("aldric").get("name", "")), "aldric")


# "Existing characters keep their names": anything already named (migration 053 defaults the flag
# to true) is refused outright, so no live character can be renamed through this route.
func test_an_already_named_character_is_never_renamed() -> void:
	var cid := _fresh("steamfresh")
	CharacterManager.set_character_name(cid, "aldric")
	var attempt: Dictionary = CharacterManager.set_character_name(cid, "impostor")
	assert_false(attempt["ok"])
	assert_eq(CharacterManager.get_character("impostor"), {}, "nothing was written")


# The acceptance case the ticket names explicitly: a duplicate gets a machine reason the client
# turns into plain English, and the character keeps its old name so the player can retry.
func test_duplicate_name_is_rejected_and_the_character_is_untouched() -> void:
	var taken := _fresh("alice")
	assert_true(CharacterManager.set_character_name(taken, "aldric")["ok"])
	var mine := _fresh("bob")
	var clash: Dictionary = CharacterManager.set_character_name(mine, "aldric")
	assert_false(clash["ok"])
	assert_eq(clash["reason"], "name_taken")
	assert_eq(str(CharacterManager.get_character("bob").get("name", "")), "bob", "unchanged")
	assert_false(bool(CharacterManager.get_character("bob").get("name_chosen", true)), "retryable")


# Squatting another account's username is the gateway's _name_reserved rule — that account's own
# bootstrap character is named after it, so the name is spoken for.
func test_another_accounts_username_is_reserved() -> void:
	_fresh("alice")
	var mine := _fresh("bob")
	var squat: Dictionary = CharacterManager.set_character_name(mine, "alice")
	assert_false(squat["ok"])
	assert_eq(squat["reason"], "name_taken")


# Keeping your own account name is legal — it is what the character is called already.
func test_keeping_the_suggested_account_name_is_allowed() -> void:
	var cid := _fresh("steamfresh")
	var result: Dictionary = CharacterManager.set_character_name(cid, "steamfresh")
	assert_true(result["ok"], str(result))
	assert_true(bool(CharacterManager.get_character("steamfresh").get("name_chosen", false)))


func test_charset_and_length_are_enforced_server_side() -> void:
	var cid := _fresh("steamfresh")
	for bad in ["ab", "a".repeat(21), 'al"ric', "al ric", "al\tric"]:
		var result: Dictionary = CharacterManager.set_character_name(cid, str(bad))
		assert_false(result["ok"], "rejects %s" % bad)
		assert_ne(str(result.get("reason", "")), "", "and says why")
	assert_eq(str(CharacterManager.get_character("steamfresh").get("name", "")), "steamfresh")


func test_names_are_normalised_before_they_are_stored() -> void:
	var cid := _fresh("steamfresh")
	assert_true(CharacterManager.set_character_name(cid, "  Aldric  ")["ok"])
	assert_eq(str(CharacterManager.get_character("aldric").get("name", "")), "aldric")


func test_unknown_character_is_an_honest_failure() -> void:
	var result: Dictionary = CharacterManager.set_character_name(999999, "aldric")
	assert_false(result["ok"])
	assert_eq(result["reason"], "unknown_character")
