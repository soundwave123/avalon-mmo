class_name OnboardingController
# T-376: keeps the onboarding wiring OUT of main.gd (at the gdlint 1000-line cap). A Node under the
# HUD that owns the controls handbook card, listens for the F1 help key itself, watches the class
# panel, and decides the once-per-user first-entry auto-show — never over the class panel, never
# again once seen (persisted per-username via OnboardingPrefs). main.gd just adds it, feeds the
# token, and folds card.visible into its Esc-close precedence.
#
# T-710/T-711: also the client half of the guided first session — it routes the server-pushed
# tutorial offer into the QuestOfferPanel (deferred until creation resolves), injects the
# pre-accept "find Drillmaster Hale" tracker line, aims the compass guidance pip at the giver
# (independent of marker distance), and runs the OSRS-style stall detector on the fire-once hint
# chassis. T-714: every auto-shown surface gates on the WHOLE creation sequence (latches, not
# panel visibility) and Esc closes the topmost surface during any illegal overlap.

extends Node

const ControlsCard = preload("res://scripts/ui/controls_card.gd")
const ControlsReference = preload("res://scripts/ui/controls_reference.gd")
const OnboardingPrefs = preload("res://scripts/ui/onboarding_prefs.gd")
const HintReference = preload("res://scripts/ui/hint_reference.gd")
const HintToast = preload("res://scripts/ui/hint_toast.gd")

# T-710/T-711: the tutorial giver's npc_id — the guidance pip anchor. The SERVER owns what he
# offers (the pushed talk_result); the client only needs to know which indicator row to aim at.
const TUTORIAL_GIVER := "npc_drillmaster"
# T-713: the tutorial's LAST quest — turning it in IS graduation (mirrors the master's
# onboarding_store.GRADUATION_QUEST, which is what actually flips the account flag).
const GRADUATION_QUEST := "q_tut_03"

var card: ControlsCard = null
var toast: HintToast = null  # T-426: the one-line contextual hint strip
var smoke_mode := false  # net-smoke / harness runs never pop the card
var _class_panel: Control = null
var _gender_panel: Control = null  # T-558: the creation gender modal — also suppresses the handbook
var _username: String = ""
var _shown := false  # one auto-show per session guard
var _session_hints: Dictionary = {}  # hint id -> true, fired this session (saves file re-reads)
var _return_reason_state: Dictionary = {}  # T-483: read-only server appointment view
# T-550: ACCOUNT onboarding state from the handshake — server-authoritative, shared across alts.
var _tutorial_done := false  # account already graduated the tutorial (an alt = don't force-feed)
var _account_hints_seen: Dictionary = {}  # hint id -> true, seen by the ACCOUNT (any char/device)
var _report_hint_seen: Callable = Callable()  # persist a sighting at account scope (server-side)
# T-714: the CreationFlow — the latch truth for "is the creation sequence still owed?" (visibility
# alone missed the gender→class hand-off instant, portal #105).
var _creation_flow = null
# T-710: the QuestOfferPanel, captured on the first routed talk_result; a result that arrives while
# creation is unresolved is HELD here (latest wins) and re-played the moment creation completes.
var _offer_panel: Control = null
var _deferred_talk: Dictionary = {}
# T-710/T-711 guide seams (bind_guide): the HUD (tracker + compass pip) and two live providers.
var _player_hud = null  # PlayerHud
var _player_provider: Callable = Callable()  # () -> LocalPlayer (position + yaw), null pre-spawn
var _combat_state: Callable = Callable()  # () -> [autoattack_on: bool, target_id: int]
var _world_ready := false
var _control_started_msec: int = -1  # armed on the first frame with world ready AND creation done
var _quest_seen := false  # latched on the first non-empty objectives model this session
var _tracker_model: Array = []  # the quest log's live active_tracker_model
var _objectives_sig := ""  # change detector feeding the rule-2 untouched clock
var _objectives_touched_msec: int = -1
var _failed_casts := 0  # T-711 rule 3: rejected ability presses this session (monotonic is fine)
var _giver_pos := Vector3.INF  # tutorial giver's world anchor, from npc_indicators (x, _, y)
var _line_shown := false  # last rendered state of the injected pre-accept tracker line


# Parent under the HUD (so _input fires), build the card + hint strip + the "?" affordance, and
# watch the class panel. `creation_flow` (T-714) supplies the whole-sequence in-creation truth.
func setup(
	hud: Node, class_panel: Control, gender_panel: Control = null, creation_flow = null
) -> void:
	_creation_flow = creation_flow
	hud.add_child(self)
	card = ControlsCard.new()
	card.name = "ControlsCard"
	hud.add_child(card)
	card.hints_toggled.connect(set_hints_enabled)  # T-426: the handbook's "Show hints" switch
	toast = HintToast.new()
	toast.name = "HintToast"
	hud.add_child(toast)
	hud.add_child(_build_help_button())  # T-426: the always-there "?" (GameFlow "no manual needed")
	_class_panel = class_panel
	_gender_panel = gender_panel  # T-558
	# T-558: the permanent one-time choices (gender FIRST, then class) own the screen at spawn — the
	# handbook must not stack behind them. A fresh character resolves both modals first; the handbook
	# auto-shows once either modal closing re-evaluates the gate (or immediately for a returning,
	# locked character via maybe_show, whose modals never appear).
	if class_panel != null:
		class_panel.visibility_changed.connect(maybe_show)
	if gender_panel != null:
		gender_panel.visibility_changed.connect(maybe_show)
	# T-716: the NAME modal is now the LAST creation step, so it — not the class panel — is what
	# closes last on a fresh account. Without this the queue would never drain: the handbook and the
	# held tutorial offer both wait on maybe_show being re-run by a modal closing.
	if creation_flow != null and creation_flow.name_panel != null:
		creation_flow.name_panel.visibility_changed.connect(maybe_show)


# Once the session is known: decode the per-user onboarding key from the token's JWT `sub`, and
# record whether this is a harness run (which must never pop the card).
func begin(token: String, smoke: bool) -> void:
	_username = OnboardingPrefs.username_from_token(token)
	smoke_mode = smoke
	if card != null:  # T-426: the handbook switch reflects this user's persisted setting
		card.set_hints_checked(OnboardingPrefs.hints_enabled(_username))


# T-550: fold the server's ACCOUNT onboarding state in once the handshake lands. `tutorial_done`
# graduates the account (an alt is not force-fed the guided chain); `hints_seen` seeds the fire-once
# memory at ACCOUNT scope so a fresh alt — even on a new device — never re-nags a hint the account
# already saw. `report_hint_seen` is the send seam that persists a new sighting account-wide.
func begin_account(state: Dictionary, report_hint_seen: Callable = Callable()) -> void:
	_tutorial_done = bool(state.get("tutorial_done", false))
	_account_hints_seen.clear()
	for id: Variant in state.get("hints_seen", []):
		_account_hints_seen[str(id)] = true
	_report_hint_seen = report_hint_seen


# T-550: has the ACCOUNT already graduated the tutorial? main.gd gates the unprompted first-spawn
# guided nudge on this — an alt plays instead of being walked through the newbie chain again.
func tutorial_graduated() -> bool:
	return _tutorial_done


# T-710/T-711: the guided-onboarding seams — the HUD (objective tracker + compass pip) and two live
# providers main.gd owns. Optional: harnesses/tests that never bind them keep the guide inert.
func bind_guide(player_hud, player_provider: Callable, combat_state: Callable) -> void:
	_player_hud = player_hud
	_player_provider = player_provider
	_combat_state = combat_state


# World entry (never called on smoke/harness runs — main returns before it). T-426/T-550: only a
# fresh, non-graduated account gets the unprompted move nudge; T-711: this also opens the window
# for the stall-detector control clock, armed in _process once creation resolves.
func on_world_ready() -> void:
	_world_ready = true
	if not _tutorial_done:
		hint("move")


# T-519/T-710/T-714: the ONE talk_result route into the QuestOfferPanel. While the creation
# sequence is unresolved the result is HELD (latest wins) and re-played by maybe_show the moment
# creation completes, so the server's first-entry tutorial offer can never stack over the
# gender/class modals. The offer prompt also joins the no-two-onboarding-panels rule: its close
# re-evaluates the gate, which is what lets the handbook show only AFTER the offer is resolved.
func route_talk_result(panel: Control, data: Dictionary) -> void:
	if not bool(data.get("ok", false)):
		print("[client] talk: %s" % str(data.get("reason", "")))
	if _offer_panel == null and panel != null:
		_offer_panel = panel
		panel.visibility_changed.connect(maybe_show)
	if _creation_blocks():
		_deferred_talk = data
		return
	if panel != null:
		panel.call("handle_talk_result", data)


# Auto-show the handbook exactly once for a first-time user — but never while the creation
# sequence is unresolved, never over the quest prompt, and never for someone who has already seen
# it. Safe to call repeatedly (idempotent once shown).
func maybe_show() -> void:
	if card == null or smoke_mode:
		return
	# T-558/T-714: the WHOLE creation sequence (latches AND visible modals) suppresses every
	# auto-shown surface. Each modal's visibility_changed re-runs this, so the queue drains the
	# moment creation completes.
	if _creation_blocks():
		return
	# T-710: a held tutorial offer outranks the handbook — strictly serial (gender → class →
	# offer → handbook); the offer panel's own close re-runs this gate for the handbook's turn.
	if _flush_deferred_talk():
		return
	if _offer_panel != null and _offer_panel.visible:
		return
	if _shown:
		return
	if not OnboardingPrefs.should_autoshow_controls(OnboardingPrefs.has_seen_controls(_username)):
		return
	_shown = true
	OnboardingPrefs.mark_controls_seen(_username)  # seen once = never nag on return
	card.open(true)  # T-717: the auto-shown first impression is the 3-line card, not the full table


# T-558: pure gate — is either permanent creation modal (gender or class) currently on screen? The
# handbook stays suppressed while this is true so no two onboarding panels are ever visible at once.
static func creation_modal_open(gender_panel: Control, class_panel: Control) -> bool:
	if gender_panel != null and gender_panel.visible:
		return true
	if class_panel != null and class_panel.visible:
		return true
	return false


# T-714 defense: during an illegal overlap (a creation modal under an auto-shown onboarding
# surface), Esc closes the TOPMOST surface — the handbook card first (it draws last), then the
# quest prompt. "" = no overlap, Esc keeps its normal main.gd precedence. Pure for headless tests.
static func escape_closes(modal_open: bool, card_visible: bool, offer_visible: bool) -> String:
	if not modal_open:
		return ""
	if card_visible:
		return "card"
	if offer_visible:
		return "offer"
	return ""


# T-714: in-creation truth = the flow's latches (the whole gender→class sequence) OR a visible
# creation modal. The latches are what close portal #105's transition instant.
func _creation_blocks() -> bool:
	if _creation_flow != null and _creation_flow.creation_pending():
		return true
	return creation_modal_open(_gender_panel, _class_panel)


# T-710: re-play the talk_result held during creation. True = the offer panel opened (caller stops
# before the handbook). A held result with nothing to show falls through to the handbook normally.
func _flush_deferred_talk() -> bool:
	if _deferred_talk.is_empty() or _offer_panel == null:
		return false
	var data: Dictionary = _deferred_talk
	_deferred_talk = {}
	return bool(_offer_panel.call("handle_talk_result", data))


# T-426: fire a contextual hint by id — the ONE entry point main.gd's seams call. Fires at most
# once per user EVER (persisted) and once per session (cheap guard); the "hide hints" setting
# suppresses all of them; harness runs never toast. Safe to call every frame from a hot seam.
func hint(id: String, override_text: String = "") -> void:
	if toast == null or smoke_mode or _session_hints.get(id, false):
		return
	var text := override_text if override_text != "" else HintReference.text_for(id)
	if text == "":
		return
	# T-550: fire-once is now ACCOUNT-authoritative (server-fed hints_seen) with the per-device
	# user://onboarding.cfg as the offline/degraded fallback. Either "already seen" suppresses it.
	var seen := OnboardingPrefs.combined_seen(
		bool(_account_hints_seen.get(id, false)), OnboardingPrefs.has_seen_hint(_username, id)
	)
	if not OnboardingPrefs.should_show_hint(seen, OnboardingPrefs.hints_enabled(_username)):
		return
	_session_hints[id] = true
	_account_hints_seen[id] = true  # T-550: also suppress this account's other characters
	OnboardingPrefs.mark_hint_seen(_username, id)  # device cache (offline fallback)
	if _report_hint_seen.is_valid():  # T-550: persist at account scope, server-authoritative
		_report_hint_seen.call({"type": "onboarding_hint_seen", "hint_id": id})
	toast.show_hint(text)


# T-713: the GRADUATION beat. Turning in q_tut_03 is the moment the tutorial ends, and until now
# nothing in the first 15 minutes pointed at anything beyond the training yard. Hale's own dialog
# carries the long-term stakes (the quest's turnin_text — south to Highkeep, plus the Hollowing
# tease); this half surfaces the OTHER players: the LFG board (T-625) exists and was never once
# mentioned, and relatedness independently predicts return intention (Ryan 2006, Study 4).
#
# Deliberately a NON-MODAL toast on the fire-once hint chassis, so it is account-persisted (an alt
# is never re-nagged), respects the hints toggle, never fires on a harness run, and cannot stack
# over the turn-in dialog the way an auto-shown panel would. It names the keybind rather than
# opening the panel — a surface the player chose to open is worth more than one thrown at them.
func on_turn_in(data: Dictionary) -> void:
	if not bool(data.get("ok", false)):
		return
	if str(data.get("quest_id", "")) != GRADUATION_QUEST:
		return
	hint("lfg_graduation")


# T-666 (portal #85): a brand-new character's first-ever resource-starved ability press reads as
# "the game is broken" (the combat log deliberately records outcomes, not denials — T-027/T-402).
# Route ONLY the insufficient_resource rejection through the standard fire-once hint path (account-
# persisted, session-guarded, hints-toggle aware — a veteran never sees it again); every other
# rejection reason stays visually silent here — but T-711 rule 3 COUNTS it: auto-attack OFF + a
# live target + repeated failed casts surfaces the same fire-once resource hint regardless of the
# rejection label (belt-and-braces for the #85 silent wall; a no-op once the hint ever fired).
func on_ability_rejected(msg: Dictionary, resource_kind: String) -> void:
	_failed_casts += 1
	if str(msg.get("reason", "")) == "insufficient_resource":
		hint("resource", HintReference.resource_hint(resource_kind))
		return
	if _tutorial_done or not _combat_state.is_valid():
		return
	var state: Array = _combat_state.call()
	if OnboardingStall.resource_wall_hit(true, bool(state[0]), int(state[1]), _failed_casts):
		hint("resource", HintReference.resource_hint(resource_kind))


# T-461/T-710/T-711: the quest log's live objectives view-model. The controller injects the
# pre-accept tutorial line, renders the HUD tracker (main.gd used to render it directly), and
# timestamps objective movement for the rule-2 stall clock.
func on_objectives(model: Array) -> void:
	if not model.is_empty():
		_quest_seen = true  # acting permanently disarms rule 1 and retires the tutorial line
	var sig := JSON.stringify(model)
	if sig != _objectives_sig:
		_objectives_sig = sig
		_objectives_touched_msec = Time.get_ticks_msec()
	_tracker_model = model
	_render_tracker()


# T-426 (first-marker hint) + T-710/T-711: the indicator payload also anchors the tutorial giver's
# world position for the guidance pip — marker DISTANCE therefore never gates the pip. Server
# (x, y) ground maps to Godot (x, _, y), same as npc_world_layer.
func on_npc_indicators(npcs: Array) -> void:
	if npcs.is_empty():
		return
	hint("quest")
	for row: Dictionary in npcs:
		if str(row.get("npc_id", "")) == TUTORIAL_GIVER:
			_giver_pos = Vector3(float(row.get("x", 0.0)), 0.0, float(row.get("y", 0.0)))
			return


# T-710: the persistent pre-accept tracker line — a synthetic "report to Drillmaster Hale" row
# above the (empty) active set until the account's first quest is accepted. Pure for headless tests.
static func guided_tracker_model(model: Array, show_tutorial_line: bool) -> Array:
	if not show_tutorial_line:
		return model
	var line := {
		"title": "Tutorial",
		"objectives": [{"desc": "Speak with Drillmaster Hale", "current": 0, "required": 1}],
	}
	return [line] + model


# T-710/T-711: the per-frame guide tick — arms the control clock the first frame creation is
# resolved, keeps the tracker line + compass pip honest, and escalates the stall hints. Every
# branch is cheap (hint() is safe to call hot; the pip setter no-ops on an unchanged offset).
func _process(_delta: float) -> void:
	if smoke_mode or not _world_ready or _tutorial_done:
		_update_pip(false)
		return
	if _creation_blocks():
		return  # the clock starts at CONTROL, not at spawn-behind-modals (T-711 "60s after control")
	var now := Time.get_ticks_msec()
	if _control_started_msec < 0:
		_control_started_msec = now
		_objectives_touched_msec = now
	if _line_shown != _tutorial_line_active():
		_render_tracker()
	_update_pip(not _quest_seen)
	_tick_stalls(now)


func _render_tracker() -> void:
	if _player_hud == null or _player_hud.objective_tracker == null:
		return
	_line_shown = _tutorial_line_active()
	_player_hud.objective_tracker.render(guided_tracker_model(_tracker_model, _line_shown))


# The pre-accept tutorial line shows only while guidance is live: fresh account, in control, no
# quest ever accepted this session. (_quest_seen also retires it right after graduation turn-in —
# the session that just graduated never sees it reappear even though _tutorial_done is stale.)
func _tutorial_line_active() -> bool:
	return _world_ready and not _tutorial_done and not _quest_seen and not smoke_mode


# T-710/T-711: aim the compass pip at the tutorial giver while guidance is active; clear otherwise.
func _update_pip(active: bool) -> void:
	if _player_hud == null:
		return
	var lp = _player_provider.call() if _player_provider.is_valid() else null
	if not active or lp == null or not _giver_pos.is_finite():
		_player_hud.clear_compass_pip()
		return
	_player_hud.set_compass_pip(
		CompassStrip.relative_bearing_deg(lp.rotation.y, lp.global_position, _giver_pos)
	)


# T-711: the escalation ladder (pure decisions in OnboardingStall; fire-once via the hint chassis).
func _tick_stalls(now: int) -> void:
	var pre_grad := not _tutorial_done
	var control_secs := float(now - _control_started_msec) / 1000.0
	if OnboardingStall.find_giver_due(pre_grad, _quest_seen, control_secs):
		hint("stall_find_hale")
	var untouched_secs := float(now - _objectives_touched_msec) / 1000.0
	var has_active := not _tracker_model.is_empty()
	if OnboardingStall.objective_restate_due(pre_grad, has_active, untouched_secs):
		hint("stall_objective", OnboardingStall.restate_text(_tracker_model))


# T-483: accept only the server-fed daily view; duplicate it so formatting can never mutate the
# network payload shared with another HUD consumer. A later bounty browse may enrich login state.
func set_return_reason_state(daily: Dictionary) -> void:
	if bool(daily.get("ok", false)):
		var next := _return_reason_state.duplicate(true)
		next.merge(daily.duplicate(true), true)
		_return_reason_state = next


# The first Esc/end-session menu is the gentle final tutorial beat. It uses the same persisted
# fire-once and user suppression path as every T-426 hint, and is a no-op without valid state.
func show_return_reason() -> void:
	hint("return_reason", HintReference.return_reason_text(_return_reason_state))


# T-426: the handbook's "Show hints" switch — persists per user; OFF also clears the live strip.
func set_hints_enabled(enabled: bool) -> void:
	OnboardingPrefs.set_hints_enabled(_username, enabled)
	if not enabled and toast != null:
		while toast.is_showing():
			toast.dismiss()


func hints_enabled() -> bool:
	return OnboardingPrefs.hints_enabled(_username)


# T-426: a small always-visible "?" beside the compass — the discoverable route into the handbook
# for a player who never learns F1. Explicit anchors (the 4.7 HUD-blank trap): pinned top-right.
# T-532: de-boxed to the T-396/T-460 idle-HUD idiom — no opaque StyleBoxFlat fill and no border on
# any idle state; legibility lives in the glyph (gold-bright, outlined + shadowed like the compass
# cardinal), not a panel. A faint hover fill is the sole chrome, only while the mouse is on it.
func _build_help_button() -> Button:
	var b := Button.new()
	b.name = "HelpAffordance"
	b.text = "?"
	b.tooltip_text = "The Adventurer's Handbook (F1)"
	# T-518: mouse-only — a keyboard-focusable "?" makes SPACE (Godot's default ui_accept) fire its
	# pressed handler and pop the handbook, which collides with SPACE=jump. Same rule as the chat
	# tabs (chat_panel.gd): HUD affordances never steal keyboard focus from movement.
	b.focus_mode = Control.FOCUS_NONE
	b.anchor_left = 1.0
	b.anchor_right = 1.0
	b.anchor_top = 0.0
	b.anchor_bottom = 0.0
	b.offset_left = -36.0
	b.offset_right = -10.0
	b.offset_top = 10.0
	b.offset_bottom = 36.0
	# T-532: strip the opaque gray box off every idle state (normal/pressed/disabled/focus) so the
	# corner reads as an outlined HUD hint, not a default button. Only hover ramps a faint backdrop
	# toward the T-396 ~65% weight — the sole chrome, and only while the mouse is on it.
	b.add_theme_stylebox_override("normal", UiTheme.no_box_stylebox(4.0))
	b.add_theme_stylebox_override("pressed", UiTheme.no_box_stylebox(4.0))
	b.add_theme_stylebox_override("disabled", UiTheme.no_box_stylebox(4.0))
	b.add_theme_stylebox_override("focus", UiTheme.no_box_stylebox(4.0))
	var hover := StyleBoxFlat.new()
	hover.bg_color = Color(0.0, 0.0, 0.0, 0.65)
	hover.set_corner_radius_all(4)
	hover.set_content_margin_all(4)
	b.add_theme_stylebox_override("hover", hover)
	# T-532: legibility from the TEXT — the compass-cardinal treatment (gold-bright, outlined +
	# shadowed) so the "?" reads over bright sky/snow without a filled box behind it.
	b.add_theme_color_override("font_color", UiTheme.GOLD_BRIGHT)
	b.add_theme_color_override("font_hover_color", Color(1.0, 1.0, 1.0, 1.0))
	b.add_theme_color_override("font_pressed_color", UiTheme.GOLD_BRIGHT)
	b.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	b.add_theme_constant_override("outline_size", 3)
	b.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.7))
	b.add_theme_font_size_override("font_size", 20)
	b.pressed.connect(func(): card.toggle())
	return b


# F1 (ControlsReference.HELP_KEYCODE) re-opens/closes the handbook any time. Own _input so main.gd
# stays lean; chat-typing focus is handled upstream (main eats keys while the chat line is active).
# T-714 defense: if an onboarding surface ever DOES overlap a creation modal (the bug class this
# ticket fixes at the gate), Esc closes the topmost surface here — deeper in the tree than main's
# Esc precedence, so the overlap is always escapable (portal #105: "Esc closed neither").
func _input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.is_pressed() or event.is_echo():
		return
	if UiInputGate.is_text_input_focused(get_viewport()):
		return
	var key := event as InputEventKey
	if key.keycode == ControlsReference.HELP_KEYCODE and card != null:
		card.toggle()
		get_viewport().set_input_as_handled()
	elif key.keycode == KEY_ESCAPE:
		match escape_closes(
			creation_modal_open(_gender_panel, _class_panel),
			card != null and card.visible,
			_offer_panel != null and _offer_panel.visible
		):
			"card":
				card.close_card()
				get_viewport().set_input_as_handled()
			"offer":
				_offer_panel.call("close_panel")
				get_viewport().set_input_as_handled()
