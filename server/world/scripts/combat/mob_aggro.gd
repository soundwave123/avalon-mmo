# T-402: level-relative aggro radius — pure, deterministic, no OS time / no global state.
#
# The engine's original aggro was a flat near-contact radius (~2-6 m): a player could stand just
# outside it indefinitely, then one step aggroed the whole cluster (T-399 live defect). WoW-family
# aggro is level-relative — ~8-20 m at/below your level, shrinking smoothly as you out-level the
# mob, with a floor, and ZERO once the mob is "gray" (out-leveled past the cutoff).
#
# `base_radius` is the mob's authored SAME-LEVEL reach (mob JSON `aggro_radius`). `leash_radius` is
# the mob's tether from spawn — the effective reach is never allowed to exceed it, so a mob can't
# aggro a target it would evade off of on the very next tick. Every tuning constant lives in
# server_config (AGGRO_*); this module only does the arithmetic. Inputs are never mutated.

extends RefCounted

const _SC = preload("res://scripts/server_config.gd")


# Effective aggro radius for this (mob, player) level pair. Returns 0.0 when the mob is gray to the
# player (never aggros). Callers compare against squared distance via effective_radius_sq() to keep
# the per-mob-per-tick proximity check cheap.
static func effective_radius(
	base_radius: float, mob_level: int, player_level: int, leash_radius: float = INF
) -> float:
	var over: int = player_level - mob_level  # how far the player OUT-levels the mob (may be < 0)
	if over >= _SC.AGGRO_GRAY_DELTA:
		return 0.0  # gray mob — never aggros (anti-farm, mirrors mob_xp.GRAY_DELTA)
	var r: float = base_radius - _SC.AGGRO_PER_LEVEL_SHRINK * float(over)
	var ceiling: float = minf(_SC.AGGRO_MAX, leash_radius)
	return clampf(r, _SC.AGGRO_FLOOR, ceiling)


# Squared effective radius for a distance_squared_to() early-out (no sqrt in the hot path). Returns
# 0.0 for a gray mob so `dist_sq <= 0.0` fails for any real separation — gray mobs never aggro.
static func effective_radius_sq(
	base_radius: float, mob_level: int, player_level: int, leash_radius: float = INF
) -> float:
	var r: float = effective_radius(base_radius, mob_level, player_level, leash_radius)
	return r * r
