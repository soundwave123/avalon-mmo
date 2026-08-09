class_name QuestOfferPanel
extends Control

# T-519: the quest-prompt dialog a quest-giver click opens. Before this, clicking an NPC silently
# auto-accepted/turned-in the quest (via TalkActions), so the click only flipped the `!`/`?` marker
# and never showed the player a prompt. Now it renders the server's talk_result `offers` — each an
# "offer" (`!` available) or "turn_in" (`?` ready) card with the quest title, its objectives and a
# reward summary — with an Accept / Turn In button per card plus a Decline. Buttons emit
# action_selected(meta); main.gd turns that into the server-authoritative accept_quest / turn_in
# intent (the SERVER still owns whether the quest is offered/ready). Built in CODE (the
# SettingsPanel/ServicePanel idiom, no .tscn); headless-unit-testable via get_offer_count() /
# get_action_metas() / get_text().

signal action_selected(meta: String)  # "accept|<qid>" / "turn_in|<qid>" / "decline"
# T-674: the voiced-dialogue seam — emitted whenever the panel shows an NPC's spoken flavour line,
# so a VoicePlayer (self-connected via the "voice_line_source" group) can play its recording.
# Signal-only: the panel owns no audio, and the subtitle it already draws stays the source of truth.
signal line_shown(npc_id: String, text: String)

const TalkActions = preload("res://scripts/net/talk_actions.gd")
# T-713/T-719: the tallest a giver's spoken line may grow before it scrolls (keeps the card,
# and therefore the objectives and reward, inside 720p next to the chat panel).
const _SPEECH_MAX_H := 190.0

var _net_provider: Callable = Callable()  # main.gd → the live ClientNet (accept_quest / turn_in)
var _title: Label = null
var _flavor: Label = null
var _body: VBoxContainer = null
var _npc_id: String = ""
var _summary: String = ""  # headless-test text mirror of the rendered cards
var _action_metas: Array[String] = []  # metas of the accept/turn-in buttons currently shown


func _ready() -> void:
	add_to_group("voice_line_source")  # T-674: VoicePlayer self-connects to line_shown from here
	set_anchors_preset(Control.PRESET_FULL_RECT)
	visible = false  # opened from a quest-giver's talk_result (main.gd)
	theme = UiTheme.build()  # T-400: SolidWindow variation resolves off the shared theme
	var dim := ColorRect.new()
	dim.color = Color(0.0, 0.0, 0.0, 0.55)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(dim)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(center)
	var panel := PanelContainer.new()
	panel.theme_type_variation = "SolidWindow"  # T-396: deliberate window = opaque opt-in
	center.add_child(panel)
	var box := VBoxContainer.new()
	box.custom_minimum_size = Vector2(400.0, 0.0)
	box.add_theme_constant_override("separation", 8)
	panel.add_child(box)

	_title = Label.new()
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title.add_theme_font_size_override("font_size", 22)
	_title.add_theme_color_override("font_color", UiTheme.GOLD_BRIGHT)
	box.add_child(_title)

	_flavor = Label.new()
	_flavor.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_flavor.add_theme_color_override("font_color", Color(0.85, 0.82, 0.7))
	box.add_child(_flavor)

	_body = VBoxContainer.new()
	_body.add_theme_constant_override("separation", 8)
	box.add_child(_body)

	var decline := Button.new()
	decline.name = "QoDecline"
	decline.text = "Close"
	decline.pressed.connect(func(): _choose("decline"))
	box.add_child(decline)


# main.gd: build + wire the panel in one call (CraftingUi.mount idiom). net_provider returns the
# live ClientNet so a button choice routes back through it (the server re-validates eligibility).
static func mount(hud: Node, net_provider: Callable) -> QuestOfferPanel:
	var panel := QuestOfferPanel.new()
	panel.name = "QuestOfferPanel"
	panel._net_provider = net_provider
	hud.add_child(panel)
	return panel


# main._on_result: a talk_result → open the prompt IF it's a plain quest-giver with something to
# offer. Trainers/services route to their own panels, so those return false (untouched). The
# SERVER decides what's offered/ready (talk_result.offers); this only draws + dispatches.
func handle_talk_result(data: Dictionary) -> bool:
	if bool(data.get("trainer", false)) or str(data.get("service", "")) != "":
		return false
	var offers := TalkActions.prompt_model(data)
	# T-647: any new talk_result closes or rebuilds the panel; empty offers ⇒ hide panel.
	if offers.is_empty():
		close_panel()
		return false
	open(
		str(data.get("npc_id", "")),
		str(data.get("name", "")),
		str(data.get("talk_text", "")),
		offers
	)
	return true


# Open for one NPC: draw its offer/turn-in cards.
func open(npc_id: String, npc_name: String, flavor: String, offers: Array) -> void:
	_npc_id = npc_id
	_title.text = npc_name if npc_name != "" else npc_id
	_flavor.text = flavor
	_flavor.visible = flavor != ""
	_build_body(offers)
	visible = true
	if flavor != "":
		line_shown.emit(npc_id, flavor)  # T-674: cue the NPC's voiced greeting (silent if unvoiced)


func close_panel() -> void:
	visible = false


func _build_body(offers: Array) -> void:
	for child in _body.get_children():
		child.queue_free()
	_action_metas.clear()
	var lines: Array[String] = []
	for offer: Dictionary in offers:
		lines.append_array(_add_card(offer))
	_summary = "\n".join(lines)


# One quest card: title + Accept/Turn-In button, an objective bullet per objective, a reward line.
func _add_card(offer: Dictionary) -> Array[String]:
	var lines: Array[String] = []
	var kind := str(offer.get("kind", "offer"))
	var qid := str(offer.get("quest_id", ""))
	var card := PanelContainer.new()
	card.add_theme_stylebox_override("panel", _card_stylebox())
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 3)
	card.add_child(vb)
	var head := HBoxContainer.new()
	var title := Label.new()
	title.text = str(offer.get("title", qid))
	title.add_theme_color_override("font_color", UiTheme.GOLD_BRIGHT)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(title)
	# T-622: a group/elite quest wears an "Elite" badge on the card — the visible social marker that
	# says "bring a party for a premium reward" (pairs with the T-621 difficulty colour). Server owns
	# the flag (recommended_players > 1); the client only paints it.
	if bool(offer.get("elite", false)):
		var badge := Label.new()
		badge.text = "⚔ Elite"
		badge.add_theme_color_override("font_color", Color(1.0, 0.62, 0.28))
		head.add_child(badge)
		lines.append("Elite")
	var meta := "%s|%s" % ["turn_in" if kind == "turn_in" else "accept", qid]
	var btn := Button.new()
	btn.text = "Turn In" if kind == "turn_in" else "Accept"
	btn.add_theme_color_override("font_color", Color(0.4, 1.0, 0.4))
	btn.pressed.connect(func(): _choose(meta))
	head.add_child(btn)
	vb.add_child(head)
	_action_metas.append(meta)
	lines.append(str(offer.get("title", qid)))
	# T-713: the giver's spoken TURN-IN line, under the card title — this is where the graduation
	# beat (Hale pointing south to Highkeep + the Hollowing tease) actually lands for the player.
	# The server only ever sets it on turn_in cards, so offer cards are untouched.
	var spoken := str(offer.get("turnin_text", ""))
	if spoken != "":
		var said := Label.new()
		said.text = spoken
		said.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		said.add_theme_color_override("font_color", Color(0.85, 0.82, 0.7))
		# A long spoken line (the T-713 graduation beat is ~10 wrapped lines) grew the card taller
		# than the viewport, at which point the CenterContainer clamps it to the origin and the
		# objectives + reward spill under the chat panel. Cap the SPEECH in its own scroll so the
		# actionable half of the card is always on screen and legible.
		var said_scroll := ScrollContainer.new()
		said_scroll.custom_minimum_size = Vector2(0.0, _SPEECH_MAX_H)
		said_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
		said.custom_minimum_size = Vector2(380.0, 0.0)
		said_scroll.add_child(said)
		vb.add_child(said_scroll)
		lines.append(spoken)
	for obj: Dictionary in offer.get("objectives", []):
		var row := Label.new()
		var req := int(obj.get("required", 0))
		var suffix := (" (0/%d)" % req) if req > 0 else ""
		row.text = "- %s%s" % [str(obj.get("desc", "")), suffix]
		vb.add_child(row)
		lines.append(str(obj.get("desc", "")))
	var xp := int(offer.get("xp", 0))
	var coins := int(offer.get("coins", 0))
	if xp > 0 or coins > 0:
		var rew := Label.new()
		rew.text = "Reward: %d XP, %d coin" % [xp, coins]
		rew.add_theme_color_override("font_color", Color(0.8, 0.85, 0.6))
		vb.add_child(rew)
		lines.append("Reward: %d XP, %d coin" % [xp, coins])
	_body.add_child(card)
	return lines


func _choose(meta: String) -> void:
	visible = false
	action_selected.emit(meta)  # T-519: kept for headless tests; live dispatch routes to ClientNet
	var parts := meta.split("|")
	var qid := parts[1] if parts.size() > 1 else ""
	var net = _net_provider.call() if _net_provider.is_valid() else null
	if net == null or qid == "":
		return
	if parts[0] == "accept":
		net.accept_quest(qid)
	elif parts[0] == "turn_in":
		net.turn_in(qid)


func _card_stylebox() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.0, 0.0, 0.0, 0.25)
	sb.border_color = Color(UiTheme.BRONZE.r, UiTheme.BRONZE.g, UiTheme.BRONZE.b, 0.5)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(3)
	sb.set_content_margin_all(6)
	return sb


# ---- headless-test accessors ----


func get_offer_count() -> int:
	return _action_metas.size()


func get_action_metas() -> Array[String]:
	return _action_metas


func get_text() -> String:
	return _summary


func is_open() -> bool:
	return visible
