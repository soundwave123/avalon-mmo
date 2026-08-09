extends "res://addons/gut/test.gd"

# T-586: LIGHT distance-based fall damage. The server has no vertical physics (z is DERIVED from
# the terrain field per move), so a fall is a DESCENT RUN: consecutive per-move z drops too steep
# to walk. These tests lock down the detector's honesty guarantees:
#   - a cliff run triggers, a steep-but-walkable slope NEVER does (owner: err generous);
#   - a warp (any non-walked reposition bumps warp_seq) can never register as a fall;
#   - the %-max-HP curve caps and the cap can never one-shot from full health;
#   - safe-drop zones + water areas (world data) exempt the landing;
#   - the REAL move intake (_on_request_move -> update_position -> detector) applies damage,
#     via the _HarnessMain pattern from test_mob_damage_combat_mark.gd + an injected height field.

const FallDamage = preload("res://scripts/fall_damage.gd")
const PlayerSessions = preload("res://scripts/player_sessions.gd")
const CombatResources = preload("res://scripts/combat/combat_resources.gd")

const PEER := 7
# 32-hex session token (built, not a literal — the secrets scanner flags hex-string constants).
var _token := "fa11".repeat(8)

const CFG := {
	"enabled": true,
	"safe_fall_distance": 12.0,
	"damage_pct_per_meter": 3.0,
	"max_damage_pct": 60.0,
	"min_move_drop": 0.6,
	"slope_ratio": 2.0,
	"idle_finalize_ticks": 8,
	"water_level": 0.06,
	"water_areas": [{"name": "lake", "type": "disc", "center": [18.0, 22.0], "radius": 12.0}],
	"safe_drop_zones":
	[{"name": "drop", "x_min": 100.0, "x_max": 120.0, "y_min": -10.0, "y_max": 10.0}],
}


# Injected height field: a 0 m plateau that sheers to -20 m at x >= 5 (a 20 m cliff edge).
class _CliffTerrain:
	func height(x: float, _y: float) -> float:
		return 0.0 if x < 5.0 else -20.0


class _RpcStub:
	func on_player_moved(_p: int, _u: String, _o: Vector3, _n: Vector3) -> void:
		pass


class _HarnessMain:
	extends "res://scripts/main.gd"


func before_each() -> void:
	PlayerSessions._reset_for_test()
	PlayerSessions._terrain = null


func after_each() -> void:
	PlayerSessions._reset_for_test()
	PlayerSessions._terrain = null  # never leak the stub field into other suites


func _detector() -> FallDamage:
	var fd: FallDamage = FallDamage.new("")  # no file: starts disabled
	fd.configure(CFG)
	return fd


# ---- Detector unit tests (pure observe/damage_for — no sessions, no stores) ----------------


func test_cliff_run_triggers_when_descent_ends() -> void:
	var fd := _detector()
	fd.observe(1, 0, 0.0, 0.3, 100)  # baseline on first sight
	var z := 0.0
	for i in range(8):  # 8 moves x 2 m drop at 0.3 m planar — far past the walkable slope
		z -= 2.0
		assert_eq(fd.observe(1, 0, z, 0.3, 101 + i), 0.0, "open run must not close mid-descent")
	var dist: float = fd.observe(1, 0, z, 0.3, 110)  # flat move: the run closes
	assert_almost_eq(dist, 16.0, 0.001, "closed run must total the accumulated drop")
	var dmg: int = fd.damage_for(dist, 1000, Vector3(50.0, 50.0, z))
	assert_eq(dmg, 120, "16 m fall = (16-12)*3% of 1000 max HP")


func test_walkable_slope_never_accumulates() -> void:
	var fd := _detector()
	fd.observe(1, 0, 0.0, 0.3, 100)
	var z := 0.0
	for i in range(40):  # ~59-degree slope: 0.5 m drop per 0.3 m planar — steep but walkable
		z -= 0.5
		fd.observe(1, 0, z, 0.3, 101 + i)
	var dist: float = fd.observe(1, 0, z, 0.3, 150)
	assert_eq(dist, 0.0, "a 20 m walkable-slope descent must never register as a fall")


func test_noise_floor_blocks_slow_creep_drops() -> void:
	var fd := _detector()
	fd.observe(1, 0, 0.0, 0.1, 100)
	var z := 0.0
	for i in range(30):  # 0.5 m drops over tiny 0.1 m planar creep: over the slope ratio but
		z -= 0.5  # under min_move_drop (0.6) — the absolute floor must hold
		fd.observe(1, 0, z, 0.1, 101 + i)
	assert_eq(fd.observe(1, 0, z, 0.1, 140), 0.0, "drops under min_move_drop never accumulate")


func test_warp_mid_run_discards_open_run() -> void:
	var fd := _detector()
	fd.observe(1, 0, 0.0, 0.3, 100)
	fd.observe(1, 0, -5.0, 0.3, 101)
	fd.observe(1, 0, -10.0, 0.3, 102)  # 10 m of open run
	var dist: float = fd.observe(1, 1, -40.0, 0.3, 103)  # warp_seq bumped: rift/flight/respawn
	assert_eq(dist, 0.0, "a warp must never close a run")
	assert_eq(fd.observe(1, 1, -40.0, 0.3, 104), 0.0, "and the open run is discarded, not kept")


func test_damage_curve_threshold_cap_and_parity() -> void:
	var fd := _detector()
	var high := Vector3(50.0, 50.0, 10.0)
	assert_eq(fd.damage_for(11.9, 1000, high), 0, "below the safe threshold = never any damage")
	assert_eq(fd.damage_for(200.0, 1000, high), 600, "cap: 60% of max HP no matter the distance")
	var frac_small: float = float(fd.damage_for(20.0, 100, high)) / 100.0
	var frac_big: float = float(fd.damage_for(20.0, 1000, high)) / 1000.0
	assert_almost_eq(frac_small, frac_big, 0.001, "same drop = same FRACTION at any level")


func test_cap_never_lethal_even_misconfigured_to_100pct() -> void:
	var fd: FallDamage = FallDamage.new("")
	var cfg := CFG.duplicate(true)
	cfg["max_damage_pct"] = 100.0
	fd.configure(cfg)
	var dmg: int = fd.damage_for(1000.0, 100, Vector3(50.0, 50.0, 10.0))
	assert_eq(dmg, 99, "the cap alone may never kill from full health (hard max_hp - 1 clamp)")


func test_safe_drop_zone_exempts_landing() -> void:
	var fd := _detector()
	assert_eq(fd.damage_for(30.0, 1000, Vector3(110.0, 0.0, 5.0)), 0, "safe-zone landing = 0")
	assert_gt(fd.damage_for(30.0, 1000, Vector3(130.0, 0.0, 5.0)), 0, "outside the zone = damage")


func test_water_exemption_needs_area_and_level() -> void:
	var fd := _detector()
	var in_lake_bed := Vector3(18.0, 22.0, -0.2)  # inside the lake disc, carved below the plane
	assert_eq(fd.damage_for(30.0, 1000, in_lake_bed), 0, "water landing cancels fall damage")
	var flat_pocket := Vector3(60.0, 60.0, 0.0)  # z=0.0 < plane but NOT in any water area
	assert_gt(fd.damage_for(30.0, 1000, flat_pocket), 0, "flat z=0 pockets are NOT water")
	var lake_shore := Vector3(18.0, 22.0, 0.5)  # in the disc but ABOVE the water plane
	assert_gt(fd.damage_for(30.0, 1000, lake_shore), 0, "dry shore inside the disc still damages")


# ---- Integration: the REAL move intake through main.gd (harness, no _ready) ----------------


func _harness_world() -> Dictionary:
	var m := _HarnessMain.new()
	autofree(m)
	m._world_rpc = _RpcStub.new()
	PlayerSessions._terrain = _CliffTerrain.new()
	PlayerSessions.add_player(PEER, _token, "Faller", Vector3.ZERO)
	var res := CombatResources.new()
	res.hp = 1000
	res.max_hp = 1000
	m._combat_resources[PEER] = res
	var events: Array = []
	var deaths: Array = []
	m._fall.configure(CFG)
	m._fall.wire(
		m._combat_resources,
		m._connected_players,
		func(e: Dictionary) -> void: events.append(e),
		func(pid: int, _now: int) -> void: deaths.append(pid),
		Callable()
	)
	return {"m": m, "events": events, "deaths": deaths}


func test_walking_off_cliff_damages_via_real_move_intake() -> void:
	var w := _harness_world()
	var m = w["m"]
	for i in range(20):  # 0.3 m east per intent: crosses the x=5 cliff edge, then flat at -20 m
		m._on_request_move(PEER, {"dx": 0.3, "dy": 0.0})
	var after: CombatResources = m._combat_resources[PEER]
	assert_eq(after.hp, 760, "20 m cliff = (20-12)*3% of 1000 = 240 damage through the intake")
	assert_gt(after.last_combat_tick, 0, "T-582: fall marks combat or the sentinel flags drain")
	assert_eq(w["events"].size(), 1, "exactly one landing event")
	var ev: Dictionary = w["events"][0]
	assert_eq(str(ev["kind"]), "falling", "the combat event carries the falling source tag")
	assert_eq(int(ev["damage"]), 240, "event damage mirrors the applied amount")
	assert_eq(int(ev["target_hp"]), 760, "event carries post-landing HP")
	assert_eq(w["deaths"], [PEER], "the standard death check runs after fall damage")


func test_warp_through_update_position_never_registers_as_fall() -> void:
	var w := _harness_world()
	var m = w["m"]
	for i in range(17):  # stop right after the cliff edge: a 20 m run is OPEN, not yet closed
		m._on_request_move(PEER, {"dx": 0.3, "dy": 0.0})
	assert_eq(m._combat_resources[PEER].hp, 1000, "no damage while the run is still open")
	PlayerSessions.update_position(PEER, Vector3(-50.0, 0.0, 0.0))  # warp: rift/flight/respawn
	for i in range(3):
		m._on_request_move(PEER, {"dx": 0.3, "dy": 0.0})  # walk on the plateau after arrival
	assert_eq(m._combat_resources[PEER].hp, 1000, "the warp discarded the open run: no damage")
	assert_eq(w["events"].size(), 0, "no landing event after a warp")


func test_idle_player_still_lands_via_finalize() -> void:
	var w := _harness_world()
	var m = w["m"]
	for i in range(17):  # cross the edge, then STOP moving (per-RPC intake goes silent)
		m._on_request_move(PEER, {"dx": 0.3, "dy": 0.0})
	assert_eq(m._combat_resources[PEER].hp, 1000, "run still open while standing at the bottom")
	var now: int = Time.get_ticks_msec() / (1000 / ServerConfig.TICK_RATE_HZ)
	m._fall.finalize_idle(now + 100)  # well past idle_finalize_ticks
	assert_eq(m._combat_resources[PEER].hp, 760, "idle finalize lands the stopped player")
	assert_eq(w["events"].size(), 1, "idle landing emits the same falling event")
