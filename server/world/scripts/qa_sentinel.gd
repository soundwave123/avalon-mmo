extends RefCounted

# T-561: Runtime anomaly sentinel — the deterministic FLOOR of autonomous bug testing.
#
# PURE, engine-loop-free invariant module. It ingests one cheap per-player
# observation snapshot per server tick and returns a list of anomalies. It holds
# NO node references, does NO I/O, and NEVER mutates game state — the world tick
# owns the logging. Because it is a plain RefCounted with injected `now_tick`, it
# is fully unit-testable without a live server.
#
# WHY THIS EXISTS (real incidents this session): a `SCRIPT ERROR` in
# `relay_mob_damage` masked player damage, and a training effigy silently killed
# idle players — every unit test stayed GREEN. Deterministic runtime monitors
# would have flagged both instantly. This module catches the second class
# (server-side symptoms); the log watchdog catches the first (crash text).
#
# DETECTORS:
#   (a) idle_hp_drain      — HP falls while the player is alive, NOT in combat,
#                            NOT the target of any mob, and stationary. The exact
#                            effigy / "drowning" symptom.
#   (b) death_loop         — >= death_count deaths inside death_window_ticks near
#                            the same position (spawn trap / kill zone).
#   (c) unattributed_death — HP reaches 0 with no recorded damage source and no
#                            attacker (a normal combat death does NOT fire).
#
# Every detector DEDUPES via a per-player latch so a persistent condition emits
# one line, not one per tick, and re-arms only after the condition clears.

# --- Defaults (all windows in server ticks so tests inject their own clock) ---
const DEFAULT_IDLE_DRAIN_MIN_HP_DROP := 1  # any real HP loss qualifies
const DEFAULT_DEATH_WINDOW_TICKS := 1200  # ~60s @ 20 ticks/s
const DEFAULT_DEATH_COUNT := 3
const DEFAULT_DEATH_RADIUS := 8.0  # metres; "near the same position"
const DEFAULT_MOVE_EPSILON := 0.05  # metres of drift below which we call it stationary

var _idle_drain_min_hp_drop: int
var _death_window_ticks: int
var _death_count: int
var _death_radius_sq: float
var _move_epsilon_sq: float

# Per-player rolling history (pid -> value).
var _last: Dictionary = {}  # pid -> {"hp": int, "pos": Vector3, "alive": bool}
var _idle_latched: Dictionary = {}  # pid -> bool: idle-drain reported, awaiting re-arm
var _deaths: Dictionary = {}  # pid -> Array of {"tick": int, "pos": Vector3}
var _death_latched: Dictionary = {}  # pid -> bool: death-loop already reported


func _init(config: Dictionary = {}) -> void:
	_idle_drain_min_hp_drop = int(
		config.get("idle_drain_min_hp_drop", DEFAULT_IDLE_DRAIN_MIN_HP_DROP)
	)
	_death_window_ticks = int(config.get("death_window_ticks", DEFAULT_DEATH_WINDOW_TICKS))
	_death_count = int(config.get("death_count", DEFAULT_DEATH_COUNT))
	var radius := float(config.get("death_radius", DEFAULT_DEATH_RADIUS))
	_death_radius_sq = radius * radius
	var eps := float(config.get("move_epsilon", DEFAULT_MOVE_EPSILON))
	_move_epsilon_sq = eps * eps


# Ingest a full-tick batch. `observations` is an Array of per-player Dictionaries:
#   pid                     : int
#   hp                      : int   (current HP)
#   max_hp                  : int   (context only; optional)
#   pos                     : Vector3
#   in_combat               : bool  (recently dealt/took damage)
#   attacked_by_mob         : bool  (is the top-threat target of some mob)
#   damage_source_recorded  : bool  (was the last HP change attributable?)
# Returns an Array of anomaly Dictionaries (see `_anomaly`). The caller logs them.
func observe(now_tick: int, observations: Array) -> Array:
	var anomalies: Array = []
	for obs in observations:
		anomalies.append_array(_observe_one(now_tick, obs))
	return anomalies


func _observe_one(now_tick: int, obs: Dictionary) -> Array:
	var out: Array = []
	var pid := int(obs.get("pid", -1))
	var hp := int(obs.get("hp", 0))
	var pos: Vector3 = obs.get("pos", Vector3.ZERO)
	var in_combat := bool(obs.get("in_combat", false))
	var attacked := bool(obs.get("attacked_by_mob", false))
	var src_recorded := bool(obs.get("damage_source_recorded", true))

	var prev: Variant = _last.get(pid, null)
	if prev != null:
		var prev_hp := int(prev["hp"])
		var prev_pos: Vector3 = prev["pos"]
		var was_alive := bool(prev["alive"])
		var hp_drop := prev_hp - hp
		var moving := pos.distance_squared_to(prev_pos) > _move_epsilon_sq
		var now_dead := hp <= 0

		if was_alive and now_dead:
			out.append_array(_on_death(now_tick, pid, pos, in_combat, attacked, src_recorded))

		# Idle HP-drain only applies while still alive; a drain to zero is a death.
		if hp_drop >= _idle_drain_min_hp_drop and hp > 0:
			if not in_combat and not attacked and not moving:
				if not bool(_idle_latched.get(pid, false)):
					_idle_latched[pid] = true
					out.append(
						_anomaly(
							"idle_hp_drain",
							pid,
							pos,
							{"hp": hp, "prev_hp": prev_hp, "hp_drop": hp_drop}
						)
					)
			else:
				_idle_latched[pid] = false  # explained loss re-arms the latch
		else:
			_idle_latched[pid] = false  # HP stable / rising re-arms the latch

	_last[pid] = {"hp": hp, "pos": pos, "alive": hp > 0}
	return out


func _on_death(
	now_tick: int, pid: int, pos: Vector3, in_combat: bool, attacked: bool, src_recorded: bool
) -> Array:
	var out: Array = []

	# Unattributed death: nobody dealt the killing blow and no mob was on us. A
	# normal combat death carries a recorded source (or an attacker) and skips this.
	if not src_recorded and not attacked and not in_combat:
		out.append(_anomaly("unattributed_death", pid, pos, {}))

	var history: Array = _deaths.get(pid, [])
	history.append({"tick": now_tick, "pos": pos})
	var pruned: Array = []
	for d in history:
		if now_tick - int(d["tick"]) <= _death_window_ticks:
			pruned.append(d)
	_deaths[pid] = pruned

	var cluster := 0
	for d in pruned:
		var dp: Vector3 = d["pos"]
		if pos.distance_squared_to(dp) <= _death_radius_sq:
			cluster += 1

	if cluster >= _death_count:
		if not bool(_death_latched.get(pid, false)):
			_death_latched[pid] = true
			out.append(
				_anomaly(
					"death_loop", pid, pos, {"deaths": cluster, "window_ticks": _death_window_ticks}
				)
			)
	else:
		_death_latched[pid] = false
	return out


func _anomaly(reason: String, pid: int, pos: Vector3, detail: Dictionary) -> Dictionary:
	return {"reason": reason, "pid": pid, "pos": pos, "detail": detail}


# Canonical one-line render for the server log. The `[qa-anomaly]` prefix is the
# grep anchor other tooling (including the log watchdog) keys off of.
func format_line(anomaly: Dictionary) -> String:
	var pos: Vector3 = anomaly.get("pos", Vector3.ZERO)
	return (
		"[qa-anomaly] reason=%s player=%d pos=(%.2f,%.2f,%.2f) detail=%s"
		% [
			str(anomaly.get("reason", "?")),
			int(anomaly.get("pid", -1)),
			pos.x,
			pos.y,
			pos.z,
			str(anomaly.get("detail", {})),
		]
	)
