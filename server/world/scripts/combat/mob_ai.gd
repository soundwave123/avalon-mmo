# T-025: Mob AI FSM — pure functions, no OS time, no global state.
#
# ai_tick(mob, players, threat_table, now, rng) -> MobAIResult
#   - mob, threat_table: untyped (parse-gate compat; no class_name on MobData)
#   - players: Dict[peer_id -> {position, combat_state, resources, stats}]
#   - now: injected server tick counter — never read OS time here
#   - rng: caller's seeded RandomNumberGenerator — never created inside here
#
# HARD CONSTRAINTS:
#   - Inputs never mutated. main.gd applies result.new_mob to _mobs[id].
#   - threat_table is READ-ONLY here. clear_mob is signaled via events.
#   - Positions are Vector3 (flat M1 world; height deferred to M2).

extends RefCounted

enum MobAIState { IDLE, AGGROED, MELEE, EVADING }


class MobAIResult:
	var new_mob = null  # updated MobData (untyped — no class_name on mob_data.gd)
	var events: Array = []  # [{type, ...}] — processed by main.gd

	static func create(mob, evts: Array) -> MobAIResult:
		var r = MobAIResult.new()
		r.new_mob = mob
		r.events = evts
		return r


const _SC = preload("res://scripts/server_config.gd")
const _CS = preload("res://scripts/combat/combat_state.gd")
const _AA = preload("res://scripts/combat/auto_attack.gd")
const _MD = preload("res://scripts/combat/mob_data.gd")
const _AGG = preload("res://scripts/combat/mob_aggro.gd")  # T-402: level-relative aggro reach

# T-226: Crystal Lake is impassable for mobs (they walked on water in the T-220 proof).
# KEEP IN SYNC with scripts/world-audit.py LAKE and the terrain_splat water ring.
const LAKE_CENTER := Vector3(18.0, 22.0, 0.0)  # server ground frame (x, y ground)
const LAKE_RADIUS := 12.0


# Clamp a movement destination out of the lake disc: slide to the shore rim along the
# center ray (tangential progress around the shore; never enters the water).
static func clamp_out_of_water(to: Vector3) -> Vector3:
	var flat := Vector2(to.x - LAKE_CENTER.x, to.y - LAKE_CENTER.y)
	if flat.length() >= LAKE_RADIUS + 0.2:
		return to
	var rim := flat.normalized() if flat.length() > 0.001 else Vector2.RIGHT
	rim *= LAKE_RADIUS + 0.2
	return Vector3(LAKE_CENTER.x + rim.x, LAKE_CENTER.y + rim.y, to.z)


static func ai_tick(mob, players: Dictionary, threat_table, now: int, rng) -> MobAIResult:
	# T-698: no-op ticks return the ORIGINAL mob unchanged (never a _copy_mob) — main.gd re-assigns
	# it to the same _mobs slot, so skipping the ~60-field copy is invisible. The T-402 field-missed-
	# in-copy trap argues for exactly this shape (no-op-return) over trimming the copy's fields.
	# T-026: Skip AI tick for dead mobs (respawn handled by main.gd timer).
	if mob.combat_state.state == _CS.CombatStateEnum.DEAD:
		return MobAIResult.create(mob, [])

	# T-516: a training dummy is a static, passive practice target — it never aggros, moves, or
	# attacks. Short-circuit the entire AI so it just stands there taking hits (playtest bug: the
	# dummy chased the player and dealt damage). It stays targetable/damageable via the combat path.
	if mob.is_dummy:
		return MobAIResult.create(mob, [])

	# T-063: CC — a stunned mob does nothing; a rooted mob can't move (chase). frost_nova roots.
	if now < mob.combat_state.stunned_until:
		return MobAIResult.create(mob, [])
	var rooted: bool = now < mob.combat_state.rooted_until

	match mob.ai_state:
		MobAIState.IDLE:
			return _tick_idle(mob, players, threat_table, rng)
		MobAIState.AGGROED:
			# T-350: a ranged mob kites instead of closing to melee — the same tick covers both the
			# approach-to-band and the firing, so AGGROED and MELEE both route through it.
			if mob.ranged:
				return _tick_ranged(mob, players, threat_table, now, rng, rooted)
			return _tick_aggroed(mob, players, threat_table, rooted)
		MobAIState.MELEE:
			if mob.ranged:
				return _tick_ranged(mob, players, threat_table, now, rng, rooted)
			return _tick_melee(mob, players, threat_table, now, rng)
		MobAIState.EVADING:
			return _tick_evading(mob)
		_:
			return MobAIResult.create(mob, [])  # T-698: unknown state = no-op, no copy


# T-534: the mob's CHASE step for ONE server tick. Base is the player's per-tick run distance
# (ServerConfig.MOB_MOVE_SPEED = PLAYER_RUN_SPEED / TICK_RATE_HZ); the per-mob multiplier (default
# 1.01) adds the small closing edge. main.gd applies this exactly once per server tick, so the
# effective speed = MOB_MOVE_SPEED * speed_mult * TICK_RATE_HZ u/s, independent of frame rate.
# Every movement site (chase / kite / evade / patrol) routes through here.
static func _chase_step(mob) -> float:
	return _SC.MOB_MOVE_SPEED * mob.speed_mult


# ---- State tick handlers ----


static func _tick_idle(mob, players: Dictionary, threat_table = null, rng = null) -> MobAIResult:
	# T-698: copy LAZILY — only on an actual mutation (aggro flip / patrol step). An idle mob with
	# nobody near and no patrol step is the overwhelmingly common tick; it returns `mob` unchanged.
	# T-070: threat pull — ranged damage on an idle mob aggros it even outside proximity,
	# as long as the attacker is inside the leash (else it would instantly evade-loop).
	var top_id: int = _top_living_threat(mob, players, threat_table)
	if top_id != -1:
		var top_pos: Vector3 = players[top_id].get("position", Vector3.ZERO)
		if mob.spawn_position.distance_to(top_pos) <= mob.leash_radius:
			return _aggro_result(mob, top_id)
		# T-726: the attacker holding threat stands OUTSIDE the leash circle, so this mob can never
		# legally engage them — the branch above just refused to. Standing there absorbing free hits
		# is the door-pull cheese the Shallow Graves repro measured: TRIAL_ENTRANCE is 15.16 m from
		# Pallbearer Ost's spawn, past his 12 m leash, while every caster nuke reaches 25-30 units,
		# so a lone mage took him from 333 to 229 HP in 45 s while he sat at ai_state IDLE with
		# target_id -1 and never reset. The engaged states (_tick_aggroed/_tick_melee/_tick_ranged)
		# already answer an out-of-leash target with _enter_evading; IDLE was the one state that
		# didn't, so damage taken there was the only damage in the game that could never be undone.
		# Reuse the SAME transition: full restore now, threat cleared when it reaches home a tick
		# later (it is already standing on its spawn, so the reset is effectively immediate).
		# Guarded on damage actually taken, so an untouched idle mob with stale distant threat never
		# churns evade events — and a full-HP mob has nothing to reset anyway.
		if mob.resources.hp < mob.resources.max_hp:
			return _enter_evading(mob)

	# T-564: retaliate-only — this mob never proximity-aggros (report #18: the tutorial sparring
	# effigy was auto-meleeing an idle new player walking up to the quest giver, before the trainee
	# had done anything). The threat-pull check above still applies unconditionally, so attacking it
	# engages it exactly like any other mob — only the unprovoked proximity scan below is skipped.
	if not mob.retaliate_only:
		for pid in players:
			if _is_dead_entry(players[pid]):  # T-070: corpses don't pull aggro
				continue
			# T-402: level-relative reach. The base is the mob's authored same-level radius; it shrinks
			# as the player out-levels the mob and is 0 (never aggro) for a gray mob. Squared compare +
			# level read keep this per-mob-per-tick check cheap (no sqrt, no allocation).
			var player_level: int = int(players[pid].get("level", 1))
			var radius_sq: float = _AGG.effective_radius_sq(
				mob.aggro_radius, mob.mob_level, player_level, mob.leash_radius
			)
			if radius_sq <= 0.0:  # gray mob — never aggros this player
				continue
			var dist_sq: float = mob.position.distance_squared_to(
				players[pid].get("position", Vector3.ZERO)
			)
			if dist_sq <= radius_sq:
				return _aggro_result(mob, pid)

	# T-080: nobody to fight — patrol a small loop around the spawn (world life).
	return _tick_patrol(mob, rng)


# T-698: the IDLE→AGGROED flip (the one idle-tick mutation besides a patrol step).
static func _aggro_result(mob, target_id: int) -> MobAIResult:
	var new_mob = _copy_mob(mob)
	new_mob.ai_state = MobAIState.AGGROED
	new_mob.current_target_id = target_id
	return MobAIResult.create(new_mob, [{"type": "aggro", "mob_id": mob.entity_id}])


# T-080: pick a waypoint inside patrol_radius (rare, rng-gated) and amble toward it at half
# chase speed. Aggro checks always run first. T-698: rng draw order is byte-identical to the
# pre-copy-on-write shape; _copy_mob runs ONLY when a waypoint is drawn or a step is taken.
static func _tick_patrol(mob, rng) -> MobAIResult:
	if mob.patrol_radius <= 0.0 or rng == null:
		return MobAIResult.create(mob, [])  # non-patroller: a true no-op tick
	var has_target: bool = mob.patrol_target != Vector3.INF
	if not has_target or mob.position.distance_to(mob.patrol_target) < 0.3:
		if rng.randf() < 0.02:  # ~once per 2.5 s at 20 Hz: choose a new waypoint
			var angle: float = rng.randf_range(0.0, TAU)
			var reach: float = rng.randf_range(1.0, mob.patrol_radius)
			var new_mob = _copy_mob(mob)
			new_mob.set(
				"patrol_target", mob.spawn_position + Vector3(cos(angle), sin(angle), 0.0) * reach
			)
			return MobAIResult.create(new_mob, [])
		return MobAIResult.create(mob, [])  # no waypoint drawn — nothing changed
	var to_target: Vector3 = mob.patrol_target - mob.position
	if to_target.length() <= 0.0:
		return MobAIResult.create(mob, [])
	var step: float = minf(to_target.length(), _chase_step(mob) * 0.5)  # T-534: half chase speed
	var new_mob = _copy_mob(mob)
	new_mob.position = clamp_out_of_water(mob.position + to_target.normalized() * step)
	return MobAIResult.create(new_mob, [])


static func _tick_aggroed(
	mob, players: Dictionary, threat_table = null, rooted: bool = false
) -> MobAIResult:
	var new_mob = _copy_mob(mob)
	var target_id: int = mob.current_target_id

	# T-070: chase the top LIVING threat (re-target like MELEE); a dead or vanished target
	# falls back to the threat table before evading.
	var top_id: int = _top_living_threat(mob, players, threat_table)
	if top_id != -1:
		target_id = top_id
		new_mob.current_target_id = target_id

	if not players.has(target_id) or _is_dead_entry(players[target_id]):
		return _enter_evading(mob)

	var target_pos: Vector3 = players[target_id].get("position", Vector3.ZERO)

	# Leash: measured from spawn to target (mob chases into leash radius from spawn)
	if mob.spawn_position.distance_to(target_pos) > mob.leash_radius:
		return _enter_evading(mob)

	# Move toward target — direct update, no pathfinding (M1 stub)
	var to_target: Vector3 = target_pos - mob.position  # M1 stub
	var dist: float = to_target.length()
	var move: float = min(dist, _chase_step(mob))  # T-534: player-matched +1% per-tick chase step
	if dist > 0.0 and not rooted:  # T-063: a rooted mob holds position
		new_mob.position = clamp_out_of_water(mob.position + to_target.normalized() * move)

	if dist <= mob.melee_range:
		new_mob.ai_state = MobAIState.MELEE

	return MobAIResult.create(new_mob, [])


static func _tick_melee(mob, players: Dictionary, threat_table, now: int, rng) -> MobAIResult:
	var new_mob = _copy_mob(mob)
	var events: Array = []

	# Re-evaluate target via threat table (may switch to higher-threat attacker).
	# T-070: only LIVING, connected attackers qualify.
	var top_id: int = _top_living_threat(mob, players, threat_table)
	var target_id: int = mob.current_target_id
	if top_id != -1:
		target_id = top_id
		new_mob.current_target_id = target_id

	if not players.has(target_id):
		return _enter_evading(mob)

	var target: Dictionary = players[target_id]
	var target_pos: Vector3 = target.get("position", Vector3.ZERO)

	if target.get("combat_state", null) != null:
		if target["combat_state"].state == _CS.CombatStateEnum.DEAD:
			return _enter_evading(mob)

	if mob.spawn_position.distance_to(target_pos) > mob.leash_radius:
		return _enter_evading(mob)

	# T-070: melee range re-check — a target that stepped out of melee range is chased
	# (AGGROED), never hit from across the map ("range stubbed always-in-range" since M1).
	if mob.position.distance_to(target_pos) > mob.melee_range:
		new_mob.ai_state = MobAIState.AGGROED
		return MobAIResult.create(new_mob, [])

	# Auto-attack: injected rng threads through — never created here
	var aa = _AA.process_auto_attack(
		mob.combat_state,
		mob.resources,
		mob.stats,
		target_id,
		now,
		target.get("stats", null),
		mob.melee_ability,
		rng
	)

	if not aa.is_noop:
		new_mob.combat_state.next_swing_tick = aa.new_next_swing_tick
		new_mob.resources = mob.resources.apply_stamina_drain(_SC.STAMINA_DRAIN_PER_SWING)
		# T-294: elite enrage — the extra ability, riding the existing swing path. At/below the
		# HP-fraction threshold, this connecting swing hits for enrage_mult× (a hit, not a miss/dodge:
		# damage_amount > 0). Reuses the already-computed swing; no new effect framework.
		var amount: int = aa.damage_amount
		var enraged: bool = false
		if mob.elite and mob.enrage_mult > 1.0 and amount > 0 and mob.resources.max_hp > 0:
			var frac: float = float(mob.resources.hp) / float(mob.resources.max_hp)
			if frac <= mob.enrage_threshold:
				amount = int(round(float(amount) * mob.enrage_mult))
				enraged = true
		(
			events
			. append(
				{
					"type": "damage",
					"mob_id": mob.entity_id,
					"target_id": target_id,
					"amount": amount,
					"mitigated": aa.mitigated_amount,
					"outcome": aa.outcome,
					"enraged": enraged,  # T-294: elite low-HP damage buff fired this swing
				}
			)
		)

	return MobAIResult.create(new_mob, events)


# T-350: ranged kiter tick (gun mobs). Holds the firing BAND [ranged_min, ranged_max]: closes when
# farther than max, backs AWAY when closer than min (kite), and fires a hitscan volley only while
# inside the band. Fire reuses the melee auto-attack gate (weapon_speed cadence, hit/miss/crit roll)
# so damage math is shared — the only additions are the keep-distance movement and the ranged/burst
# metadata on the damage event (the client draws muzzle flash + tracer + impact from it). Pure/
# deterministic, mirroring _tick_melee: inputs never mutated, rng + now injected by the caller.
static func _tick_ranged(
	mob, players: Dictionary, threat_table, now: int, rng, rooted: bool
) -> MobAIResult:
	var new_mob = _copy_mob(mob)
	var events: Array = []

	var top_id: int = _top_living_threat(mob, players, threat_table)
	var target_id: int = mob.current_target_id
	if top_id != -1:
		target_id = top_id
		new_mob.current_target_id = target_id

	if not players.has(target_id) or _is_dead_entry(players[target_id]):
		return _enter_evading(mob)

	var target: Dictionary = players[target_id]
	var target_pos: Vector3 = target.get("position", Vector3.ZERO)
	if mob.spawn_position.distance_to(target_pos) > mob.leash_radius:
		return _enter_evading(mob)

	var to_target: Vector3 = target_pos - mob.position
	var dist: float = to_target.length()
	var dir: Vector3 = to_target.normalized() if dist > 0.001 else Vector3.ZERO

	# Keep-distance movement: close if beyond the band, kite BACK if inside the min. A rooted mob
	# (T-063 CC) holds position and fires from wherever it is. Inside the band it stands and shoots.
	if not rooted:
		if dist > mob.ranged_max:
			new_mob.ai_state = MobAIState.AGGROED
			var close: float = minf(dist - mob.ranged_max, _chase_step(mob))  # T-534
			new_mob.position = clamp_out_of_water(mob.position + dir * close)
		elif dist < mob.ranged_min:
			new_mob.ai_state = MobAIState.AGGROED
			var back: float = minf(mob.ranged_min - dist, _chase_step(mob))  # T-534: kite at chase speed
			new_mob.position = clamp_out_of_water(mob.position - dir * back)

	# Fire only when standing inside the band (never mid-reposition — a shot must read as aimed).
	var new_dist: float = new_mob.position.distance_to(target_pos)
	if new_dist < mob.ranged_min or new_dist > mob.ranged_max:
		return MobAIResult.create(new_mob, events)
	new_mob.ai_state = MobAIState.MELEE  # "in the fight, firing" — reuses the shared attack gate

	var aa = _AA.process_auto_attack(
		mob.combat_state,
		mob.resources,
		mob.stats,
		target_id,
		now,
		target.get("stats", null),
		mob.melee_ability,
		rng
	)
	if not aa.is_noop:
		new_mob.combat_state.next_swing_tick = aa.new_next_swing_tick
		new_mob.resources = mob.resources.apply_stamina_drain(_SC.STAMINA_DRAIN_PER_SWING)
		# One firing window = ranged_burst shots (the tommy's heavier read). Each is its own damage
		# event carrying the same aa roll + the ranged/weapon metadata, so the client fires N tracers
		# and N flashes and the target takes N hits. The revolver (burst 1) fires exactly one.
		for shot in range(mob.ranged_burst):
			(
				events
				. append(
					{
						"type": "damage",
						"mob_id": mob.entity_id,
						"target_id": target_id,
						"amount": aa.damage_amount,
						"mitigated": aa.mitigated_amount,
						"outcome": aa.outcome,
						"enraged": false,
						"ranged": true,
						"weapon": mob.ranged_attack,
						"burst_index": shot,
					}
				)
			)
	return MobAIResult.create(new_mob, events)


static func _tick_evading(mob) -> MobAIResult:
	var new_mob = _copy_mob(mob)

	var dist: float = mob.position.distance_to(mob.spawn_position)
	if dist <= _SC.SPAWN_EPSILON:
		new_mob.ai_state = MobAIState.IDLE
		new_mob.current_target_id = -1
		return (
			MobAIResult
			. create(
				new_mob,
				[
					{"type": "clear_threat", "mob_id": mob.entity_id},
					{"type": "mob_reset", "mob_id": mob.entity_id},
				]
			)
		)

	var to_spawn: Vector3 = mob.spawn_position - mob.position  # M1 stub
	var move: float = min(dist, _chase_step(mob))  # T-534: return home at chase speed
	new_mob.position = mob.position + to_spawn.normalized() * move

	return MobAIResult.create(new_mob, [])


# ---- Helpers ----


# T-070: a DEAD player is never a valid aggro/chase/melee target (corpse-camping loop).
static func _is_dead_entry(entry: Dictionary) -> bool:
	var cs = entry.get("combat_state", null)
	return cs != null and cs.state == _CS.CombatStateEnum.DEAD


# T-070: highest-threat attacker that is connected AND alive; -1 when none.
static func _top_living_threat(mob, players: Dictionary, threat_table) -> int:
	if threat_table == null:
		return -1
	var top: int = -1
	var top_threat: int = 0
	for pid in threat_table.get_attackers(mob.entity_id):
		if not players.has(pid) or _is_dead_entry(players[pid]):
			continue
		var th: int = threat_table.get_threat(mob.entity_id, pid)
		if th > top_threat:
			top_threat = th
			top = pid
	return top


static func _enter_evading(mob) -> MobAIResult:
	"""Transition to EVADING with instant full resource restore (D3 — owner-approved)."""
	var new_mob = _copy_mob(mob)
	new_mob.ai_state = MobAIState.EVADING
	new_mob.current_target_id = -1
	# Instant full restore — mob cannot be killed mid-evade (standard MMO behavior)
	var res = new_mob.resources  # already a copy from _copy_mob
	res.hp = res.max_hp
	res.mana = res.max_mana
	res.stamina = res.max_stamina
	return MobAIResult.create(new_mob, [{"type": "mob_evading", "mob_id": mob.entity_id}])


static func _copy_mob(src):
	"""Deep copy of MobData. main.gd always receives a new object; inputs are never mutated."""
	var dst = _MD.new()
	dst.entity_id = src.entity_id
	# T-331/T-332: soft-instance scope must survive the tick copy — else every ai_tick would reset a
	# crypt mob to instance 0 (leaking it into the open-world broadcast + breaking boss add scoping).
	dst.instance_id = src.instance_id
	dst.mob_type_id = src.mob_type_id
	dst.mob_id = src.mob_id  # T-047: alias for quest kill-credit — must survive the AI-tick copy
	dst.name = src.name
	dst.position = src.position
	dst.spawn_position = src.spawn_position
	dst.aggro_radius = src.aggro_radius
	dst.leash_radius = src.leash_radius
	# T-402/T-358 live find: _copy_mob runs EVERY ai tick and any field it misses resets to the
	# MobData default after tick one — mob_level fell to 1 (gray -> proximity aggro dead) and xp
	# to 0 (every live mob kill granted nothing) while all first-tick tests passed. If you add a
	# field to MobData, add it HERE and to the second-tick persistence test.
	dst.mob_level = src.mob_level
	dst.xp = src.xp
	dst.melee_range = src.melee_range
	dst.speed_mult = src.speed_mult  # T-534: per-mob chase multiplier must survive the tick copy
	dst.ai_state = src.ai_state
	dst.current_target_id = src.current_target_id
	# T-051: full copy via the single CombatState.copy() (was a 4-field hand-copy that dropped the cast
	# fields — a mob_id-class drift bug, inert until M3 caster mobs).
	dst.combat_state = src.combat_state.copy()
	# Deep-copy resources (apply_damage(0) returns a copy with identical values)
	dst.resources = src.resources.apply_damage(0)
	# stats, melee_ability and loot are immutable at runtime — safe to share reference
	dst.stats = src.stats
	dst.melee_ability = src.melee_ability
	dst.loot = src.loot  # T-073: loot must survive the AI-tick copy (same trap as mob_id)
	dst.patrol_radius = src.patrol_radius  # T-080
	dst.patrol_target = src.patrol_target  # T-080: waypoint survives the tick copy
	dst.is_dummy = src.is_dummy  # T-516: training-dummy flag must survive the tick copy
	dst.non_lethal = src.non_lethal  # T-560: non-lethal-trainer flag must survive the tick copy
	dst.retaliate_only = src.retaliate_only  # T-564: passive-until-attacked flag survives the copy
	# T-350: ranged/kite profile must survive the tick copy (same trap as mob_id/loot).
	dst.ranged = src.ranged
	dst.ranged_min = src.ranged_min
	dst.ranged_max = src.ranged_max
	dst.ranged_attack = src.ranged_attack
	dst.ranged_burst = src.ranged_burst
	# T-294: elite tier + enrage state must survive the tick copy (same trap as mob_id/loot).
	dst.elite = src.elite
	dst.render_kind = src.render_kind
	dst.enrage_threshold = src.enrage_threshold
	dst.enrage_mult = src.enrage_mult
	# T-332: boss-mechanic state (config + live bookkeeping) must survive the tick copy too —
	# boss_mechanics.gd reads last_mechanic_tick / in_phase2 / dirge_hp_at_start off the ticked mob.
	dst.boss_mechanic = src.boss_mechanic
	dst.control_immune = src.control_immune
	dst.interrupt_immune = src.interrupt_immune
	dst.mechanic_cadence = src.mechanic_cadence
	dst.last_mechanic_tick = src.last_mechanic_tick
	dst.add_mob_file = src.add_mob_file
	dst.add_render_kind = src.add_render_kind
	dst.add_anchors = src.add_anchors
	dst.max_adds = src.max_adds
	dst.dirge_channel_ticks = src.dirge_channel_ticks
	dst.dirge_damage = src.dirge_damage
	dst.dirge_radius = src.dirge_radius
	dst.dirge_interrupt_damage = src.dirge_interrupt_damage
	dst.dirge_hp_at_start = src.dirge_hp_at_start
	dst.phase2_threshold = src.phase2_threshold
	dst.phase2_cadence = src.phase2_cadence
	dst.in_phase2 = src.in_phase2
	dst.render_scale = src.render_scale
	dst.temporary = src.temporary
	dst.summoned_by = src.summoned_by
	return dst
