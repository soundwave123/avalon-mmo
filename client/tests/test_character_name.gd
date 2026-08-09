extends "res://addons/gut/test.gd"

const CharacterName = preload("res://scripts/ui/character_name.gd")
# T-716: CharacterName — the shared name rule set. This copy lives in the CLIENT project; the
# gateway and master carry byte-identical copies (scripts/check_shared_files_sync.sh), so a name
# accepted while typing is the same name the server accepts.


func test_a_plain_name_is_valid() -> void:
	assert_true(CharacterName.is_valid("aldric"))
	assert_eq(CharacterName.reject_reason("aldric"), "")


# reject_reason validates what would be STORED, so the free-type field normalises first and the
# player who types "Aldric" is helped, not scolded. Raw validation stays strict, which is what the
# gateway's char-select relies on.
func test_capitals_and_padding_are_normalised_before_validation() -> void:
	assert_eq(CharacterName.normalize("  Aldric  "), "aldric")
	assert_true(CharacterName.is_valid(CharacterName.normalize("Aldric")))
	assert_eq(CharacterName.reject_reason("Aldric"), "bad_chars", "raw validation stays strict")


func test_length_bounds() -> void:
	assert_eq(CharacterName.reject_reason("ab"), "too_short")
	assert_eq(CharacterName.reject_reason("a".repeat(21)), "too_long")
	assert_true(CharacterName.is_valid("a".repeat(CharacterName.MIN_LENGTH)))
	assert_true(CharacterName.is_valid("a".repeat(CharacterName.MAX_LENGTH)))


# The charset is the wire-safety rule, not a style choice: names ride jwt.gd's hand-rolled JSON and
# database.gd's TSV layers, so quotes/tabs/newlines/non-ASCII must never get in.
func test_wire_hostile_characters_are_rejected() -> void:
	for bad in ['al"ric', "al\tric", "al\nric", "al ric", "aldriç", "al;ric", "al/ric"]:
		assert_eq(CharacterName.reject_reason(bad), "bad_chars", "rejects %s" % bad)


func test_every_reason_has_a_plain_english_sentence() -> void:
	for reason in ["too_short", "too_long", "bad_chars", "name_taken", "name_chosen"]:
		var text := CharacterName.plain_english(reason)
		assert_ne(text, "", "%s must read as English" % reason)
		assert_false(text.contains(reason), "%s must not leak the machine token" % reason)
	assert_eq(CharacterName.plain_english(""), "", "no error, no sentence")
	assert_ne(
		CharacterName.plain_english("some_new_server_reason"), "", "unknowns still say something"
	)
