class_name PartyInviteDialog
extends Control

# T-736: the invitee's Accept/Decline dialog — "X has invited you to their party." The owner
# flow's second half: a party_invite push opens it, a click answers it, and the server's
# INVITE_TTL_MS (echoed as ttl_ms on the push) auto-dismisses an ignored one.
#
# Deliberately NOT in the "ui_blocking_modal" group and NOT dimmed: an invite may sit on
# screen for 45 s and freezing the whole keyboard/game for it would hand griefers exactly the
# disruption T-736 exists to remove. It floats top-center (the WoW invite spot), owns only the
# clicks on its two buttons (T-718 _input routing), and everything else plays on. The T-598
# chat line + /party accept|decline keep working underneath as the text fallback.
#
# A lapse sends NOTHING: the server prunes its own pending lazily, and a timeout must not
# count as a decline (anti-grief counter feeds on explicit declines only).

signal answered(accepted: bool)  # true = Accept clicked, false = Decline clicked
signal lapsed  # the countdown ran out with no answer (nothing was sent)

const _FALLBACK_TTL_MS := 45000  # mirrors party_logic.INVITE_TTL_MS if the push omits ttl_ms
const _TOP_OFFSET := 120.0

var _panel: PanelContainer = null
var _body: Label = null
var _countdown: Label = null
var _accept_btn: Button = null
var _decline_btn: Button = null
var _from: String = ""
var _deadline_ms: int = 0


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE  # button clicks are routed in _input (T-718)
	visible = false
	theme = UiTheme.build()
	_panel = PanelContainer.new()
	_panel.theme_type_variation = "SolidWindow"
	add_child(_panel)
	var box := VBoxContainer.new()
	box.custom_minimum_size = Vector2(340.0, 0.0)
	box.add_theme_constant_override("separation", 8)
	_panel.add_child(box)
	var title := Label.new()
	title.text = "Party Invite"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 20)
	title.add_theme_color_override("font_color", UiTheme.GOLD_BRIGHT)
	box.add_child(title)
	_body = Label.new()
	_body.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_body)
	_countdown = Label.new()
	_countdown.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_countdown.add_theme_color_override("font_color", Color(0.7, 0.68, 0.6))
	box.add_child(_countdown)
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 16)
	box.add_child(row)
	_accept_btn = Button.new()
	_accept_btn.name = "PartyInviteAccept"  # stable name: pilot click_node drives the E2E
	_accept_btn.text = "Accept"
	_accept_btn.add_theme_color_override("font_color", Color(0.4, 1.0, 0.4))
	_accept_btn.pressed.connect(func(): _answer(true))
	row.add_child(_accept_btn)
	_decline_btn = Button.new()
	_decline_btn.name = "PartyInviteDecline"
	_decline_btn.text = "Decline"
	_decline_btn.add_theme_color_override("font_color", Color(1.0, 0.5, 0.4))
	_decline_btn.pressed.connect(func(): _answer(false))
	row.add_child(_decline_btn)


# A party_invite push landed: show the dialog with its server-fed countdown.
func open(from: String, ttl_ms: int = _FALLBACK_TTL_MS) -> void:
	_from = from
	_deadline_ms = Time.get_ticks_msec() + maxi(1000, ttl_ms)
	if _body != null:
		_body.text = "%s has invited you to their party." % from
	visible = true
	ModalInput.raise_to_front(self)
	_position_top_center()
	_tick_countdown()
	print("[party] invite modal shown from %s" % from)


func close_dialog() -> void:
	visible = false


func is_open() -> bool:
	return visible


func inviter() -> String:
	return _from


func _answer(accepted: bool) -> void:
	if not visible:
		return  # a re-emit after closing must never double-send
	visible = false
	print("[party] invite modal answered %s" % ("accept" if accepted else "decline"))
	answered.emit(accepted)


func _process(_delta: float) -> void:
	if not visible:
		return
	if Time.get_ticks_msec() >= _deadline_ms:
		visible = false
		print("[party] invite modal timed out (no answer sent)")
		lapsed.emit()
		return
	_tick_countdown()


func _tick_countdown() -> void:
	if _countdown != null:
		var left := maxi(0, _deadline_ms - Time.get_ticks_msec())
		_countdown.text = "Expires in %d s" % int(ceil(left / 1000.0))


# T-718: the two buttons are answered at the _input stage so no later sibling can eat them.
func _input(event: InputEvent) -> void:
	if not visible:
		return
	if not (event is InputEventMouseButton) or not event.pressed:
		return
	var mouse := event as InputEventMouseButton
	var index := ModalInput.hit_index([_accept_btn, _decline_btn], mouse.position)
	if index == -1:
		return  # not ours — the world plays on underneath (this dialog never blocks)
	([_accept_btn, _decline_btn][index] as Button).pressed.emit()
	get_viewport().set_input_as_handled()  # exactly one dispatch — never also via gui_input


func _position_top_center() -> void:
	if _panel == null:
		return
	_panel.reset_size()
	var vp := get_viewport_rect().size
	_panel.position = Vector2((vp.x - _panel.get_combined_minimum_size().x) / 2.0, _TOP_OFFSET)
