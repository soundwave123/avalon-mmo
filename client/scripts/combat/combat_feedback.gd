class_name CombatFeedback
# T-027: Orchestrator — receives raw server events, dispatches to UI subsystems.
#
# Subsystems:
#   - CombatEventParser: parses raw dicts → typed signals
#   - FloatingTextPool: pooled damage/heal labels above entities
#   - HealthBar: per-entity HP bars
#   - CombatLog: append-style text log (200-line cap)
#
# Usage: call `process_event(data)` for each raw server broadcast dict.
# In a real client, CombatFeedback would be a child of the main scene and
# would receive events from the network layer.

extends Node

const _COLOR_DAMAGE: Color = Color(1.0, 0.2, 0.2)
const _COLOR_MISS: Color = Color(0.5, 0.5, 0.5)
const _COLOR_HEAL: Color = Color(0.2, 1.0, 0.2)
const _COLOR_SYSTEM: Color = Color(1.0, 1.0, 1.0)
const _COLOR_ERROR: Color = Color(1.0, 0.45, 0.3)  # T-402: out-of-range feedback line

# T-402 item 3: minimum ms between out_of_range log lines — the attack key repeats ~1.6s but a
# mashed hotkey rejects every press; the log surfaces the state, not every attempt (WoW idiom).
const REJECT_LOG_THROTTLE_MS: int = 2000

var local_player_id: int = -1  # set by the client; only flash when WE take damage
var hud_overlays_enabled: bool = true  # T-057: false in 3D (3D health bars + log replace these)
var show_tick: bool = false  # T-308: raw [tick=NNN] prefix is off; AVALON_DEBUG_TICKS=1 re-enables

var _last_reject_log_ms: int = -REJECT_LOG_THROTTLE_MS  # T-402: first rejection always logs

var _parser: CombatEventParser
var _floating_pool: FloatingTextPool
var _combat_log: CombatLog
var _cast_bar: CastBar
var _screen_flash: ScreenFlash
var _health_bars: Dictionary = {}  # entity_id -> HealthBar


func _ready() -> void:
	show_tick = OS.get_environment("AVALON_DEBUG_TICKS") == "1"  # T-308: debug-only tick ids
	_parser = CombatEventParser.new()

	_floating_pool = FloatingTextPool.new()
	_floating_pool.name = "FloatingTextPool"
	add_child(_floating_pool)

	_combat_log = CombatLog.new()
	_combat_log.name = "CombatLog"
	add_child(_combat_log)
	# T-607: no standalone CombatLogPanel here anymore — it used to render as a second on-screen
	# surface overlapping ChatPanel's rect. main.gd now binds `_combat_log` directly into ChatPanel
	# (chat_panel.bind_combat_log) so combat lines ride the chat window's single fade/wake timer.

	_cast_bar = CastBar.new()
	_cast_bar.name = "CastBar"
	add_child(_cast_bar)

	_screen_flash = ScreenFlash.new()
	_screen_flash.name = "ScreenFlash"
	add_child(_screen_flash)

	# Wire parser signals
	_parser.ability_result_event.connect(_on_ability_result)
	_parser.heal_event.connect(_on_heal)
	_parser.player_death_event.connect(_on_player_death)
	_parser.player_respawn_event.connect(_on_player_respawn)
	_parser.mob_death_event.connect(_on_mob_death)
	_parser.mob_respawn_event.connect(_on_mob_respawn)
	_parser.ability_rejected_event.connect(_on_ability_rejected)
	_parser.cast_started_event.connect(_on_cast_started)
	_parser.cast_cancelled_event.connect(_on_cast_cancelled)


func process_event(data: Dictionary) -> void:
	"""Process a raw server event dict."""
	_parser.parse(data)
	_update_health(data)


# T-575: surfaces a non-combat action failure (quest accept/turn_in/talk/abandon, etc.) on the same
# transient log surface T-402 uses for out-of-range — the established "a real failure must be
# visible, not silent" idiom. hud_handlers.gd composes the player-facing message; this just logs it.
func report_action_failure(msg: String) -> void:
	_combat_log.add_entry(msg, _COLOR_ERROR)


# T-635: a neutral (non-error) system line — the same transient log surface, the SYSTEM colour
# already used internally for death/respawn messages (see _on_player_death et al). Public so
# non-combat callers (the level-up celebration) can post a "You have reached level N!" line
# without reaching into a private member.
func report_system_message(msg: String) -> void:
	_combat_log.add_entry(msg, _COLOR_SYSTEM)


# T-057: the 3D client renders world-space health bars; turn off these 2D ones + floating text.
func set_overlays_enabled(on: bool) -> void:
	hud_overlays_enabled = on
	if _floating_pool != null:
		_floating_pool.enabled = on


func _update_health(data: Dictionary) -> void:
	"""If this event carries HP data, update the health bar."""
	if not hud_overlays_enabled:
		return
	var msg_type: String = str(data.get("type", ""))
	var hp: int = int(data.get("target_hp", -1))
	var max_hp: int = int(data.get("target_max_hp", 0))

	if hp < 0:
		return

	var target_id: int = int(data.get("target_id", -1))
	var target_name: String = str(data.get("target_name", ""))

	if target_id > 0:
		var bar: HealthBar = _health_bars.get(target_id, null)
		if bar == null:
			bar = _create_health_bar(target_id, target_name)
			_health_bars[target_id] = bar
		bar.update_hp(hp, max_hp)


func _create_health_bar(entity_id: int, entity_name: String) -> HealthBar:
	var bar := HealthBar.new()
	bar.name = "HealthBar_%d" % entity_id
	bar.set_entity(entity_id, entity_name)
	add_child(bar)
	return bar


# ---- Signal handlers (each dispatches to the correct subsystem) ----------


func _on_ability_result(evt: CombatEventParser.CombatEvent) -> void:
	# Our cast (if any) has resolved — the local player's cast bar can clear.
	if evt.caster_id == local_player_id and _cast_bar.is_casting():
		_cast_bar.cancel()

	# Floating text above target (unchanged); the combat-log line goes through the T-308 formatter,
	# which strips the [tick=NNN] prefix (unless show_tick) and colours by meaning to the local player.
	if evt.outcome in ["miss", "dodge", "parry"]:
		_floating_pool.spawn_text(evt.target_id, evt.outcome.to_upper(), _COLOR_MISS)
	elif evt.outcome == "crit":
		_floating_pool.spawn_text(evt.target_id, "CRIT %d!" % evt.damage, _COLOR_DAMAGE)
		_maybe_flash(evt)
	else:
		_floating_pool.spawn_text(evt.target_id, str(evt.damage), _COLOR_DAMAGE)
		_maybe_flash(evt)
	var line: Dictionary = CombatLogFormatter.format_ability(
		evt.caster_id,
		evt.caster_name,
		evt.target_id,
		evt.target_name,
		evt.damage,
		evt.outcome,
		evt.tick,
		local_player_id,
		show_tick,
		evt.kind  # T-586: "falling" gets its own casterless log line
	)
	_combat_log.add_entry(line["msg"], line["color"])


func _maybe_flash(evt: CombatEventParser.CombatEvent) -> void:
	# Red screen flash only when the LOCAL player is the one taking damage (T-027 §5).
	if local_player_id >= 0 and evt.target_id == local_player_id and evt.damage > 0:
		_screen_flash.flash()


func _on_cast_started(ability_id: int, cast_ticks: int) -> void:
	_cast_bar.start_cast(ability_id, cast_ticks)


func _on_cast_cancelled(_reason: String) -> void:
	_cast_bar.cancel()


func set_local_player(entity_id: int) -> void:
	local_player_id = entity_id


func _on_heal(evt: CombatEventParser.CombatEvent) -> void:
	_floating_pool.spawn_text(evt.target_id, "+%d" % evt.damage, _COLOR_HEAL)
	_combat_log.add_entry(
		"%s heals %s for %d." % [evt.caster_name, evt.target_name, evt.damage], _COLOR_HEAL
	)


func _on_player_death(evt: CombatEventParser.CombatEvent) -> void:
	_floating_pool.spawn_text(evt.target_id, "DEAD", _COLOR_SYSTEM)
	_combat_log.add_entry(evt.system_message, _COLOR_SYSTEM)
	# Hide health bar on death
	var bar: HealthBar = _health_bars.get(evt.target_id, null)
	if bar != null:
		bar.hide()


func _on_player_respawn(evt: CombatEventParser.CombatEvent) -> void:
	_combat_log.add_entry(evt.system_message, _COLOR_SYSTEM)
	# Show health bar on respawn and reset to full HP
	var bar: HealthBar = _health_bars.get(evt.target_id, null)
	if bar != null:
		bar.show()


func _on_mob_death(evt: CombatEventParser.CombatEvent) -> void:
	_floating_pool.spawn_text(evt.target_id, "DEAD", _COLOR_SYSTEM)
	_combat_log.add_entry(evt.system_message, _COLOR_SYSTEM)
	# Hide health bar on death
	var bar: HealthBar = _health_bars.get(evt.target_id, null)
	if bar != null:
		bar.hide()


func _on_mob_respawn(evt: CombatEventParser.CombatEvent) -> void:
	_combat_log.add_entry(evt.system_message, _COLOR_SYSTEM)
	# Show health bar on respawn
	var bar: HealthBar = _health_bars.get(evt.target_id, null)
	if bar != null:
		bar.show()


# T-402 item 3: out_of_range is surfaced (it IS a server-confirmed verdict — the live gap was a
# melee player whose abilities silently no-op'd against a kiting gunsel). All other rejection
# reasons stay silent per the T-027 spec (the log records outcomes, not every denied press).
func _on_ability_rejected(reason: String, detail: Dictionary = {}) -> void:
	if reason != "out_of_range":
		return
	if not _should_show_reject_feedback():
		return
	var msg := "Out of range."
	if detail.has("dist_m") and detail.has("range_m"):
		msg = (
			"Out of range — target %.1fm away, ability reaches %.1fm."
			% [float(detail["dist_m"]), float(detail["range_m"])]
		)
	_combat_log.add_entry(msg, _COLOR_ERROR)


# T-644: check if sufficient time has passed since the last out_of_range rejection to show feedback.
# Shared by both the combat log line and the floating text to keep them synchronized.
func should_show_reject_feedback() -> bool:
	var now: int = Time.get_ticks_msec()
	if now - _last_reject_log_ms < REJECT_LOG_THROTTLE_MS:
		return false
	_last_reject_log_ms = now
	return true


# Private helper for the internal handler.
func _should_show_reject_feedback() -> bool:
	var now: int = Time.get_ticks_msec()
	if now - _last_reject_log_ms < REJECT_LOG_THROTTLE_MS:
		return false
	_last_reject_log_ms = now
	return true


# ---- Accessors (for testing) --------------------------------------------


func get_parser() -> CombatEventParser:
	return _parser


func get_combat_log() -> CombatLog:
	return _combat_log


func get_floating_pool() -> FloatingTextPool:
	return _floating_pool


func get_health_bar(entity_id: int) -> HealthBar:
	return _health_bars.get(entity_id, null)


func get_cast_bar() -> CastBar:
	return _cast_bar


func get_screen_flash() -> ScreenFlash:
	return _screen_flash
