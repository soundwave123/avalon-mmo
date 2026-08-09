# T-332: Hollowed Crypt boss mechanics — PURE, headless, ONE mechanic beyond the T-294 enrage.
#
# Mirrors the mob_ai/npc_wander pure-tick discipline (feedback_orchestrator + standing orders): the
# input MobData is never mutated, no OS time is read (the caller injects `now`), and the rng is the
# caller's seeded generator. Given ONE boss it returns a full COPY with the mechanic's bookkeeping
# advanced — the dirge channel window, the summon cadence clock, the phase flag — plus a list of
# abstract ACTIONS the LIVE layer (instance_service.tick_bosses) resolves against the running world:
# summon adds, pulse the dirge AoE, announce the phase flip. This module knows nothing about the
# _mobs table, the player snapshot, or the broadcast, so every cadence/threshold rule unit-tests in
# isolation. Reuses CombatState.CHANNELING + cast_start/cast_end for the dirge — the existing cast
# plumbing (T-017), not a new timer.
extends RefCounted

const _MAI = preload("res://scripts/combat/mob_ai.gd")
const _CS = preload("res://scripts/combat/combat_state.gd")

# Sentinel cast_ability_id for the boss dirge channel — a scripted encounter channel, not a player
# ability id (those are >= 0). Keeps the channel legible if the cast fields are ever inspected.
const DIRGE_ABILITY_ID := -2

# Re-arm sentinel: a mechanic whose last_mechanic_tick is this far in the past fires immediately on
# the first engaged tick (a fresh pull / post-reset). Matches mob_data's default.
const _ARMED := -100000


class BossTickResult:
	var new_mob = null  # full MobData copy with mechanic bookkeeping advanced (never the input)
	var actions: Array = []  # [{type, ...}] resolved by instance_service.tick_bosses

	static func create(m, a: Array) -> BossTickResult:
		var r = BossTickResult.new()
		r.new_mob = m
		r.actions = a
		return r


# A boss runs its mechanic only while actively fighting (AGGROED / MELEE) and alive. A leashing,
# evading, idle or dead boss is NOT active — it re-arms clean so the next pull starts the mechanic
# from scratch (no mid-fight dirge resuming, cadence reset).
static func is_active(mob) -> bool:
	if mob.combat_state.state == _CS.CombatStateEnum.DEAD:
		return false
	return mob.ai_state == _MAI.MobAIState.AGGROED or mob.ai_state == _MAI.MobAIState.MELEE


# Advance one boss by one tick. Returns {new_mob, actions}. A non-boss (empty boss_mechanic) is a
# no-op that returns the input unchanged (no copy) — cheap to call over the whole mob table.
static func tick(mob, now: int, _rng) -> BossTickResult:
	if mob.boss_mechanic == "":
		return BossTickResult.create(mob, [])
	var m = _MAI._copy_mob(mob)  # full copy incl. boss fields (the input is never mutated)
	if not is_active(mob):
		# Out of combat: reset the mechanic clock/phase and drop any lingering dirge channel.
		m.last_mechanic_tick = _ARMED
		m.in_phase2 = false
		m.dirge_hp_at_start = -1
		if m.combat_state.state == _CS.CombatStateEnum.CHANNELING:
			m.combat_state.state = _CS.CombatStateEnum.IDLE
			m.combat_state.cast_end = 0
		return BossTickResult.create(m, [])
	match mob.boss_mechanic:
		"summon":
			return _tick_summon(m, now, mob.mechanic_cadence)
		"dirge":
			return _tick_dirge(m, now)
		"training_dirge":
			# T-426: the tutorial sparring effigy reuses the dirge WIND-UP/interrupt bookkeeping, but the
			# LANDING is a single token hit at channel end — NOT the crypt dirge's per-tick pulse (which
			# stacks dirge_damage every server tick across the whole channel and wipes a L1 trainee). The
			# distinct name also keeps a real crypt dirge boss from ever crediting a tutorial interrupt
			# (training_interrupt.gd gates on it).
			return _tick_training_dirge(m, now)
		"phase_summon":
			return _tick_phase_summon(m, now)
		_:
			return BossTickResult.create(m, [])


# ---- Summon (Warden Aldric): raise adds on a cadence; instance_service caps them at max_adds. ----


static func _tick_summon(m, now: int, cadence: int) -> BossTickResult:
	if cadence <= 0 or now - m.last_mechanic_tick < cadence:
		return BossTickResult.create(m, [])
	m.last_mechanic_tick = now
	return (
		BossTickResult
		. create(
			m,
			[
				{
					"type": "summon",
					"mob_file": m.add_mob_file,
					"render_kind": m.add_render_kind,
					"anchors": m.add_anchors,
					"max_adds": m.max_adds,
				}
			]
		)
	)


# ---- Dirge (Vharis): a channeled room-wide pulse the party interrupts by out-damaging a threshold.


static func _tick_dirge(m, now: int) -> BossTickResult:
	# T-434: a dedicated interrupt already moved the CombatState out of CHANNELING. Consume the
	# server-stamped interrupt tick here so the boss waits a full cadence instead of restarting on
	# this same mechanic tick. The damage-threshold path below remains unchanged.
	if (
		m.dirge_hp_at_start >= 0
		and m.combat_state.last_full_interrupt_at >= 0
		and m.combat_state.last_full_interrupt_at > m.last_mechanic_tick
	):
		return _end_dirge(m, now, true)
	if m.combat_state.state == _CS.CombatStateEnum.CHANNELING:
		var lost: int = m.dirge_hp_at_start - m.resources.hp
		# Interrupt: the party out-damaged the threshold during the channel — the dirge is cancelled
		# and the boss must wait a full cadence before it can start another.
		if m.dirge_interrupt_damage > 0 and lost >= m.dirge_interrupt_damage:
			return _end_dirge(m, now, true)
		# Channel ran its full length uninterrupted — the pulses already landed each tick.
		if now >= m.combat_state.cast_end:
			return _end_dirge(m, now, false)
		# Mid-channel: pulse the AoE this tick.
		return BossTickResult.create(
			m, [{"type": "dirge_pulse", "amount": m.dirge_damage, "radius": m.dirge_radius}]
		)
	# Not channeling — start a new dirge once the cadence since the last one has elapsed.
	if m.mechanic_cadence <= 0 or now - m.last_mechanic_tick < m.mechanic_cadence:
		return BossTickResult.create(m, [])
	m.combat_state.state = _CS.CombatStateEnum.CHANNELING
	m.combat_state.cast_start = now
	m.combat_state.cast_end = now + m.dirge_channel_ticks
	m.combat_state.cast_ability_id = DIRGE_ABILITY_ID
	m.dirge_hp_at_start = m.resources.hp
	return BossTickResult.create(m, [{"type": "dirge_start"}])


static func _end_dirge(m, now: int, interrupted: bool) -> BossTickResult:
	m.combat_state.state = _CS.CombatStateEnum.IDLE
	m.combat_state.cast_end = 0
	m.dirge_hp_at_start = -1
	m.last_mechanic_tick = now  # cadence counts from the END of a dirge (gap between casts)
	return BossTickResult.create(m, [{"type": "dirge_end", "interrupted": interrupted}])


# ---- Training telegraph (Straw Sparring Effigy, q_tut_03): same wind-up + interrupt bookkeeping as
# the crypt dirge, but a WIN, never a wipe. An UNINTERRUPTED channel lands exactly ONE token hit of
# dirge_damage at the end (not a per-tick pulse), so a L1 trainee — even the squishy mage — always
# survives it and gets to try the interrupt again. Interrupting (damage threshold OR a dedicated
# interrupt) cancels the wind-up before it lands, dealing nothing.
static func _tick_training_dirge(m, now: int) -> BossTickResult:
	# Dedicated interrupt already left CHANNELING — consume the stamped tick (mirrors _tick_dirge).
	if (
		m.dirge_hp_at_start >= 0
		and m.combat_state.last_full_interrupt_at >= 0
		and m.combat_state.last_full_interrupt_at > m.last_mechanic_tick
	):
		return _end_dirge(m, now, true)
	if m.combat_state.state == _CS.CombatStateEnum.CHANNELING:
		var lost: int = m.dirge_hp_at_start - m.resources.hp
		# Broke the wind-up by out-damaging the threshold during the window — nothing lands.
		if m.dirge_interrupt_damage > 0 and lost >= m.dirge_interrupt_damage:
			return _end_dirge(m, now, true)
		# Wind-up completed uninterrupted — the move lands as ONE token hit, then the effigy re-arms.
		if now >= m.combat_state.cast_end:
			m.combat_state.state = _CS.CombatStateEnum.IDLE
			m.combat_state.cast_end = 0
			m.dirge_hp_at_start = -1
			m.last_mechanic_tick = now
			var acts: Array = []
			if m.dirge_damage > 0:
				acts.append(
					{"type": "dirge_pulse", "amount": m.dirge_damage, "radius": m.dirge_radius}
				)
			acts.append({"type": "dirge_end", "interrupted": false})
			return BossTickResult.create(m, acts)
		# Mid-channel: pure telegraph — the trainee reads the wind-up, no damage yet.
		return BossTickResult.create(m, [])
	# Not channeling — start a new wind-up once the cadence since the last one has elapsed.
	if m.mechanic_cadence <= 0 or now - m.last_mechanic_tick < m.mechanic_cadence:
		return BossTickResult.create(m, [])
	m.combat_state.state = _CS.CombatStateEnum.CHANNELING
	m.combat_state.cast_start = now
	m.combat_state.cast_end = now + m.dirge_channel_ticks
	m.combat_state.cast_ability_id = DIRGE_ABILITY_ID
	m.dirge_hp_at_start = m.resources.hp
	return BossTickResult.create(m, [{"type": "dirge_start"}])


# ---- Phase summon (Maldrath): a one-time flip at phase2_threshold, then faster summons. The enrage
# rides the T-294 swing path (enrage_threshold set to the same fraction), so it is FREE here. ----


static func _tick_phase_summon(m, now: int) -> BossTickResult:
	var actions: Array = []
	if not m.in_phase2 and m.resources.max_hp > 0:
		var frac: float = float(m.resources.hp) / float(m.resources.max_hp)
		if frac <= m.phase2_threshold:
			m.in_phase2 = true
			actions.append({"type": "phase_flip"})
	var cadence: int = m.phase2_cadence if m.in_phase2 else m.mechanic_cadence
	var res := _tick_summon(m, now, cadence)  # operates on the same `m`
	for a in res.actions:
		actions.append(a)
	return BossTickResult.create(res.new_mob, actions)
