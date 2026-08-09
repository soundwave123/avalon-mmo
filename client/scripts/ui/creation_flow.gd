class_name CreationFlow
extends RefCounted

# T-520/T-716: owns the character-CREATION panel sequence — gender FIRST, then class, then NAME
# (login → gender → class → name → world). Holds all three modals plus their monotonic latches
# (ClassPanelGate/T-320 + GenderPanelGate + the name latch), so main.gd (AT the 1000-line cap) just
# forwards class_kit / player_stats / set_*_result here. The latches only ever flip false → true
# within a session; a reroll deletes the character row and reconnects fresh (a new flow with fresh
# latches).
#
# T-716 also makes this the MOUNT point for the three panels (the CharacterSheetPanel.mount idiom):
# main.gd was at its line cap, so the flow builds and parents its own modals and hands back the two
# nodes main still needs public handles on.

var class_panel: ClassPanel = null  # T-065 (public: main.gd's 1-4 key gate + the pilot state dump)
var gender_panel: GenderPanel = null  # T-520
var name_panel: NamePanel = null  # T-716

var _gender_chosen: bool = false
var _class_locked: bool = false
# T-716: DEFAULT TRUE. "No name step owed" is the safe default — only a bootstrap character whose
# name was picked FOR it (the account name) ever carries name_chosen=false, and a payload that
# doesn't mention naming at all (an older server, a harness, a unit test) must never strand a
# player behind a modal. Mirrors class_locked defaulting to true in on_class_kit.
var _name_chosen: bool = true
# The monotonic half. This flag is what the OTHER two steps get from their gates for free: once the
# set_name ack resolves the step, a later in-flight player_stats carrying the pre-rename
# name_chosen=false must NOT reopen the modal (the T-320/T-597 stale-resend class of bug).
var _name_latched: bool = false


# Build + parent the three creation modals under the HUD and return the wired flow.
static func mount(hud: Node) -> CreationFlow:
	var flow := CreationFlow.new()
	var gender := GenderPanel.new()
	gender.name = "GenderPanel"
	hud.add_child(gender)
	var klass := ClassPanel.new()
	klass.name = "ClassPanel"
	hud.add_child(klass)
	var namer := NamePanel.new()
	namer.name = "NamePanel"
	hud.add_child(namer)
	flow.setup(gender, klass, namer)
	return flow


func setup(gender: GenderPanel, klass: ClassPanel, namer: NamePanel = null) -> void:
	gender_panel = gender
	class_panel = klass
	name_panel = namer


# One dispatcher for every creation modal's action (set_gender / set_class / set_name metas), so
# main.gd wires the whole sequence in a single line.
func connect_actions(dispatch: Callable) -> void:
	for panel: Control in [gender_panel, class_panel, name_panel]:
		if panel != null:
			panel.action_selected.connect(func(meta: String): dispatch.call(meta))


# Each class_kit resend re-evaluates the panels: the gender panel shows until a gender is chosen;
# the class panel shows ONLY once gender is chosen AND class is still unlocked (the creation order).
func on_class_kit(data: Dictionary) -> void:
	var g: Dictionary = GenderPanelGate.next_visible(
		_gender_chosen, str(data.get("gender", "")) != ""
	)
	_gender_chosen = bool(g["chosen"])
	if gender_panel != null:
		gender_panel.visible = bool(g["visible"])
	var c: Dictionary = ClassPanelGate.next_visible(
		_class_locked, bool(data.get("class_locked", true))
	)
	_class_locked = bool(c["locked"])
	if class_panel != null:
		class_panel.visible = GenderPanelGate.class_visible(bool(c["visible"]), _gender_chosen)
	_sync_name_panel()


# T-716: the naming truth rides player_stats, which the server sends at handshake AND on every
# stat repush — including the one the class lock triggers, i.e. exactly when the name step becomes
# due. The latch is monotonic for the same reason the other two are (a stale resend must never
# reopen a resolved step), and `name` seeds the default suggestion (the account name for a
# bootstrap character).
func on_player_stats(data: Dictionary) -> void:
	if not _name_latched:
		_name_chosen = bool(data.get("name_chosen", true))
	if name_panel != null:
		name_panel.set_suggestion(str(data.get("name", "")))
	_sync_name_panel()


# set_gender_result ok: gender persisted — latch it, hide the gender panel, and advance to the class
# panel (unless class is already locked, e.g. a reroll edge that skipped straight past gender).
func on_gender_chosen() -> void:
	_gender_chosen = true
	if gender_panel != null:
		gender_panel.visible = false
	if class_panel != null and not _class_locked:
		class_panel.visible = true
	_sync_name_panel()


# set_class_result ok: latch locked here too — this ack alone must hide the panel for good (the
# follow-up class_kit resend is not guaranteed). Mirrors ClassPanelGate.next_visible(_, true).
func on_class_locked() -> void:
	_class_locked = true
	if class_panel != null:
		class_panel.visible = false
	_sync_name_panel()


# T-716: set_name_result. A success latches and closes the last creation modal (this ack alone —
# the player_stats resend behind it is not guaranteed); a rejection keeps the panel up and hands
# the player the plain-English reason to retry against.
func on_name_result(data: Dictionary) -> void:
	if bool(data.get("ok", false)):
		_name_chosen = true
		_name_latched = true
	elif name_panel != null:
		name_panel.on_result(data)
	_sync_name_panel()


func is_class_locked() -> bool:
	return _class_locked


# T-714 (portal #105): is any part of the one-time creation sequence still owed? The whole
# gender→class→name sequence counts as in-creation until EVERY latch flips — panel visibility alone
# missed the hand-off instants (all modals momentarily hidden), which let the Handbook auto-show
# stack over the incoming panel. Auto-shown onboarding surfaces gate on this, not on what happens
# to be visible this frame. T-716 folds the name step in, so the Handbook and the pushed tutorial
# offer still wait for the WHOLE sequence.
func creation_pending() -> bool:
	return not (_gender_chosen and _class_locked and _name_chosen)


# The name modal is last in the order: it shows only once gender AND class are settled, and only
# while the name step is still owed.
func _sync_name_panel() -> void:
	if name_panel != null:
		name_panel.visible = _gender_chosen and _class_locked and not _name_chosen
