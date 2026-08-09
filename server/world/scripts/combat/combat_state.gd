class_name CombatState

# T-017: Per-entity combat state struct.
#
# Pure data — no side effects, no OS time, no engine calls.
# Instances are copied by tick()/advance_timers() via duplicate();
# the original is never mutated (pure-function discipline).
#
# GCD tick constant: 1.5s at 20 Hz = 30 ticks (from ServerConfig).

extends RefCounted

# ---- Enums ----

enum CombatStateEnum {
	IDLE,
	GLOBAL_COOLDOWN,
	CASTING,
	CHANNELING,
	EXECUTING,
	DEAD,
}

enum IntentType {
	USE_ABILITY,
	CANCEL_CAST,
}

# ---- Sub-classes ----


class CombatIntent:
	"""
	Client-sent intent. Only type/ability_id/target_id travel with it —
	positions are NEVER client-supplied (server owns truth).
	triggers_gcd: set by the server when translating intent from ability config.
	Client never decides GCD timing.
	"""
	var type: IntentType = IntentType.USE_ABILITY
	var ability_id: int = -1
	var target_id: int = -1
	var triggers_gcd: bool = true
	var cast_ticks: int = 0  # T-022: 0 = instant; >0 = cast-time (set by ability_executor)


class CombatEvent:
	"""
	Emit from tick() / advance_timers(). The netcode layer consumes these
	to broadcast state changes. In M1 we only need DEDUCT_MANA.
	"""
	enum EventType {
		DEDUCT_MANA,
		ABILITY_HIT,
		ABILITY_REJECTED,
	}
	var event_type: EventType = EventType.DEDUCT_MANA
	var amount: int = 0
	var ability_id: int = -1


class CombatResult:
	"""
	Returned by tick(). Carries a NEW CombatState (input is never mutated),
	whether the intent was accepted, rejection reason if not, and emitted events.
	"""
	var new_state: CombatState = null
	var accepted: bool = false
	var rejection_reason: String = ""
	var events: Array[CombatEvent] = []


# ---- Fields ----

var state: CombatStateEnum = CombatStateEnum.IDLE
var gcd_until: int = 0  # server tick when GCD expires
var cast_start: int = 0  # server tick when cast began
var cast_end: int = 0  # server tick when cast completes
var position_snapshot: Vector3 = Vector3.ZERO
var cast_target_id: int = -1
var cast_ability_id: int = -1
var next_swing_tick: int = 0  # T-019: tick at which next auto-attack fires
var respawn_at: int = 0  # T-026: tick when respawn fires; set on DEAD entry
var stunned_until: int = 0  # T-063: control — cannot act until this tick (0 = not stunned)
var rooted_until: int = 0  # T-063: control — cannot move until this tick (0 = not rooted)
var revive_sickness_until: int = 0  # T-364: rez debuff — reduced damage/heal output until this tick
# T-434: all clocks remain server-owned and tick-injected. Dictionaries are deep-copied below so
# pure resolution never mutates an input state's cooldown, school-lock, or DR tables by alias.
var ability_cooldowns: Dictionary = {}  # ability_id -> ready tick
var school_locks: Dictionary = {}  # school -> ready tick
var control_dr_stages: Dictionary = {}  # category -> 0..3 (next duration step)
var control_dr_reset_at: Dictionary = {}  # category -> tick that restores full duration
var last_full_interrupt_at: int = -1  # boss mechanics consume this to start post-kick cadence


# T-051: single full CombatState copy. Replaced 3 drifting hand-copies (one dropped cast fields, a
# mob_id-class bug). Add any new CombatState field here only.
func copy() -> CombatState:
	var c := CombatState.new()
	c.state = state
	c.gcd_until = gcd_until
	c.cast_start = cast_start
	c.cast_end = cast_end
	c.position_snapshot = position_snapshot
	c.cast_target_id = cast_target_id
	c.cast_ability_id = cast_ability_id
	c.next_swing_tick = next_swing_tick
	c.respawn_at = respawn_at
	c.stunned_until = stunned_until
	c.rooted_until = rooted_until
	c.revive_sickness_until = revive_sickness_until
	c.ability_cooldowns = ability_cooldowns.duplicate(true)
	c.school_locks = school_locks.duplicate(true)
	c.control_dr_stages = control_dr_stages.duplicate(true)
	c.control_dr_reset_at = control_dr_reset_at.duplicate(true)
	c.last_full_interrupt_at = last_full_interrupt_at
	return c
