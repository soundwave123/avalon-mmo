extends RefCounted

# T-586: LIGHT, DISTANCE-based fall damage — the descent-run detector + %-max-HP curve.
#
# WHY DISTANCE, NOT VELOCITY (verified 2026-08-08, docs/research/per-ticket/T-586.md): the server
# has NO vertical physics. movement_collision.gd resolves planar (x, y) movement and
# player_sessions.gd DERIVES z from the terrain height field on every move — a player is never
# airborne server-side. Walking off a cliff shows up as a rapid sequence of downward z deltas
# while x/y crosses the height field. So the only honest fall signal is a DESCENT RUN:
# consecutive per-move z drops too steep to be walked accumulate; when z stabilizes (a
# non-descending move) or the mover goes idle, the run closes and the accumulated drop is the
# fall distance.
#
# WARP SUPPRESSION: the ONLY feed is the walked path (main._on_request_move). Every other
# position write — rift/instance transfer, flight arrival, battleground launch/return, respawn,
# resurrect — bumps the session's warp_seq (player_sessions.update_position, walked=false), so
# on_walk_move sees the changed seq, DROPS any open run, and re-baselines. A warp can never
# start, extend, or close a run. (There is no server-side dev teleport; the pilot's "goto" walks
# rate-legal request_move hops, which is honest walking.)
#
# Tuning + world data (safe threshold, curve, cap, safe-drop zones, water areas) live in
# res://data/fall_damage.json — never hardcode; missing/malformed config = system disabled.

const _PS = preload("res://scripts/player_sessions.gd")
const _CEB = preload("res://scripts/combat/combat_event_builder.gd")

const DEFAULT_CONFIG_PATH := "res://data/fall_damage.json"

var _enabled: bool = false
var _safe_distance: float = 12.0
var _pct_per_meter: float = 3.0
var _max_pct: float = 60.0
var _min_move_drop: float = 0.6
var _slope_ratio: float = 2.0
var _idle_ticks: int = 8
var _water_level: float = 0.06
var _water_areas: Array = []  # [{center: Vector2, radius: float}]
var _safe_zones: Array = []  # [{x_min, x_max, y_min, y_max} floats]

# peer_id -> {run: float, last_z: float, warp_seq: int, last_tick: int}
var _runs: Dictionary = {}

# Wired once by main.gd (or a test): the live resource store + the standard combat-event paths.
var _resources: Dictionary = {}  # peer_id -> CombatResources (main._combat_resources, by ref)
var _players: Dictionary = {}  # peer_id -> session metadata (main._connected_players, by ref)
var _emit_combat: Callable = Callable()  # event_dispatch.combat — region-scoped client event
var _check_death: Callable = Callable()  # main._check_death_player — the ONE death path
var _tel: Callable = Callable()  # main._tel — telemetry, fire-and-forget


func _init(config_path: String = DEFAULT_CONFIG_PATH) -> void:
	if config_path != "" and FileAccess.file_exists(config_path):
		var file := FileAccess.open(config_path, FileAccess.READ)
		if file == null:
			push_warning("[fall_damage] cannot open %s — fall damage disabled" % config_path)
			return
		var doc = JSON.parse_string(file.get_as_text())
		if not doc is Dictionary:
			push_warning("[fall_damage] malformed %s — fall damage disabled" % config_path)
			return
		configure(doc)


func configure(doc: Dictionary) -> void:
	"""Load tuning + world data from a config dict (the file's shape; also the test seam)."""
	_enabled = bool(doc.get("enabled", false))
	_safe_distance = float(doc.get("safe_fall_distance", 12.0))
	_pct_per_meter = float(doc.get("damage_pct_per_meter", 3.0))
	_max_pct = float(doc.get("max_damage_pct", 60.0))
	_min_move_drop = float(doc.get("min_move_drop", 0.6))
	_slope_ratio = float(doc.get("slope_ratio", 2.0))
	_idle_ticks = int(doc.get("idle_finalize_ticks", 8))
	_water_level = float(doc.get("water_level", 0.06))
	_water_areas = []
	for w in doc.get("water_areas", []):
		var c: Array = w.get("center", [0.0, 0.0])
		(
			_water_areas
			. append(
				{
					"center": Vector2(float(c[0]), float(c[1])),
					"radius": float(w.get("radius", 0.0)),
				}
			)
		)
	_safe_zones = []
	for z in doc.get("safe_drop_zones", []):
		(
			_safe_zones
			. append(
				{
					"x_min": float(z.get("x_min", 0.0)),
					"x_max": float(z.get("x_max", 0.0)),
					"y_min": float(z.get("y_min", 0.0)),
					"y_max": float(z.get("y_max", 0.0)),
				}
			)
		)


func wire(
	resources: Dictionary,
	players: Dictionary,
	emit_combat: Callable,
	check_death: Callable,
	tel: Callable
) -> void:
	"""Bind the live stores + the standard damage/death/telemetry paths (main.gd, once)."""
	_resources = resources
	_players = players
	_emit_combat = emit_combat
	_check_death = check_death
	_tel = tel


func on_walk_move(peer_id: int, planar_dist: float, now_tick: int) -> void:
	"""Feed one WALKED move (already committed to PlayerSessions). Reads the derived ground z +
	warp_seq back from the session record; closes and applies a run when the descent ends."""
	if not _enabled:
		return
	var sess: Dictionary = _PS.get_player_view(peer_id)
	if sess.is_empty():
		return
	var pos: Vector3 = sess.get("pos", Vector3.ZERO)
	var dist: float = observe(peer_id, int(sess.get("warp_seq", 0)), pos.z, planar_dist, now_tick)
	if dist > 0.0:
		_land(peer_id, dist, pos, now_tick)


func observe(peer_id: int, warp_seq: int, new_z: float, planar_dist: float, now_tick: int) -> float:
	"""Pure descent-run state machine (no session/store access — unit-testable). Returns the
	accumulated fall distance when this move CLOSES a run, else 0.0.

	A move extends the run only if its z drop beats BOTH the walkable-slope test
	(slope_ratio * planar distance) and the absolute noise floor (min_move_drop) — so steep
	walkable slopes never accumulate. Any other move (flat, ascent, shallow) closes the run.
	A changed warp_seq (any non-walked reposition) or an unseen peer just re-baselines."""
	var st = _runs.get(peer_id)
	if st == null or int(st["warp_seq"]) != warp_seq:
		_runs[peer_id] = {"run": 0.0, "last_z": new_z, "warp_seq": warp_seq, "last_tick": now_tick}
		return 0.0
	var drop: float = float(st["last_z"]) - new_z
	st["last_z"] = new_z
	st["last_tick"] = now_tick
	if drop > maxf(_min_move_drop, _slope_ratio * planar_dist):
		st["run"] = float(st["run"]) + drop
		return 0.0
	var closed: float = float(st["run"])
	st["run"] = 0.0
	return closed


func finalize_idle(now_tick: int) -> void:
	"""Close any open run whose mover stopped sending intents (per-RPC intake: a player who lands
	and stands still gets no further on_walk_move — land them idle_finalize_ticks later)."""
	if not _enabled:
		return
	for pid in _runs:
		var st: Dictionary = _runs[pid]
		if float(st["run"]) > 0.0 and now_tick - int(st["last_tick"]) >= _idle_ticks:
			var dist: float = float(st["run"])
			st["run"] = 0.0
			_land(int(pid), dist, _PS.get_player_view(int(pid)).get("pos", Vector3.ZERO), now_tick)


func damage_for(distance: float, max_hp: int, landing: Vector3) -> int:
	"""Pure curve + exemptions: %-max-HP linear above the safe threshold, capped — and the cap
	itself can never kill from full health (hard-clamped to max_hp - 1 whatever the config)."""
	if not _enabled or max_hp <= 0 or distance <= _safe_distance:
		return 0
	if _in_safe_zone(landing) or _in_water(landing):
		return 0
	var pct: float = minf((distance - _safe_distance) * _pct_per_meter, _max_pct)
	return mini(int(floor(float(max_hp) * pct / 100.0)), max_hp - 1)


func erase(peer_id: int) -> void:
	"""Drop a peer's tracker state (named to match the store-clearing seam in main.gd)."""
	_runs.erase(peer_id)


func _land(pid: int, distance: float, landing: Vector3, now_tick: int) -> void:
	"""A closed descent run: damage through the SAME stores/paths as any other player damage."""
	var cr = _resources.get(pid)
	if cr == null:
		return
	var amount: int = damage_for(distance, cr.max_hp, landing)
	if amount <= 0:
		return
	# T-582 lesson: mark combat or the QA sentinel reads the HP drop as idle_hp_drain.
	_resources[pid] = cr.apply_damage(amount).mark_combat(now_tick)
	var uname := str(_players.get(pid, {}).get("username", "Unknown"))
	var after = _resources[pid]
	# ability_result shape rides the whole existing client feedback path (number/flash/hit-react);
	# caster_id -1 = environment (non-peer ids drop out of recipients); kind tags the combat log.
	var event: Dictionary = _CEB.ability_result(
		0, "Falling", -1, pid, amount, "hit", now_tick, "", uname, after.hp, after.max_hp, 0, false
	)
	event["kind"] = "falling"
	if _emit_combat.is_valid():
		_emit_combat.call(event)
	print("[world] fall_damage peer_id=%d dist=%.1f amount=%d" % [pid, distance, amount])
	if _tel.is_valid():
		_tel.call("fall_damage", pid, {"distance": snappedf(distance, 0.1), "amount": amount})
	if _check_death.is_valid():
		_check_death.call(pid, now_tick)


func _in_safe_zone(landing: Vector3) -> bool:
	for z in _safe_zones:
		if (
			landing.x >= z["x_min"]
			and landing.x <= z["x_max"]
			and landing.y >= z["y_min"]
			and landing.y <= z["y_max"]
		):
			return true
	return false


func _in_water(landing: Vector3) -> bool:
	# BOTH tests must hold: inside an authored water area AND ground carved below the water plane
	# (flat walked pockets read z=0.0 < 0.06 everywhere — a bare level test would exempt them all).
	if landing.z > _water_level:
		return false
	for w in _water_areas:
		if Vector2(landing.x, landing.y).distance_to(w["center"]) <= w["radius"]:
			return true
	return false
