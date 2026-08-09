# T-520 carve: the one-shot character-CREATION choices — T-065 class + T-520 gender — extracted from
# character_manager.gd, which sits AT the 1000-line gdlint cap (same reason T-360 split out
# rested_persist.gd and T-353 inventory_persist.gd). Each choice is one-shot: the value itself is
# the lock (class_locked for class; a non-empty gender for gender), so a second set is rejected and
# reroll (character-row deletion) is the only way out.
#
# Backend seam (mirrors rested_persist): character_manager passes the already-resolved character
# row, its `_test_skip_db` flag, its `_test_characters` dict (a reference — mutations persist), and
# Callable for `_execute`. This module needs no DB credentials of its own and stays unit-testable
# against the in-memory backend. It carries its own `_is_truthy` (Postgres TSV "t"/"f" strings).

extends RefCounted

# T-716: shared module — preloaded, never class_name (its copies would collide).
const CharacterName = preload("res://scripts/character_name.gd")

const _CLASSES := ["warrior", "mage", "priest"]
const _GENDERS := ["female", "male"]


static func _is_truthy(v) -> bool:
	if v is bool:
		return v
	return str(v) == "t" or str(v) == "true"


static func set_class(
	character: Dictionary,
	char_class: String,
	test_skip_db: bool,
	test_chars: Dictionary,
	exec: Callable
) -> Dictionary:
	if not char_class in _CLASSES:
		return {"ok": false, "reason": "unknown_class"}
	if character.is_empty():
		return {"ok": false, "reason": "unknown_character"}
	if _is_truthy(character.get("class_locked", false)):
		return {"ok": false, "reason": "class_locked"}
	if test_skip_db:
		character["class"] = char_class
		character["class_locked"] = true
		test_chars[str(character.get("username", ""))] = character
		return {"ok": true, "reason": "", "class": char_class}
	if not exec.call(
		"UPDATE chars.characters SET class = $1, class_locked = true WHERE id = $2",
		[char_class, int(character.get("id", -1))]
	):
		return {"ok": false, "reason": "db_error"}
	return {"ok": true, "reason": "", "class": char_class}


# T-716: the in-world NAME step (after class, before the Handbook). One-shot like class/gender, but
# its lock is an explicit column: `name` is non-null from birth (ensure_character seeds it with the
# ACCOUNT name so nothing downstream ever sees a nameless character), so the VALUE cannot be the
# lock. migration 053's name_chosen defaults TRUE — every pre-existing character and every
# gateway-created alt (the player already typed a name there) keeps its name and is never re-asked.
#
# Uniqueness is the migration-044 partial unique index on live names; the guarded UPDATE below is
# the race arbiter (a lost race updates 0 rows -> name_taken), exactly like the gateway's insert —
# which is why this one takes `query` (RETURNING rows) rather than `exec`: execute_query reports
# "the statement ran", not "a row changed", so an exec-only guard would report a stolen name as ok.
# The second NOT EXISTS is the gateway's _name_reserved rule: a name equal to ANOTHER account's
# username is reserved, because that account's bootstrap character is named after it.
# NOTE the name: `set_name` would shadow Resource.set_name (these modules are called statically
# ON the GDScript object, so the built-in setter wins and the call fails at runtime).
static func set_character_name(
	character: Dictionary,
	raw_name: String,
	test_skip_db: bool,
	test_chars: Dictionary,
	query: Callable
) -> Dictionary:
	if character.is_empty():
		return {"ok": false, "reason": "unknown_character"}
	if _is_truthy(character.get("name_chosen", false)):
		return {"ok": false, "reason": "name_chosen"}
	var name := CharacterName.normalize(raw_name)
	var reason := CharacterName.reject_reason(name)
	if reason != "":
		return {"ok": false, "reason": reason}
	var character_id := int(character.get("id", -1))
	var account := str(character.get("username", ""))
	var old_name := str(character.get("name", ""))
	if test_skip_db:
		for key: String in test_chars:
			var row: Dictionary = test_chars[key]
			var owner := str(row.get("username", ""))
			var taken := str(row.get("name", "")) == name and int(row.get("id", -2)) != character_id
			if taken or (owner == name and owner != account):
				return {"ok": false, "reason": "name_taken"}
		character["name"] = name
		character["name_chosen"] = true
		test_chars.erase(old_name)  # the in-memory store is keyed by name (get_character(name))
		test_chars[name] = character
		return {"ok": true, "reason": "", "name": name, "previous_name": old_name}
	var rows: Array = query.call(
		(
			"UPDATE chars.characters SET name = $1, name_chosen = true "
			+ "WHERE id = $2 AND name_chosen = false "
			+ "AND NOT EXISTS (SELECT 1 FROM chars.characters "
			+ "WHERE name = $1 AND deleted_at IS NULL) "
			+ "AND NOT EXISTS (SELECT 1 FROM auth.accounts "
			+ "WHERE username = $1 AND username <> $3) RETURNING id"
		),
		[name, character_id, account]
	)
	if rows.is_empty():
		return {"ok": false, "reason": "name_taken"}
	return {"ok": true, "reason": "", "name": name, "previous_name": old_name}


static func set_gender(
	character: Dictionary,
	gender: String,
	test_skip_db: bool,
	test_chars: Dictionary,
	exec: Callable
) -> Dictionary:
	if not gender in _GENDERS:
		return {"ok": false, "reason": "unknown_gender"}
	if character.is_empty():
		return {"ok": false, "reason": "unknown_character"}
	if str(character.get("gender", "")) != "":
		return {"ok": false, "reason": "gender_set"}
	if test_skip_db:
		character["gender"] = gender
		test_chars[str(character.get("username", ""))] = character
		return {"ok": true, "reason": "", "gender": gender}
	if not exec.call(
		"UPDATE chars.characters SET gender = $1 WHERE id = $2 AND gender IS NULL",
		[gender, int(character.get("id", -1))]
	):
		return {"ok": false, "reason": "db_error"}
	return {"ok": true, "reason": "", "gender": gender}
