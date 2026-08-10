class_name GuildLogic
extends RefCounted

# T-362: the PURE rank/permission brain for guilds (mirrors lfg_logic/auction_logic purity — no I/O,
# no state, no OS time). GuildStore owns durable membership; every "may this actor do X to Y?"
# decision routes through here so the permission MATRIX is unit-testable headlessly and the store
# stays a thin persistence layer.
#
# Ranks are ordered by AUTHORITY, lowest number = highest power:
#   0 Leader  — full control: invite, kick anyone below, promote/demote, disband.
#   1 Officer — invite, kick members (strictly-lower rank only).
#   2 Member  — guild chat + roster; no management verbs.

const RANK_LEADER := 0
const RANK_OFFICER := 1
const RANK_MEMBER := 2

const RANK_NAMES := {0: "Leader", 1: "Officer", 2: "Member"}

# Guild-name shape: 3..24 chars, letters/digits/spaces, no leading/trailing space. A name sink and a
# uniqueness key — validated here so both the store and any future rename path agree on the rule.
const NAME_MIN := 3
const NAME_MAX := 24
const RECRUITMENT_BLURB_MAX := 160

# T-683 guild bank: per-withdrawal coin cap by rank. Deposit is open to any member; WITHDRAW is
# gated to Officer+ (the shared-wallet trust boundary). The Leader draws without limit (-1); an
# Officer is capped per withdrawal so a single officer can't drain the vault in one op; a plain
# Member cannot withdraw at all (0, and the rank gate rejects them before a cap ever applies).
const BANK_WITHDRAW_CAP := {0: -1, 1: 5000, 2: 0}  # copper; -1 = unlimited


static func is_rank(rank: int) -> bool:
	return RANK_NAMES.has(rank)


static func rank_name(rank: int) -> String:
	return str(RANK_NAMES.get(rank, "Member"))


static func valid_name(name: String) -> bool:
	if name.strip_edges() != name:
		return false  # no leading/trailing whitespace
	if name.length() < NAME_MIN or name.length() > NAME_MAX:
		return false
	for ch in name:
		var ok := (
			(ch >= "a" and ch <= "z")
			or (ch >= "A" and ch <= "Z")
			or (ch >= "0" and ch <= "9")
			or ch == " "
		)
		if not ok:
			return false
	return true


# T-755: true when `text` carries a BBCode tag delimiter. The client escapes markup before it
# reaches a RichTextLabel and THAT is the real fix — a server can never know what every present and
# future client will do with a string. This is the defence-in-depth half: the master should not
# accept a stored attack payload in the first place, so that a client which someday forgets the
# escape is not handed live ammunition out of the database.
#
# Brackets are the whole vocabulary of a BBCode tag — no "[" means no tag, whatever the tag name
# would have been — so this needs no list of tag names to keep in sync with Godot's parser. "]" is
# rejected too: harmless alone, but it can close a tag opened by an adjacent field.
static func has_markup(text: String) -> bool:
	return text.contains("[") or text.contains("]")


# Public listing copy is deliberately short and single-line. Empty is valid because the open flag
# carries the actual consent to be listed; a guild can recruit without writing marketing copy.
#
# T-755: this was the one free-text field with NO charset rule (guild NAMES were always an
# alphanumeric allowlist, and character names go through character_name.gd), which made the blurb
# the live vector for the guild-panel injection. Rejecting rather than stripping is deliberate
# here: _set_recruitment already has a "bad_blurb" reply path, so the player is TOLD their copy was
# refused instead of silently publishing something they did not write.
static func valid_recruitment_blurb(blurb: String) -> bool:
	if blurb.length() > RECRUITMENT_BLURB_MAX:
		return false
	if has_markup(blurb):
		return false
	return not blurb.contains("\n") and not blurb.contains("\r")


# ---- permission matrix (the only place authority is decided) --------------------


static func can_invite(actor_rank: int) -> bool:
	return actor_rank <= RANK_OFFICER


# A kicker must have invite-tier authority AND strictly outrank the target (an officer cannot kick a
# peer officer or the leader; the leader can kick anyone below).
static func can_kick(actor_rank: int, target_rank: int) -> bool:
	return actor_rank <= RANK_OFFICER and actor_rank < target_rank


static func can_promote(actor_rank: int) -> bool:
	return actor_rank == RANK_LEADER


static func can_disband(actor_rank: int) -> bool:
	return actor_rank == RANK_LEADER


# T-683: guild-bank authority. Deposit is a member-wide right (anyone in the guild can pool coin/
# items); withdraw is an Officer+ trust gate (the same authority tier that can invite/manage).
static func can_deposit_bank(actor_rank: int) -> bool:
	return is_rank(actor_rank)


static func can_withdraw_bank(actor_rank: int) -> bool:
	return actor_rank <= RANK_OFFICER


# Per-withdrawal coin cap for a rank: -1 unlimited (Leader), a positive ceiling (Officer), or 0
# (Member — never reached, can_withdraw_bank rejects first). Pure lookup so the store stays thin.
static func bank_withdraw_cap(actor_rank: int) -> int:
	return int(BANK_WITHDRAW_CAP.get(actor_rank, 0))


# Promote one step UP, but never into the Leader seat (leadership transfer is a separate verb, out
# of T-362 scope). Member(2) -> Officer(1); Officer(1) stays Officer.
static func promoted_rank(rank: int) -> int:
	return max(RANK_OFFICER, rank - 1)


# Demote one step DOWN. Officer(1) -> Member(2); Member(2) stays Member; Leader is never demoted.
static func demoted_rank(rank: int) -> int:
	return min(RANK_MEMBER, rank + 1)
