# T-594: prop-streaming policy — decides WHICH world-dressing props are resident given the player's
# position, so a continent's worth of dressing never sits in memory at once. Pure + static (mirrors
# lod_policy.gd): world_props_layer.gd owns the GLB node lifecycle and calls this to plan streaming.
# No node, no OS time, no viewport, inputs never mutated — so the decision is unit-testable in
# isolation and, crucially, DETERMINISTIC.
#
# TWO gates, matching continent-plan (hand-authored hubs resident; procedural dressing streams):
#   1. REGION residency (coarse). A prop only loads while its terrain region (the nearest T-590
#      origin) is the player's region. Crossing to another region (a rift/flight — already a loading
#      moment) swaps the whole dressing set; this alone drops every other era's props (the ~148
#      Ashmoor props never instantiate while you stand in the Wold). world_props_layer tears the old
#      region down whole on a change, so no per-building interior/collision bookkeeping leaks.
#   2. DISTANCE ring (fine). Within the active region each prop CLASS has a draw-distance ring —
#      hero landmark (infinite) > building (large) > flora carpet (small). Only FLORA streams by
#      distance (buildings/hero keep their silhouette = navigation), so the individual load/unload
#      path only ever touches simple decorative nodes (leak-safe). The ring is the per-km² density
#      lever the big P2 zones need at ~300-500 props/km².
#
# DETERMINISM: `resident_target` is a pure function of player position (no hysteresis, no history) —
# walking a border back and forth always yields the identical resident set — the leak/orphan test's
# invariant. `plan` is a pure set difference. The FLORA ring is chunky (>100 m) and the layer's
# streaming pass throttled, so boundary micro-jitter can at most load/unload a prop a few times a
# second, never per frame.

extends RefCounted

# Draw-distance tiers, most-resident first (continent-plan §6.4: hero landmark > building > flora).
enum { TIER_HERO, TIER_BUILDING, TIER_FLORA }

# Default ring radii (m). Deliberately set ABOVE the LodPolicy cull distances so P1 has zero visible
# pop-in: anything streamed out was already past its draw distance. The flora ring (340) exceeds the
# longest flora cull (tree impostor cull 320, sapling 240); the building ring (900) exceeds a whole
# P1 zone (Wold diagonal ~877 m, farthest region-0 building 338 m from origin) so every in-region
# building stays resident — buildings only stream at the REGION seam (rift/flight), never mid-zone,
# at P1. Both rings become real per-km² density levers at the 8 km P2 zone sizes. Override via cfg.
const DEFAULT_FLORA_RING := 340.0
const DEFAULT_BUILDING_RING := 900.0

# T-692 Part B: deterministic flora-density thinning (see density_kept below) — Knuth's 2^32/phi
# multiplier, taken mod 1000 permille buckets. gcd(K mod 1000, 1000) = 1, so any 1000 consecutive
# indices map to a permutation of the buckets: the kept count over a full bucket is EXACT.
const _DENSITY_HASH := 2654435761

# Hub set-piece scene stems + tags — hand-authored landmarks that stay resident within their region
# (never distance-culled): the capital, the cathedral/keep silhouette, the era rift monolith.
const _HERO_STEMS := [
	"prop_hk_keep",
	"prop_hk_cathedral",
	"prop_hk_gatehouse",
	"prop_hk_walls",
	"prop_hk_bank",
	"prop_hk_auction",
	"prop_rift",
	"prop_monolith",
	"prop_watchtower",
]
const _HERO_TAGS := ["highkeep", "capital", "hero", "rift"]

# Structure stems — the building ring (silhouette = navigation, so a large ring).
const _BUILDING_STEMS := [
	"prop_house",
	"prop_hk_house",
	"prop_cottage",
	"prop_inn",
	"prop_tavern",
	"prop_smithy",
	"prop_barn",
	"prop_farmhouse",
	"prop_watermill",
	"prop_windmill",
	"prop_dovecote",
	"prop_palisade",
	"prop_church",
	"prop_warehouse",
	"prop_constab",
	"prop_shop",
	"prop_stable",
]


# The draw-distance tier for a prop's scene basename + authoring tag. Tag wins for hub set-pieces
# (an authored landmark is resident regardless of its mesh); otherwise the scene stem decides
# building vs flora. Unknown/decorative props (trees, rocks, ferns, flowers, fences, clutter) fall
# through to FLORA — the streaming carpet.
static func classify(scene_base: String, tag: String) -> int:
	for t in _HERO_TAGS:
		if tag == t:
			return TIER_HERO
	for s in _HERO_STEMS:
		if scene_base.begins_with(s):
			return TIER_HERO
	for s in _BUILDING_STEMS:
		if scene_base.begins_with(s):
			return TIER_BUILDING
	return TIER_FLORA


# The ring radius (m) for a tier: HERO is unbounded within its region (INF), BUILDING + FLORA read
# their configured rings.
static func ring_for(tier: int, cfg: Dictionary) -> float:
	if tier == TIER_HERO:
		return INF
	if tier == TIER_BUILDING:
		return float(cfg.get("building_ring", DEFAULT_BUILDING_RING))
	return float(cfg.get("flora_ring", DEFAULT_FLORA_RING))


# T-692 Part B: preset knobs riding the same stream cfg dict as the rings ({flora_ring,
# building_ring, flora_density, lod_mult}). Pure readers so the layer and the chunk pools share
# one truth for defaults/clamping.
static func lod_mult(cfg: Dictionary) -> float:
	return float(cfg.get("lod_mult", 1.0))


static func flora_density(cfg: Dictionary) -> float:
	return clampf(float(cfg.get("flora_density", 1.0)), 0.0, 1.0)


# T-692 Part B: does manifest index `index` survive a flora density in [0, 1]? A pure function of
# the index (multiplicative hash into permille buckets), so the kept subset is identical every
# boot AND monotonic across tiers — everything kept at 0.5 is also kept at 0.75, so raising the
# preset only ADDS flora (no reshuffle).
static func density_kept(index: int, density: float) -> bool:
	if density >= 1.0:
		return true
	if density <= 0.0:
		return false
	return (index * _DENSITY_HASH) % 1000 < int(density * 1000.0)


# T-692 Part B: the load_manifest thinning gate. Only the decorative FLORA carpet thins —
# buildings/hero keep their silhouette (navigation) at every tier, and special bases (critters/
# night-lights/legacy chimneys: gameplay + lighting, not carpet) are never dropped.
static func density_drops(
	tier: int, base: String, index: int, cfg: Dictionary, special: Dictionary
) -> bool:
	if tier != TIER_FLORA or special.has(base):
		return false
	return not density_kept(index, flora_density(cfg))


# The index (into `origins`) of the region a ground position belongs to — nearest origin, the T-371
# idiom mirrored client-side. `origins` is an Array of Vector2 (terrain_field.region_origins()).
# -1 when the table is empty.
static func region_of(ground: Vector2, origins: Array) -> int:
	var best := -1
	var best_d2: float = INF
	for i in origins.size():
		var d2: float = ground.distance_squared_to(origins[i])
		if d2 < best_d2:
			best_d2 = d2
			best = i
	return best


# The set {meta_index: true} of props that should be resident RIGHT NOW for a player at `player`
# (ground x,y) whose active region is `region`. A meta entry is {i:int, ground:Vector2, tier:int,
# region:int}. A prop is resident iff its region is the active region AND it is within its tier's
# ring. Pure function of `player` — the determinism guarantee.
static func resident_target(
	metas: Array, player: Vector2, region: int, cfg: Dictionary
) -> Dictionary:
	var out: Dictionary = {}
	var flora_r: float = float(cfg.get("flora_ring", DEFAULT_FLORA_RING))
	var building_r: float = float(cfg.get("building_ring", DEFAULT_BUILDING_RING))
	for m in metas:
		if int(m["region"]) != region:
			continue
		var tier: int = int(m["tier"])
		if tier == TIER_HERO:
			out[int(m["i"])] = true
			continue
		var ring: float = building_r if tier == TIER_BUILDING else flora_r
		if (m["ground"] as Vector2).distance_to(player) <= ring:
			out[int(m["i"])] = true
	return out


# The load/unload plan to move from the `current` resident set to the `target` set (both {i: true}).
# {load: Array[i], unload: Array[i]}. Pure set difference — no dupes: an index already resident is
# never in `load`, an index still wanted is never in `unload`.
static func plan(current: Dictionary, target: Dictionary) -> Dictionary:
	var load_list: Array = []
	var unload_list: Array = []
	for i in target:
		if not current.has(i):
			load_list.append(i)
	for i in current:
		if not target.has(i):
			unload_list.append(i)
	return {"load": load_list, "unload": unload_list}


# Is this FLORA-tier prop safe to stream individually (load/unload without region teardown)? True
# plain decorative flora; FALSE for anything that builds satellite state the layer would have to
# unwind by hand — a critter (its wander entry) is the one FLORA-classed exception. Buildings/hero
# are never individually streamed (they ride the region teardown), so only FLORA is asked.
static func flora_streamable(scene_base: String, critter_bases: Dictionary) -> bool:
	return not critter_bases.has(scene_base)


# T-693: the NAME-level half of the "may this prop batch into a chunked MultiMesh?" decision.
# Batching is for the repeated decorative carpet, so: FLORA tier only (hero landmarks, buildings
# and tag-promoted set-pieces keep the individual path), and none of the layer's special-cased
# bases (`special_bases` = critters + engine-attached night-light/legacy-chimney props — anything
# world_props_layer bolts satellite state onto by basename). The CONTENT half (a GLB carrying
# lights/sockets/an AnimationPlayer/a door marker) is checked at mesh-library extraction in
# prop_chunks.gd — both must pass. Pure, so it's unit-testable next to classify().
static func batchable_stem(scene_base: String, tag: String, special_bases: Dictionary) -> bool:
	if classify(scene_base, tag) != TIER_FLORA:
		return false
	return not special_bases.has(scene_base)


# T-693 residual #2: may a TAG-promoted hero placement render via an ALWAYS-RESIDENT chunk pool?
# The 216 "highkeep"-tagged dressing placements are TIER_HERO purely by authoring tag — mostly
# repeated flora/clutter scenes (fences, barrels, banner poles) pinned resident so the capital
# never pops. The tag's SEMANTICS are residency, not per-node rendering, so those whose SCENE
# would otherwise be plain batchable flora may batch into hero pools that mirror the residency
# (never ring-streamed, torn down only at the region seam). True hero landmarks (hero STEMS —
# keep/cathedral/rift), buildings, and the layer's special bases keep the individual path. The
# GLB content gate in prop_chunks._extract (lights/sockets/AnimationPlayer/door) still applies.
static func hero_batchable_stem(scene_base: String, tag: String, special_bases: Dictionary) -> bool:
	if classify(scene_base, tag) != TIER_HERO:
		return false
	if classify(scene_base, "") != TIER_FLORA:
		return false  # promoted by its own stem (landmark) or a building-stem scene — individual
	return not special_bases.has(scene_base)
