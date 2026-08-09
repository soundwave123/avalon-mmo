class_name PvpPanel
extends Control

# T-401: the PvP panel (toggle P, chat-focus-gated like O/G/Y). Makes the whole server-complete PvP
# stack (T-390 ratings/seasons, T-391 honor/reward-tracks/titles) visible for the first time: your
# rating + tier, the season leaderboard top-N, your honor balance, and the reward tracks with their
# PUBLISHED costs (data/pvp_rewards.json — the honest-economy guardrail: the player sees the exact
# price before spending) plus activate / spend / wear-title actions. It sends INTENTS only — every
# number it shows came from a server reply, and the server re-validates every action.
#
# Shape mirrors inventory_panel's CURRENT (post-fix) window idiom EXACTLY (the a32d538 + T-400 4.7
# lessons): a SolidWindow PanelContainer with a self-carried theme, EXPLICIT anchor assignment after
# add_child (never set_anchors_preset — the preset call itself collapses containers on 4.7), and a
# plain RichTextLabel filling the frame (no ScrollContainer — that zero-sizes the RTL). Replies land
# via ReplyRouter (main.gd registers no per-type handler); the panel self-registers what it needs.

signal action_selected(meta: String)  # test/introspection hook mirroring inventory_panel

var _send_fn: Callable = Callable()
var _is_typing_fn: Callable = Callable()  # chat focus gate — P must not fire while typing
var _rtl: RichTextLabel = null

var _rating: Dictionary = {}  # last pvp_rating reply
var _board: Array = []  # last pvp_leaderboard entries
var _tracks: Array = []  # last pvp_tracks browse: [{id, name, tiers, tier}]
var _honor: int = 0
var _active: String = ""  # active reward track id
var _notice: String = ""  # last pvp_result reason line (title set / rejected)


func _ready() -> void:
	visible = false  # toggled open with P
	# EXPLICIT anchors (never set_anchors_preset — the preset recompute collapses containers on 4.7).
	anchor_left = 1.0
	anchor_top = 0.0
	anchor_right = 1.0
	anchor_bottom = 1.0
	offset_left = -420.0
	offset_right = -16.0
	offset_top = 56.0
	offset_bottom = -56.0
	# T-400: the shared theme's SolidWindow frame — self-carried (settings_panel idiom) so the
	# "SolidWindow" variation resolves without depending on an ancestor's theme.
	theme = UiTheme.build()
	var frame := PanelContainer.new()
	frame.name = "Frame"
	frame.theme_type_variation = "SolidWindow"  # T-396: deliberate window = opaque opt-in
	add_child(frame)
	# EXPLICIT anchors on the frame too, AFTER add_child (inventory_panel lesson).
	frame.anchor_left = 0.0
	frame.anchor_top = 0.0
	frame.anchor_right = 1.0
	frame.anchor_bottom = 1.0
	frame.offset_left = 0.0
	frame.offset_top = 0.0
	frame.offset_right = 0.0
	frame.offset_bottom = 0.0
	_rtl = RichTextLabel.new()
	_rtl.bbcode_enabled = true
	_rtl.scroll_active = true
	_rtl.meta_clicked.connect(_on_meta)
	frame.add_child(_rtl)
	_render()


# main.gd wires this once: the transport (sends ride main._send_to_server), the chat-typing gate,
# and the routed-reply hub the panel self-registers its reply types on (no per-type main.gd wiring).
func setup(send_fn: Callable, is_typing_fn: Callable, reply_router) -> void:
	_send_fn = send_fn
	_is_typing_fn = is_typing_fn
	if reply_router != null:
		reply_router.register("pvp_rating", func(d): receive(d))
		reply_router.register("pvp_leaderboard", func(d): receive(d))
		reply_router.register("pvp_tracks", func(d): receive(d))
		reply_router.register("pvp_result", func(d): receive(d))


func _input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.is_pressed() or event.is_echo():
		return
	if (event as InputEventKey).keycode != KEY_P:
		return
	if UiInputGate.is_text_input_focused(get_viewport()):
		return
	if _is_typing_fn.is_valid() and bool(_is_typing_fn.call()):
		return  # chat holds the keyboard
	visible = not visible
	if visible:
		_refresh()  # pull fresh rating + leaderboard + tracks on open (social_panel _emit idiom)
	get_viewport().set_input_as_handled()


# Ask the server for the whole panel state. Every reply routes back through receive().
func _refresh() -> void:
	_emit({"type": "pvp_rating"})
	_emit({"type": "pvp_leaderboard", "limit": 10})
	_emit({"type": "pvp_tracks", "action": "browse"})


# Server reply router target. Each reply carries its own `type`; store + re-render. Activate/spend
# acks (a pvp_tracks reply WITHOUT the full `tracks` list, or a pvp_result) trigger a fresh pull so
# the honor balance + tier progress reflect the mutation.
func receive(data: Dictionary) -> void:
	match str(data.get("type", "")):
		"pvp_rating":
			_rating = data
			_honor = int(data.get("honor", _honor))
			_active = str(data.get("active_track", _active))
			_render()
		"pvp_leaderboard":
			_board = data.get("entries", [])
			_render()
		"pvp_tracks":
			if data.has("tracks"):
				_tracks = data.get("tracks", [])
				_honor = int(data.get("honor", _honor))
				_active = str(data.get("active", _active))
				_render()
			else:
				_refresh()  # activate/spend ack — pull the fresh full state
		"pvp_result":
			_notice = _result_notice(data)
			_render()
			if bool(data.get("ok", false)):
				_refresh()  # a title set/spend landed — refresh balances/progress


# ---- pure render helpers (unit-tested without instantiating the Control) ----


# The next unbought tier index of a track, or -1 when the track is complete. tier == -1 means
# nothing bought yet, so the next index is 0.
static func next_tier_index(track: Dictionary) -> int:
	var tiers: Array = track.get("tiers", [])
	var next := int(track.get("tier", -1)) + 1
	return next if next < tiers.size() else -1


# The title unlock ids the player OWNS: every tier <= the track's bought tier whose unlock is a
# `title:` id. These are the only titles the server will let them wear (validated against the unlock
# set), so the panel offers [wear] only for these — never a title they have not earned.
static func unlocked_titles(tracks: Array) -> Array:
	var out: Array = []
	for t: Dictionary in tracks:
		var bought := int(t.get("tier", -1))
		var tiers: Array = t.get("tiers", [])
		for i in range(mini(bought + 1, tiers.size())):
			var unlock := str((tiers[i] as Dictionary).get("unlock", ""))
			if unlock.begins_with("title:"):
				out.append(unlock)
	return out


# The pvp_result reason line — a title set/clear confirmation, or a fail-closed rejection reason.
static func _result_notice(data: Dictionary) -> String:
	if bool(data.get("ok", false)):
		var title := str(data.get("title", ""))
		if title == "":
			return "Title cleared."
		return "Now wearing: %s" % title.trim_prefix("title:")
	return "Rejected: %s" % str(data.get("reason", "error"))


# ---- rendering ----


func _render() -> void:
	if _rtl == null:
		return
	var lines: Array[String] = ["[b]PvP  (P)[/b]"]
	_render_rating(lines)
	_render_tracks(lines)
	_render_titles(lines)
	_render_board(lines)
	if _notice != "":
		lines.append("")
		lines.append("[i]%s[/i]" % _notice)
	_rtl.text = "\n".join(lines)


func _render_rating(lines: Array[String]) -> void:
	lines.append("")
	if _rating.is_empty():
		lines.append("[color=#808080](loading standing…)[/color]")
		return
	var r: Dictionary = _rating.get("rating", {})
	var ranked := bool(_rating.get("ranked", false))
	(
		lines
		. append(
			(
				"[b]Rating[/b] %d  [color=#ffcc66]%s[/color]  (%dW/%dL)%s"
				% [
					int(r.get("rating", 0)),
					str(r.get("tier", "")),
					int(r.get("wins", 0)),
					int(r.get("losses", 0)),
					"" if ranked else "  [color=#808080](unranked — placement)[/color]",
				]
			)
		)
	)
	lines.append("[b]Honor[/b] [color=#ffdd88]%d[/color]" % _honor)


func _render_tracks(lines: Array[String]) -> void:
	lines.append("")
	lines.append("[b]Reward Tracks[/b]")
	if _tracks.is_empty():
		lines.append("  [color=#808080](none)[/color]")
		return
	for t: Dictionary in _tracks:
		var tid := str(t.get("id", ""))
		var is_active := tid == _active
		var mark := "[color=#88ff88]▶[/color] " if is_active else "  "
		var act := (
			""
			if is_active
			else "  [url=activate|%s][color=#88ccff]\\[activate\\][/color][/url]" % tid
		)
		lines.append("%s[b]%s[/b]%s" % [mark, str(t.get("name", tid)), act])
		var next := next_tier_index(t)
		var tiers: Array = t.get("tiers", [])
		for i in range(tiers.size()):
			var tier: Dictionary = tiers[i]
			var cost := int(tier.get("cost", 0))
			var unlock := str(tier.get("unlock", ""))
			var rarity := str(tier.get("rarity", "common"))
			var owned := i < next or (next == -1)
			var status := ""
			if owned:
				status = " [color=#88ff88]✓[/color]"
			elif is_active and i == next:
				var afford := _honor >= cost
				status = (
					"  [url=spend][color=#%s]\\[buy %d honor\\][/color][/url]"
					% ["ffdd88" if afford else "aa6666", cost]
				)
			else:
				status = "  [color=#808080](%d honor)[/color]" % cost
			lines.append(
				"    %s [color=#%s]%s[/color]%s" % [cost, _rarity_hex(rarity), unlock, status]
			)


func _render_titles(lines: Array[String]) -> void:
	var titles := unlocked_titles(_tracks)
	if titles.is_empty():
		return
	lines.append("")
	lines.append("[b]Titles[/b]  [url=title|][color=#808080]\\[clear\\][/color][/url]")
	for tid: String in titles:
		lines.append(
			(
				"  %s  [url=title|%s][color=#88ccff]\\[wear\\][/color][/url]"
				% [str(tid).trim_prefix("title:"), tid]
			)
		)


func _render_board(lines: Array[String]) -> void:
	lines.append("")
	lines.append("[b]Leaderboard[/b]")
	if _board.is_empty():
		lines.append("  [color=#808080](no ranked players yet)[/color]")
		return
	for e: Dictionary in _board:
		(
			lines
			. append(
				(
					"  %d. %s  [color=#ffcc66]%d[/color] %s"
					% [
						int(e.get("rank", 0)),
						_bbcode_safe(str(e.get("name", ""))),
						int(e.get("rating", 0)),
						str(e.get("tier", "")),
					]
				)
			)
		)


# T-599: a leaderboard entry's name is SERVER DATA (a player's username), not a dev-authored catalog
# string — a raw "[" would open (or, worse, complete) a real BBCode tag and the RichTextLabel would
# swallow every character after it to the end of the string, including the closing color tag. Same
# neutralisation idiom as ChatFormatter._escape (client/scripts/ui/chat_formatter.gd).
static func _bbcode_safe(s: String) -> String:
	return s.replace("[", "[lb]")


func _rarity_hex(rarity: String) -> String:
	match rarity:
		"uncommon":
			return "1eff00"
		"rare":
			return "0070dd"
		_:
			return "cccccc"


func _on_meta(meta: Variant) -> void:
	action_selected.emit(str(meta))
	var p := str(meta).split("|", true)
	match p[0]:
		"activate":
			if p.size() >= 2:
				_emit({"type": "pvp_tracks", "action": "activate", "track": p[1]})
		"spend":
			_emit({"type": "pvp_tracks", "action": "spend"})
		"title":
			# p[1] is the full "title:<name>" id (or "" to clear); the server re-validates ownership.
			_emit({"type": "pvp_set_title", "title": p[1] if p.size() >= 2 else ""})


func _emit(msg: Dictionary) -> void:
	if _send_fn.is_valid():
		_send_fn.call(msg)


func toggle() -> void:
	visible = not visible
	if visible:
		_refresh()


# test/introspection
func body_text() -> String:
	return _rtl.text if _rtl != null else ""
