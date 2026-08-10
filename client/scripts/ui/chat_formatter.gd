class_name ChatFormatter
# T-361: turns a relayed chat message into a styled BBCode line, colour-coded by channel — the same
# idiom as CombatLogFormatter (T-308), kept SEPARATE from the combat log (they are distinct panels).
# Pure static utility (no scene) so the formatting is unit-testable headlessly.

extends RefCounted

# Channel accents, tuned to read against the dark-iron chat panel.
const COLOR_SAY := Color(0.87, 0.83, 0.72)  # parchment — local speech
const COLOR_PARTY := Color(0.46, 0.74, 1.0)  # blue — party voice (matches the loot/party read)
const COLOR_WORLD := Color(0.95, 0.72, 0.36)  # amber — the global channel
const COLOR_SYSTEM := Color(0.72, 0.34, 0.30)  # muted red — rejections / system notices
const COLOR_EMOTE := Color(0.80, 0.60, 0.86)  # orchid — /wave-style emote action lines (T-361)
const COLOR_GM := Color(1.0, 0.78, 0.28)  # bright herald-gold — trusted operations only
const COLOR_WHISPER := Color(0.98, 0.55, 0.78)  # pink — private 1:1, distinct from every ambient
# channel so a whisper never gets lost in the say/world noise (T-626)

const _CHANNEL_TAG := {"say": "", "party": "[Party] ", "world": "[World] "}


# Format a relayed {channel, from, text} into {msg (BBCode-safe), color}. The speaker is bolded; the
# channel tag prefixes non-local channels so a scrollback line is self-describing.
static func format(channel: String, speaker: String, text: String) -> Dictionary:
	var tag := str(_CHANNEL_TAG.get(channel, ""))
	var line := "%s%s: %s" % [tag, _escape(speaker), _escape(text)]
	return {"msg": line, "color": _channel_color(channel)}


# A system/rejection notice (rate-limited, not in a party, ...) — no speaker, muted-red.
static func format_system(text: String) -> Dictionary:
	return {"msg": _escape(text), "color": COLOR_SYSTEM}


# `gm` is a SERVER-ONLY field: chat_service never copies it from player intents, and main.gd drops
# every server-message RPC not sent by peer 1. The literal [GM] tag therefore cannot be
# player-spoofed.
static func format_gm(channel: String, text: String) -> Dictionary:
	var scope := " Whisper" if channel == "whisper" else ""
	return {
		"msg": _escape("[GM]%s: %s" % [scope, text]),
		"color": COLOR_GM,
	}


# An emote action line (T-361 item 3). The server sends the fully-resolved text ("You wave." /
# "Alice waves.") — the speaker is already baked in, so it renders as a whole line in a distinct
# orchid, no channel tag and no "speaker:" prefix.
static func format_emote(text: String) -> Dictionary:
	return {"msg": _escape(text), "color": COLOR_EMOTE}


# T-626: a private whisper. `direction` is server-labeled per recipient — "out" is the sender's
# own echo ("[To Bob]: ..."), "in" is an incoming line ("[From Alice]: ...") — so a whisper always
# reads which way it went, distinct pink so it never blends into say/world/party.
static func format_whisper(direction: String, from: String, to: String, text: String) -> Dictionary:
	var label := "To %s" % _escape(to) if direction == "out" else "From %s" % _escape(from)
	return {"msg": "[%s]: %s" % [label, _escape(text)], "color": COLOR_WHISPER}


static func _channel_color(channel: String) -> Color:
	match channel:
		"party":
			return COLOR_PARTY
		"world":
			return COLOR_WORLD
		_:
			return COLOR_SAY


# Neutralise BBCode so a player cannot inject markup (e.g. "[color=red]") into the RichTextLabel.
# T-755 promoted this idiom to the shared BBCode utility (it had been copied here and into
# pvp_panel); this wrapper keeps every call site above reading unchanged.
static func _escape(s: String) -> String:
	return BBCode.escape(s)
