class_name BBCode
# T-755: the ONE place client UI neutralises player-controlled text before it reaches a
# `bbcode_enabled` RichTextLabel. Pure static utility (no scene, no state) so it is unit-testable
# headlessly, mirroring the ChatFormatter/CombatLogFormatter idiom.
#
# WHY THIS EXISTS. A RichTextLabel with bbcode_enabled parses its `text` as markup. Any string a
# player typed — a guild name, a recruitment blurb, an LFG note, a character name — is an
# ATTACKER-AUTHORED string as far as that parser is concerned. Two distinct harms, and they need
# two distinct escapes:
#
#   1. Painted markup. "[color=red]" or "[b]" lets one player restyle another player's window;
#      worse, an unclosed tag makes the label swallow every character after it to the end of the
#      string, so a crafted note can ERASE the roster lines rendered below it.
#   2. Forged intent links. GuildPanel/SocialPanel/LfgPanel/TradePanel each wire meta_clicked to
#      real intents (guild_kick / guild_promote / guild_demote / party_invite / unfriend). A
#      crafted "[url=kick|victim]" painted by a hostile note renders as a clickable link that
#      fires a privileged-looking intent when ANOTHER player clicks it. The server re-validates
#      authority on every verb, so this cannot grant power the clicker lacks — but a leader who
#      clicks an attacker's fake "[x]" really does kick the named member, which is a social-
#      engineering hole, not a cosmetic one.
#
# Godot's own escape for a literal open bracket is the "[lb]" tag, so escape() is loss-free: the
# label displays exactly the characters the player typed, as INERT text.

extends RefCounted


# Neutralise DISPLAY text. "[" is the only character that can open a BBCode tag, so replacing it
# with the "[lb]" (left-bracket) entity is sufficient and complete — a lone "]" is already inert.
# Use this at EVERY interpolation of player-controlled text into a bbcode_enabled label.
static func escape(s: String) -> String:
	return s.replace("[", "[lb]")


# Neutralise text used as a `[url=...]` META PAYLOAD (the value _on_meta later parses).
#
# escape() is wrong here: the "[lb]" entity is a DISPLAY escape, and inside a tag's attribute it
# would be stored literally into the meta rather than rendered. What matters in an attribute is
# that the value cannot terminate the tag early or forge extra arguments, so brackets are DROPPED
# outright. "|" is the panels' own argument separator (str(meta).split("|")); a value carrying one
# would shift the argument positions _on_meta reads, so it goes too.
#
# Dropping rather than escaping is safe because every payload today is an identity the server
# re-resolves (a character name), and character_name.gd restricts those to [a-z0-9_-] — so for
# well-formed data this function is the identity. It is the guard for the day that rule loosens.
static func escape_meta(s: String) -> String:
	return s.replace("[", "").replace("]", "").replace("|", "")
