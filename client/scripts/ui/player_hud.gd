class_name PlayerHud
# T-308: the always-on combat HUD, extracted into its own node so main.gd (already at the gdlint
# size cap) only wires data in. Owns and lays out the vitals frame (health + class resource), the
# action bar (kit slots + hotkeys + GCD-estimate sweeps), compass, and selected-target frame, and
# carries the shared medieval Theme so all standing combat surfaces share one treatment.

extends Control

var vitals: VitalsFrame = null
var action_bar: ActionBar = null
var compass: CompassStrip = null
var spellbook: SpellbookPanel = null  # T-422b: ability reference (B) — consumes the same kit
var target_frame: TargetFrame = null  # T-462: authoritative selected-enemy name/level/live HP
var target_of_target_frame: TargetFrame = null  # T-665: selected unit's authoritative target
var objective_tracker: ObjectiveTracker = null  # T-461: always-on right-edge quest tracker
var autoattack_indicator: Label = null  # T-571 (#26): always-visible ON/OFF auto-attack readout


func _ready() -> void:
	# 4.7 regression (HUD-judge find, 2026-07-13): PRESET_FULL_RECT under the HUD CanvasLayer
	# yielded a 0x0 rect, throwing every child (vitals/action bar/compass/cast bar) off-screen.
	# Explicit anchors + zero offsets are engine-proof against the preset's offset recompute.
	anchor_left = 0.0
	anchor_top = 0.0
	anchor_right = 1.0
	anchor_bottom = 1.0
	offset_left = 0.0
	offset_top = 0.0
	offset_right = 0.0
	offset_bottom = 0.0
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	theme = UiTheme.build()  # propagates to the Control children below

	# T-505: conventional MMO unit-frame cluster, top-left. The target frame sits immediately to
	# the right; keeping both server-fed health reads in one glance zone resolved the playtest miss.
	vitals = VitalsFrame.new()
	vitals.name = "VitalsFrame"
	add_child(vitals)
	# 4.7 regression (HUD-judge find, 2026-07-13): set_anchors_preset on an OUT-OF-TREE control
	# left anchors at (0,0), throwing the frame off-screen. Explicit anchors after add_child are
	# engine-proof — never preset-then-offsets on a node that isn't in the tree yet.
	vitals.anchor_left = 0.0
	vitals.anchor_right = 0.0
	vitals.anchor_top = 0.0
	vitals.anchor_bottom = 0.0
	vitals.offset_left = 20.0
	vitals.offset_right = 276.0
	vitals.offset_top = 20.0
	vitals.offset_bottom = 90.0

	# Action bar, center-bottom above the XP belt.
	action_bar = ActionBar.new()
	action_bar.name = "ActionBar"
	add_child(action_bar)

	# Compass strip, top-center.
	compass = CompassStrip.new()
	compass.name = "CompassStrip"
	add_child(compass)

	# T-462/T-505: target status joins the player vitals in the top-left cluster.
	target_frame = TargetFrame.new()
	target_frame.name = "TargetFrame"
	add_child(target_frame)
	target_of_target_frame = TargetFrame.new()
	target_of_target_frame.name = "TargetOfTargetFrame"
	target_of_target_frame.configure_compact()
	add_child(target_of_target_frame)

	# T-571 (#26): a small always-on readout under the vitals frame so re-pressing the auto-attack
	# key is an informed choice, not a silent footgun (the bug was: no ON/OFF feedback at all).
	autoattack_indicator = Label.new()
	autoattack_indicator.name = "AutoAttackIndicator"
	add_child(autoattack_indicator)
	autoattack_indicator.anchor_left = 0.0
	autoattack_indicator.anchor_right = 0.0
	autoattack_indicator.anchor_top = 0.0
	autoattack_indicator.anchor_bottom = 0.0
	autoattack_indicator.offset_left = 20.0
	autoattack_indicator.offset_right = 276.0
	autoattack_indicator.offset_top = 94.0
	autoattack_indicator.offset_bottom = 116.0
	set_autoattack(false)

	# T-422b: the spellbook (B). Self-anchoring centered window; main wires its chat-typing gate.
	spellbook = SpellbookPanel.new()
	spellbook.name = "SpellbookPanel"
	add_child(spellbook)

	# T-461: always-on objective tracker, top-right. Non-interactive; main wires it to the quest
	# log's `objectives_changed` signal so it renders the SAME active quest state.
	objective_tracker = ObjectiveTracker.new()
	objective_tracker.name = "ObjectiveTracker"
	add_child(objective_tracker)


func set_kit(kit: Array) -> void:
	if action_bar != null:
		action_bar.set_kit(kit)
	if spellbook != null:  # T-422b: the reference view lists the same kit with rich tooltips
		spellbook.set_kit(kit)


func update_vitals(hp: int, max_hp: int, res_kind: String, res: int, res_max: int) -> void:
	if vitals == null:
		return
	vitals.update_health(hp, max_hp)
	vitals.update_resource(res_kind, res, res_max)
	if spellbook != null:  # T-422b: name the tooltip cost line's resource correctly
		spellbook.set_resource_kind(res_kind)
	if action_bar != null:
		# T-464: same resource name for the action-bar hover tooltip.
		# T-731: and the LEVEL too — the bar dims slots it can't currently pay for, so this snapshot
		# feed is what makes rage build/decay and mana regen read on the buttons live.
		action_bar.set_resource_state(res_kind, res, res_max)


func on_ability_pressed(slot: int) -> void:
	if action_bar != null:
		action_bar.trigger_slot(slot)


func update_heading(yaw_rad: float) -> void:
	if compass != null:
		compass.update_heading(yaw_rad)


# T-710/T-711: the guided-onboarding compass pip — OnboardingController aims it at the tutorial
# giver's relative bearing while guidance is active; distance never gates it.
func set_compass_pip(rel_deg: float) -> void:
	if compass != null:
		compass.set_pip(rel_deg)


func clear_compass_pip() -> void:
	if compass != null:
		compass.clear_pip()


# Join the selected id to the COMPLETE reconstructed positions snapshot. Returns false only when a
# selected id vanished, so Main can clear selection/autoattack together. Every display value below
# came from the server broadcast; the client never supplies level, identity, or health.
func update_target(target_id: int, viewer_id: int, data: Dictionary) -> bool:
	if target_frame == null:
		return target_id == -1
	if target_id == -1:
		clear_target()
		return true
	var viewer := {"peer_id": viewer_id}
	var selected := _find_unit(target_id, data)
	if selected.is_empty():
		clear_target()
		return false
	_bind_snapshot(target_frame, selected, viewer)
	_update_target_of_target(selected, viewer, data)
	return true


func _find_unit(target_id: int, data: Dictionary) -> Dictionary:
	for player: Dictionary in data.get("players", []):
		if int(player.get("peer_id", -1)) == target_id:
			return {"row": player, "is_mob": false}
	for mob: Dictionary in data.get("mobs", []):
		if int(mob.get("mob_id", -1)) == target_id:
			return {"row": mob, "is_mob": true}
	return {}


func _bind_snapshot(frame: TargetFrame, unit: Dictionary, viewer: Dictionary) -> void:
	var row: Dictionary = unit["row"]
	var is_mob := bool(unit["is_mob"])
	var unit_name := str(row.get("name" if is_mob else "username", ""))
	if unit_name == "":
		unit_name = (
			str(row.get("kind", "mob")).trim_prefix("mob_").capitalize() if is_mob else "Player"
		)
	var facts := (
		{"is_mob": true, "hostile": bool(row.get("hostile", true))}
		if is_mob
		else {
			"peer_id": int(row.get("peer_id", -1)),
			"party_id": int(row.get("party_id", 0)),
			"pvp_flag": bool(row.get("pvp_flag", false)),
		}
	)
	frame.bind_target(
		unit_name,
		int(row.get("hp", 0)),
		int(row.get("max_hp", 0)),
		Relationship.plate_color(Relationship.of(viewer, facts)),
		int(row.get("level", 0))
	)


func _update_target_of_target(selected: Dictionary, viewer: Dictionary, data: Dictionary) -> void:
	if target_of_target_frame == null:
		return
	var row: Dictionary = selected["row"]
	var target_id := int(row.get("target_id", -1))
	var target := _find_unit(target_id, data) if target_id != -1 else {}
	if target.is_empty():
		target_of_target_frame.clear()
		return
	_bind_snapshot(target_of_target_frame, target, viewer)


func clear_target() -> void:
	if target_frame != null:
		target_frame.clear()
	if target_of_target_frame != null:
		target_of_target_frame.clear()


# T-571 (#26): main.gd is the one owner of the `_autoattack` bool — this only renders whatever
# state it's told, via the pure AutoAttackIndicatorState mapping (unit-testable independently).
func set_autoattack(active: bool) -> void:
	if autoattack_indicator == null:
		return
	autoattack_indicator.text = AutoAttackIndicatorState.label_text(active)
	autoattack_indicator.add_theme_color_override(
		"font_color", AutoAttackIndicatorState.color(active)
	)
