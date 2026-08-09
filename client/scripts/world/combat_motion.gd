class_name CombatMotion
extends RefCounted

# T-307: procedural combat motion for entities whose rig LACKS the clip for an action. The
# placeholder creatures (mob_wolf/mob_kobold_miner/mob_bloodthorn_lasher) carry only idle+walk
# clips, and the generic-box mob has no AnimationPlayer at all, so EntityVisuals.play_state()
# resolves "attack"/"hit"/"death" to nothing and they stand frozen mid-fight (the exact T-307
# defect: a biting wolf idle-locked, a killed wolf left standing). This computes a transient
# LOCAL-space transform for such an entity's visual node so it lunges on a swing, jerks on a hit,
# and topples on death — the ticket's "procedural lunge/recoil" (step 5) + "crumple, don't stand"
# (step 4) stand-in until real creature attack/death clips exist in the rig pipeline.
#
# Pure/deterministic, mirroring AnimStateMachine/critter_wander: no OS time, no globals, inputs
# never mutated, the caller injects `elapsed` seconds (time since the action started) and applies
# the returned transform. Forward is local -Z (the visual's facing); creature visuals bake
# yaw_deg=0 and rest position ZERO, so a creature's visual-node local frame == its body frame and
# the returned offset/pitch drop straight onto the node.

# Attack: a committed forward lunge that surges out fast then settles back (0 -> reach -> 0).
const LUNGE_DURATION := 0.45
const LUNGE_REACH := 0.35  # metres forward at the peak
const LUNGE_PEAK := 0.30  # fraction of the duration where the surge peaks (fast out, slow back)

# Hit: a short backward recoil jerk that does NOT fully interrupt (it releases on its own).
const RECOIL_DURATION := 0.28
const RECOIL_REACH := 0.22  # metres backward at the peak
const RECOIL_PEAK := 0.35

# Death: topple forward + sink over the collapse window, then HOLD the final prone pose (a corpse
# stays down — the caller clears it only on a respawn). No blink-out: the dead mob keeps being
# broadcast in-place until it respawns, so this pose persists on the ground the whole time.
const COLLAPSE_DURATION := 0.6
const COLLAPSE_PITCH := deg_to_rad(82.0)  # radians nose-down onto the ground
const COLLAPSE_SINK := 0.25  # metres the body drops as it folds

# The action states that get a procedural stand-in. "cast" is intentionally absent — none of our
# creatures cast (a caster is always a hero carrying the real Spell_Simple_Shoot clip), so there
# is nothing to stand in for.
# T-350: firearm RECOIL — a sharp back-and-up kick that snaps out and settles (the §7 "delivery
# punch" for a gun). Used for "shoot" on ANY rig: the T-118 hero rig the gun mobs ride has no gun
# clip (UAL is melee/caster only, Mixamo is login-gated), so has_state_clip("shoot") is false and
# the caller drives this procedural kick over the idle body. Shorter/snappier than a melee lunge.
const RECOIL_SHOT_DURATION := 0.30
const RECOIL_SHOT_KICK := 0.09  # metres the body snaps BACKWARD on the shot
const RECOIL_SHOT_PITCH := deg_to_rad(-6.0)  # slight muzzle-rise lean-back at the peak
const RECOIL_SHOT_PEAK := 0.20  # fast out (fraction of the duration), slow settle back

const PROCEDURAL_ACTIONS := ["attack", "hit", "death", "shoot"]


# Does this event have a procedural motion at all? (Used to skip cast/respawn/unknown events.)
static func has_procedural(event: String) -> bool:
	return event in PROCEDURAL_ACTIONS


# How long the motion runs before it releases. Death "runs" only until the collapse completes;
# after that motion() keeps returning the final prone pose (see is_done).
static func duration(event: String) -> float:
	match event:
		"attack":
			return LUNGE_DURATION
		"hit":
			return RECOIL_DURATION
		"shoot":
			return RECOIL_SHOT_DURATION
		"death":
			return COLLAPSE_DURATION
		_:
			return 0.0


# True once a non-death action has fully played out, so the caller can drop it and reset the node
# to rest. Death is terminal: it NEVER reports done (the corpse holds its pose until a respawn
# clear), matching AnimStateMachine's death stickiness.
static func is_done(event: String, elapsed: float) -> bool:
	if event == "death":
		return false
	return elapsed >= duration(event)


# The transient LOCAL transform for the visual node at `elapsed` seconds into `event`:
#   offset  — local-space position delta in metres (-Z is forward, +Y is up).
#   pitch_x — extra rotation about local X (radians) for the death topple; 0 for lunge/recoil.
# Outside a known/active window this is the rest pose (zero offset, zero pitch).
static func motion(event: String, elapsed: float) -> Dictionary:
	var e := maxf(0.0, elapsed)
	match event:
		"attack":
			return {
				"offset": Vector3(0.0, 0.0, -_pulse(e, LUNGE_DURATION, LUNGE_PEAK) * LUNGE_REACH),
				"pitch_x": 0.0,
			}
		"hit":
			return {
				"offset": Vector3(0.0, 0.0, _pulse(e, RECOIL_DURATION, RECOIL_PEAK) * RECOIL_REACH),
				"pitch_x": 0.0,
			}
		"shoot":
			var k := _pulse(e, RECOIL_SHOT_DURATION, RECOIL_SHOT_PEAK)
			return {
				"offset": Vector3(0.0, 0.0, k * RECOIL_SHOT_KICK),  # +Z is backward (local)
				"pitch_x": k * RECOIL_SHOT_PITCH,
			}
		"death":
			var s := _ease_out(clampf(e / COLLAPSE_DURATION, 0.0, 1.0))
			return {"offset": Vector3(0.0, -COLLAPSE_SINK * s, 0.0), "pitch_x": COLLAPSE_PITCH * s}
		_:
			return {"offset": Vector3.ZERO, "pitch_x": 0.0}


# A 0 -> 1 -> 0 pulse: eases up to 1 at `peak_frac` of `dur`, then eases back to 0 at `dur`.
# Zero at or outside the [0, dur] window.
static func _pulse(e: float, dur: float, peak_frac: float) -> float:
	if e <= 0.0 or e >= dur:
		return 0.0
	var peak := dur * peak_frac
	if e < peak:
		return _ease_out(e / peak)
	return 1.0 - _ease_out((e - peak) / (dur - peak))


# Quadratic ease-out on a 0..1 input (fast start, soft finish) — snappy, readable game feel.
static func _ease_out(t: float) -> float:
	var c := clampf(t, 0.0, 1.0)
	return 1.0 - (1.0 - c) * (1.0 - c)
