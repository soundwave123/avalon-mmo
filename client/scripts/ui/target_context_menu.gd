class_name TargetContextMenu
extends Control

# T-736: the right-click context menu on a FRIENDLY player — the party invite's discoverable
# entry point (owner flow: select a player -> right-click their name -> "Invite to Party").
# The FIRST context menu in the client, so keep it minimal and reusable: a titled action list
# opened at the cursor; every action is a meta string main-side wiring turns into an intent
# (the quest_offer_panel action_selected idiom). PartyInviteFlow owns WHO it opens for
# (relationship gating) and what the metas mean; this node only draws and dispatches.
#
# Input rides the T-718 ModalInput idiom: clicks are routed in _input (the stage that runs
# BEFORE GUI picking) via hit_index + pressed.emit(), so a later-built full-rect sibling can
# never swallow the press while the menu still looks clickable. Any click OUTSIDE the panel
# closes the menu and deliberately does NOT consume — the click still selects/deselects
# whatever it landed on, which is how every desktop context menu behaves.

signal action_selected(meta: String)  # "party_invite|<username>"

const _PANEL_W := 180.0
const _MARGIN := 8.0

var _panel: PanelContainer = null
var _title: Label = null
var _invite_btn: Button = null
var _target_name: String = ""


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE  # routing happens in _input, never by blocking
	visible = false
	theme = UiTheme.build()
	_panel = PanelContainer.new()
	_panel.theme_type_variation = "SolidWindow"
	add_child(_panel)
	var box := VBoxContainer.new()
	box.custom_minimum_size = Vector2(_PANEL_W, 0.0)
	box.add_theme_constant_override("separation", 4)
	_panel.add_child(box)
	_title = Label.new()
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title.add_theme_color_override("font_color", UiTheme.GOLD_BRIGHT)
	box.add_child(_title)
	_invite_btn = Button.new()
	_invite_btn.name = "CtxInviteParty"  # stable name: the pilot's click_node drives E2E through it
	_invite_btn.text = "Invite to Party"
	_invite_btn.pressed.connect(_choose_invite)
	box.add_child(_invite_btn)


# Open for one friendly player, panel top-left at the click (clamped inside the viewport).
func open_for(target_name: String, pos: Vector2) -> void:
	_target_name = target_name
	if _title != null:
		_title.text = target_name
	visible = true
	ModalInput.raise_to_front(self)  # T-718: last child wins BOTH draw and GUI pick order
	if _panel != null:
		_panel.reset_size()
		var vp := get_viewport_rect().size
		var panel_size := _panel.get_combined_minimum_size()
		_panel.position = Vector2(
			clampf(pos.x, _MARGIN, maxf(_MARGIN, vp.x - panel_size.x - _MARGIN)),
			clampf(pos.y, _MARGIN, maxf(_MARGIN, vp.y - panel_size.y - _MARGIN))
		)
	print("[party] context menu open for %s" % target_name)


func close_menu() -> void:
	visible = false


func is_open() -> bool:
	return visible


func target_name() -> String:
	return _target_name


func _choose_invite() -> void:
	if not visible:
		return  # a re-emit after closing must never double-send
	visible = false
	print("[party] invite chosen for %s" % _target_name)
	action_selected.emit("party_invite|%s" % _target_name)


# T-718: route clicks at the _input stage (before GUI picking). A hit on an action emits its
# pressed and consumes the event; a click anywhere else closes the menu WITHOUT consuming.
func _input(event: InputEvent) -> void:
	if not visible:
		return
	# T-761: physical position (KeyRegistry modal_cancel) — Esc is layout-stable, but reading it the
	# same way as every other listener is what keeps the meta-test's coverage sweep honest.
	var esc: bool = event is InputEventKey and event.is_pressed()
	if esc and KeyRegistry.event_code(event as InputEventKey) == KEY_ESCAPE:
		close_menu()
		get_viewport().set_input_as_handled()
		return
	if not (event is InputEventMouseButton) or not event.pressed:
		return
	var mouse := event as InputEventMouseButton
	if ModalInput.hit_index([_invite_btn], mouse.position) == 0:
		_invite_btn.pressed.emit()
		get_viewport().set_input_as_handled()  # exactly one dispatch — never also via gui_input
		return
	close_menu()  # outside click: dismiss, let the click land where it fell
