class_name GuildPanel
# T-362: the guild window (toggle G). Server-fed and intent-only — every roster line it shows came
# back from a guild_roster reply, and the panel emits nothing but DESIRES (create/invite/accept/
# leave/kick/promote/demote/disband) through the injected transport. Rank truth, membership, and
# permissions are the master's; this UI never assumes an action succeeded until the server echoes a
# fresh roster. Code-built on the shared T-308 theme, mirroring SocialPanel.

extends Control

var _send_fn: Callable = Callable()
var _is_typing_fn: Callable = Callable()  # chat focus gate — G must not fire while typing
var _body: RichTextLabel = null
var _name_box: LineEdit = null
var _blurb_box: LineEdit = null
var _note_box: LineEdit = null
var _bank_amount_box: LineEdit = null  # T-683: guild-bank coin deposit/withdraw amount
var _open_check: CheckBox = null
var _status: Label = null
var _bank_coins := -1  # -1 = not yet fetched (drives whether the bank line shows)
var _bank_items: Array = []
var _guild_name := ""
var _members: Array = []
var _my_rank := -1  # -1 = not in a guild (drives which controls show)
var _pending_invite := ""  # a guild name we've been invited to (accept/decline offered)
var _open_guilds: Array = []
var _seekers: Array = []
var _who: Array = []
var _mentorship: Array = []  # T-477: server-fed mentor/mentee signal rows


func _ready() -> void:
	visible = false
	set_anchors_preset(Control.PRESET_CENTER_RIGHT)
	custom_minimum_size = Vector2(320, 400)
	offset_left = -340.0
	offset_right = -20.0
	offset_top = -200.0
	offset_bottom = 200.0
	var frame := PanelContainer.new()
	frame.name = "GuildFrame"
	frame.theme_type_variation = "SolidWindow"  # T-396: deliberate window = opaque opt-in
	frame.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(frame)
	var col := VBoxContainer.new()
	frame.add_child(col)
	var title := Label.new()
	title.text = "Guild  (G)"
	col.add_child(title)
	_body = RichTextLabel.new()
	_body.name = "GuildBody"
	_body.bbcode_enabled = true
	_body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_body.meta_clicked.connect(_on_meta)
	col.add_child(_body)
	_name_box = LineEdit.new()
	_name_box.name = "GuildNameBox"
	_name_box.placeholder_text = "guild or character name"
	col.add_child(_name_box)
	_blurb_box = LineEdit.new()
	_blurb_box.name = "RecruitmentBlurb"
	_blurb_box.placeholder_text = "short recruitment blurb"
	_blurb_box.max_length = 160
	col.add_child(_blurb_box)
	_note_box = LineEdit.new()
	_note_box.name = "SeekingNote"
	_note_box.placeholder_text = "what kind of guild are you seeking?"
	_note_box.max_length = 120
	col.add_child(_note_box)
	_open_check = CheckBox.new()
	_open_check.name = "RecruitmentOpen"
	_open_check.text = "Open recruitment"
	col.add_child(_open_check)
	# T-653 (#74): at the 320px panel width these rows' natural button widths (esp. "Seek Mentor" /
	# "Mentees" / "Publish") sum past what an HBoxContainer can give them, so it squeezed every
	# button below its own minimum size instead — "Mentees" rendered as "Mente", "Publish" as "Pu".
	# HFlowContainer wraps overflow onto additional lines instead, so no button is ever shrunk
	# below the size its own label needs.
	var row := HFlowContainer.new()
	col.add_child(row)
	# When guildless: [Create] founds a guild named by the box. When in a guild: [Invite] a character
	# by name; [Leave] the guild; the leader additionally sees [Disband].
	row.add_child(_btn("Create", func(): _named("guild_create")))
	row.add_child(_btn("Invite", func(): _named("guild_invite")))
	row.add_child(_btn("Leave", func(): _emit({"type": "guild_leave"})))
	row.add_child(_btn("Disband", func(): _emit({"type": "guild_disband"})))
	var discover_row := HFlowContainer.new()
	col.add_child(discover_row)
	discover_row.add_child(_btn("Browse", func(): _request_discovery("guild_browse")))
	discover_row.add_child(_btn("Seek", _seek))
	discover_row.add_child(_btn("Unseek", func(): _emit({"type": "guild_unseek"})))
	discover_row.add_child(_btn("Seekers", func(): _request_discovery("guild_seek_list")))
	discover_row.add_child(_btn("Who", func(): _request_discovery("player_who")))
	discover_row.add_child(_btn("Publish", _set_recruitment))
	var mentor_row := HFlowContainer.new()
	col.add_child(mentor_row)
	mentor_row.add_child(_btn("Offer Help", func(): _mentor_flag("mentor")))
	mentor_row.add_child(_btn("Seek Mentor", func(): _mentor_flag("mentee")))
	mentor_row.add_child(_btn("Mentors", func(): _request_mentors("mentor")))
	mentor_row.add_child(_btn("Mentees", func(): _request_mentors("mentee")))
	mentor_row.add_child(_btn("Clear", func(): _emit({"type": "mentor_unflag"})))
	# T-683: guild bank. Deposit is member-wide; withdraw is Officer+ and the server refuses below
	# rank (this UI only sends intent). Contents are shown read-only from the server's bank view.
	_bank_amount_box = LineEdit.new()
	_bank_amount_box.name = "BankAmount"
	_bank_amount_box.placeholder_text = "coin amount"
	col.add_child(_bank_amount_box)
	var bank_row := HFlowContainer.new()
	col.add_child(bank_row)
	bank_row.add_child(_btn("Bank", func(): _emit({"type": "guild_bank_view"})))
	bank_row.add_child(_btn("Deposit", func(): _bank_coin("guild_bank_deposit")))
	bank_row.add_child(_btn("Withdraw", func(): _bank_coin("guild_bank_withdraw")))
	_status = Label.new()
	_status.name = "GuildStatus"
	col.add_child(_status)
	_render()


func setup(send_fn: Callable, is_typing_fn: Callable = Callable()) -> void:
	_send_fn = send_fn
	_is_typing_fn = is_typing_fn


func _input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.is_pressed() or event.is_echo():
		return
	var key := KeyRegistry.event_code(event as InputEventKey)
	# T-653 (#74): main._input's top-of-function is_text_input_focused check swallows Escape
	# whenever ANY of this panel's three LineEdits holds focus, so main._handle_escape() never
	# runs and the panel (which had no Close button either) could only be recovered by a relog.
	# Same local-escape idiom as chat_panel: the panel that owns the focused field is the only one
	# that can react — release focus AND close in one press, same as report #74 asked for.
	if key == KEY_ESCAPE and visible and _has_own_focus():
		get_viewport().gui_release_focus()
		visible = false
		get_viewport().set_input_as_handled()
		return
	if key != KEY_G:
		return
	if UiInputGate.is_text_input_focused(get_viewport()):
		return
	if _is_typing_fn.is_valid() and bool(_is_typing_fn.call()):
		return  # chat holds the keyboard
	visible = not visible
	if visible:
		_emit({"type": "guild_roster"})  # refresh from the server on open
	get_viewport().set_input_as_handled()


# T-653: an unhandled mouse click means it missed EVERY GUI control in the scene (Buttons/LineEdits
# consume clicks themselves before an event ever reaches here) — i.e. it landed in the 3D world.
# The report's repro (clicking at 300,300 in-world) never released the LineEdit's focus, leaving
# every other world hotkey swallowed by UiInputGate.is_text_input_focused indefinitely.
func _unhandled_input(event: InputEvent) -> void:
	if not visible or not (event is InputEventMouseButton):
		return
	if not (event as InputEventMouseButton).pressed:
		return
	if _has_own_focus():
		get_viewport().gui_release_focus()


# True only when one of THIS panel's own LineEdits owns viewport focus — never another panel's
# (e.g. chat mid-typing), so this panel doesn't steal/close on a keystroke meant elsewhere.
func _has_own_focus() -> bool:
	if not is_inside_tree():
		return false
	var owner := get_viewport().gui_get_focus_owner()
	return (
		owner == _name_box or owner == _blurb_box or owner == _note_box or owner == _bank_amount_box
	)


func _release_own_focus() -> void:
	if _has_own_focus():
		get_viewport().gui_release_focus()


# Server replies routed here by SocialUi.on_social (type-prefixed "guild_*").
func receive(data: Dictionary) -> void:
	match str(data.get("type", "")):
		"guild_roster":
			_guild_name = str(data.get("guild_name", ""))
			_members = data.get("members", [])
			_my_rank = _rank_of(str(data.get("you", "")))
			_pending_invite = ""
			_open_check.button_pressed = bool(data.get("recruitment_open", false))
			_blurb_box.text = str(data.get("recruitment_blurb", ""))
			_status.text = ""
			_render()
		"guild_discovery":
			_open_guilds = data.get("guilds", [])
			_status.text = "Open guilds: %d" % _open_guilds.size()
			_render()
		"guild_seek_board":
			_seekers = data.get("players", [])
			_status.text = "Seeking players: %d" % _seekers.size()
			_render()
		"guild_who":
			_who = data.get("players", [])
			_status.text = "Online players: %d" % _who.size()
			_render()
		"mentor_board":
			_mentorship = data.get("players", [])
			_status.text = "Mentorship signals: %d" % _mentorship.size()
			_render()
		"mentor_result":
			if not bool(data.get("ok", false)):
				_status.text = "Mentorship: %s" % str(data.get("reason", "error"))
		"guild_invite":
			_pending_invite = str(data.get("guild_name", ""))
			_status.text = "%s invited you to <%s>" % [str(data.get("from", "?")), _pending_invite]
			visible = true
			_render()
		"guild_disbanded":
			_guild_name = ""
			_members = []
			_my_rank = -1
			_bank_coins = -1  # T-683: the vault is gone with the guild
			_bank_items = []
			_status.text = "Your guild was disbanded."
			_render()
		"guild_bank":
			# T-683: view carries bank_coins+items; a move carries move keys. Refresh contents after
			# a move so the read-only list stays truthful without the panel guessing at state.
			if data.has("bank_coins"):
				_bank_coins = int(data.get("bank_coins", 0))
			if data.has("items"):
				_bank_items = data.get("items", [])
			_status.text = _bank_status(data)
			if str(data.get("action", "")) != "guild_bank_view":
				_emit({"type": "guild_bank_view"})  # pull the fresh contents after the move
			_render()
		"guild_result":
			if not bool(data.get("ok", false)):
				_status.text = "Guild: %s" % str(data.get("reason", "error"))


func _rank_of(my_name: String) -> int:
	# The roster's "you" field names the viewer's own row, so management controls gate to the
	# viewer's REAL rank (the server re-checks every verb regardless). -1 = not in this roster.
	for m: Dictionary in _members:
		if str(m.get("name", "")) == my_name:
			return int(m.get("rank", 2))
	return -1


# T-755: EVERY value interpolated below arrives in a server reply and is ultimately player-typed
# (guild names, recruitment blurbs, seek/mentor notes) or a player identity. This label is
# bbcode_enabled AND its meta_clicked fires guild_kick/guild_promote/guild_demote/party_invite, so
# an unescaped "[" here lets a crafted note paint a fake management link that acts on whoever
# clicks it. The rule is uniform and admits no per-field judgement: DISPLAY text goes through
# BBCode.escape, and anything embedded in a [url=...] payload goes through BBCode.escape_meta.
func _render() -> void:
	if _body == null:
		return
	var lines: Array[String] = []
	if _pending_invite != "":
		lines.append("[b]Invitation[/b]")
		lines.append(
			(
				"  <%s>  [url=accept]\\[accept\\][/url]  [url=decline]\\[decline\\][/url]"
				% BBCode.escape(_pending_invite)
			)
		)
		lines.append("")
	if _members.is_empty() and _pending_invite == "":
		lines.append("[color=#808080]You are not in a guild.[/color]")
		lines.append("Create one, browse open guilds, or flag yourself as seeking.")
	else:
		lines.append("[b]<%s>[/b]  (%d)" % [BBCode.escape(_guild_name), _members.size()])
		for m: Dictionary in _members:
			var mname := BBCode.escape_meta(str(m.get("name", "")))
			var online := bool(m.get("online", false))
			var rank_name := str(m.get("rank_name", ""))
			var promote := (
				" [url=promote|%s]\\[+\\][/url] [url=demote|%s]\\[-\\][/url]" % [mname, mname]
			)
			var kick := " [url=kick|%s]\\[x\\][/url]" % mname
			var mgmt := (
				(promote + kick) if _my_rank == 0 and not bool(m.get("is_leader", false)) else ""
			)
			(
				lines
				. append(
					(
						"  [color=#%s]%s[/color] (%s)%s"
						% [
							"7fff7f" if online else "808080",
							BBCode.escape(str(m.get("name", ""))),
							BBCode.escape(rank_name),
							mgmt,
						]
					)
				)
			)
	if _my_rank >= 0 and _bank_coins >= 0:
		lines.append("")
		lines.append("[b]Guild Bank[/b]  %d copper" % _bank_coins)
		for entry: Dictionary in _bank_items:
			lines.append(
				(
					"  %s x%d"
					% [
						BBCode.escape(str(entry.get("item_id", ""))),
						int(entry.get("item_count", 0))
					]
				)
			)
	if not _open_guilds.is_empty():
		lines.append("")
		lines.append("[b]Open Guilds[/b]")
		for guild: Dictionary in _open_guilds:
			lines.append(
				(
					"  <%s> (%d) — %s"
					% [
						BBCode.escape(str(guild.get("name", ""))),
						int(guild.get("members", 0)),
						BBCode.escape(str(guild.get("blurb", "")))
					]
				)
			)
	if not _seekers.is_empty():
		lines.append("")
		lines.append("[b]Looking for Guild[/b]")
		for seeker: Dictionary in _seekers:
			var sname := str(seeker.get("name", ""))
			lines.append(
				(
					"  [url=invite|%s]%s[/url] L%d %s — %s"
					% [
						BBCode.escape_meta(sname),
						BBCode.escape(sname),
						int(seeker.get("level", 1)),
						BBCode.escape(str(seeker.get("role", ""))),
						BBCode.escape(str(seeker.get("note", "")))
					]
				)
			)
	if not _who.is_empty():
		lines.append("")
		lines.append("[b]Who Is Online[/b]")
		for player: Dictionary in _who:
			var guild := str(player.get("guild", ""))
			lines.append(
				(
					"  %s L%d %s — %s%s"
					% [
						BBCode.escape(str(player.get("name", ""))),
						int(player.get("level", 1)),
						BBCode.escape(str(player.get("role", ""))),
						BBCode.escape(str(player.get("zone", ""))),
						" <%s>" % BBCode.escape(guild) if guild != "" else ""
					]
				)
			)
	if not _mentorship.is_empty():
		lines.append("")
		var showing_mentors := str(_mentorship[0].get("kind", "")) == "mentor"
		lines.append("[b]%s[/b]" % ("Available Mentors" if showing_mentors else "Seeking Mentors"))
		for entry: Dictionary in _mentorship:
			var player_name := str(entry.get("name", ""))
			(
				lines
				. append(
					(
						"  [url=party|%s]%s[/url] L%d %s — %s — %s"
						% [
							BBCode.escape_meta(player_name),
							BBCode.escape(player_name),
							int(entry.get("level", 1)),
							BBCode.escape(str(entry.get("role", ""))),
							BBCode.escape(str(entry.get("zone", ""))),
							BBCode.escape(str(entry.get("note", ""))),
						]
					)
				)
			)
	_body.text = "\n".join(lines)


func _on_meta(meta: Variant) -> void:
	var p := str(meta).split("|")
	match p[0]:
		"accept":
			_emit({"type": "guild_accept"})
		"decline":
			_emit({"type": "guild_decline"})
			_pending_invite = ""
			_render()
		"kick":
			if p.size() >= 2:
				_emit({"type": "guild_kick", "name": p[1]})
		"promote":
			if p.size() >= 2:
				_emit({"type": "guild_promote", "name": p[1]})
		"demote":
			if p.size() >= 2:
				_emit({"type": "guild_demote", "name": p[1]})
		"invite":
			if p.size() >= 2:
				_emit({"type": "guild_invite", "name": p[1]})
		"party":
			if p.size() >= 2:
				_emit({"type": "party_invite", "target": p[1]})


func _request_discovery(intent: String) -> void:
	_emit({"type": intent})


func _seek() -> void:
	var note := _note_box.text.strip_edges() if _note_box != null else ""
	_emit({"type": "guild_seek", "note": note})


func _mentor_flag(kind: String) -> void:
	var note := _note_box.text.strip_edges() if _note_box != null else ""
	_emit({"type": "mentor_flag", "kind": kind, "note": note})


func _request_mentors(kind: String) -> void:
	_emit({"type": "mentor_list", "kind": kind})


func _set_recruitment() -> void:
	_emit(
		{
			"type": "guild_set_recruitment",
			"open": _open_check.button_pressed if _open_check != null else false,
			"blurb": _blurb_box.text.strip_edges() if _blurb_box != null else "",
		}
	)


func _bank_coin(intent: String) -> void:
	var amount := int(_bank_amount_box.text.strip_edges()) if _bank_amount_box != null else 0
	if amount > 0:
		_emit({"type": intent, "amount": amount})
		_bank_amount_box.clear()


func _bank_status(data: Dictionary) -> String:
	if data.has("deposited"):
		return "Deposited %d copper." % int(data["deposited"])
	if data.has("withdrew"):
		return "Withdrew %d copper." % int(data["withdrew"])
	return "Bank: %d copper" % _bank_coins


func _named(intent: String) -> void:
	var n := _name_box.text.strip_edges() if _name_box != null else ""
	if n != "":
		_emit({"type": intent, "name": n})
		_name_box.clear()


func _emit(msg: Dictionary) -> void:
	if _send_fn.is_valid():
		_send_fn.call(msg)


func _btn(label: String, fn: Callable) -> Button:
	var b := Button.new()
	b.name = label.replace(" ", "")
	b.text = label
	b.focus_mode = Control.FOCUS_NONE
	# T-653 (#74): FOCUS_NONE keeps the button itself from stealing focus, but that also means a
	# click on it never releases whichever LineEdit already holds it — the button handler ran fine
	# (the report confirmed "Who" updated status text) while the player stayed keyboard-locked.
	# Every button click now explicitly drops this panel's own focus before running its action.
	b.pressed.connect(
		func():
			_release_own_focus()
			fn.call()
	)
	return b


# test/introspection helpers
func body_text() -> String:
	return _body.text if _body != null else ""
