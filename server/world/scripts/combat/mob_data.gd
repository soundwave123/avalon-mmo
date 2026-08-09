# T-025: Mob entity state — server-side only.
# No class_name — avoids parse-gate cache issues; consumers preload via const.
# T-052: positions are Vector3 — (x, y) is the ground plane, z is height (0 on flat ground; the
# client remaps to Godot's y-up at render time).

extends RefCounted

# T-560: floor a non_lethal trainer's hit at 15% of max HP — a sting, never a kill.
const NON_LETHAL_FLOOR_PCT := 0.15

var entity_id: int = -1
# T-331: soft-instance scope. 0 = the shared open world (every existing spawn). A non-zero id ties
# this mob to one Hollowed Crypt instance so the positions broadcast only shows it to that party.
var instance_id: int = 0
var mob_type_id: int = 1
var mob_id: String = ""  # T-042: string alias (mob_<name>) for quest kill-objective matching
var name: String = "Mob"
var position: Vector3 = Vector3.ZERO
var spawn_position: Vector3 = Vector3.ZERO
var aggro_radius: float = 5.0
var leash_radius: float = 15.0
var melee_range: float = 2.0
# T-534: per-mob chase-speed multiplier applied to ServerConfig.MOB_MOVE_SPEED (the player-matched
# per-tick step). Default 1.01 mirrors ServerConfig.MOB_CHASE_SPEED_MULT: a chasing mob closes on a
# fleeing player at +1% of run speed. Data-driven (loaded from JSON "speed_mult") so a mob can be
# tuned fast/slow later. Literal default keeps this file preload-free (parse-gate).
var speed_mult: float = 1.01
var ai_state: int = 0  # MobAIState value from mob_ai.gd; int avoids circular preload
var current_target_id: int = -1
var combat_state = null  # CombatState
var resources = null  # CombatResources
var stats = null  # CharacterStats
var melee_ability = null  # AbilityData — built from mob JSON at load time
var loot: Array = []  # T-073: loot-table entries [{item_id, chance, count_min, count_max}]
var difficulty: int = 1  # T-232: 1-5, drives the rarity-weighted loot roll
# T-358: mob-kill XP. `xp` = the authored per-kill XP value (0 = grants none, e.g. the dummy);
# `mob_level` gates the gray-mob cutoff (mob_xp.gd) so out-leveled kills grant nothing. Both are
# server-observed and applied master-side via the kill-credit snapshot — never client-asserted.
var xp: int = 0
var mob_level: int = 1
# T-411: rare/variable-ratio spawn tuning (set per spawns.json entry by mob_loader; fail-open so
# every existing entry is unchanged). spawn_chance = probability the mob re-appears on a given
# respawn cycle (1.0 = an ordinary always-present mob); a rare (<1.0) is dormant for a geometric
# number of cycles, so its return is unpredictable — the variable-ratio "burst" the ticket wants.
# respawn_ticks = this mob's DEAD->IDLE dwell (defaults to the global ServerConfig.MOB_RESPAWN_TICKS
# in the loader; a rare authors a long dwell). Both are server-side timers — no client verb.
var spawn_chance: float = 1.0
var respawn_ticks: int = 600  # mirrors ServerConfig.MOB_RESPAWN_TICKS; overridden per spawn entry
# T-080: patrol — wander inside this radius of spawn while IDLE (0 = stationary).
var patrol_radius: float = 0.0
var patrol_target: Vector3 = Vector3.INF  # INF = no waypoint chosen yet
# T-516: a training dummy — a static, passive practice target. It never aggros, moves, or attacks
# (the AI tick is a full no-op); it stays targetable and takes damage. Loaded from the JSON "dummy".
var is_dummy: bool = false
# T-564: retaliate-only — passive until attacked, then fights back exactly like a normal mob. Unlike
# is_dummy (a full AI no-op — never aggros, never channels), this mob still has real AI: it just
# never PROXIMITY-aggros (mob_ai._tick_idle skips the aggro_radius scan for it). It still aggros the
# instant it takes threat (T-070's existing threat-pull check, which ignores aggro_radius already —
# see mob_ai._tick_idle), so attacking it engages it fully. Fixes report #18: the tutorial sparring
# effigy (training_effigy.json) was proximity-aggroing an idle new player walking up to the quest
# giver, before the trainee had done anything — a training target should never attack unprovoked.
# Loaded from the JSON "retaliate_only".
var retaliate_only: bool = false
# T-560: a non-lethal trainer (the tutorial sparring effigy) may bruise a player but must NEVER land
# the killing blow — the training-ring encounter teaches interrupting (q_tut_03, no kill required),
# so an idle or confused new player standing at the ring cannot die to the practice target. Loaded
# from the JSON "non_lethal"; the damage cap is enforced by non_lethal_damage() at apply time.
var non_lethal: bool = false
# T-350: ranged/kite profile (gun mobs — the T-349 Gunsel/Torpedo). ranged=false leaves a mob
# pure-melee (every field below inert), so the whole melee family is untouched. A ranged mob
# holds a firing BAND [ranged_min, ranged_max]: it closes when farther than max, kites BACK when
# closer than min, and fires (hitscan) only while inside the band. ranged_burst>1 = the tommy's
# multi-hit window (each shot is its own damage event + tracer). ranged_attack selects the client
# muzzle/tracer/audio look ("revolver" | "tommy_burst"). Loaded from the JSON "_ranged" block.
var ranged: bool = false
var ranged_min: float = 0.0
var ranged_max: float = 0.0
var ranged_attack: String = ""
var ranged_burst: int = 1
# T-294: elite / rare tier. Data-driven; the loader bakes the HP/damage multipliers into the
# resources and the melee ability at load time, so combat math downstream is unchanged.
var elite: bool = false
# T-294: render silhouette when it differs from mob_id — an elite reuses a base creature model
# (e.g. mob_wolf) while mob_id stays a UNIQUE kill-credit alias (e.g. mob_greymaw). Empty = use
# mob_id (the normal path). Broadcast as `kind`; the client picks the visual from it.
var render_kind: String = ""
# T-294: enrage — the elite's extra ability, on the existing swing path (no new effect framework):
# at/below enrage_threshold HP fraction the next melee swings hit for enrage_mult× damage.
# Defaults (0.0 / 1.0) make it inert for normal mobs.
var enrage_threshold: float = 0.0
var enrage_mult: float = 1.0
# T-332: Hollowed Crypt boss mechanics — ONE data-driven mechanic beyond the T-294 enrage, advanced
# by boss_mechanics.gd (pure) and resolved against the live world by instance_service.tick_bosses.
# Empty boss_mechanic = a normal mob/elite (fields below stay inert). ALL must survive the mob_ai
# tick copy (_copy_mob) — the alias/loot drift trap the earlier tickets hit.
var boss_mechanic: String = ""  # "" | "summon" | "dirge" | "phase_summon" (the three bosses)
# T-434: encounter guardrails. Final bosses may resist hard CC/interrupts; interrupt-teaching
# bosses leave interrupt_immune false. These are loaded server-side and never client-asserted.
var control_immune: bool = false
var interrupt_immune: bool = false
var mechanic_cadence: int = 0  # server ticks between activations (summon waves / dirge casts)
var last_mechanic_tick: int = -100000  # tick the mechanic last completed; -100000 = armed on pull
# Summon (Warden / Maldrath): raise adds at these WORLD anchors, capped at max_adds alive at once.
var add_mob_file: String = ""  # e.g. "skeletal_warrior.json" — resolved under res://data/mobs
var add_render_kind: String = ""  # visual kind broadcast for the add (a base undead silhouette)
var add_anchors: Array = []  # [[x, y], ...] world ground coords (mirror layout.json add_anchors)
var max_adds: int = 0  # cap on simultaneously-live summoned adds
# Dirge (Vharis): a channeled room-wide pulse the party interrupts by out-damaging a threshold — it
# reuses the CombatState.CHANNELING + cast_start/cast_end plumbing (T-017), not a new timer.
var dirge_channel_ticks: int = 0  # channel length in ticks (uninterrupted → full pulse train)
var dirge_damage: int = 0  # damage per channel tick to every in-instance player inside dirge_radius
var dirge_radius: float = 0.0  # AoE radius around the boss (room-wide — positioning does not dodge)
var dirge_interrupt_damage: int = 0  # boss HP lost DURING the channel that cancels the dirge
var dirge_hp_at_start: int = -1  # boss HP snapshot when the channel began (the interrupt reference)
# Phase (Maldrath): a one-time flip at phase2_threshold HP fraction — enrage (set enrage_threshold
# to the SAME fraction so the T-294 swing path handles it) plus a faster summon cadence.
var phase2_threshold: float = 0.0
var phase2_cadence: int = 0
var in_phase2: bool = false
# T-332: broadcast render scale (the Hollow King towers). 1.0 = the base mesh; the client multiplies
# its GLB_MODELS scale by this. Visual-only, defaults inert.
var render_scale: float = 1.0
# T-332: a summoned add is TEMPORARY — erased on death (killing it makes it STAY dead, teaching
# focus-fire) and on instance teardown, and tagged with the boss entity_id that raised it (add-cap
# counting). -1 / false = a normal, respawning mob.
var temporary: bool = false
var summoned_by: int = -1


# T-560: cap an incoming hit so a non_lethal trainer (the sparring effigy) can never reduce a player
# below the HP floor. Static + pure so the "repeated effigy hits do not kill a trainee" guarantee
# unit-tests in isolation. A lethal mob (or a null target) is returned unchanged; once the target is
# at/under the floor the result is 0 (no killing blow — main's amount>0 guard then skips the death
# check). `mob` and `res` are duck-typed (mob.non_lethal; res.hp / res.max_hp).
static func non_lethal_cap(mob, incoming: int, res) -> int:
	if not mob.non_lethal or res == null:
		return incoming
	var floor_hp: int = int(ceil(float(res.max_hp) * NON_LETHAL_FLOOR_PCT))
	return clampi(incoming, 0, maxi(0, res.hp - floor_hp))
