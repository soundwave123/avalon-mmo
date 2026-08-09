# T-331: LIVE soft-instance coordinator — the main.gd delegate that wires instance_manager.gd's
# pure membership store to the running world (mob spawns + session scope). Split out of main.gd,
# which sits at the gdlint 1000-line cap; main holds one instance and routes the enter/leave intents
# here (the world_rpc.handles/handle precedent). The actual player-vs-player isolation is done by
# broadcast_builder.positions_frames — this module only seeds a scoped mob set and moves sessions
# into an instance_id.
#
# STATE: T-330 (crypt layout + stair) and T-341 (undead family) have landed. Spawns now come from
# data/instances/hollowed_crypt.json (real undead packs at the catacomb's world anchors); the
# entrance/exit anchors below are the true crypt vestibule + churchyard-porch coords. The
# enter_instance / leave_instance intents fire from the client's crypt_gate.gd threshold trigger
# (T-330) at the porch; they still work when sent explicitly (the two-party E2E harness). Boss
# ANCHORS live in data/dungeons/hollowed_crypt_layout.json for T-332. Fallback if this scope is
# cut: the dungeon ships open (design §4 Path A) and nothing here loads. This seam +
# instance_manager.gd are unchanged by the T-330/T-341 landing.
extends RefCounted

const _IM = preload("res://scripts/instance_manager.gd")
const _LFGB = preload("res://scripts/lfg_board_service.gd")  # T-334 board, T-719 carve
const _PL = preload("res://scripts/party_logic.gd")  # T-369: auto-drop on an era cross
const _BB = preload("res://scripts/broadcast_builder.gd")  # T-369: T-371 region model for era scope
const _ML = preload("res://scripts/combat/mob_loader.gd")
const _BM = preload("res://scripts/combat/boss_mechanics.gd")  # T-332: pure boss-mechanic advance
const _CS = preload("res://scripts/combat/combat_state.gd")
const _PS = preload("res://scripts/player_sessions.gd")  # T-332: per-player scope for the dirge AoE
const _RS = preload("res://scripts/combat/rift_scaling.gd")  # T-393: pure tier -> multiplier curve
const _RL = preload("res://scripts/combat/rift_loot.gd")  # T-538: pure tier -> banded loot pool
const _WR = preload("res://scripts/world_regions.gd")  # T-590: per-region overworld respawn anchor
const _IA = preload("res://scripts/instance_assets.gd")  # T-719 carve: the lazy content reads
const _TS = preload("res://scripts/combat/trial_scaling.gd")  # T-719: pure 1-5 headcount curve

# T-330 real anchors. The crypt stands in a DISTANT FLAT OFFSET REGION at world ~(420, 0): T-327
# derives z = TerrainField.height(x,y) and overwrites client z, so a true negative-y underground
# layer is impossible — instead the catacomb is a roofed box on the dead-flat plain past r~330
# (height() == 0 there), invisible to the village and LOD-culled. ENTRANCE = the crypt vestibule
# (server ground x,y); EXIT = the churchyard surface just clear of the porch (gen_crypt_entrance).
const CRYPT_ENTRANCE := Vector3(420.0, 0.2, 0.0)  # vestibule, facing the descent (T-330-tune:
# pulled off the pack1 threshold — was (420,-1.0), only 3.2-4.0u from pack1's mobs, inside the
# skeletal warrior's aggro_radius 7.0, so bare entrants were meleed on arrival; now ~7.5-8.1u from
# the nearest pack1 mob, clear of the vestibule's own stair geometry (blender y <= -0.35) and the
# gallery_a doorway (world y -1.5). Mirror kept in sync with
# data/dungeons/hollowed_crypt_layout.json's entrance_vestibule.
const CRYPT_EXIT := Vector3(12.0, -10.5, 0.0)  # churchyard surface, clear of the porch
# T-347: ASHMOOR era-rift teleport anchors. Ashmoor is a DISTANT FLAT OFFSET REGION at world
# (-420, 0), OPEN/SHARED (instance_id 0 — an era is a world, players see each other; NOT a crypt-
# style instance alloc). ASHMOOR_ARRIVAL = the arrival plaza just N of the monolith (mirrors
# data/regions/ashmoor.json arrival.point); RIFT_RETURN = the dev-only return to the crypt Vault
# surface (the fiction is one-way; a real return waypoint is deferred to the systems milestone).
const ASHMOOR_ARRIVAL := Vector3(-420.0, -5.0, 0.0)
const RIFT_RETURN := Vector3(420.0, -41.5, 0.0)
# T-684 (owner decision 2026-07-22): the rift is EARNED, but by EITHER capstone — a PARALLEL key,
# not the crypt's private one, so T-627's crypt-free solo spine earns its own crossing (the quest
# that SENDS you to the Sky Dock is itself the grant). Neither door widens. Deliberately absent:
# q_wold_kingsroad_ashmoor (L10, no prereq) — see T-684 Work item 3, an open owner call.
const RIFT_CAPSTONES := ["q_rift_vault_counted", "q_wold_moor_road_ashmoor"]
# T-369: the ERA-2 respawn / graveyard point. A death in the Ashmoor offset region must respawn IN
# Ashmoor (the era-2 graveyard, the pauper's field SW of the arrival plaza), NEVER at the era-1
# world origin (Vector3.ZERO) or the crypt vestibule — that would strand a dead era-2 player 840 m
# across the map in the wrong era. Mirrors data/regions/ashmoor.json respawn.point (z=0, flat).
const ASHMOOR_RESPAWN := Vector3(-432.0, -14.0, 0.0)
# T-380: PROXIMITY anchors for the teleport-via-intent gate (security-model.md vector 1b). These
# repositioning intents snap the session to a fixed anchor, bypassing the movement budget — so the
# server must confirm the sender is actually STANDING at the threshold the client fires from, not
# firing it from across the map as a free teleport. The two anchors mirror the client threshold
# triggers so a legit at-anchor player always passes:
#   CRYPT_PORCH  = crypt_gate.gd ENTER_POINT  — where enter_instance legitimately fires (churchyard)
#   ASHMOOR_RIFT = rift_gate.gd  EXIT_POINT   — the Ashmoor arrival monolith (leave_era's origin)
# ANCHOR_RADIUS is generous vs the client's 2.2/2.6 trigger radius (server/client position sync
# slack + goto's 0.5u arrival), yet hundreds of units short of any cross-region jump, so "fire it
# from anywhere" is rejected. Planar (x,y) distance: movement is planar-authoritative and z is
# terrain-derived, so the anchor's z is irrelevant to the check.
const CRYPT_PORCH := Vector2(14.0, -12.5)
const ASHMOOR_RIFT := Vector2(-420.0, -10.0)
const ANCHOR_RADIUS := 6.0
# T-628: the crypt had NO entry gate (only porch proximity) — a solo L7 walked in, was swarmed by
# pack1 (skeletal_warrior L15; T-402's level-relative growth inflates its 4.5m aggro_radius to
# ~9.75m effective reach for a barely-eligible visitor) and died in a self-sustaining loop (T-561
# death_loop fired on itself). Mirrors enter_raid's SERVER-GATED pattern below. min_level 12 matches
# the undead content's own mob levels (skeletal_warrior/crypt_ghoul start at 12). Geometry note
# (verified against gen_hollowed_crypt_real.py's VEST room): the vestibule's walkable floor is only
# ~1.85m long before the descent stair begins, and pack1 already sits at its far doorway — no
# position in the modeled entrance room clears pack1's leash_radius (16m) or the boss anchor's
# (crypt_aldric, 20m, 12.2m from the vestibule), so CRYPT_ENTRANCE stays put: the level gate is
# what actually closes the trap (ticket's own "either alone closes the trap" framing).
const CRYPT_MIN_LEVEL := 12
# T-473: the Vault of the First Hollowing — the Era-1 10-man raid, same seam as the crypt. The
# Vault box sits NORTH of the crypt in the SAME (420,0) offset region (crypt y -7..-43, Vault
# y +66..+99), so the T-371 region bucket and T-355 capacity levers apply unchanged; player-vs-
# player isolation is the same instance_id filter. VAULT_PORCH is the surface threshold — the
# sealed undercroft door past the churchyard's east wall (~8u from CRYPT_PORCH, outside both
# ANCHOR_RADIUS gates; the art-lane door prop + client gate trigger are the visual follow-up,
# the intent works when sent explicitly per the T-331 precedent). Entry is gated to a T-472 RAID
# of more than MAX_PARTY members (enter_raid below).
const VAULT_ENTRANCE := Vector3(420.0, 60.0, 0.0)  # antechamber, ~6u shy of the first pack's aggro
const VAULT_EXIT := Vector3(18.0, -16.0, 0.0)  # surface, just clear of the undercroft door
const VAULT_PORCH := Vector2(20.0, -18.0)
const _SPAWN_FILE := "res://data/instances/hollowed_crypt.json"
const _VAULT_SPAWN_FILE := "res://data/instances/hollow_vault.json"
# Instance kinds — which threshold an instance was allocated from; drives the exit/respawn anchor
# and blocks a raid's party_index instance from being joined through the WRONG door.
const KIND_CRYPT := "crypt"
const KIND_VAULT := "vault"
# T-393: a Rift Trial is a crypt-arena instance whose seed is SCALED by the entrant's keystone tier
# (read from master, never the wire). Slice 1 reuses the crypt threshold/spawns/bosses verbatim.
const KIND_RIFT := "rift"
# T-719: The Shallow Graves — the tutorial capstone. Same churchyard stair, same crypt box, a
# SEPARATE instance seeded with level-2 undead: enter() routes here instead of REJECTING a sub-
# CRYPT_MIN_LEVEL party (the T-628 dead end), so a fresh graduate's first dungeon exists at all.
const KIND_TRIAL := "trial"
# The same vestibule landing and the same churchyard surface (one door), but its OWN anchors —
# deliberately not aliases of the crypt's, so a later re-authoring of either dungeon's threshold
# can't silently move both, and so "an under-level session never stands on CRYPT_ENTRANCE" stays a
# testable statement. x is offset 1.5 m west of the crypt's spot: still inside the VEST room
# (world x 417.5-422.5) and clear of the descent-stair dressing (world x 418.7-421.3), which puts
# the trial's respawn 7.12 m from its nearest mob — the T-628 mistake inverted.
const TRIAL_ENTRANCE := Vector3(418.5, 0.2, 0.0)
const TRIAL_EXIT := Vector3(12.0, -10.5, 0.0)
const _TRIAL_SPAWN_FILE := "res://data/instances/shallow_graves.json"
const _MOB_DIR := "res://data/mobs"
# Crypt entity ids live at _EID_BASE + instance_id*1000 + index — far above the world spawns
# (entity_id_base >= 1000, well under 100k) so a crypt mob never collides with an open-world one.
const _EID_BASE := 1_000_000
# T-332: summoned boss adds get ids above the seeded crypt range so they never collide with either.
const _ADD_EID_BASE := 2_000_000

# T-334: the LFG-lite board rides this coordinator — it is crypt-scoped by design ("looking for
# the Hollowed Crypt"), and BOTH capped files stay untouched: main.gd (999/1000) already routes
# intents here, world_rpc.gd (1000/1000) never learns about LFG (clear-on-group-up is a prune
# against the live party_of truth instead of a hook in the party path). T-719 carved the board's
# BODY to lfg_board_service.gd for line room; this handle is public so the routing stays one call.
var lfg = _LFGB.new()

var _mobs: Dictionary  # main._mobs (by ref — GDScript Dictionaries are reference types)
var _next_add_eid: int = _ADD_EID_BASE  # T-332: monotonic id source for summoned adds
var _store: Dictionary  # instance membership store (owned here)
var _instance_kind: Dictionary = {}  # T-473: iid -> KIND_* (erased on teardown)
var _party_of: Dictionary  # main._party_store["party_of"] (by ref) — the instance key source
var _set_session_instance: Callable  # PlayerSessions.set_instance(peer, iid)
var _move_session: Callable  # PlayerSessions.update_position(peer, pos)
var _clear_threat: Callable  # ThreatTable.clear_mob(entity_id)
var _char_class: Dictionary = {}  # main._char_class (by ref) — the server-true role source
var _lfg_reply: Callable = Callable()  # main._send_to_peer(peer_id, dict)
# T-628: main._char_level (by ref) — the crypt's min-level entry gate reads this, never the wire.
# Default {} + the enter() lookup below both fall back to "allow" on an unknown peer (mirrors
# _near_anchor's synthetic-test-peer bypass), so unit tests that don't wire a level keep passing
# unless they explicitly set one to exercise the gate.
var _char_level: Dictionary = {}
# T-352: the MasterClient (call_master) — injected via setup_lfg so main.gd's edit stays one line
# (it is at the 1000-line cap). Used ONLY by the rift eligibility gate; null in unit tests, which
# leaves the crossing UNGATED (the pure-move contract test_rift_era asserts stays intact).
var _master = null
# T-590: the zone-origin table, lazy-loaded once for respawn_point's per-region overworld anchor.
var _world_regions = null
# T-369: rift/era edge-case wiring, injected via setup_rift so main.gd stays under its line cap.
# _party_store = main._party_store (the FULL roster, by ref) for the auto-drop-on-cross rule;
# _notify_party = world_rpc._notify_members (refreshes affected peers' party frames after the drop);
# _combat_states = main._combat_states (by ref) so a DEAD player can be rejected at the rift (the
# crossing is atomic w.r.t. combat state — you cross alive or not at all). All default-empty so unit
# tests that call setup_lfg/2..3 keep the ungated pure-move contract test_rift_era asserts.
var _party_store: Dictionary = {}
var _notify_party: Callable = Callable()
var _combat_states: Dictionary = {}
var _observe_move: Callable = Callable()  # T-427: forced rift moves still cross discovery edges
# T-393: live Rift Trial runs, iid -> {tier, holder, peers:{username:peer}, deadline, adjudicated}.
# The tier here was read from the master's keystone at the threshold — no client field touches it.
var _rift_runs: Dictionary = {}
var _rift_clock: Callable = Callable()  # test-injectable unix-seconds source (default: OS clock)


func setup(
	mobs: Dictionary,
	party_of: Dictionary,
	set_session_instance: Callable,
	move_session: Callable,
	clear_threat: Callable
) -> void:
	_mobs = mobs
	_store = _IM.new_store()
	_party_of = party_of
	_set_session_instance = set_session_instance
	_move_session = move_session
	_clear_threat = clear_threat


# T-334: second-stage wiring for the LFG board (a separate setter keeps main.gd's edit to one
# line — it sits at the file cap). char_class is held by reference; reply is main._send_to_peer.
# T-352: `master` (default null) rides the same setter so main.gd stays at its line cap — the rift
# eligibility gate needs a MasterClient to query quest completion. Tests call setup_lfg/2 → null.
func setup_lfg(
	char_class: Dictionary, reply: Callable, master = null, char_level: Dictionary = {}
) -> void:
	_char_class = char_class
	_lfg_reply = reply
	_master = master
	_char_level = char_level
	lfg.setup(_party_of, char_class, reply)  # T-719 carve: the board owns its own state now


# T-369: rift edge-case wiring — the FULL party roster (auto-drop-on-cross), world_rpc's party-frame
# notifier, and the live combat-state store (reject-cross-while-dead). All optional + defaulted so
# the unit tests that call setup/5 keep the ungated pure-move contract test_rift_era asserts. Kept
# off the base setup() args (a separate setter) so main.gd's edit stays one small wiring block.
# the file cap.
func setup_rift(party_store: Dictionary, notify_party: Callable, combat_states: Dictionary) -> void:
	_party_store = party_store
	_notify_party = notify_party
	_combat_states = combat_states


func setup_discovery(observe_move: Callable) -> void:
	_observe_move = observe_move


func handles(msg_type: String) -> bool:
	return (
		msg_type == "enter_instance"
		or msg_type == "enter_raid_instance"
		or msg_type == "leave_instance"
		or msg_type == "enter_era"
		or msg_type == "leave_era"
		or msg_type in ["enter_rift_instance", "rift_status", "rift_leaderboard"]  # T-393
		or msg_type in ["lfg_flag", "lfg_unflag", "lfg_list"]
	)


func handle(msg_type: String, peer_id: int, data: Dictionary) -> void:
	if msg_type == "enter_instance":
		enter(peer_id)
	elif msg_type == "enter_raid_instance":
		enter_raid(peer_id)
	elif msg_type == "leave_instance":
		leave(peer_id)
	elif msg_type == "enter_era":
		enter_era(peer_id)
	elif msg_type == "leave_era":
		leave_era(peer_id)
	elif msg_type == "enter_rift_instance":
		# T-393: `data` is DELIBERATELY not passed — a forged {"tier": N} field can never reach the
		# rift path. The tier is read from the master's keystone inside enter_rift.
		enter_rift(peer_id)
	elif msg_type == "rift_status":
		_rift_status(peer_id)
	elif msg_type == "rift_leaderboard":
		# Only the clamped limit crosses; the master action is WORLD-FORCED (a client "action"
		# field is discarded), so this read intent can never reach the result/tier writes.
		_rift_leaderboard(peer_id, clampi(int(data.get("limit", 10)), 1, 25))
	else:
		lfg.handle(msg_type, peer_id, data)


# T-347: the ERA-RIFT crossing (the crypt Vault monolith -> Ashmoor, 100 years on). Ashmoor is
# OPEN/SHARED (instance_id 0), so this is a PURE SESSION MOVE, NOT an instance alloc — the honest
# reuse of the crypt teleport plumbing (rift_gate.gd fires the intent; this owns the move). A
# traveller crossing FROM the crypt Vault is still bound to that instance, so drop the membership
# first (freeing its spawns if last out), then move to the arrival plaza in the open world.
#
# ELIGIBILITY GATE (T-352, wired): the rift is EARNED (ashmoor-direction.md S2/S3). The crossing
# requires the arrival quest "What the Vault Counted" (q_rift_vault_counted) to be underway — a
# quest whose OWN prerequisite is the Era-1 capstone (q_crypt_restless_dead complete), so touching
# the monolith only crosses if Osric has sent you. The T-347 TODO said no completion query existed;
# it was there all along — master's `quest_entry` returns the persisted {state}, so we query it
# honestly (T-684 added the solo capstone as a SECOND key — see RIFT_CAPSTONES). Dev/QA backdoor:
# AVALON_RIFT_UNGATED=1 bypasses it; unit tests inject no master (null) → ungated, preserving
# test_rift_era's pure-move contract.
func enter_era(peer_id: int) -> void:
	# T-369 case 2 — DEATH DURING THE CROSSING. The teleport is atomic w.r.t. combat state: reject the
	# cross while DEAD (checked BEFORE the master round-trip so a corpse never even queries the gate).
	# A dead player stays put and respawns via the normal path at their CURRENT era's point (case 3),
	# so nobody is ever stranded mid-teleport at a region seam or duplicated across eras.
	if _is_dead(peer_id):
		if _lfg_reply.is_valid():
			_lfg_reply.call(peer_id, {"type": "rift_sealed", "reason": "dead"})
		print("[rift] peer %d BLOCKED at the rift (dead — cross is atomic)" % peer_id)
		return
	if not await _rift_eligible(peer_id):
		if _lfg_reply.is_valid():
			_lfg_reply.call(peer_id, {"type": "rift_sealed", "reason": "not_eligible"})
		print("[rift] peer %d BLOCKED at the rift (not eligible)" % peer_id)
		return
	if _IM.instance_of(_store, peer_id) != _IM.WORLD:
		_free_if_torn_down(_IM.leave(_store, peer_id))
	_set_session_instance.call(peer_id, _IM.WORLD)
	var old_pos: Vector3 = _PS.get_player(peer_id).get("pos", Vector3.ZERO)
	_move_session.call(peer_id, ASHMOOR_ARRIVAL)
	var discover_user := str(_PS.get_player(peer_id).get("username", ""))
	if _observe_move.is_valid() and discover_user != "":
		_observe_move.call(peer_id, discover_user, old_pos, ASHMOOR_ARRIVAL)
	# T-369 case 1 — PARTY SPLIT ACROSS ERAS. Spike rule (era-direction.md §6): AUTO-DROP the crosser
	# from their party. A true cross-era party needs the deferred era_id scope (§6); until then a split
	# party's state is undefined, so we dissolve the membership at the boundary. Remaining members
	# get a refreshed party frame (the crosser drops off their roster); the crosser's frame clears.
	_drop_from_party(peer_id)
	# T-353 GEAR-CARRY HOOK (era-direction.md S4.3 Rule A) — the crossing re-scales each held epic/
	# legendary ONE hop (above new-era rare, below its epic) and retires common-through-rare. The
	# inventory lives on master, so this is a master round-trip: master reads the inventory, runs the
	# pure era_gear re-scale, and persists. Ashmoor is Era 2, so target_era = 2. Rarities are injected
	# because items.json is world-side. Skipped when master is unwired (unit tests) — the pure-move
	# contract test_rift_era asserts enter_era stays a plain session move without a master.
	if _master != null:
		var username: String = str(_PS.get_player(peer_id).get("username", ""))
		if username != "":
			var summary: Dictionary = await _master.call_master(
				"carry_gear", {"username": username, "target_era": 2, "rarities": _IA.rarity_map()}
			)
			print(
				(
					"[rift] peer %d gear-carry: %d carried, %d retired"
					% [
						peer_id,
						(summary.get("carried", []) as Array).size(),
						(summary.get("retired", []) as Array).size(),
					]
				)
			)
	print("[rift] peer %d crossed to Ashmoor (open region, instance 0)" % peer_id)


# T-352/T-684: ungated with no master (unit tests) or the QA backdoor; else ANY capstone, as above.
func _rift_eligible(peer_id: int) -> bool:
	if _master == null or OS.get_environment("AVALON_RIFT_UNGATED") == "1":
		return true
	var username: String = str(_PS.get_player(peer_id).get("username", ""))
	if username == "":
		return false
	for quest_id: String in RIFT_CAPSTONES:
		var resp: Dictionary = await _master.call_master(
			"quest_entry", {"username": username, "quest_id": quest_id}
		)
		if str((resp.get("entry", {}) as Dictionary).get("state", "")) in ["active", "complete"]:
			return true
	return false


# Dev-only return (the fiction is one-way). Pure session move back to the crypt Vault surface; the
# traveller stays in the open world (instance 0). A real return convenience is a systems-milestone
# concern (ashmoor-direction.md S2).
func leave_era(peer_id: int) -> void:
	# T-380: gate this "dev-only return" so it isn't a free cross-map teleport (security-model 1b).
	# A legit return fires from the Ashmoor arrival monolith, so require proximity to it. The existing
	# rift backdoor AVALON_RIFT_UNGATED bypasses for dev/QA; a peer with no live session (unit tests)
	# is not position-enforceable, so it passes — safe because a real connected client always has one.
	if OS.get_environment("AVALON_RIFT_UNGATED") != "1" and not _near_anchor(peer_id, ASHMOOR_RIFT):
		if _lfg_reply.is_valid():
			_lfg_reply.call(peer_id, {"type": "rift_sealed", "reason": "not_in_ashmoor"})
		print("[rift] peer %d BLOCKED leaving Ashmoor (not at the arrival monolith)" % peer_id)
		return
	# T-369 case 2 — same atomic-crossing rule as enter_era: a DEAD player can't cross the seam back.
	if _is_dead(peer_id):
		if _lfg_reply.is_valid():
			_lfg_reply.call(peer_id, {"type": "rift_sealed", "reason": "dead"})
		print("[rift] peer %d BLOCKED leaving Ashmoor (dead — cross is atomic)" % peer_id)
		return
	_set_session_instance.call(peer_id, _IM.WORLD)
	_move_session.call(peer_id, RIFT_RETURN)
	_drop_from_party(peer_id)  # T-369 case 1: any era-boundary cross dissolves cross-era party state
	print("[rift] peer %d returned from Ashmoor" % peer_id)


# T-380: is peer_id standing within ANCHOR_RADIUS of a fixed teleport anchor? A peer with NO live
# session (a synthetic unit-test peer / an unhandshaked sender) cannot have its position enforced,
# so it is treated as a pass — safe because a real connected client always carries a session (main
# resolves+validates it before dispatch), so the forged-from-anywhere case in prod is always gated.
func _near_anchor(peer_id: int, anchor: Vector2) -> bool:
	var player: Dictionary = _PS.get_player(peer_id)
	if player.is_empty():
		return true
	var pos: Vector3 = player.get("pos", Vector3.ZERO)
	return Vector2(pos.x, pos.y).distance_to(anchor) <= ANCHOR_RADIUS


# A peer descends the crypt stair: join or allocate the party's instance (solo entrants get a
# private one — instance_manager's key rule), seed the crypt spawns on FIRST entry, move the session
# into the instance and to the entrance anchor. Returns the instance_id.
func enter(peer_id: int) -> int:
	# T-380: gate on proximity to the churchyard porch (the crypt_gate threshold). enter_instance is
	# ungated in the wire; without this a client fires it from anywhere for a free jump to
	# CRYPT_ENTRANCE. Legit entry walks onto the porch first (client gate + the E2E goto). Rejected
	# entrants stay in the open world (return WORLD, no session move). See _near_anchor for the
	# no-session bypass that keeps synthetic unit-test peers working.
	if not _near_anchor(peer_id, CRYPT_PORCH):
		if _lfg_reply.is_valid():
			_lfg_reply.call(peer_id, {"type": "instance_denied", "reason": "too_far"})
		print("[instance] peer %d BLOCKED entering crypt (not at the porch)" % peer_id)
		return _IM.WORLD
	# T-628 kept, T-719 rewritten: an under-level party must never touch the crypt's L15 packs (the
	# death loop T-628 was filed for), but TURNING IT AWAY left a new player with no dungeon at all.
	# The stair now ROUTES instead of rejecting — sub-CRYPT_MIN_LEVEL descends into the Shallow
	# Graves (L2-4 undead, its own instance), 12+ descends into the Hollowed Crypt exactly as before.
	# The T-628 guarantee is structural either way: an under-level session is never moved to
	# CRYPT_ENTRANCE and never shares an instance_id with a skeletal warrior.
	if _crypt_kind_for(peer_id) == KIND_TRIAL:
		var sc: Dictionary = _TS.params_for(_party_headcount(peer_id))
		var iid: int = _enter_kind(
			peer_id, KIND_TRIAL, _TRIAL_SPAWN_FILE, TRIAL_ENTRANCE, float(sc["hp_mult"])
		)
		if iid != _IM.WORLD and _lfg_reply.is_valid():
			_lfg_reply.call(
				peer_id, {"type": "instance_entered", "kind": KIND_TRIAL, "players": sc["players"]}
			)
		return iid
	return _enter_kind(peer_id, KIND_CRYPT, _SPAWN_FILE, CRYPT_ENTRANCE)


# T-719: which dungeon this stair opens onto. The PARTY'S LOWEST level decides, not the entrant's —
# that is what makes "bring your level-20 friend to your first dungeon" work (the campaign's rule
# that first grouped content must never be gated on who you can find) while keeping the T-628
# guarantee absolute: if anyone in the group is under the crypt minimum, nobody in that group is
# standing among level-15 skeletons. An unknown peer (no level wired, e.g. most unit tests) reads as
# CRYPT_MIN_LEVEL, so the crypt stays the default and existing suites are untouched.
func _crypt_kind_for(peer_id: int) -> String:
	var lowest := int(_char_level.get(peer_id, CRYPT_MIN_LEVEL))
	for member in _party_members(peer_id):
		lowest = mini(lowest, int(_char_level.get(int(member), CRYPT_MIN_LEVEL)))
	return KIND_TRIAL if lowest < CRYPT_MIN_LEVEL else KIND_CRYPT


# The live party roster for a peer ([] when party-less or when the roster is unwired in tests).
func _party_members(peer_id: int) -> Array:
	var pid: int = int(_party_of.get(peer_id, -1))
	if pid < 0 or _party_store.is_empty():
		return []
	return _party_store.get("parties", {}).get(pid, {}).get("members", []) as Array


# T-719: how many players the trial seed scales for — the live party roster, never the wire. A solo
# entrant (or an unwired test peer) is 1, which trial_scaling maps to the authored tuning exactly.
func _party_headcount(peer_id: int) -> int:
	return maxi(1, _party_members(peer_id).size())


# T-473: a raid descends into the Vault of the First Hollowing. Same alloc/join/seed path as the
# crypt (the party record is the instance key, so all 10 raid members share one instance), but the
# threshold is the Vault porch and entry is SERVER-GATED to a T-472 raid of MORE than MAX_PARTY
# members — a plain 5-party (or an under-filled raid) is turned away at the door, the ticket's
# entrance-gate assertion. Membership is read from the live party record (never the wire).
func enter_raid(peer_id: int) -> int:
	if not _near_anchor(peer_id, VAULT_PORCH):
		if _lfg_reply.is_valid():
			_lfg_reply.call(peer_id, {"type": "instance_denied", "reason": "too_far"})
		print("[instance] peer %d BLOCKED entering the Vault (not at the door)" % peer_id)
		return _IM.WORLD
	var pid: int = int(_party_of.get(peer_id, -1))
	var party: Dictionary = _party_store.get("parties", {}).get(pid, {})
	var size: int = (party.get("members", []) as Array).size()
	if not party.has("subgroup") or size <= _PL.MAX_PARTY:
		if _lfg_reply.is_valid():
			_lfg_reply.call(peer_id, {"type": "instance_denied", "reason": "requires_raid"})
		print("[instance] peer %d BLOCKED entering the Vault (no raid of >5)" % peer_id)
		return _IM.WORLD
	return _enter_kind(peer_id, KIND_VAULT, _VAULT_SPAWN_FILE, VAULT_ENTRANCE)


# Shared threshold body: join or allocate the party's instance, stamp/verify its KIND, seed on
# first entry, move the session in. The kind guard closes the party_index cross-door hole: a party
# whose live instance is the crypt cannot walk a straggler in through the Vault door (and vice
# versa) — the join is rolled back and the entrant stays in the open world.
# T-719: hp_mult carries the trial's 1-5 headcount scaling into the seed (the same lever the rift's
# tier uses); it defaults to 1.0, so the crypt and Vault seeds stay byte-identical.
func _enter_kind(
	peer_id: int, kind: String, spawn_file: String, entrance: Vector3, hp_mult: float = 1.0
) -> int:
	var party_id: int = int(_party_of.get(peer_id, -1))
	var r: Dictionary = _IM.enter(_store, peer_id, party_id)
	var iid: int = int(r["instance_id"])
	if r["created"]:
		_instance_kind[iid] = kind
		_IM.set_spawns(_store, iid, _seed(iid, spawn_file, hp_mult))
	elif str(_instance_kind.get(iid, kind)) != kind:
		_free_if_torn_down(_IM.leave(_store, peer_id))
		if _lfg_reply.is_valid():
			_lfg_reply.call(peer_id, {"type": "instance_denied", "reason": "wrong_threshold"})
		print("[instance] peer %d BLOCKED (party's instance %d is not a %s)" % [peer_id, iid, kind])
		return _IM.WORLD
	_set_session_instance.call(peer_id, iid)
	_move_session.call(peer_id, entrance)
	print("[instance] peer %d entered %s instance %d (party %d)" % [peer_id, kind, iid, party_id])
	return iid


# ---- T-393: Rift Trials — the infinite-scaling keystone ladder -------------------------------
#
# A Rift Trial is an instance on the SAME chassis as the crypt (alloc/join/seed/teardown), whose
# mob seed is multiplied by the entrant's keystone tier and whose clear/fail verdict is SERVER-
# OBSERVED: all bosses dead before the tier's deadline -> clear (keystone upgrades, scaled reward
# rolls on master); the deadline passing, or the last member bailing out, -> fail (downgrade).
# The client's whole vocabulary is "enter_rift_instance" — it can never name a tier, a clear, a
# timer result, or a reward (adversarial-tested).


# Enter through the crypt porch with YOUR keystone: the tier is read from the master's persisted
# rift.keystone for the entering character — the intent's payload is never consulted. The instance
# creator is the run's key HOLDER (their keystone up/downgrades on the verdict); party members who
# follow them in share the run and the best-tier credit.
func enter_rift(peer_id: int) -> int:
	if not _near_anchor(peer_id, CRYPT_PORCH):
		if _lfg_reply.is_valid():
			_lfg_reply.call(peer_id, {"type": "instance_denied", "reason": "too_far"})
		print("[rift-trial] peer %d BLOCKED entering a rift (not at the porch)" % peer_id)
		return _IM.WORLD
	var username := str(_PS.get_player(peer_id).get("username", ""))
	var tier := 1
	if _master != null and username != "":
		var resp: Dictionary = await _master.call_master(
			"rift_op", {"action": "keystone", "username": username}
		)
		tier = _RS.clamp_tier(int(resp.get("tier", 1)))
	var r: Dictionary = _IM.enter(_store, peer_id, int(_party_of.get(peer_id, -1)))
	var iid: int = int(r["instance_id"])
	if r["created"]:
		var sc: Dictionary = _RS.params_for(tier)
		_instance_kind[iid] = KIND_RIFT
		_IM.set_spawns(
			_store, iid, _seed(iid, _SPAWN_FILE, float(sc["hp_mult"]), float(sc["dmg_mult"]))
		)
		_rift_runs[iid] = {
			"tier": tier,
			"holder": username,
			"peers": {username: peer_id},
			"deadline": _rift_now() + int(sc["timer_secs"]),
			"adjudicated": false,
		}
	elif str(_instance_kind.get(iid, "")) != KIND_RIFT:
		_free_if_torn_down(_IM.leave(_store, peer_id))
		if _lfg_reply.is_valid():
			_lfg_reply.call(peer_id, {"type": "instance_denied", "reason": "wrong_threshold"})
		print("[rift-trial] peer %d BLOCKED (party's instance %d is not a rift)" % [peer_id, iid])
		return _IM.WORLD
	else:
		var joined: Dictionary = _rift_runs.get(iid, {})
		if not joined.is_empty() and username != "":
			joined["peers"][username] = peer_id
	_set_session_instance.call(peer_id, iid)
	_move_session.call(peer_id, CRYPT_ENTRANCE)
	var run: Dictionary = _rift_runs.get(iid, {})
	if _lfg_reply.is_valid():
		(
			_lfg_reply
			. call(
				peer_id,
				{
					"type": "rift_started",
					"tier": int(run.get("tier", tier)),
					"timer_secs": _RS.timer_secs(int(run.get("tier", tier))),
					"deadline": int(run.get("deadline", 0)),
				}
			)
		)
	print("[rift-trial] peer %d entered rift instance %d at tier %d" % [peer_id, iid, tier])
	return iid


# Read-only: your keystone tier + the tuning the next run will use (all server truth, published).
func _rift_status(peer_id: int) -> void:
	var username := str(_PS.get_player(peer_id).get("username", ""))
	var tier := 1
	if _master != null and username != "":
		var resp: Dictionary = await _master.call_master(
			"rift_op", {"action": "keystone", "username": username}
		)
		tier = _RS.clamp_tier(int(resp.get("tier", 1)))
	if _lfg_reply.is_valid():
		var sc: Dictionary = _RS.params_for(tier)
		(
			_lfg_reply
			. call(
				peer_id,
				{
					"type": "rift_status",
					"tier": tier,
					"timer_secs": int(sc["timer_secs"]),
					"hp_mult": float(sc["hp_mult"]),
					"dmg_mult": float(sc["dmg_mult"]),
					"reward_weight": float(sc["reward_weight"]),
				}
			)
		)


# Read-only: the season's best-cleared-tier top-N (the T-390 shared leaderboard seam). The master
# action is world-forced — no client field is forwarded except the pre-clamped limit.
func _rift_leaderboard(peer_id: int, limit: int) -> void:
	var res: Dictionary = {}
	if _master != null:
		res = await _master.call_master("rift_op", {"action": "leaderboard", "limit": limit})
	if _lfg_reply.is_valid():
		(
			_lfg_reply
			. call(
				peer_id,
				{
					"type": "rift_leaderboard",
					"season": int(res.get("season", 0)),
					"entries": res.get("entries", []),
				}
			)
		)


# Sweep the live runs for a verdict (called every server tick from tick_bosses). Both verdicts are
# SERVER-observed: the deadline is this module's own clock; the clear is the mobs' DEAD states.
func _adjudicate_rifts() -> void:
	for iid in _rift_runs.keys():
		var run: Dictionary = _rift_runs[iid]
		if bool(run["adjudicated"]):
			continue
		if _rift_now() >= int(run["deadline"]):
			_adjudicate(int(iid), false)
		elif _rift_bosses_dead(int(iid)):
			_adjudicate(int(iid), true)


# All seeded bosses in the rift instance are DEAD (and at least one boss existed — an unseeded
# instance can never vacuously "clear").
func _rift_bosses_dead(iid: int) -> bool:
	var seen := false
	for eid in _mobs:
		var mob = _mobs[eid]
		if int(mob.instance_id) != iid or mob.boss_mechanic == "":
			continue
		seen = true
		if mob.combat_state.state != _CS.CombatStateEnum.DEAD:
			return false
	return seen


# Deliver the verdict ONCE: flag the run synchronously (no double adjudication across the awaits),
# then hand it to the master — which reads the holder's PERSISTED tier, moves the keystone, credits
# season bests, and rolls each member's scaled reward on ITS rng — and toast every member.
func _adjudicate(iid: int, cleared: bool) -> void:
	var run: Dictionary = _rift_runs.get(iid, {})
	if run.is_empty() or bool(run["adjudicated"]):
		return
	run["adjudicated"] = true
	var verdict := "CLEAR" if cleared else "FAIL"
	print("[rift-trial] instance %d tier %d adjudicated: %s" % [iid, int(run["tier"]), verdict])
	var res: Dictionary = {}
	if _master != null:
		var sched := _IA.rift_schedule()
		res = await (
			_master
			. call_master(
				"rift_op",
				{
					"action": "result",
					"holder": str(run["holder"]),
					"members": (run["peers"] as Dictionary).keys(),
					"cleared": cleared,
					"reward":
					_RL.reward_payload(
						sched, int(run["tier"]), _RS.reward_weight(int(run["tier"]))
					),
					"item_registry": _IA.item_registry(),
				}
			)
		)
	if _lfg_reply.is_valid():
		for uname in run["peers"]:
			(
				_lfg_reply
				. call(
					int(run["peers"][uname]),
					{
						"type": "rift_result",
						"cleared": cleared,
						"tier": int(run["tier"]),
						"new_tier": int(res.get("new_tier", 0)),
						"rewards": res.get("rewards", []),
					}
				)
			)


# Unix-seconds clock, injectable for deterministic timer tests (prod: the OS clock).
func setup_rift_clock(clock: Callable) -> void:
	_rift_clock = clock


func _rift_now() -> int:
	if _rift_clock.is_valid():
		return int(_rift_clock.call())
	return int(Time.get_unix_time_from_system())


# A peer climbs back out: drop membership, free the spawns if it was the last one out, and return
# the session to the open world at the surface anchor.
func leave(peer_id: int) -> void:
	var iid: int = _IM.instance_of(_store, peer_id)
	if iid == _IM.WORLD:
		return
	var exit_pos: Vector3 = _exit_anchor(str(_instance_kind.get(iid, "")))
	var r: Dictionary = _IM.leave(_store, peer_id)
	_set_session_instance.call(peer_id, _IM.WORLD)
	_move_session.call(peer_id, exit_pos)
	_free_if_torn_down(r)


# Where an instance kind puts you back on the surface. Unknown/crypt/trial all share the churchyard
# anchor (one door, one way out); only the Vault has its own undercroft threshold.
func _exit_anchor(kind: String) -> Vector3:
	if kind == KIND_VAULT:
		return VAULT_EXIT
	if kind == KIND_TRIAL:
		return TRIAL_EXIT
	return CRYPT_EXIT


# T-719: is this peer inside an instance that must never punish a death? The tutorial capstone is a
# teaching space — the campaign's "never punish during learning" rule — so main.gd routes the T-364
# durability wear through here and it is SKIPPED for a trial death. Every other death (open world,
# crypt, Vault, rift) wears gear exactly as before. Kept as a death HOOK rather than a predicate so
# main.gd, which sits at the 1000-line cap, changes one existing line instead of gaining a branch.
#
# T-724: RETURNS whether wear was actually applied. This function is the single place the waiver is
# decided, so it is also the only honest source for the client's "Your gear was damaged." line — the
# death payload carries this verdict outward (event_dispatch.player_death) instead of the client
# re-deriving a rule it cannot see. A waived trial death, a missing master and a nameless peer all
# return false: nothing was worn, so nothing may be claimed.
func on_player_died(master, peer_id: int, username: String) -> bool:
	if master == null or username == "":
		return false
	if str(_instance_kind.get(_IM.instance_of(_store, peer_id), "")) == KIND_TRIAL:
		print("[instance] peer %d died in a trial instance — durability wear waived" % peer_id)
		return false
	master.call_master("apply_death_wear", {"username": username})
	return true


# Disconnect / duplicate-login teardown — same membership drop as leave() but never repositions a
# session that is already gone. Idempotent and safe for a world (0) peer.
# T-334: also drops the peer from the LFG board (the ticket's clear-on-disconnect rule).
func on_peer_gone(peer_id: int) -> void:
	lfg.on_peer_gone(peer_id)
	if _IM.instance_of(_store, peer_id) == _IM.WORLD:
		return
	_free_if_torn_down(_IM.leave(_store, peer_id))


# Test/introspection: the live LFG board (post-prune shape is the caller's concern).
func lfg_board() -> Array:
	return lfg.board()


# Where a dead player respawns:
#  - bound to a crypt instance -> the crypt entrance (their membership survives death — a corpse run
#    stays inside);
#  - open world (instance 0) inside the ERA-2 Ashmoor offset region -> the Ashmoor graveyard (T-369
#    case 3: an era-2 death must respawn IN era 2, never at the era-1 origin 840 m away);
#  - open world elsewhere (era-1 village) -> Vector3.ZERO (world origin, as-is).
# Era membership is read from the player's live position via the SAME T-371 nearest-anchor region
# model the broadcast buckets by, so respawn-era and broadcast-era can never disagree.
func respawn_point(peer_id: int) -> Vector3:
	var iid: int = _IM.instance_of(_store, peer_id)
	if iid != _IM.WORLD:
		var kind := str(_instance_kind.get(iid, ""))
		if kind == KIND_VAULT:
			return VAULT_ENTRANCE
		# T-719: the trial's vestibule anchor is >=7.1 m from its nearest mob (shallow_graves.json) —
		# the T-628 mistake inverted, so a wipe can never respawn a learner inside the pack that
		# killed them.
		if kind == KIND_TRIAL:
			return TRIAL_ENTRANCE
		return CRYPT_ENTRANCE
	var pos: Vector3 = _PS.get_player(peer_id).get("pos", Vector3.ZERO)
	# T-590: the overworld respawn anchor is the nearest region's own respawn point (read from the
	# zone-origin table), generalizing the hardcoded era-1-origin / Ashmoor-graveyard branch to every
	# future zone. Byte-identical today: the wold region's anchor is (0,0) and Ashmoor's is the
	# pauper's field (mirrors ASHMOOR_RESPAWN). The region-index boundary (x < -210) is the SAME T-371
	# nearest-anchor split _in_ashmoor uses, so respawn-era and broadcast-era can never disagree.
	if _world_regions == null:
		_world_regions = _WR.load_default()
	if _world_regions.region_count() > 0:
		var rp: Vector2 = _world_regions.respawn_at(pos.x, pos.y)
		return Vector3(rp.x, rp.y, 0.0)
	# Fallback (data file missing): the pre-T-590 hardcoded branch, so respawn never breaks.
	if _in_ashmoor(pos):
		return ASHMOOR_RESPAWN
	return Vector3.ZERO


# T-369: is peer_id currently DEAD? Reads the injected live combat-state store (by ref from main).
# Unwired in unit tests (_combat_states empty) -> false, preserving the ungated pure-move contract.
func _is_dead(peer_id: int) -> bool:
	var cs = _combat_states.get(peer_id, null)
	return cs != null and cs.state == _CS.CombatStateEnum.DEAD


# T-369: is a planar position inside the era-2 Ashmoor offset region? True iff the nearest T-371 era
# anchor is the Ashmoor one (resolved dynamically from ASHMOOR_ARRIVAL so it tracks REGION_ANCHORS
# without hardcoding an index). y is planar (server ground is x,y); z-height never gates a domain.
func _in_ashmoor(pos: Vector3) -> bool:
	return _BB.region_of(pos.x, pos.y) == _BB.region_of(ASHMOOR_ARRIVAL.x, ASHMOOR_ARRIVAL.y)


# T-369: auto-drop the crosser from their party at an era boundary (case 1). No-op when unwired
# (unit tests) or party-less. Snapshots members BEFORE the leave so world_rpc._notify_members can
# still reach the ones whose party auto-disbanded out from under them, then refreshes every one.
func _drop_from_party(peer_id: int) -> void:
	if _party_store.is_empty():
		return
	var party_of: Dictionary = _party_store.get("party_of", {})
	if not party_of.has(peer_id):
		return
	var pid: int = int(party_of[peer_id])
	var affected: Array = (
		(_party_store.get("parties", {}).get(pid, {}).get("members", []) as Array).duplicate()
	)
	_PL.leave(_party_store, peer_id)
	if _notify_party.is_valid():
		_notify_party.call(affected)
	print("[rift] peer %d auto-dropped from party %d on the era cross" % [peer_id, pid])


func _free_if_torn_down(r: Dictionary) -> void:
	if not r["torn_down"]:
		return
	# T-393: abandoning a live rift (last member out/disconnected before a verdict) is a FAIL —
	# the keystone downgrades exactly as a blown timer, so bailing can never dodge the flywheel.
	var torn_iid := int(r["instance_id"])
	if _rift_runs.has(torn_iid):
		if not bool(_rift_runs[torn_iid]["adjudicated"]):
			_adjudicate(torn_iid, false)
		_rift_runs.erase(torn_iid)
	_instance_kind.erase(int(r["instance_id"]))  # T-473: kind dies with the instance
	for eid in r["freed_spawns"]:
		_mobs.erase(eid)
		_clear_threat.call(int(eid))
	print(
		(
			"[instance] instance %d torn down, freed %d spawns"
			% [int(r["instance_id"]), r["freed_spawns"].size()]
		)
	)


# Seed an instance's trash/bosses from its spawn layout (crypt or T-473 Vault), tagging each mob
# the instance_id and a collision-free entity_id. Returns the seeded entity_ids (for teardown).
# T-393: hp/dmg multipliers scale a Rift Trial's seed the same way T-294 bakes elite multipliers
# into the derived resources — downstream damage/AI math needs zero tier-awareness. Defaults (1.0)
# keep the crypt/Vault seed byte-for-byte. T-725: load_seeded applies each ENTRY's respawn tuning.
func _seed(
	iid: int, spawn_file: String = _SPAWN_FILE, hp_mult: float = 1.0, dmg_mult: float = 1.0
) -> Array:
	var seeded: Array = []
	var file := FileAccess.open(spawn_file, FileAccess.READ)
	if file == null:
		printerr("[instance] cannot open %s" % spawn_file)
		return seeded
	var parsed = JSON.parse_string(file.get_as_text())
	file.close()
	if parsed == null or not (parsed.get("spawns", null) is Array):
		printerr('[instance] %s malformed (need {"spawns":[...]})' % spawn_file)
		return seeded
	var idx := 0
	for entry in parsed["spawns"]:
		var mob_file: String = str(entry.get("mob_file", ""))
		for pos in entry.get("positions", []):
			var eid: int = _EID_BASE + iid * 1000 + idx
			var mob = _ML.load_seeded(_MOB_DIR.path_join(mob_file), eid, entry)
			if mob == null:
				continue
			mob.instance_id = iid
			mob.position = Vector3(float(pos[0]), float(pos[1]), 0.0)
			mob.spawn_position = mob.position
			if hp_mult > 1.0:
				mob.resources.max_hp = int(round(float(mob.resources.max_hp) * hp_mult))
				mob.resources.hp = mob.resources.max_hp
			if dmg_mult > 1.0:
				mob.melee_ability.base_damage = int(
					round(float(mob.melee_ability.base_damage) * dmg_mult)
				)
			_mobs[eid] = mob
			seeded.append(eid)
			idx += 1
	return seeded


# ---- T-332: boss encounters ----
#
# Called once per server tick from main._run_mob_ai_tick, AFTER the mob-ai pass has written the
# ticked mobs back. For each live boss (boss_mechanic != "") it advances the PURE boss_mechanics
# and resolves the returned actions against the live world: summon capped adds, translate a dirge
# pulse into per-player damage events (returned for main._apply_mob_events to apply+broadcast+kill),
# announce a phase flip. Also sweeps dead temporary adds so a killed add STAYS dead (no respawn).
# Returns the accumulated damage events (same shape as mob_ai's "damage" events).
func tick_bosses(players: Dictionary, now: int, rng) -> Array:
	var damage_events: Array = []
	_adjudicate_rifts()  # T-393: rift clear/fail verdicts ride the same tick as the boss brains
	_sweep_dead_temps()
	for eid in _mobs.keys():
		var mob = _mobs.get(eid, null)
		if mob == null or mob.boss_mechanic == "":
			continue
		var res = _BM.tick(mob, now, rng)
		_mobs[eid] = res.new_mob
		for act in res.actions:
			_apply_boss_action(players, res.new_mob, act, damage_events)
	return damage_events


# Killing a summoned add makes it STAY dead (teaching focus-fire): erase temporary mobs the instant
# they enter DEAD, before main's respawn timer would revive them, and drop their spawn record.
func _sweep_dead_temps() -> void:
	for eid in _mobs.keys():
		var mob = _mobs.get(eid, null)
		if mob == null or not mob.temporary:
			continue
		if mob.combat_state.state == _CS.CombatStateEnum.DEAD:
			_mobs.erase(eid)
			_clear_threat.call(int(eid))
			_remove_spawn_record(int(mob.instance_id), int(eid))


func _apply_boss_action(players: Dictionary, boss, act: Dictionary, damage_events: Array) -> void:
	match str(act.get("type", "")):
		"summon":
			_do_summon(boss, act)
		"dirge_pulse":
			_do_dirge_pulse(players, boss, act, damage_events)
		"phase_flip":
			print("[boss] %s enters phase 2 — enrage + faster summons" % boss.name)


# Raise up to (max_adds - live) adds at the boss's anchors, tagged temporary + summoned_by so the
# cap counts them and death/teardown frees them. instance_service owns the cap so boss_mechanics
# stays pure (it emits the intent every cadence; the live world decides how many actually spawn).
func _do_summon(boss, act: Dictionary) -> void:
	var max_adds: int = int(act.get("max_adds", 0))
	var live: int = 0
	for e in _mobs:
		var mm = _mobs[e]
		if mm.summoned_by == boss.entity_id and mm.combat_state.state != _CS.CombatStateEnum.DEAD:
			live += 1
	var anchors: Array = act.get("anchors", [])
	var budget: int = mini(max_adds - live, anchors.size())
	if budget <= 0:
		return
	var mob_file: String = str(act.get("mob_file", ""))
	var render_kind: String = str(act.get("render_kind", ""))
	var made: int = 0
	for anchor in anchors:
		if made >= budget:
			break
		var eid: int = _next_add_eid
		_next_add_eid += 1
		var add = _ML.load_from_file(_MOB_DIR.path_join(mob_file), eid)
		if add == null:
			continue
		add.instance_id = boss.instance_id
		add.position = Vector3(float(anchor[0]), float(anchor[1]), 0.0)
		add.spawn_position = add.position
		add.render_kind = render_kind
		add.temporary = true
		add.summoned_by = boss.entity_id
		_mobs[eid] = add
		_record_spawn(int(boss.instance_id), eid)
		made += 1


# Pulse the dirge AoE: damage every player in the BOSS's instance within radius. Instance scope is
# essential — two parties stand at the SAME crypt coords in different instances, so a distance-only
# check would leak damage across instances.
func _do_dirge_pulse(players: Dictionary, boss, act: Dictionary, damage_events: Array) -> void:
	var amount: int = int(act.get("amount", 0))
	var radius: float = float(act.get("radius", 0.0))
	if amount <= 0:
		return
	for pid in players:
		# Instance scope from the injected snapshot if present, else the live session (main's snapshot
		# carries none, so it falls back to _PS — behaviour unchanged; tests inject it to stay hermetic).
		var pinst: int = int(players[pid].get("instance_id", _PS.get_instance(int(pid))))
		if pinst != int(boss.instance_id):
			continue
		var ppos: Vector3 = players[pid].get("position", Vector3.ZERO)
		if boss.position.distance_to(ppos) > radius:
			continue
		(
			damage_events
			. append(
				{
					"type": "damage",
					"mob_id": boss.entity_id,
					"target_id": int(pid),
					"amount": amount,
					"outcome": "hit",
					"enraged": false,
				}
			)
		)


func _record_spawn(iid: int, eid: int) -> void:
	var inst: Dictionary = _store["instances"].get(iid, {})
	if not inst.is_empty():
		inst["spawns"].append(eid)


func _remove_spawn_record(iid: int, eid: int) -> void:
	var inst: Dictionary = _store["instances"].get(iid, {})
	if not inst.is_empty():
		inst["spawns"].erase(eid)
