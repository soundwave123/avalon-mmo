extends RefCounted
# T-734: the client half of the server-authoritative day clock. WorldView._day_t stays the ONE
# seam every time-of-day consumer reads (sun arc T-289, sky/night sky, water sheen, T-733 birds,
# ambience daylight gates); this object just decides what that value does each frame:
#
#   - free-run at the shared rate (DAY_SECONDS mirrors WorldView + server world_clock.gd) between
#     server pushes, exactly as the pre-T-734 client did;
#   - when server truth arrives (day_t in handshake_ok, then a "world_clock" resync every ~15 s),
#     SNAP only when the drift is huge (first value on join, or a suspended/lagged client past
#     SNAP_THRESHOLD), otherwise slew: the residual error drains at at most CORR_RATE_MULT extra
#     day-rates forward, and at most the BASE rate backward — so the sun moves at most
#     (1 + CORR_RATE_MULT)x its normal crawl while catching up, and at worst PAUSES (never runs
#     backward) while the server is behind. Never a visible jump, never a reversed sun.
#
# PRECEDENCE: AVALON_FREEZE_DAY (WorldView._day_frozen) pins the CLIENT value for QA pilots and
# screenshot tours. WorldView guards BEFORE calling into this object — while frozen, server sync
# and free-run are both ignored entirely, exactly the pre-T-734 freeze behavior.

const DAY_SECONDS := 1200.0  # mirrors WorldView.DAY_SECONDS (the shared free-run rate)
const SNAP_THRESHOLD := 0.02  # |err| above 24 s of game time (7.2 deg of sun) snaps, else slews
const CORR_RATE_MULT := 2.0  # extra correction speed cap, in multiples of the base day rate

var _pending := 0.0  # residual correction still to apply (signed, day_t units)
var _synced := false  # the first server value snaps unconditionally (the join case)


# Server truth arrived. Returns the (possibly snapped) local value; local free-run + slew handle
# the rest. Negative t = "no value" (an older server's handshake) — ignored, so the client keeps
# free-running exactly as before T-734.
func on_server_day_t(t: float, local_day_t: float) -> float:
	if t < 0.0:
		return local_day_t
	var err := wrapped_err(t, local_day_t)
	if not _synced or absf(err) > SNAP_THRESHOLD:
		_synced = true
		_pending = 0.0
		return fposmod(t, 1.0)
	_pending = err  # replace, never accumulate: each resync re-measures total drift
	return local_day_t


# One frame step: the shared-rate walk plus a rate-capped slice of any pending correction. The
# backward cap is exactly -step (net movement >= 0): the sun may stall, never reverse.
func advance(local_day_t: float, delta: float) -> float:
	var step := delta / DAY_SECONDS
	var drain := clampf(_pending, -step, step * CORR_RATE_MULT)
	_pending -= drain
	return fposmod(local_day_t + step + drain, 1.0)


# PURE: shortest signed distance server - local on the 0..1 day circle, in (-0.5, 0.5] — so a
# resync straddling midnight corrects across the wrap instead of driving the sun the long way.
static func wrapped_err(server_t: float, local_t: float) -> float:
	var d := fposmod(server_t - local_t, 1.0)
	return d - 1.0 if d > 0.5 else d
