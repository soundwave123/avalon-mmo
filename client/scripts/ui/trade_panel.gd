class_name TradePanel
# T-363: the two-party trade window — entirely SERVER-FED: every trade_update carries both offers,
# both confirm flags, and the viewer's own bag snapshot, so nothing this panel shows is a client
# guess. The panel only emits DESIRES ({"type":"trade_*"}); the server validates and mirrors back.
# Code-built on the shared T-308 UiTheme (no .tscn, per standing orders).

extends Control

var _send_fn: Callable = Callable()  # main._send_to_server wrapper
var _body: RichTextLabel = null
var _coins_box: LineEdit = null
var _status: Label = null
var _view: Dictionary = {}


func _ready() -> void:
	visible = false
	set_anchors_preset(Control.PRESET_CENTER)
	custom_minimum_size = Vector2(460, 380)
	offset_left = -230.0
	offset_top = -190.0
	offset_right = 230.0
	offset_bottom = 190.0
	# T-759: a two-party item/coin trade is an IRREVERSIBLE transaction, but the frame resolved the
	# 0.42-alpha idle-HUD glass stylebox (the PanelContainer default) — the world read straight through
	# the thing the player is about to commit gear to. Carry the shared theme + opt into the solid
	# window surface (SocialUi also assigns the theme; self-carrying makes the modal self-sufficient).
	theme = UiTheme.build()
	var frame := PanelContainer.new()
	frame.name = "TradeFrame"
	frame.theme_type_variation = "SolidWindow"  # T-396: deliberate window = opaque opt-in
	frame.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(frame)
	var col := VBoxContainer.new()
	frame.add_child(col)
	_status = Label.new()
	_status.name = "TradeStatus"
	col.add_child(_status)
	_body = RichTextLabel.new()
	_body.name = "TradeBody"
	_body.bbcode_enabled = true
	_body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_body.meta_clicked.connect(_on_meta)
	col.add_child(_body)
	var coin_row := HBoxContainer.new()
	col.add_child(coin_row)
	_coins_box = LineEdit.new()
	_coins_box.name = "TradeCoins"
	_coins_box.placeholder_text = "coins"
	_coins_box.custom_minimum_size = Vector2(120, 0)
	coin_row.add_child(_coins_box)
	coin_row.add_child(_btn("Set Coins", _on_set_coins))
	var row := HBoxContainer.new()
	col.add_child(row)
	row.add_child(_btn("Confirm", func(): _emit({"type": "trade_confirm"})))
	row.add_child(_btn("Unconfirm", func(): _emit({"type": "trade_unconfirm"})))
	row.add_child(_btn("Cancel", func(): _emit({"type": "trade_cancel"})))


func setup(send_fn: Callable) -> void:
	_send_fn = send_fn


# Server push: a live session mirror, or the end of the trade (completed / cancelled / aborted).
func receive(data: Dictionary) -> void:
	if str(data.get("type", "")) == "trade_result":  # actor-only rejection
		if _status != null and visible:
			_status.text = "Rejected: %s" % str(data.get("reason", ""))
		return
	if bool(data.get("ended", false)):
		_view = {}
		visible = false
		return
	_view = data.get("view", {})
	visible = true
	_render()


# An invite the server relayed (state "pending", we are the invitee) renders accept/decline.
func _render() -> void:
	if _body == null:
		return
	var lines: Array[String] = []
	var partner := str(_view.get("partner", "?"))
	if str(_view.get("state", "")) == "pending":
		_status.text = "Trade with %s" % partner
		lines.append("[url=accept]\\[Accept trade\\][/url]  [url=cancel]\\[Decline\\][/url]")
		_body.text = "\n".join(lines)
		return
	var mine: Dictionary = _view.get("mine", {})
	var theirs: Dictionary = _view.get("theirs", {})
	_status.text = (
		"Trading with %s%s%s"
		% [
			partner,
			"  [you: OK]" if bool(_view.get("my_confirm", false)) else "",
			"  [them: OK]" if bool(_view.get("their_confirm", false)) else "",
		]
	)
	lines.append("[b]Your offer[/b] (%d coins)" % int(mine.get("coins", 0)))
	for it: Dictionary in mine.get("items", []):
		lines.append(
			(
				"  %s x%d [url=retract|%d]\\[retract\\][/url]"
				% [str(it["item_id"]), int(it["count"]), int(it["slot_index"])]
			)
		)
	# T-755: the partner is the one player-controlled value on this label (item_ids are dev-authored
	# content keys), and an unclosed tag here would swallow the entire offer list below it — i.e.
	# hide what you are actually agreeing to trade away.
	lines.append(
		"[b]%s's offer[/b] (%d coins)" % [BBCode.escape(partner), int(theirs.get("coins", 0))]
	)
	for it: Dictionary in theirs.get("items", []):
		lines.append("  %s x%d" % [str(it["item_id"]), int(it["count"])])
	lines.append("[b]Your bag[/b] (click to offer)")
	for slot: Dictionary in _view.get("my_bag", []):
		(
			lines
			. append(
				(
					"  [url=offer|%d|%d]%s x%d[/url]"
					% [
						int(slot["slot_index"]),
						int(slot["item_count"]),
						str(slot["item_id"]),
						int(slot["item_count"]),
					]
				)
			)
		)
	_body.text = "\n".join(lines)


func _on_meta(meta: Variant) -> void:
	var p := str(meta).split("|")
	match p[0]:
		"accept":
			_emit({"type": "trade_accept"})
		"cancel":
			_emit({"type": "trade_cancel"})
		"offer":
			if p.size() >= 3:
				_emit(
					{
						"type": "trade_offer_item",
						"slot_index": int(p[1]),
						"count": int(p[2]),
					}
				)
		"retract":
			if p.size() >= 2:
				_emit({"type": "trade_retract_item", "slot_index": int(p[1])})


func _on_set_coins() -> void:
	if _coins_box != null and _coins_box.text.strip_edges().is_valid_int():
		_emit({"type": "trade_offer_coins", "amount": int(_coins_box.text.strip_edges())})


func _emit(msg: Dictionary) -> void:
	if _send_fn.is_valid():
		_send_fn.call(msg)


func _btn(label: String, fn: Callable) -> Button:
	var b := Button.new()
	b.text = label
	b.focus_mode = Control.FOCUS_NONE
	b.pressed.connect(fn)
	return b


# test/introspection helpers
func body_text() -> String:
	return _body.text if _body != null else ""


func status_text() -> String:
	return _status.text if _status != null else ""
