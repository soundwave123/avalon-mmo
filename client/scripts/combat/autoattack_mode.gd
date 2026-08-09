class_name AutoAttackMode
extends RefCounted
# T-729: auto-attack is a STICKY MODE, not a per-target toggle. Before, the toggle refused to arm
# without a target and EVERY exit from combat (target death, target switch, your own death,
# Esc-deselect) called `_set_autoattack(false)` — a re-press per mob. Owner-directed (playtest
# 2026-08-08): once on, it stays on; selecting any future hostile resumes swinging by itself.
#
# It is NOT an aim-bot: it never acquires a target. With no target, a dead one, or a death-locked
# client it goes IDLE, which means it sends NOTHING — not "sends and gets refused". That also
# closes T-721's corpse-hammering follow-up (the T-057 timer kept casting Strike at a corpse until
# respawn, ~94 `target_is_dead` rejects/session): one gate on "is my selection still ALIVE?"
# answers both halves. T-721's arbitration is untouched — auto-swings go out as a plain
# `request_use_ability(1)` that AbilityCastQueue never treats as the queued manual press, and
# idling strictly HELPS it (a corpse no longer burns GCD windows the player wanted).
#
# The decision half (`decide`/`is_swingable`) is pure and unit-tested; the driver half reads
# Main's fields lazily (the AbilityCastQueue pattern) so main.gd stays under its 1000-line cap.

enum Tick {
	STOP,  # mode is off — halt the swing timer
	IDLE,  # mode is ARMED but has nothing alive to hit: send nothing, keep waiting
	SWING,  # a live selection — Strike
	DROP_TARGET,  # the selection vanished from the world entirely: clear it (mode survives)
}

const STRIKE_ABILITY_ID := 1  # T-057: the auto-attack swing


# PURE: the whole swing decision for one timer tick.
static func decide(enabled: bool, target_id: int, row: Dictionary, input_locked: bool) -> Tick:
	if not enabled:
		return Tick.STOP
	if input_locked or target_id == -1:
		return Tick.IDLE  # dead/fading client, or nothing selected — stay armed, stay silent
	if row.is_empty():
		return Tick.DROP_TARGET
	return Tick.SWING if is_swingable(row) else Tick.IDLE


# PURE: may auto-attack swing at this server-fed row right now? Present and ALIVE — that is the
# whole gate, and deliberately so. It does NOT read the T-665 `hostile` disposition: the server
# broadcasts `hostile:false` for dummies and retaliate-only units, and the Training Dummy / Straw
# Sparring Effigy exist precisely to be auto-attacked (T-721 built its rage on one). Disposition
# is a nameplate color, not permission; legality stays the server's call, exactly as before.
static func is_swingable(row: Dictionary) -> bool:
	return not row.is_empty() and int(row.get("hp", 1)) > 0


# One swing tick, driven by Main's `_attack_timer`.
static func tick(main: Node) -> void:
	var target_id := int(main.get("_target_id"))
	var action := decide(bool(main.get("_autoattack")), target_id, target_row(main), locked(main))
	match action:
		Tick.STOP:
			var timer = main.get("_attack_timer")
			if timer != null:
				timer.stop()
		Tick.DROP_TARGET:
			main.call("_clear_target")  # re-renders the indicator itself
			return
		Tick.SWING:
			var net = main.get("_net")
			if net != null:
				net.request_use_ability(STRIKE_ABILITY_ID, target_id)
	render(main)


# The HUD readout stays honest about all three states: OFF, ON-and-swinging, ON-but-idle.
static func render(main: Node) -> void:
	var hud = main.get("player_hud")
	if hud != null:
		hud.set_autoattack(bool(main.get("_autoattack")), is_swingable(target_row(main)))


# The server-fed row for the current selection ({} = nothing selected / not in the snapshot).
# Read the same way main.gd's TAB path and TargetSelection read it — RemoteEntitiesLayer is at its
# public-method cap, so this scans the rows rather than adding another accessor to it.
static func target_row(main: Node) -> Dictionary:
	var layer = main.get("remote_entities")
	var target_id := int(main.get("_target_id"))
	if layer == null or target_id == -1:
		return {}
	var entities: Dictionary = layer.get("_entities")
	for id: String in entities:
		var row: Dictionary = entities[id]
		if int(row.get("target_id", -1)) == target_id:
			return row
	return {}


static func locked(main: Node) -> bool:
	var death = main.get("death_presentation")
	return death != null and death.is_input_disabled()
