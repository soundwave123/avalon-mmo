extends RefCounted

# T-716: the ONE rule set for a player-chosen character name, shared byte-identically by the
# gateway (alt creation over the login socket), the master (the in-world name step's authority) and
# the client (instant feedback while typing). Canonical copy: server/shared/character_name.gd —
# see scripts/check_shared_files_sync.sh.
#
# The charset is deliberately the SAME allowlist gateway usernames use (T-074): a character name is
# a gameplay identity that flows through jwt.gd's hand-rolled JSON and database.gd's TSV layers, so
# it may not carry quotes, tabs, newlines or non-ASCII. Uppercase is not rejected — it is folded to
# lowercase by normalize(), because the live-name uniqueness index (migration 044) is
# case-SENSITIVE and "Aldric" vs "aldric" would otherwise be two different, impersonating names.
#
# Every rejection has a PLAIN-ENGLISH sentence (plain_english) — the player never sees a machine
# reason like "invalid_name".

const PATTERN := "^[a-z0-9_-]{3,20}$"  # keep in lockstep with gateway character_roster.NAME_PATTERN
const MIN_LENGTH := 3
const MAX_LENGTH := 20


# What the player typed -> what the server stores. Trims stray whitespace and folds case (see the
# header). The FREE-TYPE entry points (the creation name field and the master op behind it) run
# this first, so a player typing "Aldric" is helped rather than scolded.
static func normalize(raw: String) -> String:
	return raw.strip_edges().to_lower()


# "" when `name` is an acceptable STORED name; otherwise a machine reason for plain_english().
# Deliberately strict — it validates exactly what would be written, so callers that want to be
# lenient about case/whitespace must normalize() first (as the name field does). The gateway's
# char-select validates raw input with this and therefore keeps rejecting "UPPER" as it always has.
# Length is checked before charset so the message names the ACTUAL problem.
static func reject_reason(name: String) -> String:
	if name.length() < MIN_LENGTH:
		return "too_short"
	if name.length() > MAX_LENGTH:
		return "too_long"
	var regex := RegEx.new()
	regex.compile(PATTERN)
	if regex.search(name) == null:
		return "bad_chars"
	return ""


static func is_valid(name: String) -> bool:
	return reject_reason(name) == ""


# The sentence shown to the player. Unknown reasons degrade to an honest "try again" rather than
# leaking a machine token or inventing a cause.
static func plain_english(reason: String) -> String:
	match reason:
		"":
			return ""
		"too_short":
			return "That name is too short — use at least %d characters." % MIN_LENGTH
		"too_long":
			return "That name is too long — %d characters at most." % MAX_LENGTH
		"bad_chars":
			return "Use only letters, numbers, - and _ (no spaces or punctuation)."
		"name_taken":
			return "Someone already goes by that name. Pick another."
		"name_chosen":
			return "Your character already has a name."
		"unknown_character":
			return "We couldn't find your character. Try again in a moment."
	return "That name couldn't be set. Try another."
