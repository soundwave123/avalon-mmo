# T-382: per-peer token-bucket budget for the "expensive" master-round-trip intents
# (quest/inventory/service/party/instance/era). Movement, abilities, chat and ping each have their
# OWN cheaper path — this bucket exists solely because those other intents each fan out to a master
# RPC + a Postgres read, so a client flooding get_inventory/equip/talk in a tight loop amplifies
# load onto the single master process. Ability intents are GCD-gated and cheap; they are NOT metered
# here.
#
# Two-stage response (per the ticket): over-budget intents are throttled (rejected with
# `rate_limited`); a peer that keeps flooding accrues a leaky reject counter and, past a high mark,
# is flagged for disconnect. Legitimate bursty UI play (open a bag, talk to a vendor, list an
# auction) fits inside CAPACITY and never accrues rejects.
#
# Pure / clock-injected: `now_ms` is Time.get_ticks_msec() in main.gd, a controlled value in tests —
# no OS time is read here, so the whole thing is unit-testable. Mirrors move_rate_limiter.gd /
# chat_service's per-peer window style.

extends RefCounted

# Burst allowance: a peer may fire this many metered intents back-to-back before the refill rate
# governs. Sized generously — real UI flows are bursty (panel opens fire several intents at once)
# but low sustained rate.
const CAPACITY := 40.0
# Sustained metered-intents/second once the burst is spent. Far above any human UI cadence, far
# below a tight flood loop.
const REFILL_PER_SEC := 15.0
# A rare over-burst leaks away at this rate; only a SUSTAINED flood keeps the reject counter rising.
const REJECT_LEAK_PER_SEC := 5.0
# Accumulated (leaked) rejects past this mark => the peer is a flooder; main disconnects it.
const DISCONNECT_REJECTS := 80.0

var _peers: Dictionary = {}  # peer_id -> {"tokens": float, "rejects": float, "last_ms": int}


# True if the peer may spend one metered intent now; consumes a token when allowed, else accrues a
# reject. Refill + reject-leak are both applied from the elapsed time since this peer's last call.
func allow(peer_id: int, now_ms: int) -> bool:
	var s: Dictionary = _peers.get(peer_id, {"tokens": CAPACITY, "rejects": 0.0, "last_ms": now_ms})
	var elapsed: float = maxf(0.0, float(now_ms - int(s["last_ms"])) / 1000.0)
	s["last_ms"] = now_ms
	s["tokens"] = minf(CAPACITY, float(s["tokens"]) + elapsed * REFILL_PER_SEC)
	s["rejects"] = maxf(0.0, float(s["rejects"]) - elapsed * REJECT_LEAK_PER_SEC)
	var ok: bool
	if float(s["tokens"]) >= 1.0:
		s["tokens"] = float(s["tokens"]) - 1.0
		ok = true
	else:
		s["rejects"] = float(s["rejects"]) + 1.0
		ok = false
	_peers[peer_id] = s
	return ok


# True once a peer's leaked reject counter crosses the flood mark — main.gd disconnects it.
func should_disconnect(peer_id: int) -> bool:
	return float(_peers.get(peer_id, {}).get("rejects", 0.0)) >= DISCONNECT_REJECTS


func forget(peer_id: int) -> void:
	_peers.erase(peer_id)
