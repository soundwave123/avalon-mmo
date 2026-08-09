# T-361: pure text-hygiene for chat — a length cap plus a data-driven profanity mask. No network,
# no external moderation service (the ticket calls for a data-file hook stub only); the word list is
# loaded from res://data/chat/profanity.json and passed in, so the masking itself stays a pure,
# unit-testable function of (text, word_set).

extends RefCounted

# WoW's /say cap is ~255; we clamp to 256 and truncate (not reject) so a long line still lands.
const MAX_LEN := 256


# Load the profanity word list (lowercased) from a JSON array file. Returns {} (empty set, i.e. a
# Dictionary used as a set: word -> true) when the file is missing/malformed — masking then no-ops.
static func load_word_set(path: String) -> Dictionary:
	var out: Dictionary = {}
	if not FileAccess.file_exists(path):
		return out
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return out
	var parsed = JSON.parse_string(f.get_as_text())
	f.close()
	if not (parsed is Array):
		return out
	for w in parsed:
		out[str(w).to_lower()] = true
	return out


# Clamp then trim. Empty/whitespace-only input returns "" so the caller can drop it.
static func sanitize(text: String) -> String:
	var t := text.strip_edges()
	if t.length() > MAX_LEN:
		t = t.substr(0, MAX_LEN)
	return t


# True when the sanitized text carries at least one visible character.
static func is_valid(text: String) -> bool:
	return not sanitize(text).is_empty()


# Mask whole-word profanity (case-insensitive) with same-length asterisks. Punctuation-delimited
# tokens are matched on their alnum core so "damn!" masks to "****!". word_set is word -> true.
static func mask(text: String, word_set: Dictionary) -> String:
	if word_set.is_empty():
		return text
	var out := ""
	var token := ""
	for i in text.length() + 1:
		var ch := text[i] if i < text.length() else " "
		if _is_word_char(ch):
			token += ch
			continue
		if not token.is_empty():
			out += _mask_token(token, word_set)
			token = ""
		if i < text.length():
			out += ch
	return out


static func _mask_token(token: String, word_set: Dictionary) -> String:
	if word_set.has(token.to_lower()):
		return "*".repeat(token.length())
	return token


static func _is_word_char(ch: String) -> bool:
	return ch.to_lower() != ch.to_upper() or (ch >= "0" and ch <= "9")
