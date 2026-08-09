# T-452: pure, deterministic mentorship/level-sync policy.
#
# Party membership, true levels, and the true stat vector are injected server-owned snapshots.
# The module never reads packets, clocks, RNG, or global state and never mutates its inputs.
extends RefCounted

# Level-one anchors from the authoritative class-growth table. Primary stats grow away from 10;
# direct gear power (attack/armor) grows away from zero. Interpolating earned power between that
# anchor and the true vector makes a L40->L5 warrior land at L5-shaped primaries while scaling ALL
# talent/gear excess through the same cap. Unknown fields are preserved as non-power metadata.
const _POWER_ANCHORS := {
	"str": 10,
	"int": 10,
	"dex": 10,
	"spirit": 10,
	"stamina": 10,
	"attack": 0,
	"armor": 0,
}


# The active content ceiling for `peer`, derived only from the authoritative roster/levels.
# Opted-out or unpartied players retain true level. An unknown peer fails closed at level one.
static func ceiling_for(
	peer: int, party_store: Dictionary, true_levels: Dictionary, opted_in: Dictionary
) -> int:
	if not true_levels.has(peer):
		return 1
	var true_level: int = maxi(1, int(true_levels[peer]))
	if not opted_in.has(peer):
		return true_level
	var party_of: Dictionary = party_store.get("party_of", {})
	var pid: int = int(party_of.get(peer, -1))
	if pid == -1:
		return true_level
	var parties: Dictionary = party_store.get("parties", {})
	var party: Dictionary = parties.get(pid, {})
	var ceiling := true_level
	for member in party.get("members", []):
		var member_id := int(member)
		if true_levels.has(member_id):
			ceiling = mini(ceiling, maxi(1, int(true_levels[member_id])))
	return ceiling


# Scale a COPY of the complete T-399 stat vector to `ceiling`; cap-only by construction.
# Linear interpolation is over earned level intervals (L1 anchor -> true level), not raw L ratios,
# so baseline L1 power remains playable while every point earned above it is proportionally capped.
static func scale_stats(true_stats: Dictionary, true_level: int, ceiling: int) -> Dictionary:
	var out: Dictionary = true_stats.duplicate(true)
	var source_level := maxi(1, true_level)
	var target_level := clampi(ceiling, 1, source_level)
	if target_level >= source_level or source_level <= 1:
		return out
	var source_intervals := source_level - 1
	var target_intervals := target_level - 1
	for key: String in _POWER_ANCHORS:
		if not out.has(key):
			continue
		var original := maxi(0, int(out[key]))
		var anchor := mini(original, int(_POWER_ANCHORS[key]))
		var earned := original - anchor
		var scaled := anchor + (earned * target_intervals) / source_intervals
		out[key] = clampi(scaled, 0, original)
	return out
