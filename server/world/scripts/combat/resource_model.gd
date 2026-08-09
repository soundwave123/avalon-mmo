# T-062: pure class-resource model — rage (Warrior) and mana (casters). Clock-injected and
# deterministic (RefCounted, all static); `now` (server tick) is always passed in, never OS time.
#
# Keyed by resource KIND so a future class's energy/combo points is data + one branch here, not a
# rewrite (the ADR 0010 scalability rule). The constants below are the one tunable home.
#
# WoW Classic reference:
#   Rage — 0..100; built by landing auto-attacks (scaled by damage dealt) and by taking damage;
#          decays while OUT of combat; no passive regen.
#   Mana — max from Intellect (stat_converter.max_mana); Spirit drives regen
#          (stat_converter.mana_regen_per_interval), but it is HALTED for 5 s after any spend (the
#          "5-second rule"); a small flat base regen always applies.

extends RefCounted

const _STC = preload("res://scripts/combat/stat_converter.gd")

# Resource kinds (a character has exactly one, by class; "none" = no class resource).
const RAGE := "rage"
const MANA := "mana"
const NONE := "none"

# --- Rage (tunable) ---
const RAGE_MAX := 100
const RAGE_PER_DAMAGE_DEALT := 0.5  # rage gained per point of auto-attack damage landed
const RAGE_PER_DAMAGE_TAKEN := 0.5  # rage gained per point of damage suffered
const RAGE_DECAY_INTERVAL_TICKS := 10  # how often out-of-combat decay ticks
const RAGE_DECAY_PER_INTERVAL := 2  # rage shed per decay interval while out of combat
const RAGE_OUT_OF_COMBAT_TICKS := 100  # 5 s at 20 tps with no combat before rage decays

# --- Mana (tunable) ---
const MANA_REGEN_INTERVAL_TICKS := 30  # how often regen ticks (matches M1 mana cadence)
const MANA_REGEN_BASE := 1  # flat regen that always applies (even within the 5-second rule)
const FIVE_SECOND_RULE_TICKS := 100  # 5 s at 20 tps — Spirit regen halted this long after a spend


# Rage from a landed auto-attack / ability hit. Clamped to [0, RAGE_MAX]. Negative damage = no gain.
static func rage_on_damage_dealt(current: int, damage: int) -> int:
	var gained: int = int(round(float(maxi(0, damage)) * RAGE_PER_DAMAGE_DEALT))
	return clampi(current + gained, 0, RAGE_MAX)


# Rage from suffering damage (the defender builds rage too — WoW warrior tanking).
static func rage_on_damage_taken(current: int, damage: int) -> int:
	var gained: int = int(round(float(maxi(0, damage)) * RAGE_PER_DAMAGE_TAKEN))
	return clampi(current + gained, 0, RAGE_MAX)


# Out-of-combat rage decay. No decay in combat (now within out_of_combat_ticks of last combat).
# Ticks down on the decay interval. Pure: returns the new rage.
static func decay_rage(
	current: int, last_combat_tick: int, now: int, out_of_combat_ticks: int
) -> int:
	if now - last_combat_tick < out_of_combat_ticks:
		return current  # still in combat — rage holds
	if now % RAGE_DECAY_INTERVAL_TICKS != 0:
		return current
	return maxi(0, current - RAGE_DECAY_PER_INTERVAL)


# Mana regen with the 5-second rule. Spirit regen only applies once FIVE_SECOND_RULE_TICKS have
# elapsed since the last spend; a flat base regen always applies. Fires on the regen interval.
static func regen_mana(
	current: int, max_mana: int, last_spend_tick: int, now: int, spirit: int
) -> int:
	if now % MANA_REGEN_INTERVAL_TICKS != 0:
		return current
	var amount: int = MANA_REGEN_BASE
	if now - last_spend_tick >= FIVE_SECOND_RULE_TICKS:
		amount = _STC.mana_regen_per_interval(spirit)
	return mini(max_mana, current + amount)


# Can the entity afford `cost` of its resource? (The server's affordability gate on use_ability.)
static func can_afford(current: int, cost: int) -> bool:
	return current >= cost


# Spend (clamped to 0) — caller records the spend tick for the 5-second rule.
static func spend(current: int, cost: int) -> int:
	return maxi(0, current - maxi(0, cost))


# Starting resource (kind, current, max) from class + Intellect. Warrior rage starts
# empty (built in combat); caster mana starts full. Returned as a Dictionary so combat_resources and
# tests share one source of truth; "none" classes get an inert zero resource.
static func initial_for_class(char_class: String, int_val: int) -> Dictionary:
	match char_class:
		"warrior":
			return {"kind": RAGE, "current": 0, "max": RAGE_MAX}
		"mage", "priest":
			var m: int = _STC.max_mana(int_val)
			return {"kind": MANA, "current": m, "max": m}
		_:
			return {"kind": NONE, "current": 0, "max": 0}
