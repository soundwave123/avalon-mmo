# T-360: Rested XP — the vision doc's flagship endowed-progress / "log-off is a gift" lever.
#
# A character banks a rested POOL (measured in XP-equivalent points) while logged out, then spends
# it as bonus XP on quest turn-ins until it drains. This module is the PURE authority on the two
# operations: accrue-over-elapsed-time and split-an-award. It mirrors the pure-tick idiom of
# leveling.gd / npc_wander.gd:
#   - no OS time (the caller injects elapsed seconds — accrual measured across offline periods)
#   - no DB, no side effects, inputs never mutated, fully deterministic
#   - the level-scaled cap is injected too (the WoW "150% of a level" ceiling is curve-dependent;
#     the caller computes it from leveling.gd so this module stays standalone and test-safe).
#
# Reconciliation with the XP curve (T-360 test assertion #3): rested only ever ACCELERATES within
# the existing curve. `bonus` is drawn from a finite banked pool, so it is a transient multiplier on
# the quest XP faucet, never a new uncapped source. tools/xp_ledger.py counts authored quest XP and
# is unaffected by construction (rested is runtime-only, not content).

extends RefCounted


# Bank rested points earned over `elapsed_seconds` logged out, at `rate_per_hour`, clamped to `cap`.
# Integer-floored (no fractional points). Negative / zero / already-over-cap inputs are all safe:
# the result is always in [0, cap]. `pool` is never mutated.
static func accrue(pool: int, elapsed_seconds: int, rate_per_hour: int, cap: int) -> int:
	var p: int = maxi(0, pool)
	var c: int = maxi(0, cap)
	if elapsed_seconds <= 0 or rate_per_hour <= 0:
		return mini(p, c)
	var gained: int = (rate_per_hour * elapsed_seconds) / 3600  # integer floor
	return clampi(p + gained, 0, c)


# Split a base XP award into normal + rested-boosted. WoW's model: each point of base XP (up to the
# banked pool) earns an extra `bonus_percent`% AND drains the pool 1:1 with the base it boosted — so
# a pool of P boosts the first P points of base XP, then the remainder is awarded normally. Returns
# {base, bonus, total, pool_after, boosted_base}. Pure; inputs unmutated.
#
# Example (bonus_percent 100 = double): pool 150, base 200 -> boosted_base 150, bonus 150,
# total 350, pool_after 0. The last 50 base points fall outside the pool and get no bonus.
static func split_award(pool: int, base_xp: int, bonus_percent: int) -> Dictionary:
	var p: int = maxi(0, pool)
	var base: int = maxi(0, base_xp)
	var pct: int = maxi(0, bonus_percent)
	var boosted_base: int = mini(p, base)  # base XP that receives the rested bonus
	var bonus: int = (boosted_base * pct) / 100  # extra XP granted (integer floor)
	return {
		"base": base,
		"bonus": bonus,
		"total": base + bonus,
		"boosted_base": boosted_base,
		"pool_after": p - boosted_base,
	}
