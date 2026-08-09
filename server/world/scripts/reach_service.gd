# T-698: movement-observed reach + discovery credit, carved from world_rpc.gd (the 1000-line cap)
# so the per-move hot path can be throttled and fed the PRECOMPUTED reach-objective list instead of
# re-walking every quest's objectives twice per move message (content_query.reach_objectives).
#
# THROTTLE — ~4 Hz per player, against the last-CHECKED position. The old path ran discovery +
# reach containment at OLD and NEW pos for EVERY accepted request_move (60/s per client before the
# client-side coalescing, 15-20/s after). Reach/discovery radii are metres wide while a sprinting
# player covers ~1.5 m per 250 ms, so sampling the crossing edge at 4 Hz against the last sampled
# position credits exactly the same entries — the edge (outside->inside) is preserved because the
# anchor IS the last position that was actually tested. The first move a session ever makes is
# checked immediately (no window to anchor against yet), which also keeps single-shot test moves
# and teleport-style hops (pilot, rift) credit-exact.
#
# Trust shape unchanged: positions come from the server's own movement intake, never client wire.
# world_rpc owns one instance and delegates; replies/credit pushes ride the same injected seams.

extends RefCounted

const _CQ = preload("res://scripts/content/content_query.gd")
const _DISC = preload("res://scripts/discovery_nodes.gd")

const CHECK_INTERVAL_MSEC := 250  # ~4 Hz per player
# A single request_move whose segment is longer than this is a discrete HOP (teleport/rift/pilot/
# reach-harness), not a frame of the continuous ~20 Hz walk stream — those are ~0.3 u/msg at run
# speed (0.48 mounted), always well under 1 u. A hop BYPASSES the throttle: it must be checked on
# its own edge because it may end inside a radius with no follow-up move to trigger a later sample
# (the T-320 lesson — the single-hop reach the multi-client E2E caught the throttle stranding).
const HOP_DISTANCE := 1.0

var _master = null  # MasterClient (call_master)
var _reply: Callable = Callable()  # main._send_to_peer
var _push_quest_delta: Callable = Callable()  # world_rpc.push_quest_delta
var _ach_forward: Callable = Callable()  # achievement_service.forward (earn-toast relay)
var _repush: Callable = Callable()  # world_rpc._repush_combat_stats (discovery XP -> sheet)
var _discovery_nodes: Array = []  # T-427: authored POIs
var _reach_objectives: Array = []  # T-698: precomputed at content load (static content)
var _quest_defs: Dictionary = {}  # T-698: cached all_quest_defs (static content)
var _checkpoint: Dictionary = {}  # peer_id -> {"msec": int, "pos": Vector3} — last-checked sample


func setup(
	master,
	reply: Callable,
	push_quest_delta: Callable,
	ach_forward: Callable,
	repush: Callable,
	discovery_nodes: Array,
	reach_objectives: Array,
	quest_defs: Dictionary
) -> void:
	_master = master
	_reply = reply
	_push_quest_delta = push_quest_delta
	_ach_forward = ach_forward
	_repush = repush
	_discovery_nodes = discovery_nodes
	_reach_objectives = reach_objectives
	_quest_defs = quest_defs


func forget(peer_id: int) -> void:
	_checkpoint.erase(peer_id)


# Credit reach objectives + discovery nodes the player NEWLY entered. Called per accepted move;
# the throttle above decides whether this sample actually runs the containment checks.
# `now_msec` is injectable for tests (-1 = wall clock).
func on_player_moved(
	peer_id: int, username: String, old_pos: Vector3, new_pos: Vector3, now_msec: int = -1
) -> void:
	if _master == null or username == "":
		return
	var now: int = now_msec if now_msec >= 0 else Time.get_ticks_msec()
	var cp: Dictionary = _checkpoint.get(peer_id, {})
	# A discrete hop (or the first move of a session) is checked on its OWN edge immediately — the
	# throttle only ever coalesces the continuous small-step walk stream, never a jump that could
	# land inside a radius and then stop.
	if cp.is_empty() or old_pos.distance_to(new_pos) > HOP_DISTANCE:
		_checkpoint[peer_id] = {"msec": now, "pos": new_pos}
		_check_edges(peer_id, username, old_pos, new_pos)
		return
	if now - int(cp["msec"]) < CHECK_INTERVAL_MSEC:
		return  # inside the window — this small step is folded into the next check's edge
	var anchor: Vector3 = cp["pos"]
	_checkpoint[peer_id] = {"msec": now, "pos": new_pos}
	_check_edges(peer_id, username, anchor, new_pos)


# The T-046 edge rule, unchanged: credit targets whose radius contains new_pos but not old_pos.
func _check_edges(peer_id: int, username: String, old_pos: Vector3, new_pos: Vector3) -> void:
	for node: Dictionary in _DISC.entered(_discovery_nodes, old_pos, new_pos):
		_discover_async(peer_id, username, node)
	var new_targets: Array = _CQ.reach_targets_from(_reach_objectives, new_pos)
	if new_targets.is_empty():
		return
	var old_targets: Array = _CQ.reach_targets_from(_reach_objectives, old_pos)
	for target: String in new_targets:
		if not old_targets.has(target):
			_credit_reach_async(peer_id, username, target)


# T-565: level-trigger reach credit (called from world_rpc._accept_quest). on_player_moved only
# credits on the EDGE of crossing into a radius — a player who ACCEPTS a quest while already
# standing inside the target radius never generates that edge (e.g. q_tut_01's training ring,
# accepted from Drillmaster Hale inside that same radius). credit_event's mini() cap makes this
# idempotent alongside the move path. NEVER throttled — accept-time, not movement-rate.
func credit_on_activate(peer_id: int, username: String, ppos: Vector3) -> void:
	if _master == null or username == "":
		return
	for target: String in _CQ.reach_targets_from(_reach_objectives, ppos):
		_credit_reach_async(peer_id, username, target)


func _credit_reach_async(peer_id: int, username: String, target: String) -> void:
	var r: Dictionary = await _master.call_master(
		"credit_reach", {"username": username, "target": target, "quest_defs": _quest_defs}
	)
	_ach_forward.call(peer_id, r)  # T-367: toast any achievement this discovery just earned
	if not r.get("credited", []).is_empty():
		print("[world] reach_credit %s %s %s" % [username, target, str(r["credited"])])
		for credited_id in r.get("credited", []):  # T-058: reach credit -> targeted delta
			_push_quest_delta.call(peer_id, username, str(credited_id))


func _discover_async(peer_id: int, username: String, node: Dictionary) -> void:
	var r: Dictionary = await _master.call_master("discover", {"username": username, "node": node})
	if not bool(r.get("discovered", false)):
		return
	(
		_reply
		. call(
			peer_id,
			{
				"type": "discovery_earned",
				"node": r.get("node", {}),
				"xp": int(r.get("xp", 0)),
				"coins": int(r.get("coins", 0)),
				"rested_bonus": int(r.get("rested_bonus", 0)),
			}
		)
	)
	_ach_forward.call(peer_id, r)
	if int(r.get("xp", 0)) > 0:
		# T-642: only a real level-up may refill (apply=refill=leveled) — discovery XP never heals.
		var leveled := bool(r.get("leveling", {}).get("leveled_up", false))
		_repush.call(peer_id, username, leveled, leveled)
