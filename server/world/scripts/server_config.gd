extends Node
# Autoload singleton.
#
# Reads server configuration from environment variables (Flatpak compatibility).
# _DEFAULT_* constants are parse-time defaults. Static runtime values are
# populated in _ready() from env vars, then accessed via static functions.
#
# Env vars (all optional):
#   AVALON_PORT         ENet listen port       (default: 9200)
#   AVALON_MAX_PLAYERS  Max simultaneous peers (default: 115 — T-374 measured cap)
#   AVALON_MASTER_HOST  Master server hostname (default: 127.0.0.1)
#   AVALON_MASTER_PORT  Master server port     (default: 9100)
#   AVALON_AOI_RADIUS   T-370 broadcast interest radius, metres (default: 80; 0 = disable AOI)
#   AVALON_AOI_MAX_PEERS T-370 nearest-N player cap per broadcast (default: 50; crowd payload guard)
#   AVALON_KEYFRAME_FRAMES T-372 broadcasts between full keyframes (default: 20; 1 = deltas off)

const SERVER_NAME := "world"
const TICK_RATE_HZ := 20
const BROADCAST_RATE_HZ := 10

# Movement bounds and speed limits (T-011).
# T-074: total movement budget per peer per second (rate limit across messages). Matches
# the old single-message allowance so harness/teleport-style single hops stay legal, while
# sustained per-frame max-delta spam is rejected. Tighten alongside real client speed tuning.
const MOVE_UNITS_PER_SECOND := 100.0
const MOVE_UNITS_MOUNTED_PER_SECOND := 160.0  # T-431: server-selected mounted budget
const BOUNDS_MIN := -500.0
const BOUNDS_MAX := 500.0
const MAX_SPEED_PER_TICK := 100.0
const MAX_SPEED_MOUNTED_PER_TICK := 160.0  # T-431: cosmetic skins never change this power tier

# Session lifecycle (T-015): max age for disconnected sessions before cleanup.
const SESSION_MAX_AGE_SECONDS := 300

# T-018: Global cooldown — 1.5 s at 20 Hz = 30 ticks (WoW reference baseline).
const GCD_TICKS := 30

# T-021: Damage formula constants.
# MITIGATION_K: ratio-mitigation constant; higher = less mitigation per point of defense.
# MIN_DAMAGE: floor ensures a hit always deals at least 1 damage (never silent zero).
const MITIGATION_K: float = 100.0
const MIN_DAMAGE: int = 1

# T-022: Cast movement-cancel threshold.
# Placeholder — must be validated against real server position-update noise before tuning.
# Too tight → floating-point jitter cancels legitimate stands.
# Too loose → players can micro-move while casting without penalty.
const POSITION_EPSILON: float = 0.05

# T-023: Hit-based spell pushback.
const PUSHBACK_TICKS: int = 10  # 0.5 s at 20 Hz per hit
const MAX_PUSHBACK_TICKS: int = 9999  # effectively uncapped in M1

# T-025: Mob AI movement and spawn constants.
# T-534: authoritative player ground RUN speed (mirrors client local_player.gd MOVE_SPEED=6.0). The
# MOVE_UNITS_PER_SECOND=100 limiter above is only an anti-teleport ceiling, NOT the run speed.
const PLAYER_RUN_SPEED: float = 6.0  # units/sec — the speed a running player actually travels
# T-572: mounting was a no-op — the "mounted" cap above (100->160) only raised the anti-teleport
# BUDGET ceiling, which already sat far above the 6.0 real run speed, so a mount never actually
# moved a player faster. This is the real mounted travel speed the client now predicts and the
# server accepts. 1.6x mirrors the pre-existing MAX_SPEED_MOUNTED_PER_TICK/MAX_SPEED_PER_TICK and
# MOVE_UNITS_MOUNTED_PER_SECOND/MOVE_UNITS_PER_SECOND ratio above (WoW's classic +60% mount tier).
const MOUNT_SPEED_MULT: float = 1.6
const PLAYER_RUN_SPEED_MOUNTED: float = PLAYER_RUN_SPEED * MOUNT_SPEED_MULT  # 9.6 units/sec
# T-534: base mob CHASE step, per SERVER TICK so it is frame-rate independent. Equal to the player's
# per-tick run distance (6.0 / 20 = 0.3) — a mob with speed_mult 1.0 exactly matches the player; the
# default per-mob multiplier (below) adds the +1% edge. Applied once per SERVER TICK (main.gd gates
# _run_mob_ai_tick on the tick-edge), never per frame. Before T-534 it was 0.15 applied EVERY FRAME
# (~9 u/s at 60 fps, frame-rate dependent — the "way too fast" bug).
const MOB_MOVE_SPEED: float = PLAYER_RUN_SPEED / float(TICK_RATE_HZ)  # 0.30 units/tick
# T-534: default per-mob chase multiplier — a chasing mob closes on a fleeing player at +1% of the
# player's run speed (barely gains, never zooms). Data-driven per mob (MobData.speed_mult) so a mob
# can be tuned deliberately fast/slow later without touching this baseline.
const MOB_CHASE_SPEED_MULT: float = 1.01
const SPAWN_EPSILON: float = 0.1  # mob considered "home" within this distance of spawn_position

# T-402: level-relative aggro model (WoW shape). The per-mob JSON `aggro_radius` is now the mob's
# SAME-LEVEL base reach; mob_aggro.gd shrinks it as the player out-levels the mob and zeroes it for
# gray mobs. Only the tuning shape lives here — the base reach stays in mob data.
#   effective = clamp(base - PER_LEVEL_SHRINK * max(0, player_level - mob_level), FLOOR, MAX)
#   ...and 0 (never aggro) once the player out-levels the mob by GRAY_DELTA+ (mirrors mob_xp.gd).
# The live T-399 defect was a ~2 m near-contact radius: a player stood 4 m from a hostile and then
# one step aggroed the whole cluster. These lift the on-level reach to the WoW ~8-20 m band.
const AGGRO_PER_LEVEL_SHRINK: float = 1.75  # metres of reach lost per level the player out-levels
const AGGRO_FLOOR: float = 5.0  # a non-gray mob always notices you inside this (contact-ish) range
const AGGRO_MAX: float = 20.0  # cap on effective reach (also the growth cap vs a higher-level mob)
const AGGRO_GRAY_DELTA: int = 8  # player out-levels the mob by this many -> gray, never aggros

# T-620: WoW-shape mob-kill XP formula (owner-adjusted mob-XP model, docs/design/quest-xp-reference
# .md §3). Replaces the old flat per-mob authored "xp" JSON value; mob_loader computes the pool at
# load time from these plus the mob's level/elite flag. The MASTER-side gray cutoff (mob_xp.gd) and
# party split still apply downstream — this only sets the BASE per-kill pool before either.
const MOB_XP_PER_LEVEL := 5  # XP = mobLevel * this + MOB_XP_BASE (WoW classic: 5*level + 45)
const MOB_XP_BASE := 45
const MOB_XP_ELITE_MULT := 2  # elites (T-294 HP/damage premium) also pay double kill XP

# T-026: Death and respawn constants (ticks @ 20 Hz).
const PLAYER_RESPAWN_TICKS := 500  # 25 seconds
const MOB_RESPAWN_TICKS := 600  # 30 seconds
# T-364: revive-sickness output multiplier — a freshly-rezzed ally deals/heals this fraction until
# their sickness window (revive_sickness_ticks, per-ability) expires. Data-tunable severity knob.
const REVIVE_SICKNESS_MULT := 0.5

# T-016: Resource regen configuration (pure-function coefficients).
# All intervals in server ticks (20 Hz). Rates are additive per interval.
const HP_REGEN_INTERVAL := 20
const HP_REGEN_PER_INTERVAL := 1
const MANA_REGEN_INTERVAL := 30
const MANA_REGEN_PER_INTERVAL := 1
const STAMINA_REGEN_INTERVAL := 10
const STAMINA_REGEN_PER_INTERVAL := 2

# T-019: Auto-attack swing timer constants.
# Formula: max(SWING_TICKS_MIN, floor(NOMINATOR / ((stamina + STAMINA_ADDEND) * weapon_speed)))
const SWING_FORMULA_NOMINATOR := 15000
const SWING_FORMULA_STAMINA_ADDEND := 100
const SWING_TICKS_MIN := 5  # 0.25 s floor at 20 Hz
const STAMINA_DRAIN_PER_SWING := 5

# D2: running drains stamina. Stubbed at 0 until walk/run speed distinction is built.
# Enable and set a real value (e.g. 1-2 per tick while running) when movement speed is added.
const STAMINA_DRAIN_PER_TICK_RUNNING := 0

# Parse-time defaults (satisfy GDScript compile-time resolution).
const DEFAULT_ENET_LISTEN_PORT := 9200
# T-374 (2026-07-13): measured cap. Worst-case single-cell crowd knee ~145 peers at the 100 ms
# broadcast budget (all four capacity levers on); 80% safety -> 115. Steady-state dispersed shape
# runs ~45% budget at this N. Next lever when this is hit: per-cell nearest-N entity cap (T-355).
const DEFAULT_MAX_PLAYERS := 115
# T-370: AOI interest filter defaults. 80 m radius is the measured lever value (T-355 spike); the
# nearest-50 cap bounds the per-peer player payload so a spawn-square crowd can't blow the frame.
# Radius 0 disables the distance filter (every same-instance peer stays visible — the pre-T-370
# all-peers behaviour) while the nearest-N cap still applies.
const DEFAULT_AOI_RADIUS := 80.0
const DEFAULT_AOI_MAX_PEERS := 50
# T-372: broadcasts between full keyframes on the delta position stream. 20 frames @ 10 Hz = a full
# re-sync every ~2 s (bounds any desync recovery); 1 disables deltas (every frame is a keyframe).
const DEFAULT_KEYFRAME_FRAMES := 20
# T-594: sleeping-zone wake margin (metres). A terrain region wakes when a player is within this
# distance of its origin, on top of nearest-origin membership. 0 = pure membership (P1: regions sit
# >=420 m apart, so a player only ever wakes the zone it stands in). The margin is the tunable for
# P2's adjacent walkable borders, where a player near a seam should keep the neighbour zone live.
const DEFAULT_ZONE_WAKE_MARGIN := 0.0

# Runtime values (set in _ready() from env vars).
static var _enet_listen_port: int = DEFAULT_ENET_LISTEN_PORT
static var _max_players: int = DEFAULT_MAX_PLAYERS
static var _master_host: String = "127.0.0.1"
static var _master_port: int = 9100
static var _aoi_radius: float = DEFAULT_AOI_RADIUS
static var _aoi_max_peers: int = DEFAULT_AOI_MAX_PEERS
static var _keyframe_frames: int = DEFAULT_KEYFRAME_FRAMES
static var _zone_wake_margin: float = DEFAULT_ZONE_WAKE_MARGIN


func _ready() -> void:
	var port: Variant = OS.get_environment("AVALON_PORT")
	if port != null and str(port) != "":
		_enet_listen_port = int(port)

	var maxp: Variant = OS.get_environment("AVALON_MAX_PLAYERS")
	if maxp != null and str(maxp) != "":
		_max_players = int(maxp)

	var master_host: Variant = OS.get_environment("AVALON_MASTER_HOST")
	if master_host != null and str(master_host) != "":
		_master_host = str(master_host)

	var master_port: Variant = OS.get_environment("AVALON_MASTER_PORT")
	if master_port != null and str(master_port) != "":
		_master_port = int(master_port)

	var aoi_r: Variant = OS.get_environment("AVALON_AOI_RADIUS")
	if aoi_r != null and str(aoi_r) != "":
		_aoi_radius = float(aoi_r)

	var aoi_n: Variant = OS.get_environment("AVALON_AOI_MAX_PEERS")
	if aoi_n != null and str(aoi_n) != "":
		_aoi_max_peers = int(aoi_n)

	var kf: Variant = OS.get_environment("AVALON_KEYFRAME_FRAMES")
	if kf != null and str(kf) != "":
		_keyframe_frames = int(kf)

	var wake: Variant = OS.get_environment("AVALON_ZONE_WAKE_MARGIN")
	if wake != null and str(wake) != "":
		_zone_wake_margin = float(wake)


static func get_listen_port() -> int:
	return _enet_listen_port


# T-370: broadcast interest radius in metres (0 disables the distance filter).
static func get_aoi_radius() -> float:
	return _aoi_radius


# T-370: nearest-N player cap per broadcast frame (crowd payload guard).
static func get_aoi_max_peers() -> int:
	return _aoi_max_peers


# T-372: broadcasts between full keyframes on the delta position stream (1 = deltas disabled).
static func get_keyframe_frames() -> int:
	return _keyframe_frames


static func get_max_players() -> int:
	return _max_players


# T-594: sleeping-zone wake margin in metres (0 = nearest-origin membership only).
static func get_zone_wake_margin() -> float:
	return _zone_wake_margin


static func get_master_host() -> String:
	return _master_host


static func get_master_port() -> int:
	return _master_port


# T-016: Resource regen accessors (pure constants, no runtime state).
static func get_hp_regen_interval() -> int:
	return HP_REGEN_INTERVAL


static func get_hp_regen_per_interval() -> int:
	return HP_REGEN_PER_INTERVAL


static func get_mana_regen_interval() -> int:
	return MANA_REGEN_INTERVAL


static func get_mana_regen_per_interval() -> int:
	return MANA_REGEN_PER_INTERVAL


static func get_stamina_regen_interval() -> int:
	return STAMINA_REGEN_INTERVAL


static func get_stamina_regen_per_interval() -> int:
	return STAMINA_REGEN_PER_INTERVAL
