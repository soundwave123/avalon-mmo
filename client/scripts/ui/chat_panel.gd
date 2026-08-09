class_name ChatPanel
# T-361 / T-396: the player chat window. T-361 built a framed, bordered box; T-396 rebuilt the
# PRESENTATION to the modern-MMORPG reference model (WoW/FFXIV/GW2): no opaque box, legibility from
# outlined+shadowed TEXT, an inactivity fade, a focus opacity ramp, a typing-summoned input row, and
# a click-through idle state so it never eats a world click while you inspect the world. The T-361
# routing / focus discipline (is_typing gate) and the intent wire format are UNCHANGED — this is a
# presentation pass only. Fade/focus math lives in the pure ChatPresence state machine.
#
# Input focus discipline (the Esc-gate precedent): Enter opens/focuses the input; while it holds
# focus main.gd must NOT run WASD/hotkeys — main gates on is_typing(). Submitting sends + releases
# focus; Esc while typing cancels without sending (the global Esc menu still works when not typing).

extends Control

const MAX_LINES := 200
const _MAINTENANCE_BANNER = preload("res://scripts/ui/maintenance_banner.gd")
# T-396: the WORLD tab ships — the global channel already exists server-side (chat_router +
# chat_service, hard-capped by the rate limiter). It routes like say/party/guild: channel "world".
const CHANNELS := ["say", "party", "guild", "world", "help"]

var _rtl: RichTextLabel = null
var _input_box: LineEdit = null
var _bg: TextureRect = null
var _tab_row: HBoxContainer = null
var _tabs: Dictionary = {}  # channel -> Button
var _lines: Array[String] = []
var _channel := "say"
var _send_fn: Callable = Callable()
var _presence := ChatPresence.new()
var _hover_count := 0
var _maintenance_banner = null
var _disconnect_state: Dictionary = {}
# T-626: the last whisper PARTNER — set on /w|/tell (outgoing) and on an incoming whisper's sender,
# so /r replies without retyping a name. "" until the first whisper of either direction happens.
var _last_whisper_target := ""
# T-607: index of the most recently appended combat-log line in `_lines`, so a T-556 coalesced
# repeat can rewrite it in place. -1 means "no combat line appended yet, or it's no longer safe to
# rewrite" (a chat/system line landed after it, so the physically-last line is no longer ours).
var _last_combat_line_idx: int = -1


func _ready() -> void:
	set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	offset_left = 20.0
	offset_right = 480.0
	# T-400 judge follow-up: the vitals frame owns the bottom-left band (offsets -170..-100);
	# chat sits ABOVE it so awake chat lines never render across the HP bar.
	offset_top = -360.0
	offset_bottom = -185.0
	mouse_filter = Control.MOUSE_FILTER_IGNORE  # idle: never eat a world click (restored on focus)

	# Subtle bottom-weighted dark gradient — NOT a box. Its own alpha is driven by the focus ramp; the
	# whole area's alpha is driven by the inactivity fade (both via _apply_presence).
	_bg = TextureRect.new()
	_bg.name = "ChatGradient"
	_bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE  # purely decorative
	_bg.texture = _build_gradient()
	_bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_bg.stretch_mode = TextureRect.STRETCH_SCALE
	add_child(_bg)

	var col := VBoxContainer.new()
	col.set_anchors_preset(Control.PRESET_FULL_RECT)
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(col)
	col.add_child(_build_tabs())

	_rtl = RichTextLabel.new()
	_rtl.name = "ChatHistory"
	_rtl.bbcode_enabled = true
	_rtl.scroll_following = true
	_rtl.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_rtl.mouse_filter = Control.MOUSE_FILTER_IGNORE  # idle click-through; STOP while interactive
	# Legibility from the TEXT, not a box: a dark outline + soft drop shadow so lines read over bright
	# sky/snow/grass with no panel behind them (set explicitly so it never depends on theme wiring).
	_rtl.add_theme_color_override("default_color", UiTheme.PARCHMENT)
	_rtl.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	_rtl.add_theme_constant_override("outline_size", 4)
	_rtl.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.7))
	_rtl.add_theme_constant_override("shadow_offset_x", 1)
	_rtl.add_theme_constant_override("shadow_offset_y", 1)
	_rtl.mouse_entered.connect(_on_part_entered)
	_rtl.mouse_exited.connect(_on_part_exited)
	col.add_child(_rtl)

	# The input row only EXISTS while typing (hidden otherwise — no permanently-drawn box).
	_input_box = LineEdit.new()
	_input_box.name = "ChatInput"
	_input_box.placeholder_text = "Press Enter to chat"
	_input_box.visible = false
	_input_box.text_submitted.connect(_on_submit)
	_input_box.focus_entered.connect(_on_input_focus_entered)
	_input_box.focus_exited.connect(_on_input_focus_exited)
	col.add_child(_input_box)

	_render()
	_apply_presence()


func setup(send_fn: Callable) -> void:
	"""send_fn(intent: Dictionary) — the transport hook (main._send_to_server). The panel builds the
	intent itself: a `chat` on the active tab, or an `emote` when the line is a /slash command."""
	_send_fn = send_fn
	if _maintenance_banner == null:
		_maintenance_banner = _MAINTENANCE_BANNER.new()
		var parent := get_parent()
		var host: Node = parent if parent is CanvasLayer or parent is Control else self
		host.add_child(_maintenance_banner)


# A 1x256 transparent-top → black-bottom gradient. Scaled to fill; the bottom-weighting keeps the
# text region readable while the top stays clear of the world.
func _build_gradient() -> GradientTexture2D:
	var grad := Gradient.new()
	grad.offsets = PackedFloat32Array([0.0, 0.55, 1.0])
	grad.colors = PackedColorArray([Color(0, 0, 0, 0.0), Color(0, 0, 0, 0.35), Color(0, 0, 0, 1.0)])
	var tex := GradientTexture2D.new()
	tex.gradient = grad
	tex.width = 1
	tex.height = 256
	tex.fill_from = Vector2(0, 0)
	tex.fill_to = Vector2(0, 1)
	return tex


func _build_tabs() -> HBoxContainer:
	var row := HBoxContainer.new()
	row.name = "ChatTabs"
	row.mouse_filter = Control.MOUSE_FILTER_STOP  # the always-hoverable strip that wakes the panel
	row.mouse_entered.connect(_on_part_entered)
	row.mouse_exited.connect(_on_part_exited)
	for ch in CHANNELS:
		var b := Button.new()
		b.text = ch.capitalize()
		b.toggle_mode = true
		b.focus_mode = Control.FOCUS_NONE  # tabs never steal keyboard focus from movement
		b.pressed.connect(_select_channel.bind(ch))
		row.add_child(b)
		_tabs[ch] = b
	_tab_row = row
	_reflect_channel()
	return row


func _select_channel(channel: String) -> void:
	_channel = channel
	_reflect_channel()


# Small + translucent tabs; only the ACTIVE tab is visually loud (T-396).
func _reflect_channel() -> void:
	for ch in _tabs:
		var b := _tabs[ch] as Button
		var active: bool = ch == _channel
		b.button_pressed = active
		var sb := UiTheme.chat_tab_stylebox(active)
		b.add_theme_stylebox_override("normal", sb)
		b.add_theme_stylebox_override("pressed", UiTheme.chat_tab_stylebox(true))
		b.add_theme_stylebox_override("hover", UiTheme.chat_tab_stylebox(active))
		b.add_theme_color_override(
			"font_color", UiTheme.GOLD_BRIGHT if active else UiTheme.PARCHMENT_DIM
		)


# True while the input box holds keyboard focus — main.gd suppresses hotkeys/WASD on this.
func is_typing() -> bool:
	return _input_box != null and _input_box.has_focus()


func _input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.is_pressed() or event.is_echo():
		return
	var key := event as InputEventKey
	if key.keycode == KEY_ENTER and not is_typing():
		if UiInputGate.is_text_input_focused(get_viewport()):
			return
		_input_box.visible = true  # summon the input row, then focus it
		_input_box.grab_focus()
		get_viewport().set_input_as_handled()
	elif key.keycode == KEY_ESCAPE and is_typing():
		_input_box.clear()
		_input_box.release_focus()  # cancel typing without sending; global Esc menu stays gated
		get_viewport().set_input_as_handled()


func _on_submit(text: String) -> void:
	var trimmed := text.strip_edges()
	if not trimmed.is_empty() and _send_fn.is_valid():
		_send_fn.call(_intent_for(trimmed))
	_input_box.clear()
	_input_box.release_focus()  # WoW behaviour: sending returns control to movement


# A "/wave"-style line is an emote intent (the first word after "/" is the id; the server validates
# it against the data-driven catalog and rejects an unknown one). Anything else is chat on the
# active tab. Only the DESIRE goes on the wire — the server resolves the actor identity, never us.
func _intent_for(line: String) -> Dictionary:
	if line.begins_with("/") and line.length() > 1:
		var parts := line.substr(1).strip_edges().split(" ", false)
		var id := parts[0].to_lower()
		if id == "help" and parts.size() > 1:
			var choice := parts[1].to_lower()
			if choice in ["on", "join", "off", "leave"]:
				return {"type": "help_subscription", "subscribed": choice in ["on", "join"]}
		if id == "duel":  # T-381: consensual-duel commands ride the social hub (server-authoritative)
			return _duel_intent(parts)
		if id == "party":  # T-598: mirrors /duel accept|decline for the invite prompt below
			return _party_intent(parts)
		if id in ["w", "whisper", "tell", "r", "reply"]:  # T-626: whisper + reply-to-last-whisper
			return _whisper_or_reply_intent(id, parts)
		return {"type": "emote", "id": id}
	return {"type": "chat", "channel": _channel, "text": line}


# T-598: "/party accept" or "/party decline" — the reply to the PartyInvitePrompt system line. Any
# other/missing argument falls back to an emote id (unrecognised ids are server-rejected, same as
# any other bad /slash command) rather than silently no-op'ing.
func _party_intent(parts: PackedStringArray) -> Dictionary:
	var arg := parts[1].to_lower() if parts.size() > 1 else ""
	match arg:
		"accept":
			return {"type": "party_accept"}
		"decline":
			return {"type": "party_decline"}
		_:
			return {"type": "emote", "id": "party"}


# T-381: "/duel accept|decline|cancel" or "/duel <name>". Only the DESIRE goes on the wire — the
# server resolves the actor from the session and the target by name (proximity + liveness gated).
func _duel_intent(parts: PackedStringArray) -> Dictionary:
	var arg := parts[1].to_lower() if parts.size() > 1 else ""
	match arg:
		"accept":
			return {"type": "duel_accept"}
		"decline":
			return {"type": "duel_decline"}
		"cancel":
			return {"type": "duel_cancel"}
		_:
			return {"type": "duel_request", "target": parts[1] if parts.size() > 1 else ""}


# T-626: "/w|/tell <name> <message>" — a private 1:1 — or "/r|/reply <message>" — reply to whoever
# you last whispered OR who last whispered you (classic MMO convenience; targets "" until any
# whisper of either direction has happened, and the server then honestly rejects with
# "unknown_player" rather than silence). Only the DESIRE (target name + body) goes on the wire; the
# server resolves the sender's identity from the session and the target from the online snapshot.
# A bare "/w" or "/w <name>" with no body sends an empty text, which the server drops the same way
# any blank chat line is dropped on every other channel — no special-case needed here.
func _whisper_or_reply_intent(id: String, parts: PackedStringArray) -> Dictionary:
	if id == "r" or id == "reply":
		var body := " ".join(parts.slice(1)) if parts.size() > 1 else ""
		return {"type": "chat", "channel": "whisper", "target": _last_whisper_target, "text": body}
	var target := parts[1] if parts.size() > 1 else ""
	var body := " ".join(parts.slice(2)) if parts.size() > 2 else ""
	if not target.is_empty():
		_last_whisper_target = target  # so a follow-up /r replies to the same person
	return {"type": "chat", "channel": "whisper", "target": target, "text": body}


# Handle a server → client message: a relayed {channel, from, text} or a {chat_rejected, reason}.
func receive(data: Dictionary) -> void:
	var kind := str(data.get("type", ""))
	if kind in ["maintenance", "kicked"] or bool(data.get("gm", false)):
		_receive_trusted(data, kind)
		return
	if kind == "chat_rejected":
		_append(ChatFormatter.format_system("(%s)" % str(data.get("reason", "blocked"))))
		return
	if kind == "help_subscription":
		var state := "joined" if bool(data.get("subscribed", false)) else "left"
		_append(ChatFormatter.format_system("Help channel %s." % state))
		return
	if kind == "emote":  # T-361 item 3: server-resolved action line ("You wave." / "Alice waves.")
		_append(ChatFormatter.format_emote(str(data.get("text", ""))))
		return
	if str(data.get("channel", "")) == "system":  # T-381: duel offer/result system notice
		_append(ChatFormatter.format_system(str(data.get("text", ""))))
		return
	if str(data.get("channel", "")) == "whisper":  # T-626: server-labeled "in"/"out" per recipient
		var direction := str(data.get("direction", "in"))
		if direction == "in":
			_last_whisper_target = str(data.get("from", ""))  # so /r targets whoever whispered you
		_append(
			ChatFormatter.format_whisper(
				direction,
				str(data.get("from", "?")),
				str(data.get("to", "?")),
				str(data.get("text", ""))
			)
		)
		return
	var speaker := str(data.get("from", "?"))
	if str(data.get("channel", "")) == "help" and bool(data.get("mentor", false)):
		speaker = "[Mentor] %s" % speaker
	_append(
		ChatFormatter.format(str(data.get("channel", "say")), speaker, str(data.get("text", "")))
	)


func _receive_trusted(data: Dictionary, kind: String) -> void:
	match kind:
		"maintenance":
			_disconnect_state = {"kind": "maintenance", "reason": str(data.get("reason", ""))}
			_maintenance_banner.display(data)
			_append(ChatFormatter.format_system(str(data.get("text", "Server maintenance"))))
		"kicked":
			_disconnect_state = {
				"kind": "ban" if bool(data.get("banned", false)) else "kick",
				"reason": str(data.get("reason", "")),
			}
			_append(ChatFormatter.format_gm("system", str(data.get("reason", "Disconnected"))))
		_:
			_append(
				ChatFormatter.format_gm(
					str(data.get("channel", "system")), str(data.get("text", ""))
				)
			)


func _append(entry: Dictionary) -> void:
	var hex: String = (entry["color"] as Color).to_html(false)
	_lines.append("[color=#%s]%s[/color]" % [hex, str(entry["msg"])])
	while _lines.size() > MAX_LINES:
		_lines.pop_front()
	_render()
	_presence.notify_line()  # a new line resets the inactivity fade and snaps the panel visible
	_apply_presence()


# --- T-607: combat log merge -----------------------------------------------
# CombatLogPanel used to be a second, independently-faded RichTextLabel overlapping this one's
# rect (the stale T-027 "merge later" note). Routing CombatLog entries through this SAME
# `_lines`/`_append()` path — as an always-visible pseudo-channel, regardless of the active tab —
# closes that risk: one surface, one ChatPresence, one fade/wake timer. T-402's out-of-range
# throttle lives upstream in combat_feedback.gd and is untouched; it still gates how often an
# entry reaches `CombatLog.add_entry()` in the first place.
func bind_combat_log(combat_log: CombatLog) -> void:
	combat_log.entry_added.connect(_on_combat_entry_added)
	combat_log.entry_updated.connect(_on_combat_entry_updated)  # T-556: coalesced repeat


func _on_combat_entry_added(msg: String, color: Color) -> void:
	_append({"msg": msg, "color": color})
	_last_combat_line_idx = _lines.size() - 1


# T-556: a coalesced repeat (e.g. six "Out of range" presses) rewrites the newest combat line's
# "(xN)" count in place instead of spamming a fresh line — but only while it is STILL the
# physically-last line in the merged history. If a chat/system line landed in between, rewriting
# the older index would silently clobber someone's chat message, so fall back to a normal append.
func _on_combat_entry_updated(msg: String, color: Color) -> void:
	if _last_combat_line_idx < 0 or _last_combat_line_idx != _lines.size() - 1:
		_on_combat_entry_added(msg, color)
		return
	var hex: String = color.to_html(false)
	_lines[_last_combat_line_idx] = "[color=#%s]%s[/color]" % [hex, msg]
	_render()
	_presence.notify_line()
	_apply_presence()


func _render() -> void:
	if _rtl != null:
		_rtl.text = "\n".join(_lines)


# --- presence (inactivity fade + focus ramp + click-through) --------------
func _process(delta: float) -> void:
	_presence.tick(delta)
	_apply_presence()


func _on_input_focus_entered() -> void:
	_input_box.placeholder_text = "Type a message..."
	_presence.set_focus(true)
	_apply_presence()


func _on_input_focus_exited() -> void:
	_presence.set_focus(false)
	_input_box.placeholder_text = "Press Enter to chat"
	_input_box.visible = false  # the input row exists only while typing
	_apply_presence()


func _on_part_entered() -> void:
	_hover_count += 1
	_presence.set_hover(true)
	_apply_presence()


func _on_part_exited() -> void:
	_hover_count = maxi(_hover_count - 1, 0)
	_presence.set_hover(_hover_count > 0)
	_apply_presence()


# Push the presence state onto the nodes: whole-area alpha (inactivity fade), backdrop alpha (focus
# ramp), and mouse filtering (click-through when idle, interactive when focused/hovered).
func _apply_presence() -> void:
	modulate.a = _presence.area_alpha
	if _bg != null:
		_bg.modulate.a = _presence.bg_alpha
	var interactive := _presence.is_interactive()
	var mf := Control.MOUSE_FILTER_STOP if interactive else Control.MOUSE_FILTER_IGNORE
	mouse_filter = mf
	if _rtl != null:
		_rtl.mouse_filter = mf
	# T-645: tabs only clickable when chat is interactive (focused/hovered), like the history.
	if _tab_row != null:
		_tab_row.mouse_filter = mf


func line_count() -> int:
	return _lines.size()


func get_text() -> String:
	return "\n".join(_lines)


# --- test seams (headless; no display) ------------------------------------
func input_visible() -> bool:
	return _input_box != null and _input_box.visible


func history_mouse_filter() -> int:
	return _rtl.mouse_filter if _rtl != null else Control.MOUSE_FILTER_IGNORE


func presence() -> ChatPresence:
	return _presence


func maintenance_active() -> bool:
	return _maintenance_banner != null and _maintenance_banner.is_active()


func maintenance_banner_text() -> String:
	return _maintenance_banner.banner_text() if _maintenance_banner != null else ""


func disconnect_notice() -> Dictionary:
	return _disconnect_state.duplicate()


func _exit_tree() -> void:
	if _maintenance_banner != null and _maintenance_banner.get_parent() != self:
		_maintenance_banner.queue_free()
