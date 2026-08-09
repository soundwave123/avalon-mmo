# T-594: sleeping zones — the server perf floor for continent scale. A terrain region (the T-590/
# T-593 WorldRegions table) with no player in or near it ticks NOTHING: its mobs are skipped by
# the mob-AI pass, so an empty zone costs O(regions) awake-set math instead of O(mobs-in-zone) every
# server tick. As the land grows from 1 km² to ~150 km² the mob count grows with it, but the WORK
# stays bounded by the handful of zones that actually hold players. Pure + static (mirrors
# broadcast_builder.gd / mob_ai.gd): the awake set and the per-mob gate are unit-tested in isolation
# and main._run_mob_ai_tick is the only caller.
#
# CORRECTNESS — why skipping a mob's tick is safe. A skipped mob's combat_state is NOT advanced
# its zone sleeps, and that is fine because every timer (DEAD->IDLE respawn, GCD, root/stun) is
# compared against the ABSOLUTE server tick, never a delta: when a player re-enters and the zone
# wakes, action_state_machine.advance_timers immediately catches the mob up on the very first awake
# tick (a mob whose respawn tick already elapsed respawns at once). No state drifts, none is lost,
# and a mob can never be mid-chase when its zone sleeps — regions sit >=420 m apart at P1 while mob
# leash is <=20 m, so a player is never within aggro/leash range of a sleeping zone's mobs. The
# optional origin-distance WAKE MARGIN is the generalization hook for P2's adjacent walkable borders
# (default 0 => pure membership, byte-identical to today).
#
# INSTANCE mobs (instance_id != 0 — crypt/dungeon parties) are ALWAYS awake: a soft instance only
# exists while its party is inside (no empty-instance tick to save), and its mobs live in the
# instance offset pocket, not on the overworld region table — gating them on region membership would
# be wrong. So the sleeping gate applies to the open world (instance_id 0) only.

extends RefCounted

const PlayerSessions = preload("res://scripts/player_sessions.gd")


# The set {region_index: true} of regions that must tick this frame: every region a player occupies
# (nearest-origin membership), plus — when `wake_margin` > 0 — any region whose ORIGIN is within
# `wake_margin` metres of a player (the future adjacent-border skirt). `player_grounds` is an Array
# Vector2 ground positions (x, y — the server ground plane that WorldRegions.region_index reads).
# `regions` is a WorldRegions. An empty player list => empty set: every overworld zone sleeps (the
# idle-server floor). A null table => empty set (caller degrades to always-tick via is_mob_awake).
static func awake_regions(player_grounds: Array, regions, wake_margin: float) -> Dictionary:
	var awake: Dictionary = {}
	if regions == null:
		return awake
	var count: int = regions.region_count()
	for g in player_grounds:
		var gx: float = g.x
		var gy: float = g.y
		var idx: int = regions.region_index(gx, gy)  # membership: the nearest-origin region wakes
		if idx >= 0:
			awake[idx] = true
		if wake_margin > 0.0:  # border skirt: any region whose origin is within the margin
			for i in count:
				if awake.has(i):
					continue
				if Vector2(gx, gy).distance_to(regions.origin_of(i)) <= wake_margin:
					awake[i] = true
	return awake


# Should this mob's AI tick run this frame? An instance mob (instance_id != 0) always ticks; an
# open-world mob ticks only if its own region is in `awake`. The mob's ground plane is
# (position.x, position.y) — the T-052 convention shared with WorldRegions and mob_loader. A null
# region table degrades to always-tick (the pre-T-594 behaviour), so a boot without regions.json is
# safe.
static func is_mob_awake(mob, awake: Dictionary, regions) -> bool:
	if int(mob.instance_id) != 0:
		return true
	if regions == null:
		return true
	return awake.has(regions.region_index(mob.position.x, mob.position.y))


# T-698: {entity_id -> spawn-region index}, computed ONCE at spawn-table load. A mob's region is
# STATIC — it leashes <=20 m from spawn while regions sit >=420 m apart — so the per-mob-per-tick
# O(regions) nearest-origin scan in is_mob_awake collapses to one dict probe. An empty table (null/
# empty regions) yields an empty map, which is_mob_awake_cached reads as always-awake (the same
# degrade rule as is_mob_awake above).
static func mob_regions(mobs: Dictionary, regions) -> Dictionary:
	var out: Dictionary = {}
	if regions == null or regions.region_count() == 0:
		return out
	for mob_id in mobs:
		var mob = mobs[mob_id]
		out[int(mob.entity_id)] = regions.region_index(mob.spawn_position.x, mob.spawn_position.y)
	return out


# T-698: is_mob_awake against the precomputed spawn-region map. Instance mobs (crypt/dungeon)
# always tick — same rule as is_mob_awake; a mob missing from the map (no region table, or spawned
# dynamically after load) degrades to always-tick, never to silently-asleep.
static func is_mob_awake_cached(mob, awake: Dictionary, regions_of_mob: Dictionary) -> bool:
	if int(mob.instance_id) != 0:
		return true
	var eid: int = int(mob.entity_id)
	if not regions_of_mob.has(eid):
		return true
	return awake.has(regions_of_mob[eid])


# The Vector2 (x, y) ground positions of a mob-AI player snapshot ({pid: {position: Vector3, ...}}).
# awake_regions reads only positions, so this adapts the snapshot main already builds to that call.
# and the awake computation.
static func player_grounds(snapshot: Dictionary) -> Array:
	var out: Array = []
	for pid in snapshot:
		var pos: Vector3 = snapshot[pid].get("position", Vector3.ZERO)
		out.append(Vector2(pos.x, pos.y))
	return out


# T-594 (carved from main._run_mob_ai_tick to keep main under the 1000-line cap): the per-player
# snapshot the mob AI consumes — {pid: {position, combat_state, resources, stats, level, instance}}
# for every connected player that has a combat state. Positions are read LIVE from PlayerSessions —
# the cached login copy would make mobs chase stale positions (T-067). Pure assembly; no mutation of
# the passed stores.
static func snapshot_players(
	connected_players: Dictionary,
	combat_states: Dictionary,
	combat_resources: Dictionary,
	char_stats: Dictionary,
	effective_level: Dictionary
) -> Dictionary:
	var players: Dictionary = {}
	for pid in connected_players:
		if not combat_states.has(pid):
			continue
		players[pid] = {
			# T-698: read-only view — one fewer per-player dict duplicate per server tick.
			"position": PlayerSessions.get_player_view(pid).get("pos", Vector3.ZERO),
			"combat_state": combat_states[pid],
			"resources": combat_resources.get(pid, null),
			"stats": char_stats.get(pid, null),
			"level": effective_level.get(pid, 1),  # T-402/T-452: relative aggro reach
			"instance_id": PlayerSessions.get_instance(pid),
		}
	return players
