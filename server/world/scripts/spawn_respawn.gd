class_name SpawnRespawn
extends RefCounted


# T-414: the variable-ratio respawn math, extracted from mob_loader.next_respawn_ticks (T-411) so
# gathering nodes reuse it instead of duplicating it. Pure/deterministic given rng (caller injects
# it), no OS time — mirrors the pure-tick module contract.
#
# An always-present source (spawn_chance >= 1.0) returns exactly its base dwell. A rare source
# (spawn_chance < 1.0) folds a variable-ratio roll into the single respawn interval computed at
# depletion time: it draws a GEOMETRIC number of dormant cycles (Bernoulli success prob =
# spawn_chance) and stays gone for that many dwells, so its return is unpredictable but bounded by
# `cycle_cap` (a pathological streak can't strand it forever). spawn_chance <= 0 is treated as the
# floor (never silently "never respawns").
static func next_ticks(respawn_ticks: int, spawn_chance: float, rng, cycle_cap: int = 12) -> int:
	var base: int = maxi(1, respawn_ticks)
	var chance: float = clampf(spawn_chance, 0.0, 1.0)
	if chance >= 1.0:
		return base
	var cap: int = maxi(1, cycle_cap)
	var cycles: int = 1
	while cycles < cap and (chance <= 0.0 or rng.randf() >= chance):
		cycles += 1
	return base * cycles
