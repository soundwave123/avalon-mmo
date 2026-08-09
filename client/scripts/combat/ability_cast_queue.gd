class_name AbilityCastQueue
extends Node
# T-721: the client-side ability-press ledger. Every manual action-bar press is recorded here,
# and every server verdict about an ability use (ability_result / cast_started / ability_rejected)
# lands here too — so for the first time the client can ANSWER "which hop ate my press?" instead
# of dropping rejections on the floor (T-719's 5-of-22 mystery: the pilot could not see WHY).
#
# The server replies to EVERY use_ability intent (accept → ability_result|cast_started to the
# caster, refuse → ability_rejected), so this ledger is a complete account of hop 3 without any
# server-side log tailing. Hop 2 (client dispatch) is covered by note_manual_send/note_blocked
# from main._cast_kit_slot. Hop 1 (the pilot's key send) is the driver's own log.
#
# Lives as a child of Main; reads Main's fields lazily (same pattern the T-075 pilot uses) so
# main.gd wiring stays 4 lines. The pilot surfaces summary() through observe() (pilot_observe.gd).
#
# THE FIX (root cause, measured 2026-08-08): the T-057 autoattack timer casts Strike
# (triggers_gcd) every 1.6s, holding the caster in GLOBAL_COOLDOWN ~94% of the time (GCD 1.5s)
# — so a manual press at arbitrary phase was refused on_gcd 18 times out of 22. This queue
# remembers the LAST manual press and, when the server refuses it on_gcd, re-sends it exactly
# when the server-computed gcd_ready_in_ticks says the GCD frees (plus a small margin) — the
# spell-queue behavior every mainstream MMO ships. Retries are capped; any other refusal, or a
# landed result, drops the pending press. The server stays the sole authority on every use.
#
# AVALON_COMBAT_TRACE=1 additionally prints one stdout line per event for headless correlation.

const EVENTS_CAP := 40  # recent-events ring; counts (below) cover the whole session
const RETRY_CAP := 3  # per manual press; each retry only happens on a fresh on_gcd refusal
const TICK_S := 0.05  # one server tick (20 Hz) in seconds
const RETRY_MARGIN_S := 0.05  # land just AFTER gcd_until, never on the still-locked tick

var _events: Array = []  # ring of {t_ms, ev, ability_id, note}
var _counts: Dictionary = {}  # "<ev>:<ability_id>[:reason]" -> int, whole-session totals
var _pending: Dictionary = {}  # the last manual press: {ability_id, target_id, retries_left}
var _trace: bool = false


func _ready() -> void:
	_trace = OS.get_environment("AVALON_COMBAT_TRACE") == "1"


# hop 2: a manual action-bar press left the client for the server. Last-press-wins queueing:
# a newer press replaces any older still-pending one (standard MMO spell-queue semantics).
func note_manual_send(slot: int, ability_id: int, target_id: int) -> void:
	_pending = {"ability_id": ability_id, "target_id": target_id, "retries_left": RETRY_CAP}
	_push("send", ability_id, "slot=%d target=%d" % [slot, target_id])


# hop 2: a manual press did NOT dispatch — record WHY (input gate / no target / empty slot).
func note_blocked(slot: int, reason: String) -> void:
	_push("blocked:" + reason, -1, "slot=%d" % slot)


# hop 3: chained after main._on_combat for every server combat message (see _setup wiring).
func on_combat_event(d: Dictionary) -> void:
	var abil := int(d.get("ability_id", -1))
	match str(d.get("type", "")):
		"ability_result":
			var main := get_parent()
			if main != null and int(d.get("caster_id", -1)) == int(main.get("_my_peer_id")):
				_push("result", abil, str(d.get("outcome", "")))
				if int(_pending.get("ability_id", -1)) == abil:
					_pending = {}  # the pending press landed
		"cast_started":  # only ever sent to the caster (= us)
			_push("cast_started", abil, "")
			if int(_pending.get("ability_id", -1)) == abil:
				_pending = {}
		"ability_rejected":
			_push("rejected:" + str(d.get("reason", "")), abil, JSON.stringify(d.get("detail", {})))
			_maybe_retry(d, abil)


# The queue itself: an on_gcd refusal of OUR pending press re-sends it when the GCD frees.
# Any other matching refusal (or exhausted retries) drops the press; refusals of abilities we
# did not queue (the autoattack timer's Strike) never touch the pending press.
func _maybe_retry(d: Dictionary, abil: int) -> void:
	var wait := retry_wait_s(_pending, d)
	if wait < 0.0:
		if int(_pending.get("ability_id", -1)) == abil:
			_pending = {}  # non-retryable verdict for our press — give up cleanly
		return
	_pending["retries_left"] = int(_pending["retries_left"]) - 1
	if is_inside_tree():
		get_tree().create_timer(wait).timeout.connect(_fire_retry)


# PURE retry policy (unit-tested): seconds to wait before re-sending, or -1.0 for "don't".
static func retry_wait_s(pending: Dictionary, d: Dictionary) -> float:
	if pending.is_empty() or int(d.get("ability_id", -1)) != int(pending.get("ability_id", -1)):
		return -1.0
	if str(d.get("reason", "")) != "on_gcd" or int(pending.get("retries_left", 0)) <= 0:
		return -1.0
	var detail: Dictionary = d.get("detail") if d.get("detail") is Dictionary else {}
	var ticks := maxi(0, int(detail.get("gcd_ready_in_ticks", 2)))
	return float(ticks) * TICK_S + RETRY_MARGIN_S


func _fire_retry() -> void:
	if _pending.is_empty() or get_parent() == null:
		return
	var net = get_parent().get("_net")
	if net == null:
		return
	_push("retry", int(_pending["ability_id"]), "left=%d" % int(_pending["retries_left"]))
	net.request_use_ability(int(_pending["ability_id"]), int(_pending["target_id"]))


# The pilot's observe() surface: whole-session counters + the recent-event tail.
func summary() -> Dictionary:
	return {"counts": _counts.duplicate(), "recent": _events.duplicate(true)}


func _push(ev: String, ability_id: int, note: String) -> void:
	var key := "%s:%d" % [ev, ability_id]
	_counts[key] = int(_counts.get(key, 0)) + 1
	var t := Time.get_ticks_msec()
	_events.append({"t_ms": t, "ev": ev, "ability_id": ability_id, "note": note})
	if _events.size() > EVENTS_CAP:
		_events.pop_front()
	if _trace:
		print("[combat-trace] t=%d %s ability=%d %s" % [t, ev, ability_id, note])
