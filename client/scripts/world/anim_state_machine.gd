class_name AnimStateMachine
extends RefCounted

# T-123: pure locomotion + action animation state machine. Mirrors critter_wander.gd/npc_wander.gd's
# shape — no OS time, no globals, inputs never mutated, the caller injects `now` (seconds, any
# monotonic clock) and reads the result back. entity_visuals.gd/EntityVisuals.play_state() stays a
# dumb player: this module decides WHICH state string to feed it; entity_visuals only knows how to
# resolve a state to a clip and play it (T-123 ticket note: "entity_visuals doing only playback").
#
# state (opaque): {locomotion: "idle"|"walk"|"run"|"jump", action: ""|"attack"|"cast"|"hit"|"death",
#                  action_until: float (seconds; when the current one-shot action releases back to
#                  locomotion), dead: bool (death is terminal — nothing un-sets it but a respawn
#                  reset)}
#
# Thresholds (real measured server speeds, not guesses):
#   - LocalPlayer.MOVE_SPEED = 6.0 m/s (client/scripts/world/local_player.gd) — the ONLY speed a
#     player moves at (no run/sprint toggle exists yet), so a moving player always reads as RUN.
#   - NPC amble (server/world/scripts/npc_wander.gd _DEFAULT_SPEED) = 1.2 m/s — a stroll.
#   - Mob chase (server/world/scripts/server_config.gd MOB_MOVE_SPEED) = 3.0 m/s.
#   RUN_THRESHOLD_MPS sits between the mob chase speed (3.0, reads as WALK — a prowl, not a
#   sprint) and the player run speed (6.0, reads as RUN), so both real server speeds land on the
#   correct side without per-kind special-casing.
const RUN_THRESHOLD_MPS := 4.0
const _MOVING_EPS := 0.05  # below this, treat as stationary (avoid idle/walk flicker near zero)

# One-shot action hold durations (seconds) — the T-118 headless QA table's measured clip lengths
# for the clips these states resolve to on the baked hero rigs (Sword_Attack, Spell_Simple_Shoot,
# Hit_Chest). "death" never releases on its own (INF) — see the death-stickiness note below.
const ACTION_DURATIONS := {
	"attack": 1.567,
	"cast": 0.542,
	"hit": 0.367,
	"shoot": 0.30,  # T-350: firearm recoil one-shot (matches CombatMotion.RECOIL_SHOT_DURATION)
}

# Interrupt priority (higher wins): death > hit > attack/cast > locomotion (0, implicit). An
# incoming event is accepted only when its priority is >= the CURRENTLY ACTIVE action's priority
# (an expired one-shot has already released, so it counts as priority 0). Equal priority always
# refreshes (e.g. a fresh attack retriggers the swing even mid-swing).
const _PRIORITY := {"attack": 1, "cast": 1, "shoot": 1, "hit": 2, "death": 3}


static func new_state() -> Dictionary:
	return {"locomotion": "idle", "action": "", "action_until": 0.0, "dead": false}


# Per-frame: derive locomotion (idle/walk/run/jump) from real velocity + airborne state. A dead
# entity's locomotion is frozen (irrelevant anyway — display_state() always returns "death" once
# dead) so a corpse sliding to a stop mid-broadcast never flickers back through walk/idle.
# T-573: `is_mounted` (the server-confirmed mount state, never client-asserted) freezes the BODY to
# the "mounted" display state — the mount model carries all locomotion animation, so the on-foot
# run clip must never play under a rider (locomotion still updates underneath, so dismounting
# mid-move resolves to the honest clip on the very next display read).
static func tick(
	state: Dictionary,
	speed_mps: float,
	airborne: bool,
	is_mounted: bool = false,
	run_threshold: float = RUN_THRESHOLD_MPS
) -> Dictionary:
	return tick_in_place(state.duplicate(), speed_mps, airborne, is_mounted, run_threshold)


# T-697: allocation-free tick for per-frame hot loops (remote_entities_layer runs one per entity
# per frame) — same transition rules as tick(), but mutates `state` IN PLACE and returns it, so
# the caller that owns a private per-entity dict skips the per-frame duplicate(). tick() above
# keeps the pure never-mutate-inputs contract for everyone else.
static func tick_in_place(
	state: Dictionary,
	speed_mps: float,
	airborne: bool,
	is_mounted: bool = false,
	run_threshold: float = RUN_THRESHOLD_MPS
) -> Dictionary:
	if bool(state.get("dead", false)):
		return state
	state["mounted"] = is_mounted
	var loc: String
	if airborne:
		loc = "jump"
	elif speed_mps > run_threshold:
		loc = "run"
	elif speed_mps > _MOVING_EPS:
		loc = "walk"
	else:
		loc = "idle"
	state["locomotion"] = loc
	return state


# Event-driven: attack/cast/hit/death. `now` is seconds (any monotonic clock the caller uses
# consistently with itself — trigger() and tick()'s expiry check must share one clock per caller).
# Death is terminal: once dead, every further trigger (including a redundant "death") is a no-op;
# only respawn_reset() (a respawn) clears it. A lower-priority event arriving while a
# higher-priority one-shot is still active is dropped (e.g. an "attack" can't interrupt an
# in-flight "hit" flinch).
static func trigger(state: Dictionary, event: String, now: float) -> Dictionary:
	var out := state.duplicate()
	if bool(out.get("dead", false)):
		return out
	if event == "death":
		out["dead"] = true
		out["action"] = "death"
		out["action_until"] = INF
		return out
	var active_priority := 0
	if str(out.get("action", "")) != "" and now < float(out.get("action_until", 0.0)):
		active_priority = int(_PRIORITY.get(str(out["action"]), 0))
	var new_priority := int(_PRIORITY.get(event, 0))
	if new_priority < active_priority:
		return out  # a higher-priority one-shot is still playing — this event is dropped
	out["action"] = event
	out["action_until"] = now + float(ACTION_DURATIONS.get(event, 0.5))
	return out


# The state STRING to feed EntityVisuals.play_state(): death sticks forever; a mounted body holds
# its seated pose (T-573 — the mount carries locomotion, so no on-foot clip may show); an active
# one-shot (attack/cast/hit) shows over locomotion; otherwise locomotion (idle/walk/run/jump) shows.
static func display_state(state: Dictionary, now: float) -> String:
	if bool(state.get("dead", false)):
		return "death"
	if bool(state.get("mounted", false)):
		return "mounted"
	if str(state.get("action", "")) != "" and now < float(state.get("action_until", 0.0)):
		return str(state["action"])
	return str(state.get("locomotion", "idle"))


# Respawn: clears death + any in-flight action, back to a fresh idle state.
static func respawn_reset() -> Dictionary:
	return new_state()
