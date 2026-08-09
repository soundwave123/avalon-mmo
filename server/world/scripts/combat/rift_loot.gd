# T-538: bespoke Rift Trials loot bands — the PURE band-selection layer that replaces the six
# borrowed crypt blues (rift_schedule "pool") with a tier-gated, rarity-banded rift set. Mirrors the
# rift_scaling.gd idiom: deterministic, no DB, no OS time, inputs never mutated.
#
# The shipped roll already scales the CHANCE with rift_scaling.reward_weight(tier) + the master's
# bad-luck floor (honest, monotonic, never for sale). This module scales the QUALITY: a deeper
# climber unlocks rarer bands, so the eligible pool GROWS and enriches with tier instead of
# flatting out at the same six items. It only widens WHICH items can drop — never the honest odds,
# and grants nothing itself (the master's _roll_reward still validates every id vs the registry).
#
# SERVER-AUTHORITY: the tier is server truth (the holder's rift.keystone, read master-side); no
# client input reaches these functions. A corrupt/unset tier clamps UP to the baseline band (band
# A only), never to a richer free pool.
extends RefCounted


# The eligible drop pool for a tier: the flattened ids of EVERY band the tier has unlocked
# (band.min_tier <= tier), lowest band first. A legacy flat "pool" (back-compat with the pre-band
# schedule) is always eligible. Order is deterministic; duplicates across bands are preserved so an
# id in two bands is simply weighted heavier — the master picks uniformly from the result.
static func eligible_pool(schedule: Dictionary, tier: int) -> Array:
	var t := maxi(1, tier)
	var out: Array = []
	for band: Dictionary in schedule.get("bands", []):
		if t >= int(band.get("min_tier", 1)):
			for it in band.get("pool", []):
				out.append(str(it))
	for it in schedule.get("pool", []):  # legacy flat pool, if any — always eligible
		out.append(str(it))
	return out


# How many bands a tier has unlocked — the "the pool keeps enriching" read for tests/telemetry.
static func bands_unlocked(schedule: Dictionary, tier: int) -> int:
	var t := maxi(1, tier)
	var n := 0
	for band: Dictionary in schedule.get("bands", []):
		if t >= int(band.get("min_tier", 1)):
			n += 1
	return n


# The reward payload the world hands the master for one adjudicated clear: the tier-eligible pool +
# the published base odds. weight stays the caller's (rift_scaling.reward_weight(tier)) so the
# CHANCE curve and the QUALITY curve are wired from the same tier, never able to drift apart.
static func reward_payload(schedule: Dictionary, tier: int, weight: float) -> Dictionary:
	return {
		"pool": eligible_pool(schedule, tier),
		"base_chance": float(schedule.get("base_chance", 0.0)),
		"weight": weight,
	}
