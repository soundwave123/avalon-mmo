# T-506: pure, delta-injected local death presentation timeline. The server owns death/respawn;
# this module only derives grayscale/fade/text/input-mirror values from those event edges.
extends RefCounted

enum Phase { ALIVE, DEATH_RAMP, DEAD, RESPAWN_FADE }

const DEATH_RAMP_SECONDS := 1.0
const RESPAWN_FADE_SECONDS := 0.6
# T-515: hard cap on the DEAD hold. Server respawns at 25 s (PLAYER_RESPAWN_TICKS); clear 5 s past
# that so a dropped player_respawn packet can never strand the player on the death screen.
const FAILSAFE_DEAD_SECONDS := 30.0
const TOAST_HOLD_SECONDS := 2.4
const TOAST_FADE_SECONDS := 0.6


static func new_state() -> Dictionary:
	return {
		"phase": Phase.ALIVE,
		"elapsed": 0.0,
		"toast_elapsed": 0.0,
		"grayscale": 0.0,
		"fade": 0.0,
		"death_text_alpha": 0.0,
		"toast_alpha": 0.0,
		"input_disabled": false,
	}


static func begin_death(state: Dictionary) -> Dictionary:
	var out := state.duplicate(true)
	if int(out.get("phase", Phase.ALIVE)) != Phase.ALIVE:
		return out  # duplicate server delivery: keep the current timeline; do not restart/nag
	out["phase"] = Phase.DEATH_RAMP
	out["elapsed"] = 0.0
	out["toast_elapsed"] = 0.0
	out["grayscale"] = 0.0
	out["fade"] = 0.0
	out["death_text_alpha"] = 0.0
	out["toast_alpha"] = 1.0
	out["input_disabled"] = true
	return out


static func begin_respawn(state: Dictionary) -> Dictionary:
	var out := state.duplicate(true)
	out["phase"] = Phase.RESPAWN_FADE
	out["elapsed"] = 0.0
	out["grayscale"] = 1.0
	out["fade"] = 1.0  # cover the authoritative position snap before the next rendered frame
	out["death_text_alpha"] = 0.0
	out["toast_alpha"] = 0.0
	out["input_disabled"] = true
	return out


static func advance(state: Dictionary, delta: float) -> Dictionary:
	var out := state.duplicate(true)
	var phase := int(out.get("phase", Phase.ALIVE))
	var dt := maxf(delta, 0.0)
	if phase == Phase.ALIVE:
		return out
	out["toast_elapsed"] = float(out.get("toast_elapsed", 0.0)) + dt
	var toast_t := float(out["toast_elapsed"])
	if toast_t > TOAST_HOLD_SECONDS:
		out["toast_alpha"] = (
			1.0 - clampf((toast_t - TOAST_HOLD_SECONDS) / TOAST_FADE_SECONDS, 0.0, 1.0)
		)
	if phase == Phase.DEAD:
		# T-515 failsafe: the server auto-respawns at PLAYER_RESPAWN_TICKS (25 s) and broadcasts
		# player_respawn, which drives begin_respawn(). If that event is ever missed (a dropped ENet
		# packet), the DEAD screen would otherwise hold until relog — a tester's playtest bug. Clear
		# a few seconds past the server respawn so the overlay can never permanently strand the player.
		out["elapsed"] = float(out.get("elapsed", 0.0)) + dt
		if float(out["elapsed"]) >= FAILSAFE_DEAD_SECONDS:
			return begin_respawn(out)
		return out
	out["elapsed"] = float(out.get("elapsed", 0.0)) + dt
	if phase == Phase.DEATH_RAMP:
		var ramp := clampf(float(out["elapsed"]) / DEATH_RAMP_SECONDS, 0.0, 1.0)
		out["grayscale"] = ramp
		out["death_text_alpha"] = ramp
		if ramp >= 1.0:
			out["phase"] = Phase.DEAD
			out["elapsed"] = 0.0
		return out
	var reveal := clampf(float(out["elapsed"]) / RESPAWN_FADE_SECONDS, 0.0, 1.0)
	out["fade"] = 1.0 - reveal
	out["grayscale"] = 1.0 - reveal
	if reveal >= 1.0:
		out = new_state()
	return out
