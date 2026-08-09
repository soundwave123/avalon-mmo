# T-393: Rift Trials scaling brain — the PURE tier curve for the infinite-scaling endgame ladder.
# Mirrors the mob_xp.gd / leveling.gd pure-module idiom: deterministic, no DB, no OS time, inputs
# never mutated. tier -> {hp_mult, dmg_mult, timer_secs, reward_weight}, MONOTONIC and UNBOUNDED
# (the WoW M+ shape: compounding per-tier growth, so the gap to the next tier widens at the top and
# the ladder self-limits without a hard cap — fun-audit stream B / ticket D4 recommendation).
#
# SERVER-AUTHORITY: no client input ever reaches these functions. The tier comes from the master's
# rift.keystone row (read server-side at the rift threshold); the client sends only "enter with my
# keystone". instance_service._seed applies hp/dmg the same way T-294 bakes elite multipliers into
# the derived resources, so downstream damage/AI math needs zero tier-awareness.
extends RefCounted

# Per-tier compounding rates. Tier 1 is the BASELINE crypt (all multipliers 1.0) so the modeled
# L12-15 balance gate (test_crypt_bosses) stays the true floor of the ladder.
const HP_RATE := 1.12  # +12%/tier compounding — ~x3.1 at t11, ~x9.6 at t21 (M+ -like ramp)
const DMG_RATE := 1.09  # damage ramps slower than HP so higher tiers lengthen before they gib
const REWARD_RATE := 1.15  # reward weight outpaces HP: pushing up must FEEL paid (ticket D3)
# The clear timer. Flat across tiers (the M+ precedent: a dungeon's timer is fixed; the SCALING is
# what makes the same clock harder) — monotonic non-increasing, trivially.
const TIMER_SECS := 900


# Keystones live on [1, +inf). A corrupt/unset tier clamps UP to the baseline, never to a free
# tier-0 discount.
static func clamp_tier(tier: int) -> int:
	return maxi(1, tier)


static func hp_mult(tier: int) -> float:
	return pow(HP_RATE, clamp_tier(tier) - 1)


static func dmg_mult(tier: int) -> float:
	return pow(DMG_RATE, clamp_tier(tier) - 1)


static func reward_weight(tier: int) -> float:
	return pow(REWARD_RATE, clamp_tier(tier) - 1)


static func timer_secs(_tier: int) -> int:
	return TIMER_SECS


# The full tuning block for a tier — the one call sites use, so the four curves can never drift
# apart from each other.
static func params_for(tier: int) -> Dictionary:
	var t := clamp_tier(tier)
	return {
		"tier": t,
		"hp_mult": hp_mult(t),
		"dmg_mult": dmg_mult(t),
		"timer_secs": timer_secs(t),
		"reward_weight": reward_weight(t),
	}
