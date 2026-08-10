class_name RecipePanel
extends Control

# T-414 (slice 3): the crafting recipe panel (toggle K, chat-focus-gated like P/O/G/Y). Lists the
# recipes the player has learned — each input→output and a [Craft] action — plus, when a trainer's
# recipe_catalog reply is on hand, the trainer's teachable recipes with a [Learn] action. It sends
# INTENTS ONLY: {type:craft, recipe_id} and {type:learn_recipe, npc_id, recipe_id}. Every id it
# names is resolved server-side (craft_service.gd) against the recipe registry — the client never
# sends an output, a yield, or a coin amount; those all come back server-named in the reply.
#
# Shape mirrors pvp_panel/inventory_panel's CURRENT window idiom EXACTLY (the a32d538 + T-400 4.7
# lessons): a SolidWindow PanelContainer with a self-carried theme, EXPLICIT anchor assignment AFTER
# add_child (never set_anchors_preset — the preset recompute collapses containers on 4.7), and a
# plain RichTextLabel filling the frame (no ScrollContainer — that zero-sizes the RTL). Replies land
# via ReplyRouter (main.gd registers no per-type handler); the panel self-registers what it needs.

signal action_selected(meta: String)  # test/introspection hook mirroring inventory_panel

const _CRAFT_COLOR := Color(0.75, 0.85, 0.95)  # combat-log line colour for a craft/gather outcome
# T-687: the T-677 rare cross-find spike gets its OWN loud colour so it reads distinct from a normal
# gather line (mirrors Rarity's legendary/spike orange, ff8000 — the reward "pop").
const _RARE_COLOR := Color(1.0, 0.5, 0.0)

var _send_fn: Callable = Callable()
var _is_typing_fn: Callable = Callable()  # chat focus gate — K must not fire while typing
var _log = null  # CombatLog (add_entry) — result feedback; may be null (tests / headless)
var _rtl: RichTextLabel = null

var _defs: Dictionary = {}  # recipe_id -> def (accumulated from every recipe_catalog reply)
var _known: Array = []  # recipe_ids the player has learned (server truth, from catalog/learn)
var _trainer_npc: String = ""  # npc_id of the last trainer catalog seen (for [Learn] intents)
var _status: String = ""  # last result line shown in-panel


func _ready() -> void:
	visible = false  # toggled open with K
	# EXPLICIT anchors (never set_anchors_preset — the preset recompute collapses containers on 4.7).
	anchor_left = 1.0
	anchor_top = 0.0
	anchor_right = 1.0
	anchor_bottom = 1.0
	offset_left = -420.0
	offset_right = -16.0
	# T-759: shared safe-zone — MINIMAP_SAFE_TOP (right-side panel clears the always-on minimap),
	# PANEL_SAFE_BOTTOM clears the hotbar (was raw 56/-56 driving through both).
	offset_top = HudSafeZone.MINIMAP_SAFE_TOP
	offset_bottom = HudSafeZone.PANEL_SAFE_BOTTOM
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
# the routed-reply hub the panel self-registers on, and the combat log for result lines.
func setup(send_fn: Callable, is_typing_fn: Callable, reply_router, combat_log) -> void:
	_send_fn = send_fn
	_is_typing_fn = is_typing_fn
	_log = combat_log
	if reply_router != null:
		reply_router.register("recipe_catalog", func(d): receive(d))
		reply_router.register("craft_result", func(d): receive(d))
		reply_router.register("learn_recipe_result", func(d): receive(d))
		reply_router.register("gather_result", func(d): receive(d))


func _input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.is_pressed() or event.is_echo():
		return
	if KeyRegistry.event_code(event as InputEventKey) != KEY_K:
		return
	if UiInputGate.is_text_input_focused(get_viewport()):
		return
	if _is_typing_fn.is_valid() and bool(_is_typing_fn.call()):
		return  # chat holds the keyboard
	visible = not visible
	if visible and _trainer_npc != "":
		_emit({"type": "recipe_catalog", "npc_id": _trainer_npc})  # refresh known-state on reopen
	_render()
	get_viewport().set_input_as_handled()


# Server reply router target. Each reply carries its own `type`; fold it into state + re-render, and
# push a plain-language line to the combat log so the outcome shows even with the panel closed.
func receive(data: Dictionary) -> void:
	match str(data.get("type", "")):
		"recipe_catalog":
			_trainer_npc = str(data.get("npc_id", _trainer_npc))
			for def: Dictionary in data.get("recipes", []):
				_defs[str(def.get("id", ""))] = def
			_known = data.get("known", _known)
			_render()
		"learn_recipe_result":
			if bool(data.get("ok", false)):
				_known = data.get("known", _known)
				_notify("Learned %s." % _name_of(str(data.get("recipe_id", ""))))
			else:
				_notify("Cannot learn: %s" % str(data.get("reason", "error")))
			_render_status(data, "learn")
		"craft_result":
			var out: Dictionary = data.get("output", {})
			if bool(data.get("ok", false)):
				var made := _label_item(str(out.get("item", "")), int(out.get("count", 1)))
				_notify("Crafted %s." % made)
			else:
				_notify("Craft failed: %s" % str(data.get("reason", "error")))
			_render_status(data, "craft")
		"gather_result":
			if bool(data.get("ok", false)):
				var got := _label_item(str(data.get("item_id", "")), int(data.get("count", 1)))
				_notify("Gathered %s." % got)
				# T-677/T-687: the rare cross-find rides along in bonus_item_id/bonus_count (both empty
				# when no proc fired). Surface it as its OWN loud line so the spike actually lands.
				var bonus_id := str(data.get("bonus_item_id", ""))
				var bonus_count := int(data.get("bonus_count", 0))
				if bonus_id != "" and bonus_count > 0:
					_notify("Rare find! %s" % _label_item(bonus_id, bonus_count), _RARE_COLOR)
			else:
				_notify("Cannot gather: %s" % str(data.get("reason", "error")))


func _render_status(data: Dictionary, verb: String) -> void:
	if bool(data.get("ok", false)):
		_status = "%s ok." % verb.capitalize()
	else:
		_status = "%s rejected: %s" % [verb.capitalize(), str(data.get("reason", "error"))]
	_render()


func _on_meta(meta) -> void:
	action_selected.emit(str(meta))  # test/introspection
	var parts := str(meta).split("|")
	if parts.size() < 2:
		return
	if parts[0] == "craft":
		_emit({"type": "craft", "recipe_id": parts[1]})  # server resolves + validates the recipe
	elif parts[0] == "learn" and _trainer_npc != "":
		_emit({"type": "learn_recipe", "npc_id": _trainer_npc, "recipe_id": parts[1]})


func _emit(msg: Dictionary) -> void:
	if _send_fn.is_valid():
		_send_fn.call(msg)


func _notify(text: String, color: Color = _CRAFT_COLOR) -> void:
	if _log != null:
		_log.add_entry(text, color)


# ---- rendering (pure helpers unit-tested without instantiating the Control) ----


func _render() -> void:
	if _rtl == null:
		return
	var lines: Array[String] = ["[b]Recipes  (K)[/b]", ""]
	if _defs.is_empty():
		lines.append("[color=#808080](Talk to a crafting trainer to learn recipes.)[/color]")
	else:
		for recipe_id: String in _defs:
			lines.append(format_recipe(_defs[recipe_id], _known.has(recipe_id), _trainer_npc))
	if _status != "":
		lines.append("")
		lines.append("[i]%s[/i]" % _status)
	_rtl.text = "\n".join(lines)


# One recipe row: name, input→output, and the action link. KNOWN → [Craft] (craftable anywhere the
# server allows); teachable here but not known → [Learn]; otherwise a hint to visit the trainer.
static func format_recipe(def: Dictionary, known: bool, trainer_npc: String) -> String:
	var recipe_id := str(def.get("id", ""))
	var name := str(def.get("name", recipe_id))
	var out: Dictionary = def.get("output", {})
	var made := _label_item(str(out.get("item", "")), int(out.get("count", 1)))
	var recipe := "[b]%s[/b]  %s → %s" % [name, _format_inputs(def.get("inputs", [])), made]
	if known:
		return "%s  [url=craft|%s][color=#88ff88][Craft][/color][/url]" % [recipe, recipe_id]
	if trainer_npc != "" and str(def.get("trainer_id", "")) == trainer_npc:
		var cost := int(def.get("coin_cost", 0))
		var learn := "[url=learn|%s][color=#ffcc66][Learn %dc][/color][/url]" % [recipe_id, cost]
		return "%s  %s" % [recipe, learn]
	return "%s  [color=#808080](learn at %s)[/color]" % [recipe, str(def.get("trainer_id", ""))]


static func _format_inputs(inputs: Array) -> String:
	var parts: Array[String] = []
	for inp: Dictionary in inputs:
		parts.append(_label_item(str(inp.get("item", "")), int(inp.get("count", 1))))
	return " + ".join(parts) if not parts.is_empty() else "(nothing)"


# Human-readable item label from the server item id. Display only — the intent always carries the
# raw server id, never this string. T-687: resolve through the shared ItemNaming humanizer (the same
# source vendor/mail/service panels use) so nothing player-facing leaks an `itm_*`/underscored id;
# the crafting replies carry no server name, so this degrades to a clean title-cased name.
static func _label_item(item_id: String, count: int) -> String:
	var label := ItemNaming.display_name(item_id, "")
	return "%dx %s" % [count, label] if count != 1 else label


func _name_of(recipe_id: String) -> String:
	return str((_defs.get(recipe_id, {}) as Dictionary).get("name", recipe_id))


func get_text() -> String:
	return _rtl.text if _rtl != null else ""


func toggle() -> void:
	visible = not visible
	_render()
