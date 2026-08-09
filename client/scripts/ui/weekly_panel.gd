class_name WeeklyPanel
extends Control

# T-480: the weekly vault panel (toggle J). Server-fed: every track row and vault offer comes
# back from a weekly_state reply (the master owns progress + the once-per-week claim); the panel
# only reads and sends the two intents (status refresh, claim choice). Self-registered on the
# T-401 ReplyRouter like PerformanceRecapPanel, so main.gd (at its line cap) needs no handler.
# Ethics shape carried into the copy: no countdown, no "don't miss out" — a warm build-toward
# and a gift the player shaped. A missed week reads as "fresh tracks", never as a loss.

var _send: Callable = Callable()
var _is_typing: Callable = Callable()
var _summary: Label = null
var _tracks_box: VBoxContainer = null
var _vault_label: Label = null
var _offers_box: VBoxContainer = null
var _state: Dictionary = {}


func _ready() -> void:
	name = "WeeklyPanel"
	visible = false
	theme = UiTheme.build()
	set_anchors_preset(Control.PRESET_CENTER)
	custom_minimum_size = Vector2(420, 460)
	offset_left = -210.0
	offset_right = 210.0
	offset_top = -230.0
	offset_bottom = 230.0
	var frame := PanelContainer.new()
	frame.name = "WeeklyFrame"
	frame.theme_type_variation = "SolidWindow"  # T-396: deliberate window = opaque opt-in
	frame.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(frame)
	var column := VBoxContainer.new()
	frame.add_child(column)
	var title := Label.new()
	title.text = "Weekly Vault  (J)"
	column.add_child(title)
	_summary = Label.new()
	_summary.name = "WeeklySummary"
	_summary.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(_summary)
	_tracks_box = VBoxContainer.new()
	_tracks_box.name = "WeeklyTracks"
	column.add_child(_tracks_box)
	_vault_label = Label.new()
	_vault_label.name = "WeeklyVaultLabel"
	_vault_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(_vault_label)
	_offers_box = VBoxContainer.new()
	_offers_box.name = "WeeklyOffers"
	column.add_child(_offers_box)
	_render()


func setup(send: Callable, is_typing: Callable = Callable(), reply_router = null) -> void:
	_send = send
	_is_typing = is_typing
	if reply_router != null:
		reply_router.register("weekly_state", func(data: Dictionary): receive(data))


func _input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.is_pressed() or event.is_echo():
		return
	if (event as InputEventKey).keycode != KEY_J:
		return
	if UiInputGate.is_text_input_focused(get_viewport()):
		return
	if _is_typing.is_valid() and bool(_is_typing.call()):
		return  # chat holds the keyboard
	toggle()
	get_viewport().set_input_as_handled()


func toggle() -> void:
	visible = not visible
	if visible:
		_request_status()


func receive(data: Dictionary) -> void:
	# A claim ack has no track rows — fold it by refreshing the authoritative status once.
	if not data.has("tracks"):
		_request_status()
		return
	_state = data.duplicate(true)
	_render()


func _request_status() -> void:
	if _send.is_valid():
		_send.call({"type": "weekly_op", "action": "status"})


func _claim(choice_id: String) -> void:
	if _send.is_valid():
		_send.call({"type": "weekly_op", "action": "claim", "choice": choice_id})


func _render() -> void:
	if _summary == null:
		return
	for child in _tracks_box.get_children():
		child.queue_free()
	for child in _offers_box.get_children():
		child.queue_free()
	var tracks: Array = _state.get("tracks", [])
	if tracks.is_empty():
		_summary.text = "This week's tracks are on their way..."
		_vault_label.text = ""
		return
	_summary.text = (
		"%d of %d tracks complete this week — play any of them, in any sitting."
		% [int(_state.get("completed", 0)), tracks.size()]
	)
	for row: Dictionary in tracks:
		var box := VBoxContainer.new()
		var label := Label.new()
		var done := " — done!" if bool(row.get("complete", false)) else ""
		label.text = (
			"%s  %d/%d%s"
			% [
				str(row.get("title", "")),
				int(row.get("progress", 0)),
				int(row.get("goal", 1)),
				done
			]
		)
		box.add_child(label)
		var bar := ProgressBar.new()
		bar.show_percentage = false
		bar.max_value = int(row.get("goal", 1))
		bar.value = int(row.get("progress", 0))
		box.add_child(bar)
		_tracks_box.add_child(box)
	_render_vault(_state.get("vault", {}))


func _render_vault(vault: Dictionary) -> void:
	var offers: Array = vault.get("offers", [])
	if bool(vault.get("claimed", false)):
		_vault_label.text = "Last week's gift is chosen and delivered. New tracks are open above."
		return
	if offers.is_empty():
		_vault_label.text = "Complete any track above and next week's vault will hold a gift."
		return
	_vault_label.text = (
		"Last week earned you a choice of %d — pick the gift you want:" % offers.size()
	)
	for offer: Dictionary in offers:
		var button := Button.new()
		var choice_id := str(offer.get("id", ""))
		button.text = "%s  (%s)" % [str(offer.get("title", "")), _reward_text(offer)]
		button.pressed.connect(func(): _claim(choice_id))
		_offers_box.add_child(button)


func _reward_text(offer: Dictionary) -> String:
	var reward: Dictionary = offer.get("reward", {})
	var parts: Array[String] = []
	if int(reward.get("xp", 0)) > 0:
		parts.append("+%d XP" % int(reward["xp"]))
	if int(reward.get("coins", 0)) > 0:
		parts.append("+%d coins" % int(reward["coins"]))
	if int(reward.get("cosmetic_currency", 0)) > 0:
		parts.append("+%d tokens" % int(reward["cosmetic_currency"]))
	return " ".join(parts)
