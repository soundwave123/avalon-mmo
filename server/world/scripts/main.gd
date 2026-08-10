extends Node
# Avalon world server. ENet on port 9200: validates the handshake, dispatches intents (T-005).

const PlayerSessions = preload("res://scripts/player_sessions.gd")
const ServerConfig = preload("res://scripts/server_config.gd")
const MasterClient = preload("res://scripts/master_client.gd")
const _AR = preload("res://scripts/combat/ability_registry.gd")
const _AE = preload("res://scripts/combat/ability_executor.gd")
const _ASM = preload("res://scripts/combat/action_state_machine.gd")
const _CS = preload("res://scripts/combat/combat_state.gd")
const _CR = preload("res://scripts/combat/combat_resources.gd")
const _CSTATS = preload("res://scripts/combat/character_stats.gd")
const _STC = preload("res://scripts/combat/stat_converter.gd")  # T-295: stat payload builder
const _MAI = preload("res://scripts/combat/mob_ai.gd")
const _PL = preload("res://scripts/party_logic.gd")  # T-280
const _KC = preload("res://scripts/kill_credit.gd")  # T-293: party-scoped kill-credit snapshot
const _MD = preload("res://scripts/combat/mob_data.gd")
const _ML = preload("res://scripts/combat/mob_loader.gd")  # T-044: mob construction (headroom)
const _ADAT = preload("res://scripts/combat/ability_data.gd")
const _TT = preload("res://scripts/combat/threat_table.gd")
const _RM = preload("res://scripts/combat/resource_model.gd")  # T-062: class-resource dynamics
const _RT = preload("res://scripts/combat/resource_ticker.gd")  # T-071: once-per-tick dynamics
const _WRPC = preload("res://scripts/world_rpc.gd")  # TD-002: quest/inventory RPC coordinator
const _MRL = preload("res://scripts/move_rate_limiter.gd")  # T-074: movement rate limit
const _IRL = preload("res://scripts/intent_rate_limiter.gd")  # T-382: intent budget
const _MCOL = preload("res://scripts/movement_collision.gd")  # T-379: anti-noclip geometry gate
const _SPAWN = preload("res://scripts/spawn_dispersion.gd")  # T-373: login spawn/hub dispersion
const _BB = preload("res://scripts/broadcast_builder.gd")  # T-076: positions payload builder
const _ED = preload("res://scripts/event_dispatch.gd")  # T-699: region-scoped combat/death events
const _ISVC = preload("res://scripts/instance_service.gd")  # T-331: soft-instance coordinator
const _MOUNT = preload("res://scripts/mount_service.gd")  # T-431: authoritative movement mode
const _MENTOR = preload("res://scripts/mentorship_service.gd")  # T-452: cap-only party level sync
const _PEERS = preload("res://scripts/peer_lifecycle.gd")  # T-511: capped-main lifecycle carve
const _MOBRESPAWN = preload("res://scripts/mob_respawn.gd")  # T-514b: mob DEAD→IDLE reset carve
const BuildGate = preload("res://scripts/build_gate.gd")  # T-514b: build gate (defense in depth)
const _TI = preload("res://scripts/combat/training_interrupt.gd")  # T-426: interrupt credit
const _CFETCH = preload("res://scripts/combat_fetch.gd")  # T-426: combat fetch (cap carve)
const _QAPROBE = preload("res://scripts/qa_sentinel_probe.gd")  # T-561: runtime anomaly sentinel
const _SZ = preload("res://scripts/sleeping_zones.gd")  # T-594: empty-zone mob-tick gate + snapshot
const _WCLOCK = preload("res://scripts/world_clock.gd")  # T-734: server-authoritative day clock
const _WR = preload("res://scripts/world_regions.gd")  # T-594: region table for the sleeping gate

const HANDSHAKE_TIMEOUT_SEC := 10.0

var _cleanup_timer: float = 0.0  # T-015: cleanup timer for expired disconnected sessions
var _cleanup_interval: float = 60.0  # check every 60s

var _enet_peer: ENetMultiplayerPeer
var _connected_players: Dictionary = {}  # T-067: session metadata ONLY; position = PlayerSessions
var _handshake_timers: Dictionary = {}  # peer_id -> remaining_seconds
var _master_client: MasterClient
var _shutting_down: bool = false
var _min_build := str(OS.get_environment("AVALON_MIN_BUILD")).strip_edges()  # T-514b: gate opt-in
var _broadcast_accumulator: float = 0.0
var _pos_delta_state: Dictionary = {}  # T-372: per-peer last-sent positions frame, for deltas
var _events = _ED.new()  # T-699: region-scoped events (narrows recipients; wire unchanged)

var _combat_states: Dictionary = {}  # T-020 per-player combat (peer_id -> CombatState)
var _combat_resources: Dictionary = {}  # peer_id -> CombatResources
var _char_stats: Dictionary = {}  # peer_id -> CharacterStats
var _char_class: Dictionary = {}  # peer_id -> class (T-063: ability class-gating)
var _char_gender: Dictionary = {}  # peer_id -> persisted gender (T-597: never resend a blank one)
var _equipped: Dictionary = {}  # peer_id -> {slot: item_id} (T-225: gear everyone sees)
var _titles: Dictionary = {}  # peer_id -> worn title id (T-401: nameplate title everyone sees)
var _party_store: Dictionary = _PL.new_store()  # T-280: server party roster
var _unlocked_abilities: Dictionary = {}  # T-208: peer_id -> Array[int] trained unlocks
var _char_level: Dictionary = {}  # T-365: peer_id -> level (drives ability rank scaling)
var _effective_level: Dictionary = {}  # T-452: mentor-capped combat/aggro level
var _talent_ability_mods: Dictionary = {}  # peer_id -> resolved talent mods (T-064)
var _ability_registry = null  # AbilityRegistry instance
var _rng: RandomNumberGenerator

var _mobs: Dictionary = {}  # T-025 mob AI state (entity_id int -> MobData); threat in _threat_table
var _threat_table = null  # ThreatTable
var _world_regions = _WR.load_default()  # T-594: sleeping-zone region table (nearest-origin gate)
var _qa_probe = _QAPROBE.boot()  # T-561: anomaly sentinel; null unless AVALON_QA_SENTINEL=1 (OFF)
var _resource_ticker = _RT.new()  # T-071: resource dynamics run per server TICK (tick-edge driver)
var _asm = _ASM.new()  # T-698: stateless FSM helper, hoisted (was an _ASM.new() per frame)
var _mob_regions: Dictionary = {}  # T-698: entity_id -> spawn region (load-time sleeping-gate map)
var _awake_regions = null  # T-698: this tick's awake set, shared with the NPC/gather-node gate
var _scoped_cache: Dictionary = {}  # T-698: this tick's instance_id -> player filter (memo)
var _move_limiter = _MRL.new()  # T-074: per-peer movement budget (units/sec across messages)
var _intent_limiter = _IRL.new()  # T-382: per-peer budget for master-round-trip intents
var _move_collision = _MCOL.new()  # T-379: anti-noclip — reject moves crossing barrier data
var _snap = preload("res://scripts/combat/combat_snapshot.gd").new()
var _spawn_dispersion = null  # T-373: fresh-login hub dispersion (built in _ready via _SPAWN.boot)
var _world_rpc = null  # TD-002: WorldRpc — owns content + all quest/inventory RPC mediation
var _telemetry: TelemetryEmitter = null  # T-186: fire-and-forget gameplay-event pump
var _instance_svc = _ISVC.new()  # T-331: soft-instance membership + crypt spawn scope
var _social_svc = preload("res://scripts/social_service.gd").new()
var _bar_svc = preload("res://scripts/bar_layout_service.gd").new()  # T-422c: action-bar layout
var _mount_svc = _MOUNT.new()
var _mentor_svc = _MENTOR.new()
var _recap = preload("res://scripts/performance_recap_service.gd").new()
var _fall = preload("res://scripts/fall_damage.gd").new()  # T-586: descent-run fall damage
var _pvp_ok := Callable()  # T-381: player→player consent predicate (bound in _ready)
var _ops = null  # T-511: loopback-only GM channel; constructed only when the world enters the tree
var _world_clock = _WCLOCK.new()  # T-734: owns day_t + resync pushes + master checkpoints


func _ready() -> void:
	print("[world] Avalon world server starting")
	Engine.max_fps = 60  # T-698: headless _process free-ran uncapped for no benefit
	_boot_services()  # T-749: the wiring tail — the regression test stubs THIS to assert the cap


# T-749: _ready()'s wiring tail, verbatim — carved so the cap regression test can stub it out.
func _boot_services() -> void:
	_master_client = MasterClient.new()
	add_child(_master_client)
	_master_client.connect_to_master(ServerConfig.get_master_host(), ServerConfig.get_master_port())

	_telemetry = TelemetryEmitter.new()  # T-186: batches gameplay events -> master, fire-and-forget
	add_child(_telemetry)
	_telemetry.set_flush_callable(_master_client.call_master)

	_world_rpc = _WRPC.new()
	var content_err: String = _world_rpc.setup(
		_master_client, _send_to_peer, "res://data", Callable(self, "_apply_combat_stats")
	)
	if content_err != "":
		printerr("[world] FATAL: content load failed: %s" % content_err)
		get_tree().quit.bind(1).call_deferred()
		return
	print("[world] content + RPC ready: %s" % _world_rpc.content_ops.content_summary())
	_world_rpc.set_kit_refresh(_refresh_kit_after_training)
	_world_rpc.set_gear_update(func(pid: int, gear: Dictionary) -> void: _equipped[pid] = gear)
	_world_rpc.set_mark_mount_learned(Callable(_mount_svc, "mark_learned"))  # T-658
	_world_rpc._set_telemetry(Callable(self, "_tel"))  # T-705: first-session funnel emitter
	var mentor_stores := [_char_stats, _char_class, _talent_ability_mods, _combat_resources]
	_mentor_svc.setup(
		_party_store,
		_char_level,
		Callable(self, "_apply_combat_stats"),
		_send_to_peer,
		mentor_stores,
		Callable(_world_rpc, "talent_defs"),
		Callable(self, "_send_class_kit"),
		_effective_level
	)
	_world_rpc._set_mentorship(_mentor_svc)
	_world_rpc._set_heal(
		func(pid: int, amount: int) -> void:
			var cr = _combat_resources.get(pid)
			if cr != null and cr.hp > 0:
				_combat_resources[pid] = cr.apply_heal(amount)
	)
	_social_svc.setup(
		_send_to_peer, _party_store, _master_client, _world_rpc, func(p, t): _titles[p] = t
	)
	_ops = preload("res://scripts/ops_channel.gd").new()
	add_child(_ops)
	_ops.setup(self, _master_client, [_party_store, _char_class, _char_level, _social_svc._guilds])
	_social_svc.setup_discovery(_char_level, _char_class)  # T-451: /who + seeker truth refs
	_pvp_ok = _social_svc.pvp_eligible  # T-381: executor consent gate reads the live duel store
	_bar_svc.setup(_master_client, _send_to_peer)  # T-422c: set_bar_layout intent + saved order
	_mount_svc.setup(Callable(PlayerSessions, "set_mount_state"), _send_to_peer)
	# T-699: events land on the client via _receive_message (same as the old all-peers _broadcast) —
	# only the recipient list narrows to the origin's instance+region ∪ involved players + parties.
	_events.setup(
		func(pid: int, d: Dictionary) -> void: _receive_message.rpc_id(pid, d),
		Callable(PlayerSessions, "get_positions"),
		_party_store
	)
	_recap.setup(_send_to_peer, ServerConfig.TICK_RATE_HZ, _events.combat, _telemetry.record)
	_world_clock.setup(_master_client, Callable(self, "_send_to_peer"))  # T-734: shared day clock
	add_child(_world_clock)
	# T-586: fall landings damage through the SAME stores/event/death paths as any other hit.
	_fall.wire(_combat_resources, _connected_players, _events.combat, _check_death_player, _tel)

	_enet_peer = ENetMultiplayerPeer.new()
	var listen_port := ServerConfig.get_listen_port()
	var max_players := ServerConfig.get_max_players()
	var err := _enet_peer.create_server(listen_port, max_players)
	if err != OK:
		printerr("[world] FATAL: failed to bind ENet on port %d (err=%d)" % [listen_port, err])
		get_tree().quit.bind(1).call_deferred()
		return
	get_tree().get_multiplayer().set_multiplayer_peer(_enet_peer)
	get_tree().get_multiplayer().peer_connected.connect(_on_peer_connected)
	get_tree().get_multiplayer().peer_disconnected.connect(_on_peer_disconnected)
	print("[world] listening on enet://0.0.0.0:%d" % listen_port)
	set_process(true)
	_snap.bind(
		_combat_states,
		_combat_resources,
		_char_stats,
		_char_class,
		_talent_ability_mods,
		_effective_level,
		_unlocked_abilities
	)
	_ability_registry = _AR.new()  # T-020: ability definitions + server RNG seed
	_ability_registry.load_from_dir("res://data/abilities")
	print("[world] loaded %d abilities" % _ability_registry.count())
	_rng = RandomNumberGenerator.new()
	_rng.randomize()
	_threat_table = _TT.new()  # T-025: threat table + mob spawn
	_load_mobs()
	_wire_regions()  # T-762: static region maps for the sleeping-zone gates (mobs + NPCs + nodes)

	_instance_svc.setup(
		_mobs,
		_party_store["party_of"],
		Callable(PlayerSessions, "set_instance"),
		Callable(PlayerSessions, "update_position"),
		Callable(_threat_table, "clear_mob")
	)
	_instance_svc.setup_lfg(_char_class, _send_to_peer, _master_client, _char_level)  # T-334/352/628
	# T-369: rift edge cases — party auto-drop on cross + reject-cross-while-dead.
	_instance_svc.setup_rift(_party_store, Callable(_mentor_svc, "_notify_members"), _combat_states)
	_instance_svc.setup_discovery(Callable(_world_rpc, "on_player_moved"))
	_spawn_dispersion = _SPAWN.boot(_move_collision)  # T-373: validated login hubs


# T-762: inject the region table into every sleeping-zone consumer, ONCE at boot — run AFTER
# _load_mobs + world_rpc.setup, which seed the mob table and the NPC posts. T-699 clobbered this
# call site (see the ticket); each gate is a dict probe instead of an O(regions) scan because of it.
func _wire_regions() -> void:
	_mob_regions = _SZ.mob_regions(_mobs, _world_regions)
	_world_rpc.set_regions(_world_regions)


# T-698: the same-instance player view. _run_mob_ai_tick memoises it per tick in _scoped_cache; an
# instance method (T-749 _now_tick precedent) so the test can COUNT builds — once per instance/tick.
func _players_in_instance(players: Dictionary, instance_id: int) -> Dictionary:
	return _BB.positions_in_instance(players, instance_id)


# T-749: the ONE server-clock read here (~10 sites used to inline the same integer division, which
# is wrong at any tick rate not dividing 1000). An instance method so the gate test can script it.
func _now_tick() -> int:
	return ServerConfig.now_tick()


func _process(delta: float) -> void:
	if _shutting_down:
		return

	var timed_out: Array[int] = []  # decrement handshake timers
	for peer_id in _handshake_timers.keys():
		_handshake_timers[peer_id] -= delta
		if _handshake_timers[peer_id] <= 0:
			timed_out.append(peer_id)

	for peer_id in timed_out:
		_handshake_timers.erase(peer_id)
		if not _connected_players.has(peer_id):  # only disconnect a player who never handshook
			print("[world] timeout peer_id=%d: no_session" % peer_id)
			_disconnect_peer(peer_id)

	_broadcast_accumulator += delta  # broadcast timer accumulation (T-011)
	if _broadcast_accumulator >= 1.0 / ServerConfig.BROADCAST_RATE_HZ:
		_broadcast_positions()
		_broadcast_accumulator = 0.0

	_cleanup_timer += delta  # T-015: periodic cleanup of expired disconnected sessions
	if _cleanup_timer >= _cleanup_interval:
		_cleanup_timer = 0.0
		var cleaned = PlayerSessions.cleanup_expired(ServerConfig.SESSION_MAX_AGE_SECONDS)
		if cleaned > 0:
			print("[world] cleanup_expired removed %d old disconnected sessions" % cleaned)

	# T-698: everything below compares ABSOLUTE ticks/msec — one tick-edge gate, same semantics.
	# The delta-driven work above (handshake timeouts, broadcast, cleanup) stays per-frame.
	var now_tick: int = _now_tick()
	if not _resource_ticker.is_new_tick(now_tick):
		return

	_social_svc.bg_tick(Time.get_ticks_msec())  # T-413: Crownfield leash/score/end pass
	# T-026: Advance player combat timers (GCD->IDLE, DEAD->IDLE respawn).
	var respawn_players: Array[int] = []
	for pid in _combat_states:
		var old_state = _combat_states[pid]
		var new_state = _asm.advance_timers(old_state, now_tick)
		_combat_states[pid] = new_state
		if (  # DEAD->IDLE transition triggers respawn
			old_state.state == _CS.CombatStateEnum.DEAD
			and new_state.state == _CS.CombatStateEnum.IDLE
		):
			respawn_players.append(pid)
	for pid in respawn_players:
		_handle_player_respawn(pid)

	# T-062/T-071 resource dynamics (rage/mana/OOC HP + swing regen) share the same tick edge.
	_resource_ticker.tick_all(_combat_resources, _char_stats, _combat_states, now_tick)
	_fall.finalize_idle(now_tick)  # T-586: land any open descent run whose mover went idle

	var cast_actions: Array = []  # T-022: per-tick cast scan; collect before mutating _combat_states
	for pid in _combat_states:
		var cs = _combat_states[pid]
		if cs.state != _CS.CombatStateEnum.CASTING:
			continue
		# T-698: read-only view (pos is copied out immediately; the dict is never held or mutated).
		var pos: Vector3 = PlayerSessions.get_player_view(pid).get("pos", Vector3.ZERO)
		cast_actions.append({"pid": pid, "tick": _asm.process_cast_tick(cs, pos, now_tick)})
	for entry in cast_actions:
		var pid: int = entry["pid"]
		var tick_result = entry["tick"]
		if tick_result.status == "complete":
			_on_cast_complete(pid)
		elif tick_result.status == "cancelled":
			var cancel_intent := _CS.CombatIntent.new()
			cancel_intent.type = _CS.IntentType.CANCEL_CAST
			_combat_states[pid] = _asm.tick(_combat_states[pid], cancel_intent, now_tick).new_state
			_send_to_peer(pid, {"type": "cast_cancelled", "reason": tick_result.cancel_reason})

	_run_mob_ai_tick(now_tick)  # T-534: mob AI once per SERVER TICK (frame-rate-independent chase)
	if _qa_probe != null:  # T-561: opt-in read-only runtime invariant pass
		_qa_probe.scan(now_tick, _combat_resources, _mobs, _threat_table)


func _broadcast_positions() -> void:
	var bnow: int = _now_tick()
	var frames: Array = _BB.positions_frames_aoi(  # T-331 instance + T-370 AOI + T-401 titles
		PlayerSessions.get_positions(),
		_combat_resources,
		_char_class,
		_equipped,
		_BB.casts_map(_combat_states, bnow, ServerConfig.TICK_RATE_HZ),
		_party_store["party_of"],
		_mobs,
		_world_rpc.tick_npcs(bnow, ServerConfig.BROADCAST_RATE_HZ, _rng, _awake_regions),  # T-311
		ServerConfig.get_aoi_radius(),
		ServerConfig.get_aoi_max_peers(),
		_titles,  # T-401: worn titles ride the per-peer frame (nameplate)
		_char_gender,  # T-535: gender rides the frame so remote clients pick the female body mesh
		bnow,  # T-722: same clock the player casts use — a channeling boss ships its wind-up too
		ServerConfig.TICK_RATE_HZ
	)
	# T-372: compress each per-peer AOI frame to a delta vs its last-sent frame (periodic keyframe).
	var deltaed: Dictionary = _BB.positions_delta_frames(
		frames, _pos_delta_state, ServerConfig.get_keyframe_frames()
	)
	_pos_delta_state = deltaed["state"]
	for frame in deltaed["frames"]:  # T-370: each frame still targets exactly one peer (peers==[pid])
		_send_to_peer(frame["peers"][0], frame["payload"])


func _on_peer_connected(peer_id: int) -> void:
	print("[world] peer connected: peer_id=%d" % peer_id)
	_handshake_timers[peer_id] = HANDSHAKE_TIMEOUT_SEC


# T-186: record one gameplay event for a peer (T-507: account = login account, character = name).
# T-705: a non-empty `once_key` records the event at most once per SESSION under that key — the
# funnel reads only the first of each, so the high-frequency beats cost one row, not thousands.
# T-722: the account/character resolution + once-vs-plain dispatch moved to
# TelemetryEmitter.record_for — this script sits ON the 1000-line cap, so it carved to make room.
func _tel(event_type: String, pid: int, payload: Dictionary = {}, once_key: String = "") -> void:
	if _telemetry != null:
		_telemetry.record_for(pid, _connected_players.get(pid, {}), event_type, payload, once_key)


func _on_peer_disconnected(peer_id: int) -> void:
	if not _connected_players.has(peer_id) and PlayerSessions.get_player(peer_id).is_empty():
		return  # a reasoned ops kick already ran the teardown before ENet emitted its signal
	var player: Dictionary = _connected_players.get(peer_id, {})
	var username: String = str(player.get("username", "unknown"))
	print("[world] disconnected peer_id=%d user=%s" % [peer_id, username])
	_tel("session_end", peer_id)  # T-186
	var now_tick: int = _now_tick()
	_recap.on_disconnect(peer_id, username, now_tick)  # T-429: close private session window
	if username != "unknown" and username != "":  # T-360: stamp the rested offline-window start
		_master_client.call_master("rested_logout", {"username": username})
	PlayerSessions.preserve_on_disconnect(peer_id)  # T-015: keep state for a reconnect
	_release_local_peer_state(peer_id)  # T-181: shared with the duplicate-login kick


# T-181: idempotent per-peer teardown — body carved to peer_lifecycle for T-734 headroom.
func _release_local_peer_state(peer_id: int) -> void:
	_PEERS.release_local_state(self, peer_id)


@rpc("any_peer", "reliable")  # called when a client sends a message via ENet
func _receive_message(data: Dictionary, _mirror: bool = false) -> void:
	var sender_id: int = get_tree().get_multiplayer().get_remote_sender_id()
	var msg_type: String = str(data.get("type", ""))

	if msg_type == "session":
		_on_session_handshake(sender_id, data)
	elif msg_type == "request_move":
		_on_request_move(sender_id, data)
	elif _mount_svc.handles(msg_type) and _intent_limiter.allow(sender_id, Time.get_ticks_msec()):
		var mstate = _combat_states.get(sender_id)
		_mount_svc.handle(sender_id, data, int(mstate.state) if mstate != null else -1)
	elif msg_type == "ping":
		# Latency probe: echo back immediately with the client's timestamp
		_send_to_peer(sender_id, {"type": "pong", "ts": data.get("ts", 0)})
	elif msg_type == "use_ability":
		_on_use_ability(sender_id, data)
	elif _recap.handles(msg_type) and _intent_limiter.allow(sender_id, Time.get_ticks_msec()):
		var username := str(_connected_players.get(sender_id, {}).get("username", ""))
		var now_tick: int = _now_tick()
		_recap.handle(msg_type, sender_id, username, now_tick)
	elif _social_svc.handles(msg_type):  # T-361/T-363: chat + trade + friends/ignore hub
		_social_svc.handle(msg_type, sender_id, data, Time.get_ticks_msec())
	elif _bar_svc.handles(msg_type) and _intent_limiter.allow(sender_id, Time.get_ticks_msec()):
		_bar_svc.handle(msg_type, sender_id, data)  # T-422c: validate permutation + persist
	elif _instance_svc.handles(msg_type) or _world_rpc.handles(msg_type):
		# T-382: master-round-trip intents share a per-peer token budget; over budget → `rate_limited`.
		if not _intent_limiter.allow(sender_id, Time.get_ticks_msec()):
			_send_to_peer(sender_id, {"type": "intent_rejected", "reason": "rate_limited"})
			if _intent_limiter.should_disconnect(sender_id):
				print("[world] intent_flood peer_id=%d: throttled then disconnected" % sender_id)
				_disconnect_peer(sender_id)
		elif _instance_svc.handles(msg_type):
			_instance_svc.handle(msg_type, sender_id, data)
		else:
			_world_rpc.handle(msg_type, sender_id, data)
	elif not preload("res://scripts/debug_intents.gd").handle(self, msg_type, sender_id):
		push_warning("[world] unknown message type '%s' from peer_id=%d" % [msg_type, sender_id])


@rpc("any_peer", "reliable")  # RPC target for server→client messages (avoids echo loop)
func _receive_client_message(_data: Dictionary, _mirror: bool = false) -> void:
	pass  # server ignores client-bound messages — this method only exists as an RPC target


func _on_session_handshake(peer_id: int, data: Dictionary) -> void:
	var token: String = str(data.get("token", ""))

	if _connected_players.has(peer_id):  # duplicate handshake guard (ENet may deliver an RPC twice)
		print("[world] duplicate handshake from peer_id=%d (already registered)" % peer_id)
		return

	# T-514b: server-authoritative build gate — a cached token can't let a stale client skip the
	# update by connecting straight to the world (mirrors the gateway login gate; opt-in via env).
	var client_build := str(data.get("build", ""))
	if not BuildGate.meets_minimum(client_build, _min_build):
		print("[world] rejected peer_id=%d: outdated_build (min=%s)" % [peer_id, _min_build])
		_send_to_peer(
			peer_id,
			{"type": "handshake_err", "reason": BuildGate.REJECT_REASON, "required": _min_build}
		)
		_disconnect_peer(peer_id)
		return

	if not PlayerSessions.validate_token_format(token):  # pre-check token format
		print("[world] rejected peer_id=%d: invalid_session" % peer_id)
		_disconnect_peer(peer_id)
		return

	if _master_client == null or _master_client.is_degraded():  # master must be reachable
		print("[world] rejected peer_id=%d: master_unreachable" % peer_id)
		_disconnect_peer(peer_id)
		return

	var result: Dictionary = await _master_client.validate_session(token)  # async master validation

	if not result.has("valid") or not result["valid"]:
		var reason: String = result.get("error", "invalid_token")
		print("[world] rejected peer_id=%d: %s" % [peer_id, reason])
		_send_to_peer(peer_id, {"type": "handshake_err", "reason": reason})  # T-507: not silent
		_disconnect_peer(peer_id)
		return

	# T-507: master-resolved acting character — its NAME is the session's gameplay identity
	# (flows through the whole RPC surface); the ACCOUNT drives the duplicate-login kick.
	var account: String = str(result.get("username", ""))
	var username: String = str(result.get("character_name", ""))
	var character_id: int = int(result.get("character_id", 0))
	if username == "":
		username = account

	# T-181: kick any existing LIVE peer for this ACCOUNT before the restore (any character).
	_PEERS.kick_duplicates(account, peer_id, _enet_peer, _send_to_peer, _release_local_peer_state)

	# T-015: reconnection — restore from disconnected sessions if present.
	var restored: Dictionary = PlayerSessions.restore_session(token)
	var is_reconnect: bool = not restored.is_empty()

	# T-373 hub dispersion; T-527: live concurrency contracts it at F&F scale; reconnect overrides.
	# T-706: a not-yet-graduated account (tutorial not done) ALWAYS lands on hub[0] — dispersion
	# hubs sit past the 55 m marker horizon and would strand a first-timer with zero wayfinding.
	var start_pos: Vector3 = (
		_spawn_dispersion.pick(_rng, _connected_players.size())
		if bool(result.get("tutorial_done", false))
		else _spawn_dispersion.pick_first_hub(_rng)
	)
	if is_reconnect:
		start_pos = restored.get("last_pos", Vector3.ZERO)
		username = restored.get("username", username)  # preserve original username
		account = restored.get("account", account)  # T-507

	var success: bool = PlayerSessions.add_player(
		peer_id, token, username, start_pos, account, character_id
	)
	if not success:
		print("[world] rejected peer_id=%d: duplicate_token" % peer_id)
		_disconnect_peer(peer_id)
		return

	_handshake_timers.erase(peer_id)  # clear handshake timer on success

	var player_data: Dictionary = PlayerSessions.get_player(peer_id)
	player_data.erase("pos")  # T-067: single source of position truth = PlayerSessions
	_connected_players[peer_id] = player_data

	if is_reconnect:
		print("[world] reconnected peer_id=%d user=%s" % [peer_id, username])
	else:
		print("[world] session validated for peer_id=%d user=%s" % [peer_id, username])
		_tel("session_start", peer_id)  # T-186
		# T-360: bank rested XP for the logged-out window before combat (master owns the clock + cap).
		await _master_client.call_master("rested_login", {"username": username})

	# T-061: combat state from class+level (the L67 gap); derive HP/mana via the shared stat_converter.
	var cs := _CS.new()
	_combat_states[peer_id] = cs
	var combat: Dictionary = await _fetch_combat(username)
	if combat.get("stats", {}).is_empty():
		push_warning("[world] no combat stats for %s (master degraded?); L1 defaults" % username)
	_apply_combat_stats(
		peer_id,
		combat.get("class", "warrior"),
		combat.get("stats", {}),
		combat.get("talents", {}),
		int(combat.get("level", 1))
	)
	_unlocked_abilities[peer_id] = combat.get("unlocked_abilities", [])  # T-208 kit gate
	_bar_svc.seed(peer_id, combat.get("bar_layout", []))  # T-422c: saved slot order for the kit send
	_social_svc.seed_login(peer_id, combat)  # T-361 chat-filter + T-362 guild-chat caches
	# T-319 seed starter gear at spawn; T-420 equipped_visuals enriches so worn armor keeps armor_type.
	_equipped[peer_id] = _world_rpc._equipped_visuals(combat.get("equipped_slots", []))
	_titles[peer_id] = str(combat.get("chosen_title", ""))  # T-401: seed worn title for the broadcast
	_mount_svc.seed(peer_id, combat.get("mount_profile", {}))

	var hs := {"type": "handshake_ok", "username": username, "daily": result.get("daily", {})}
	hs["day_t"] = _world_clock.day_t()  # T-734: join snapshot — the client snaps once, here only
	hs["account_onboarding"] = combat.get("account_onboarding", {})  # T-550: alt tutorial-skip + hints
	_send_to_peer(peer_id, hs)
	_ops.on_login(peer_id)
	var cclass: String = _char_class.get(peer_id, "")
	_char_gender[peer_id] = str(combat.get("gender", ""))  # T-597: cache for every later kit resend
	_send_class_kit(peer_id, cclass, bool(combat.get("class_locked", false)))
	_send_to_peer(peer_id, _STC.player_stats_msg(combat))
	# T-710: non-graduated accounts get the tutorial offer PUSHED at entry (portal #106).
	if bool(hs["account_onboarding"].get("force_tutorial", false)):
		await _world_rpc.tut_offers.push_tutorial_offer(peer_id)


# T-597: gender always reads from the cache below, never a caller argument (no resend can blank it).
func _send_class_kit(peer_id: int, char_class: String, class_locked := true) -> void:
	var saved: Array = _bar_svc.bar_layout_for(peer_id)  # T-422c: saved slot order (spawn/train)
	var kit: Array = KitHelper.build_kit(
		_ability_registry, char_class, _unlocked_abilities.get(peer_id, []), saved
	)
	_bar_svc.set_known(peer_id, BarLayoutOps.ids(kit))  # T-422c: validation input for set_bar_layout

	var msg := {
		"type": "class_kit",
		"char_class": char_class,
		"class_locked": class_locked,
		"gender": _char_gender.get(peer_id, ""),  # T-520/T-597: "" only for a truly ungendered char
		"abilities": kit,
	}
	_send_to_peer(peer_id, msg)


func _apply_combat_stats(
	peer_id: int,
	char_class: String,
	stat_vec: Dictionary,
	talents: Dictionary = {},
	true_level: int = 1,
	preserve_resources: bool = false
) -> void:
	_mentor_svc.apply_authoritative(
		peer_id, char_class, stat_vec, talents, true_level, preserve_resources
	)


func _on_request_move(sender_id: int, data: Dictionary) -> void:
	# T-698: read-only view (audited: reads pos/username only; the write uses update_position).
	var player: Dictionary = PlayerSessions.get_player_view(sender_id)
	if player.is_empty():
		push_warning("[world] move from unknown peer_id=%d" % sender_id)
		return

	var mcs = _combat_states.get(sender_id)  # T-063: a rooted or stunned player can't move (CC).
	if mcs != null:
		var nt: int = _now_tick()
		if nt < mcs.rooted_until or nt < mcs.stunned_until:
			return

	var current_pos: Vector3 = player.get("pos", Vector3.ZERO)
	if current_pos == null:
		current_pos = Vector3.ZERO
	# T-379: intake validation (speed cap, bounds, anti-noclip) → movement_collision.resolve.
	var now_tick: int = _now_tick()
	var delta := Vector2(float(data.get("dx", 0)), float(data.get("dy", 0)))
	var current2 := Vector2(current_pos.x, current_pos.y)
	var res: Dictionary = _mount_svc.resolve_move(
		_move_collision, current2, delta, sender_id, now_tick, _move_limiter
	)
	if not res["ok"]:
		push_warning("[world] move_%s_rejected peer_id=%d" % [res["reason"], sender_id])
		return
	var new_pos := Vector3(res["pos"].x, res["pos"].y, 0.0)
	PlayerSessions.update_position(sender_id, new_pos, true)  # walked=true: the ONE non-warp path
	# T-586: only walked moves feed the fall detector (warps bump warp_seq and re-baseline).
	_fall.on_walk_move(sender_id, current2.distance_to(res["pos"]), now_tick)

	var username: String = player.get("username", "")
	# T-046: credit any reach objective the player newly entered (server-observed).
	_world_rpc.on_player_moved(sender_id, username, current_pos, new_pos)


func _on_use_ability(sender_id: int, data: Dictionary) -> void:
	if not _connected_players.has(sender_id):
		push_warning("[world] use_ability from unknown peer_id=%d" % sender_id)
		return

	var ability_id: int = int(data.get("ability_id", -1))
	var target_id: int = int(data.get("target_id", -1))

	var ability: AbilityData = _ability_registry.get_ability(ability_id)
	if ability == null:
		_reject_ability(sender_id, ability_id, "unknown_ability")
		return

	# T-067: live position read — the _connected_players copy froze positions at login.
	var target_player: Dictionary = PlayerSessions.get_player(target_id)
	var target_mob = _mobs.get(target_id, null)
	var target_is_mob: bool = target_mob != null
	var target_cs = target_mob.combat_state if target_is_mob else _combat_states.get(target_id)
	if (not target_is_mob and target_player.is_empty()) or target_cs == null:
		_reject_ability(sender_id, ability_id, "invalid_target")
		return

	# Build EntitySnapshots from server-authoritative state (never from client-supplied values).
	var caster_snap = _snap.caster(sender_id)
	var target_snap = _snap.target(target_id, target_player, target_mob, target_cs)

	var now: int = _now_tick()  # server clock

	var exec_result = _AE.execute_ability(
		caster_snap, target_snap, ability, now, _rng, _threat_table, _ability_registry, _pvp_ok
	)

	if not exec_result.accepted:
		_reject_ability(sender_id, ability_id, exec_result.rejection_reason, exec_result.detail)
		return
	_mount_svc.dismount(sender_id, "combat")

	_world_rpc._on_ability_used(sender_id, ability.icon)  # T-426: teach the "use_ability" verb

	if exec_result.outcome == "cast_started":  # save CASTING; the tick loop handles completion
		_combat_states[sender_id] = exec_result.new_caster_state
		_send_to_peer(
			sender_id,
			{"type": "cast_started", "ability_id": ability_id, "cast_ticks": ability.cast_ticks}
		)
		return

	# instant: commit + broadcast + death check via the shared path (T-068).
	_commit_ability_result(
		sender_id, target_id, target_mob, ability_id, exec_result, now, "ability_result"
	)


# T-402: `detail` carries the server-computed context (dist/reach) the client shows on a refusal.
# T-705: ONE ability-rejection path, so every refusal the player sees also lands in the first-
# session funnel — insufficient_resource / out_of_range are exactly the quit-risk moments it reads.
func _reject_ability(pid: int, ability_id: int, reason: String, detail: Dictionary = {}) -> void:
	_send_to_peer(
		pid,
		{"type": "ability_rejected", "ability_id": ability_id, "reason": reason, "detail": detail}
	)
	_tel("intent_rejected", pid, {"intent": "use_ability", "reason": reason}, "reject:" + reason)


func _on_cast_complete(caster_id: int) -> void:
	var cs = _combat_states.get(caster_id)
	if cs == null:
		return
	var ability_id: int = cs.cast_ability_id
	var target_id: int = cs.cast_target_id
	var ability: AbilityData = _ability_registry.get_ability(ability_id)
	if ability == null:
		_combat_states[caster_id] = _CS.new()
		return

	var target_player: Dictionary = PlayerSessions.get_player(target_id)  # T-068: mob or player target
	var target_mob = _mobs.get(target_id, null)
	var target_is_mob: bool = target_mob != null
	var target_cs = target_mob.combat_state if target_is_mob else _combat_states.get(target_id)
	if (not target_is_mob and target_player.is_empty()) or target_cs == null:
		_combat_states[caster_id] = _CS.new()
		_send_to_peer(caster_id, {"type": "cast_cancelled", "reason": "target_lost"})
		return

	var caster_snap = _snap.caster(caster_id)
	var target_snap = _snap.target(target_id, target_player, target_mob, target_cs)

	# T-068: completion re-validates (death/resource/range/LoS) then runs the same executor dispatch.
	var now_tick: int = _now_tick()
	var exec_result = _AE.complete_cast(
		caster_snap, target_snap, ability, now_tick, _rng, _threat_table, _ability_registry, _pvp_ok
	)

	if not exec_result.accepted:
		_combat_states[caster_id] = _CS.new()
		_reject_ability(caster_id, ability_id, exec_result.rejection_reason, exec_result.detail)
		return

	_commit_ability_result(
		caster_id, target_id, target_mob, ability_id, exec_result, now_tick, "cast_complete"
	)


# T-068: shared commit + broadcast + death-check for instant execution AND cast completion.
func _commit_ability_result(
	caster_id: int,
	target_id: int,
	target_mob,
	ability_id: int,
	exec_result,
	now: int,
	label: String
) -> void:
	var target_is_mob: bool = target_mob != null
	# T-426 slice 4: read the effigy telegraph BEFORE the commit overwrites the mob's state below.
	var broke_telegraph: bool = target_is_mob and _TI.telegraph_broken(target_mob, exec_result)
	_combat_states[caster_id] = exec_result.new_caster_state
	_combat_resources[caster_id] = exec_result.new_caster_resources
	if target_is_mob:
		if exec_result.new_target_state != null:
			target_mob.combat_state = exec_result.new_target_state
		if exec_result.new_target_resources != null:
			target_mob.resources = exec_result.new_target_resources
		_mobs[target_id] = target_mob
	elif exec_result.new_target_state != null:
		_combat_states[target_id] = exec_result.new_target_state
	if not target_is_mob and exec_result.damage_amount > 0:
		_mount_svc.dismount(target_id, "damage")
	if not target_is_mob and exec_result.new_target_resources != null:
		var tres: CombatResources = exec_result.new_target_resources
		var hit: bool = exec_result.damage_amount > 0  # T-600: marks the DEFENDER too (was caster-only)
		_combat_resources[target_id] = tres.mark_combat(now) if hit else tres
	# T-364: a resurrect stands the ally up at the CASTER's location (IDLE + reduced HP applied above).
	if not target_is_mob and exec_result.outcome == "resurrect":
		PlayerSessions.update_position(
			target_id, PlayerSessions.get_player(caster_id).get("pos", Vector3.ZERO)
		)
	var caster_name := str(_connected_players.get(caster_id, {}).get("username", "Unknown"))
	var target_name := str(
		(
			target_mob.name
			if target_is_mob
			else _connected_players.get(target_id, {}).get("username", "Unknown")
		)
	)
	var target_res = (
		target_mob.resources if target_is_mob else _combat_resources.get(target_id, _CR.new())
	)
	var ability: AbilityData = _ability_registry.get_ability(ability_id)
	_recap.relay_player_result(
		ability,
		caster_id,
		caster_name,
		target_id,
		target_mob,
		target_name,
		target_res,
		exec_result,
		now
	)
	print(
		(
			"[world] %s ability=%d caster=%d target=%d damage=%d"
			% [label, ability_id, caster_id, target_id, exec_result.damage_amount]
		)
	)

	# T-426 slice 4: a broken telegraph credits q_tut_03's interrupt objective to this caster.
	if broke_telegraph:
		_world_rpc._on_cast_interrupted(caster_id, target_mob.mob_id)

	# T-026: death check (mob path flows kill credit). T-381: a duel hit at the HP floor ends the duel.
	if target_is_mob:
		_check_death_mob(target_id, now)
	elif not _social_svc.on_duel_hit(target_id, _combat_resources, now):
		_check_death_player(target_id, now)


func _send_to_peer(peer_id: int, data: Dictionary) -> void:
	_receive_client_message.rpc_id(peer_id, data)


# T-026: Check if player died after damage application.
func _check_death_player(pid: int, now: int) -> void:
	if not _combat_resources.has(pid):
		return
	var res = _combat_resources[pid]
	if not _CR.is_dead(res):
		return
	var cs = _combat_states.get(pid)
	if cs == null:
		return
	var was_dead: bool = cs.state == _CS.CombatStateEnum.DEAD
	_combat_states[pid] = _asm.check_death_transition(
		cs, res, now, ServerConfig.PLAYER_RESPAWN_TICKS
	)
	# T-364: bounded death penalty — wear gear ONCE on the alive→dead edge (server-observed).
	var dead_user := str(_connected_players.get(pid, {}).get("username", ""))
	# T-724: the hook's return is the ONLY truth about whether gear was worn; it rides the broadcast
	# so the client's damage line can't claim a cost the trial waived (a repeat broadcast wears none).
	var worn := false
	if not was_dead and _combat_states[pid].state == _CS.CombatStateEnum.DEAD and dead_user != "":
		worn = _instance_svc.on_player_died(_master_client, pid, dead_user)  # T-719 trial waiver
	# T-699: region-scoped to the dead player's instance+region ∪ self + party (was all-peers).
	var death_max_hp: int = _combat_resources.get(pid, _CR.new()).max_hp
	var who := dead_user if dead_user != "" else "Unknown"
	_events.involving(_ED.player_death(pid, who, death_max_hp, worn), [pid])
	if not was_dead:
		_recap.finish_player_death(pid, dead_user, now)
	print("[world] player_death peer_id=%d respawn_at=%d" % [pid, _combat_states[pid].respawn_at])
	_tel("death", pid)  # T-186


# T-026: Handle player respawn after DEAD→IDLE transition.
func _handle_player_respawn(pid: int) -> void:
	# T-062: re-derive a full resource set from stats + restore the class resource (rage/mana).
	var prev: CombatResources = _combat_resources[pid]
	var res = _CR.new()
	res.derive_from_stats(_char_stats.get(pid, _CSTATS.new()))
	res.resource_kind = prev.resource_kind
	res.max_rage = prev.max_rage
	res.rage = 0
	_combat_resources[pid] = res
	var bg_spawn: Dictionary = _social_svc.bg_respawn_point(pid)  # T-413: BG death -> in-arena spawn
	PlayerSessions.update_position(pid, bg_spawn.get("spawn", _instance_svc.respawn_point(pid)))
	# T-699: region-scoped to the respawned player's instance+region ∪ self + party (was all-peers).
	var respawn_name := str(_connected_players.get(pid, {}).get("username", "Unknown"))
	_events.involving(_ED.player_respawn(pid, respawn_name, _combat_resources[pid].max_hp), [pid])
	print("[world] player_respawn peer_id=%d" % pid)
	_tel("respawn", pid)  # T-186


func _check_death_mob(mob_id: int, now: int) -> void:  # T-026: check if mob died
	if not _mobs.has(mob_id):
		return
	var mob = _mobs[mob_id]
	if not _CR.is_dead(mob.resources):
		return
	var attackers: Array = _threat_table.get_attackers(mob_id)
	mob.combat_state = _asm.check_death_transition(
		mob.combat_state, mob.resources, now, _ML.next_respawn_ticks(mob, _rng)
	)
	_mobs[mob_id] = mob
	var recipients: Array = _KC.recipients(_party_store, attackers, _combat_resources, mob.position)
	# T-699: region-scoped to the mob's instance+region ∪ the kill-credit recipients + their parties.
	_events.at(
		_ED.mob_death(mob_id, mob, recipients), int(mob.instance_id), mob.position, recipients
	)
	_recap.finish_target(mob_id, str(mob.mob_type_id), mob.name, now)
	# T-042/TD-002 + T-358: server-observed kill credit + mob-kill XP (client never asserts a kill).
	_world_rpc.on_mob_kill(recipients, mob.mob_id, mob.xp, mob.mob_level, attackers)
	_world_rpc.on_dungeon_loot(recipients, mob.mob_id, _rng)  # T-333: party-scoped dungeon rewards
	# T-073: top-threat killer loot runs before threat clear erases who earned it.
	# T-709: roll+deliver is one async hop now — quest-critical entries bypass the tier roll.
	var killer: int = _threat_table.get_top_threat_target(mob_id)
	if killer != -1 and not mob.loot.is_empty():
		_world_rpc.content_ops.roll_and_deliver_mob_loot(killer, mob.loot, mob.difficulty, _rng)
	# T-070: threat dies with the mob — read for kill credit above, then cleared for the respawn.
	_threat_table.clear_mob(mob_id)


# T-026: Handle mob respawn after DEAD→IDLE (T-514b: reset+payload carved to mob_respawn.gd).
func _handle_mob_respawn(mob_id: int) -> void:
	var payload: Dictionary = _MOBRESPAWN.respawn(_mobs, mob_id)
	var mob = _mobs[mob_id]  # T-699: origin = the respawn point; region-scoped, no involved players
	_events.at(payload, int(mob.instance_id), mob.position, [])


# T-073: data-driven spawn table via mob_loader.load_spawn_table (empty result = fail-loud abort).
func _load_mobs() -> void:
	_mobs = _ML.load_spawn_table("res://data/mobs")
	if _mobs.is_empty():
		printerr("[world] FATAL: no mobs spawned (data/mobs/spawns.json)")
		get_tree().quit.bind(1).call_deferred()
		return


func _run_mob_ai_tick(now: int) -> void:
	if _mobs.is_empty():
		return
	# T-067: snapshot LIVE player positions (carved to sleeping_zones for the file cap).
	var players: Dictionary = _SZ.snapshot_players(
		_connected_players, _combat_states, _combat_resources, _char_stats, _effective_level
	)
	# T-594: a region with no player in/near it ticks nothing — its mobs are skipped below.
	var awake: Dictionary = _SZ.awake_regions(
		_SZ.player_grounds(players), _world_regions, ServerConfig.get_zone_wake_margin()
	)
	var ai_results: Array = []  # collect before applying (don't mutate _mobs while iterating)
	_awake_regions = awake  # T-698: the NPC/gather-node gate reads it at broadcast cadence
	_scoped_cache.clear()  # T-698: per-INSTANCE player filter, rebuilt once per tick (not per mob)
	for mob_id in _mobs:
		var mob = _mobs[mob_id]
		if not _SZ.is_mob_awake_cached(mob, awake, _mob_regions):
			continue  # T-594: sleeping zone — no player present, this mob does not tick
		var old_state = mob.combat_state
		mob.combat_state = _asm.advance_timers(mob.combat_state, now)
		if (  # T-026: DEAD→IDLE mob respawn
			old_state.state == _CS.CombatStateEnum.DEAD
			and mob.combat_state.state == _CS.CombatStateEnum.IDLE
		):
			_handle_mob_respawn(mob_id)
			mob = _mobs[mob_id]  # re-read after respawn handler
		# T-330-tune: mob sees same-instance players only; T-698: filtered per-INSTANCE, not per mob.
		var iid: int = int(mob.instance_id)
		if not _scoped_cache.has(iid):
			_scoped_cache[iid] = _players_in_instance(players, iid)
		var res = _MAI.ai_tick(mob, _scoped_cache[iid], _threat_table, now, _rng)
		ai_results.append({"mob_id": mob_id, "result": res})
	for entry in ai_results:
		var mob_id: int = entry["mob_id"]
		_mobs[mob_id] = entry["result"].new_mob
		_apply_mob_events(entry["result"].events)
	# T-332: advance the Hollowed Crypt boss encounters — dirge AoE rides the mob-damage pipeline.
	_apply_mob_events(_instance_svc.tick_bosses(players, now, _rng))


func _apply_mob_events(events: Array) -> void:
	for ev in events:
		var ev_type: String = ev.get("type", "")
		if ev_type == "damage":
			var mob_id: int = ev.get("mob_id", -1)
			var target_id: int = ev.get("target_id", -1)
			var amount: int = ev.get("amount", 0)
			var outcome: String = ev.get("outcome", "hit")
			var mob = _mobs.get(mob_id, _MD.new())
			amount = _MD.non_lethal_cap(mob, amount, _combat_resources.get(target_id, null))  # T-560
			if _combat_resources.has(target_id) and amount > 0:
				_mount_svc.dismount(target_id, "damage")
				var now_tick: int = _now_tick()
				_combat_resources[target_id] = _combat_resources[target_id].apply_damage(amount)
				var tcr: CombatResources = _combat_resources[target_id]  # T-062: rage on hit
				if tcr.resource_kind == "rage":
					tcr = tcr.with_class_resource(_RM.rage_on_damage_taken(tcr.rage, amount))
				# T-582: mark_combat for ALL kinds (was rage-only, blinding the QA sentinel for mana/energy).
				_combat_resources[target_id] = tcr.mark_combat(now_tick)
				var target_name := str(
					_connected_players.get(target_id, {}).get("username", "Unknown")
				)
				_recap.relay_mob_damage(
					mob,
					target_id,
					target_name,
					_combat_resources[target_id],
					amount,
					outcome,
					now_tick,
					ev
				)
				_check_death_player(target_id, now_tick)  # T-026: died from the mob attack?
		elif ev_type == "clear_threat":
			var mob_id: int = ev.get("mob_id", -1)
			if mob_id != -1:
				_threat_table.clear_mob(mob_id)


func _disconnect_peer(peer_id: int) -> void:
	_PEERS.drop(_enet_peer, peer_id, _connected_players, _handshake_timers, _on_peer_disconnected)


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		print("[world] shutting down")
		_shutting_down = true
		_PEERS.shutdown(_disconnect_peer, _connected_players.keys(), get_tree())


# T-208: post-purchase the unlock cache is stale — refetch combat + re-send the kit (no relog).
func _refresh_kit_after_training(peer_id: int) -> void:
	var player: Dictionary = PlayerSessions.get_player(peer_id)
	var username := str(player.get("username", ""))
	if username == "":
		return
	var combat: Dictionary = await _fetch_combat(username)
	_unlocked_abilities[peer_id] = combat.get("unlocked_abilities", [])
	# T-597: re-cache gender from combat truth (this send used to default it to "" -> reopened modal).
	_char_gender[peer_id] = str(combat.get("gender", _char_gender.get(peer_id, "")))
	# T-716: post-rename resync — the display cache follows PlayerSessions' authoritative name.
	if _connected_players.has(peer_id):
		_connected_players[peer_id]["username"] = username
	_send_class_kit(peer_id, _char_class.get(peer_id, ""), bool(combat.get("class_locked", true)))


# T-061/T-399: master's combat payload; RPC shape in combat_fetch.gd. Kept a method: tests stub it.
func _fetch_combat(username: String) -> Dictionary:
	return await _CFETCH.fetch(
		_master_client, _world_rpc.talent_defs(), _world_rpc.item_stats(), username
	)
