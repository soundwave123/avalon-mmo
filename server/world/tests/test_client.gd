extends Node
# Headless ENet test client for the world server.
#
# Reads configuration from environment variables (Flatpak arg-passing workaround):
#   AVALON_HOST         - Server host (default: 127.0.0.1)
#   AVALON_PORT         - Server port  (default: 9200)
#   AVALON_TOKEN        - Session token (32-char hex or JWT)
#   AVALON_RESULT_FILE  - Path to write JSON result
#   AVALON_MOVE_DURATION - Seconds of movement phase (default: 3.0)
#   AVALON_MOVE_SPEED   - Units per tick (default: 50.0)
#   AVALON_MOVE_SEED    - Random seed for deterministic movement (default: 42)
#   AVALON_MOVE_STRAIGHT - If "1", hold ONE heading instead of the sinusoidal wander (T-727)
#   AVALON_MOVE_ANGLE_DEG - That heading in degrees, ground (x, y) plane (default: 0 = +x)
#   AVALON_USE_GATEWAY  - If "1", log in via gateway WS before ENet connect
#   AVALON_GATEWAY_HOST - Gateway WS host (default: 127.0.0.1)
#   AVALON_GATEWAY_PORT - Gateway WS port (default: 9001)
#   AVALON_USERNAME     - Gateway login username (default: player1)
#   AVALON_PASSWORD     - Gateway login password (default: dev)
#   AVALON_USE_ABILITY  - If "1", send ability intents after handshake
#   AVALON_ABILITY_ID   - Ability id to send (default: 1 / Strike)
#   AVALON_ABILITY_TARGET - Target entity id (default: 1001 / dummy mob)
#   AVALON_ABILITY_REPEAT - Max ability intents to send (default: 50)
#   AVALON_ABILITY_GAP_MS - Delay between intents, respects GCD (default: 1600)
#
# Exit codes: 0 = pass, 1 = failure

var _host: String = "127.0.0.1"
var _port: int = 9200
var _token: String = ""
var _result_file: String = ""
var _enet: ENetMultiplayerPeer

var _connected: bool = false
var _handshake_ok: bool = false
var _handshake_sent: bool = false
var _movement_phase: bool = false
var _movement_complete: bool = false
var _error: String = ""
var _connect_start: float = 0.0
var _test_timeout: float = 15.0

# T-012 movement state
var _my_peer_id: int = 0
var _movement_timer: float = 0.0
var _movement_start: float = 0.0
var _movement_elapsed: float = 0.0
var _movement_duration: float = 3.0
var _movement_speed: float = 50.0
var _move_seed: int = 42
var _move_straight: bool = false  # T-727: hold one heading (see AVALON_MOVE_STRAIGHT)
var _move_angle_deg: float = 0.0  # T-727: that heading, degrees in the server's ground (x, y) plane
var _moves_sent: int = 0
var _last_move_sent_ms: float = 0.0  # RTT: when last move was sent
var _rtt_samples: Array[float] = []  # RTT: round-trip times in ms
var _ping_sent_ms: float = 0.0  # true-RTT probe: ping send time
var _ping_rtt_ms: float = -1.0  # true-RTT probe: measured ping/pong RTT
var _ping_sent: bool = false  # true-RTT probe: send ping once
var _broadcasts_received: int = 0
var _other_peers_seen: Array[int] = []
var _other_positions_observed: Dictionary = {}  # peer_id -> Array of position strings
var _rng: RandomNumberGenerator

# T-029: LAN latency measurement mode
var _latency_mode: bool = false
var _latency_samples: Array[float] = []
var _latency_sample_count: int = 100
var _latency_current: int = 0
var _latency_t0: int = 0  # microseconds
var _latency_waiting: bool = false
var _latency_done: bool = false

# T-030: Ability-use integration mode (server-authoritative combat harness).
var _ability_mode: bool = false
var _ability_id: int = 1
var _ability_target: int = 1001
var _ability_repeat: int = 50
var _ability_gap_ms: int = 1600
var _ability_move_to_target: bool = true
var _ability_target_self: bool = false  # T-063: target our own peer_id (self-heal)
var _ability_target_x: float = 10.0
var _ability_target_y: float = 10.0
var _ability_move_sent: bool = false
var _ability_next_send_ms: int = 0
var _ability_last_send_ms: int = 0
var _ability_intents_sent: int = 0
var _ability_results_received: Array = []
var _ability_rejections_received: Array = []
var _ability_mob_death_count: int = 0
var _ability_mob_killed: bool = false
var _ability_done: bool = false
var _ability_last_outcome: String = ""
var _ability_damage_attributed_by_server: bool = false
# T-067: move-then-fight observations — mob-initiated attacks on ME and cast lifecycle events.
var _ability_aggro_wait_ms: int = 0
var _ability_attacks_on_me: int = 0
var _ability_cast_started_count: int = 0
var _ability_cast_cancel_reasons: Array = []
# TD-004 F1: harness isolation — mob targets respawn on a ~30s timer, so back-to-back
# harnesses used to fail spuriously on a dead 1001. The attack phase now waits until the
# positions broadcast shows the target ALIVE.
var _ability_target_alive: bool = false

# T-070: stay connected after a kill (stale-threat-across-respawn probe) + credited ids.
var _ability_linger_ms: int = 0
var _ability_kill_time_ms: int = 0
var _ability_mob_death_credited: Array = []
# T-071: own-HP tracking from the positions broadcast (out-of-combat regen visibility).
var _my_hp_min: int = -1
var _my_hp_last: int = -1

# T-603: accept_quest is giver-proximity gated server-side, so every mode that accepts must walk
# to the quest's giver NPC first. Own position is tracked from the broadcast until the giver move
# is sent (then the optimistic post-move value owns it — see _move_to_giver). Giver coordinates
# default per mode (q001 → Farmer Geld, q_tut_01 → the drillmaster's T-577 anchor); override with
# AVALON_GIVER_X / AVALON_GIVER_Y when running a custom quest id.
var _my_pos := Vector2.ZERO
var _my_pos_known: bool = false
var _giver_move_sent: bool = false
var _giver_x: float = 4.8
var _giver_y: float = 1.5

# T-047: Quest-loop mode (additive). Wraps the ability kill loop with accept-before + turn_in-after,
# all over real ENet: accept_quest → (kill via ability mode) → request_quest_log → turn_in.
var _quest_mode: bool = false
# T-707 retired q007; q_tut_01 keeps the same giver anchor + dummy kill (its reach ring contains
# the giver anchor, so it auto-credits at accept, and the token collect rides the T-709 guarantee).
var _quest_id: String = "q_tut_01"
var _quest_accept_sent: bool = false
var _quest_accept_result: Dictionary = {}
var _quest_log_requested: bool = false
var _quest_log_result: Dictionary = {}
var _quest_turn_in_sent: bool = false
var _quest_turn_in_result: Dictionary = {}
var _quest_kill_time_ms: int = 0
var _quest_done: bool = false

# T-216: full village -> Highkeep chain over one persisted ENet session.
var _road_mode: bool = false
var _road_actions: Array = []
var _road_action_index: int = 0
var _road_action_sent: bool = false
var _road_action_started_ms: int = 0
var _road_last_move_ms: int = 0
var _road_pos := Vector2.ZERO
var _road_talk_result: Dictionary = {}
var _road_inventory_result: Dictionary = {}
var _road_completed: Array[String] = []
var _road_letter_received: bool = false
var _road_letter_removed: bool = false
var _road_voucher_received: bool = false
var _road_coins_awarded: int = 0
var _road_done: bool = false

# T-049: reach-objective mode — accept a quest, move into a reach radius, poll the log until the
# reach objective credits (proves main._on_request_move → world_rpc.on_player_moved over real ENet).
var _reach_mode: bool = false
var _reach_quest: String = "q001"
var _reach_x: float = 42.0
var _reach_y: float = -13.0
var _reach_obj_index: int = 3
var _reach_accept_sent: bool = false
var _reach_move_sent: bool = false
var _reach_log_next_ms: int = 0
var _reach_done: bool = false

# T-049: talk-objective mode — accept, move to the NPC, talk, poll until the talk objective credits.
var _talk_mode: bool = false
var _talk_quest: String = "q001"
var _talk_npc: String = "npc_scout_mira"
var _talk_x: float = 12.0
var _talk_y: float = 8.0
var _talk_obj_index: int = 2
var _talk_accept_sent: bool = false
var _talk_move_sent: bool = false
var _talk_sent: bool = false
var _talk_log_next_ms: int = 0
var _talk_done: bool = false

# T-049: inventory mode — get a seeded bag item, equip it, assert the server moved it to its slot.
var _inv_mode: bool = false
var _inv_bag_slot: int = 0
var _inv_item: String = "itm_leather_cap"
var _inv_equip_slot: String = "head"
var _inv_get_sent: bool = false
var _inv_equip_sent: bool = false
var _inv_done: bool = false
var _inv_get_result: Dictionary = {}
var _inv_equip_result: Dictionary = {}

# T-049: collect mode — items seeded in the bag, accept the quest, poll until collect credits with NO
# inventory change (proves the accept-refresh fix; previously it stayed 0/N until a later change).
var _collect_mode: bool = false
var _collect_quest: String = "q001"
var _collect_obj_index: int = 1
var _collect_accept_sent: bool = false
var _collect_log_next_ms: int = 0
var _collect_done: bool = false

# T-064: talent mode — request_talents -> spend N points -> request_talents; all replies
# recorded raw so the harness asserts server-validated spends + persistence.
var _talent_mode: bool = false
var _talent_id: String = ""
var _talent_spends: int = 1
var _talent_state: int = 0
var _talent_before: Dictionary = {}
var _talent_after: Dictionary = {}
var _talent_spend_results: Array = []
var _talent_sent: int = 0
var _talent_done: bool = false
var _player_stats_last: Dictionary = {}  # T-060
var _quest_delta_count: int = 0  # T-058
var _npc_delta_count: int = 0  # T-058
# T-065: optional set_class attempts (comma-separated classes) before the talent flow.
var _set_class_queue: Array = []
var _set_class_results: Array = []
var _set_class_sent: int = 0

# T-015: Reconnect test mode (additive; direct path untouched)
var _reconnect_mode: bool = false
var _reconnect_phase: int = 0  # 0=idle, 1=waiting_to_reconnect, 2=reconnecting
var _reconnect_timer: float = 0.0
var _reconnect_wait_seconds: float = 1.0
var _reconnect_handshake_ok: bool = false

# T-014: Gateway auth-handoff mode (additive; direct path untouched)
var _use_gateway: bool = false
var _gw_host: String = "127.0.0.1"
var _gw_port: int = 9001
var _gw_username: String = "player1"
var _gw_password: String = "dev"
var _gw_ws: WebSocketPeer
var _gw_phase: int = 0  # 0=none, 1=connecting, 2=open, 3=response_received
var _gw_response_received: bool = false


func _ready() -> void:
	_parse_args()

	# T-014: Gateway login mode — WS first, then ENet
	if _use_gateway:
		_gateway_login()
		return

	if _token.is_empty():
		_error = "no token provided"
		_finish()
		return

	_enet = ENetMultiplayerPeer.new()
	var err := _enet.create_client(_host, _port)
	if err != OK:
		_error = "failed to create ENet client (err=%d)" % err
		_finish()
		return

	get_tree().get_multiplayer().set_multiplayer_peer(_enet)
	get_tree().get_multiplayer().connected_to_server.connect(_on_connected)
	get_tree().get_multiplayer().connection_failed.connect(_on_connection_failed)
	get_tree().get_multiplayer().server_disconnected.connect(_on_server_disconnected)

	_rng = RandomNumberGenerator.new()
	_rng.seed = _move_seed

	_connect_start = Time.get_ticks_msec() / 1000.0
	_test_timeout = _movement_duration + 6.0
	if _latency_mode:
		_test_timeout = 45.0  # 100 samples at ~5ms each + connection overhead
	if _ability_mode:
		_test_timeout = max(
			20.0,
			(
				(float(_ability_repeat * _ability_gap_ms) / 1000.0)
				+ (float(_ability_aggro_wait_ms) / 1000.0)
				+ (float(_ability_linger_ms) / 1000.0)
				+ 47.0
			)  # TD-004: covers a full 30s mob-respawn wait before the attack phase
		)
	set_process(true)


func _parse_args() -> void:
	# Read from environment variables (Flatpak compatibility)
	var env_host = OS.get_environment("AVALON_HOST")
	if env_host != null and env_host != "":
		_host = env_host

	var env_port = OS.get_environment("AVALON_PORT")
	if env_port != null and env_port != "":
		_port = int(env_port)

	var env_token = OS.get_environment("AVALON_TOKEN")
	if env_token != null and env_token != "":
		_token = env_token

	var env_result = OS.get_environment("AVALON_RESULT_FILE")
	if env_result != null and env_result != "":
		_result_file = env_result

	var env_duration = OS.get_environment("AVALON_MOVE_DURATION")
	if env_duration != null and env_duration != "":
		_movement_duration = float(env_duration)

	var env_speed = OS.get_environment("AVALON_MOVE_SPEED")
	if env_speed != null and env_speed != "":
		_movement_speed = float(env_speed)

	var env_seed = OS.get_environment("AVALON_MOVE_SEED")
	if env_seed != null and env_seed != "":
		_move_seed = int(env_seed)

	# T-727: run in a STRAIGHT line on a known compass heading instead of the default sinusoidal
	# wander (whose heading is re-randomised every move). The two-client facing guard needs a stable
	# travel direction to score dot(facing, velocity) against — a wandering mover's remote body is
	# perpetually lerping toward a new heading, which says nothing about a facing inversion.
	var env_straight = OS.get_environment("AVALON_MOVE_STRAIGHT")
	if env_straight != null and env_straight != "" and env_straight != "0":
		_move_straight = true
	var env_angle = OS.get_environment("AVALON_MOVE_ANGLE_DEG")
	if env_angle != null and env_angle != "":
		_move_angle_deg = float(env_angle)

	# T-014: Gateway auth-handoff env vars
	var env_use_gw = OS.get_environment("AVALON_USE_GATEWAY")
	if env_use_gw != null and env_use_gw != "" and env_use_gw != "0":
		_use_gateway = true

	var env_gw_host = OS.get_environment("AVALON_GATEWAY_HOST")
	if env_gw_host != null and env_gw_host != "":
		_gw_host = env_gw_host

	var env_gw_port = OS.get_environment("AVALON_GATEWAY_PORT")
	if env_gw_port != null and env_gw_port != "":
		_gw_port = int(env_gw_port)

	var env_gw_user = OS.get_environment("AVALON_USERNAME")
	if env_gw_user != null and env_gw_user != "":
		_gw_username = env_gw_user

	var env_gw_pass = OS.get_environment("AVALON_PASSWORD")
	if env_gw_pass != null and env_gw_pass != "":
		_gw_password = env_gw_pass

	# T-029: Latency measurement mode
	var env_latency = OS.get_environment("AVALON_LATENCY_MODE")
	if env_latency != null and env_latency != "" and env_latency != "0":
		_latency_mode = true

	# T-030: Ability-use integration mode
	var env_ability = OS.get_environment("AVALON_USE_ABILITY")
	if env_ability != null and env_ability != "" and env_ability != "0":
		_ability_mode = true
		_movement_duration = 0.0

	var env_ability_id = OS.get_environment("AVALON_ABILITY_ID")
	if env_ability_id != null and env_ability_id != "":
		_ability_id = int(env_ability_id)

	var env_ability_target = OS.get_environment("AVALON_ABILITY_TARGET")
	if env_ability_target != null and env_ability_target != "":
		_ability_target = int(env_ability_target)

	var env_ability_repeat = OS.get_environment("AVALON_ABILITY_REPEAT")
	if env_ability_repeat != null and env_ability_repeat != "":
		_ability_repeat = int(env_ability_repeat)

	var env_ability_gap = OS.get_environment("AVALON_ABILITY_GAP_MS")
	if env_ability_gap != null and env_ability_gap != "":
		_ability_gap_ms = int(env_ability_gap)

	var env_ability_move = OS.get_environment("AVALON_ABILITY_MOVE_TO_TARGET")
	if env_ability_move != null and env_ability_move != "":
		_ability_move_to_target = env_ability_move != "0"

	# T-067: linger after the move (before/without sending abilities) to observe mob aggro.
	var env_aggro_wait = OS.get_environment("AVALON_ABILITY_AGGRO_WAIT_MS")
	if env_aggro_wait != null and env_aggro_wait != "":
		_ability_aggro_wait_ms = int(env_aggro_wait)

	# T-070: stay connected N ms after our kill (keeps our threat entry alive server-side).
	var env_linger = OS.get_environment("AVALON_ABILITY_LINGER_MS")
	if env_linger != null and env_linger != "":
		_ability_linger_ms = int(env_linger)

	if OS.get_environment("AVALON_ABILITY_TARGET_SELF") == "1":
		_ability_target_self = true  # T-063: resolved to _my_peer_id once connected

	var env_ability_x = OS.get_environment("AVALON_ABILITY_TARGET_X")
	if env_ability_x != null and env_ability_x != "":
		_ability_target_x = float(env_ability_x)

	var env_ability_y = OS.get_environment("AVALON_ABILITY_TARGET_Y")
	if env_ability_y != null and env_ability_y != "":
		_ability_target_y = float(env_ability_y)

	# T-047: Quest-loop integration mode (reuses the ability kill loop)
	var env_quest = OS.get_environment("AVALON_QUEST_MODE")
	if env_quest != null and env_quest != "" and env_quest != "0":
		_quest_mode = true
		_ability_mode = true
		_movement_duration = 0.0
		_test_timeout = 90.0  # accept → kill (with respawns avoided: 1 kill) → log → turn_in
		_giver_x = 12.5  # T-603: q_tut_01's giver — the drillmaster's T-577 anchor
		_giver_y = 9.0
	var env_quest_id = OS.get_environment("AVALON_QUEST_ID")
	if env_quest_id != null and env_quest_id != "":
		_quest_id = env_quest_id

	# T-603: giver-anchor override for modes accepting a non-default quest id.
	var env_giver_x = OS.get_environment("AVALON_GIVER_X")
	if env_giver_x != null and env_giver_x != "":
		_giver_x = float(env_giver_x)
	var env_giver_y = OS.get_environment("AVALON_GIVER_Y")
	if env_giver_y != null and env_giver_y != "":
		_giver_y = float(env_giver_y)

	if OS.get_environment("AVALON_ROAD_CHAIN_MODE") == "1":
		_road_mode = true
		_ability_mode = true
		_movement_duration = 0.0
		_test_timeout = 170.0
		_road_actions = _build_road_actions()

	# T-049: reach-objective integration mode
	var env_reach = OS.get_environment("AVALON_REACH_MODE")
	if env_reach != null and env_reach != "" and env_reach != "0":
		_reach_mode = true
		_movement_duration = 0.0
		_test_timeout = 60.0
	var env_reach_q = OS.get_environment("AVALON_REACH_QUEST")
	if env_reach_q != null and env_reach_q != "":
		_reach_quest = env_reach_q
	var env_reach_x = OS.get_environment("AVALON_REACH_X")
	if env_reach_x != null and env_reach_x != "":
		_reach_x = float(env_reach_x)
	var env_reach_y = OS.get_environment("AVALON_REACH_Y")
	if env_reach_y != null and env_reach_y != "":
		_reach_y = float(env_reach_y)
	var env_reach_idx = OS.get_environment("AVALON_REACH_OBJ_INDEX")
	if env_reach_idx != null and env_reach_idx != "":
		_reach_obj_index = int(env_reach_idx)

	# T-049: talk-objective integration mode
	var env_talk = OS.get_environment("AVALON_TALK_MODE")
	if env_talk != null and env_talk != "" and env_talk != "0":
		_talk_mode = true
		_movement_duration = 0.0
		_test_timeout = 60.0
	var env_talk_q = OS.get_environment("AVALON_TALK_QUEST")
	if env_talk_q != null and env_talk_q != "":
		_talk_quest = env_talk_q
	var env_talk_npc = OS.get_environment("AVALON_TALK_NPC")
	if env_talk_npc != null and env_talk_npc != "":
		_talk_npc = env_talk_npc
	var env_talk_x = OS.get_environment("AVALON_TALK_X")
	if env_talk_x != null and env_talk_x != "":
		_talk_x = float(env_talk_x)
	var env_talk_y = OS.get_environment("AVALON_TALK_Y")
	if env_talk_y != null and env_talk_y != "":
		_talk_y = float(env_talk_y)
	var env_talk_idx = OS.get_environment("AVALON_TALK_OBJ_INDEX")
	if env_talk_idx != null and env_talk_idx != "":
		_talk_obj_index = int(env_talk_idx)

	# T-049: inventory integration mode
	var env_inv = OS.get_environment("AVALON_INV_MODE")
	if env_inv != null and env_inv != "" and env_inv != "0":
		_inv_mode = true
		_movement_duration = 0.0
		_test_timeout = 60.0
	var env_inv_slot = OS.get_environment("AVALON_INV_BAG_SLOT")
	if env_inv_slot != null and env_inv_slot != "":
		_inv_bag_slot = int(env_inv_slot)
	var env_inv_item = OS.get_environment("AVALON_INV_ITEM")
	if env_inv_item != null and env_inv_item != "":
		_inv_item = env_inv_item
	var env_inv_eq = OS.get_environment("AVALON_INV_EQUIP_SLOT")
	if env_inv_eq != null and env_inv_eq != "":
		_inv_equip_slot = env_inv_eq

	# T-049: collect integration mode
	var env_collect = OS.get_environment("AVALON_COLLECT_MODE")
	if env_collect != null and env_collect != "" and env_collect != "0":
		_collect_mode = true
		_movement_duration = 0.0
		_test_timeout = 60.0
	var env_collect_q = OS.get_environment("AVALON_COLLECT_QUEST")
	if env_collect_q != null and env_collect_q != "":
		_collect_quest = env_collect_q
	var env_collect_idx = OS.get_environment("AVALON_COLLECT_OBJ_INDEX")
	if env_collect_idx != null and env_collect_idx != "":
		_collect_obj_index = int(env_collect_idx)

	# T-064: talent mode
	var env_talent = OS.get_environment("AVALON_TALENT_MODE")
	if env_talent != null and env_talent != "" and env_talent != "0":
		_talent_mode = true
		_movement_duration = 0.0
		_test_timeout = 30.0
	var env_talent_id = OS.get_environment("AVALON_TALENT_ID")
	if env_talent_id != null and env_talent_id != "":
		_talent_id = env_talent_id
	var env_talent_spends = OS.get_environment("AVALON_TALENT_SPENDS")
	if env_talent_spends != null and env_talent_spends != "":
		_talent_spends = int(env_talent_spends)
	var env_set_class = OS.get_environment("AVALON_SET_CLASS")
	if env_set_class != null and env_set_class != "":
		for c in env_set_class.split(","):
			_set_class_queue.append(str(c))

	# T-015: Reconnect test mode
	var env_reconnect = OS.get_environment("AVALON_RECONNECT")
	if env_reconnect != null and env_reconnect != "" and env_reconnect != "0":
		_reconnect_mode = true
		_movement_duration = 2.0  # short movement burst before disconnect
		_test_timeout = 20.0


# gdlint: disable=max-returns
func _process(delta: float) -> void:
	# T-014: Gateway WS polling phase — must complete before ENet
	if _use_gateway and _gw_phase > 0 and _gw_phase < 3:
		_gateway_process()
		if _gw_phase == 3:
			# WS login done — transition to ENet path
			_gw_phase = 0
			_gw_ws = null
			_setup_enet_client()
		return

	if _enet == null and not _reconnect_mode:
		return

	# Check for timeout
	var elapsed = Time.get_ticks_msec() / 1000.0 - _connect_start
	if elapsed > _test_timeout:
		if not _error:
			_error = "test timeout after %.1f seconds" % _test_timeout
		_finish()
		return

	# Check if we got our result. T-047: in quest mode the kill (_ability_done) is only step 2 of 5,
	# so it must NOT finish here — quest mode finishes via _movement_complete (set on _quest_done).
	if _movement_complete or (_ability_done and not _quest_mode and not _road_mode):
		# T-015: On reconnect mode, disconnect and reconnect after successful first run
		if _movement_complete and _reconnect_mode and _reconnect_phase == 0:
			_reconnect_phase = 1  # waiting_to_reconnect
			_reconnect_timer = 0.0
			# Tear down current connection
			if _enet != null:
				get_tree().get_multiplayer().set_multiplayer_peer(null)
				_enet = null
			_connected = false
			_handshake_ok = false
			_handshake_sent = false
			_movement_phase = false
			_movement_complete = false
			_movement_elapsed = 0.0
			_error = ""
			print(
				(
					"[test_client] T-015: first connection done, waiting %.1fs before reconnect"
					% _reconnect_wait_seconds
				)
			)
			return
		_finish()
		return

	# T-015: Reconnect wait timer
	if _reconnect_phase == 1:
		_reconnect_timer += delta
		if _reconnect_timer >= _reconnect_wait_seconds:
			_reconnect_phase = 2  # reconnecting
			_connect_start = Time.get_ticks_msec() / 1000.0  # reset timeout clock
			_setup_enet_client()
		return

	if _error:
		_finish()
		return

	# Check connection state
	if _connected and not _handshake_sent and not _error:
		_send_session_handshake()
		_handshake_sent = true
		return

	# T-064: talent mode — request/spend/request over real ENet.
	if _road_mode and _handshake_ok and not _road_done:
		_process_road_mode()

	elif _talent_mode and _handshake_ok and not _talent_done:
		_process_talent_mode()

	# T-049: reach mode — accept, move into the radius, poll the log.
	elif _reach_mode and _handshake_ok and not _reach_done:
		_process_reach_mode()

	# T-049: talk mode — accept, move to the NPC, talk, poll the log.
	elif _talk_mode and _handshake_ok and not _talk_done:
		_process_talk_mode()

	# T-049: inventory mode — get_inventory, equip, assert slot movement.
	elif _inv_mode and _handshake_ok and not _inv_done:
		_process_inv_mode()

	# T-049: collect mode — accept, poll (no inventory change) until collect credits.
	elif _collect_mode and _handshake_ok and not _collect_done:
		_process_collect_mode()

	# T-047: Quest-loop mode wraps the ability kill loop (accept before, turn_in after).
	elif _quest_mode and _handshake_ok and not _quest_done:
		_process_quest_mode()

	# T-030: Ability-use mode runs after handshake instead of movement.
	elif _ability_mode and _handshake_ok and not _ability_done:
		_process_ability_mode()

	# Movement phase: send moves at 10Hz after handshake
	elif _movement_phase and not _latency_mode:
		_movement_timer += delta
		_movement_elapsed += delta
		if _movement_timer >= 0.1:  # 10Hz
			_movement_timer -= 0.1
			_send_move()

		# Check if movement phase is complete
		if _movement_elapsed >= _movement_duration:
			_movement_complete = true

	# T-029: Latency measurement phase (runs after handshake, instead of movement)
	elif _latency_mode and _handshake_ok and not _latency_done:
		# Phase 1: send one ping/pong for movement RTT baseline
		if not _ping_sent and not _latency_waiting:
			_send_ping()
			return
		# Phase 2: wait for pong before starting combat samples
		if _ping_rtt_ms < 0.0 and not _latency_waiting:
			return
		# Phase 3: send combat intent samples
		if not _latency_waiting and _latency_current < _latency_sample_count:
			_send_use_ability_intent()
		# Check if all samples collected
		if _latency_current >= _latency_sample_count:
			_latency_done = true
			_movement_complete = true


func _send_session_handshake() -> void:
	_receive_message.rpc({"type": "session", "token": _token})


func _send_ping() -> void:
	if _ping_sent:
		return
	_ping_sent = true
	_ping_sent_ms = Time.get_ticks_msec()
	_receive_message.rpc_id(1, {"type": "ping", "ts": _ping_sent_ms})


func _send_move() -> void:
	_send_ping()  # fire one latency probe on first move
	# Deterministic sinusoidal movement pattern.
	# Each client gets a unique direction angle based on its seed.
	var angle: float = _rng.randf_range(0.0, 6.28318530718)
	var phase: float = float(_moves_sent) * 0.3
	if _move_straight:  # T-727: one fixed heading, no sinusoidal sweep
		angle = deg_to_rad(_move_angle_deg)
		phase = 0.0
	var dx: float = _movement_speed * cos(angle + phase) / 10.0
	var dy: float = _movement_speed * sin(angle + phase) / 10.0

	# Broadcast move to all peers (same pattern as handshake on line 138).
	# Server receives it via its _receive_message and processes request_move.
	_receive_message.rpc_id(1, {"type": "request_move", "dx": dx, "dy": dy})
	_moves_sent += 1
	_last_move_sent_ms = Time.get_ticks_msec()


# T-029: Send a combat intent (Strike) to measure latency RTT.
# Targets invalid peer (-1) to get immediate ability_rejected without consuming resources.
func _send_use_ability_intent() -> void:
	_latency_t0 = Time.get_ticks_usec()
	_latency_waiting = true
	# ability_id=1 is Strike (instant, registered in data/abilities/strike.json)
	# target_id=-1 guarantees server returns ability_rejected (invalid_target)
	_receive_message.rpc({"type": "use_ability", "ability_id": 1, "target_id": -1})
	_latency_current += 1


# T-064: request_talents -> spend point x N -> request_talents (each step awaits its reply).
func _process_talent_mode() -> void:
	match _talent_state:
		0:
			# T-065: play any queued set_class attempts first (each awaits its result).
			if _set_class_sent < _set_class_queue.size():
				if _set_class_results.size() < _set_class_sent:
					return  # await the previous result
				_receive_message.rpc_id(
					1, {"type": "set_class", "class": str(_set_class_queue[_set_class_sent])}
				)
				_set_class_sent += 1
				return
			if _set_class_results.size() < _set_class_sent:
				return  # await the last set_class reply before reading talents
			_receive_message.rpc_id(1, {"type": "request_talents"})
			_talent_state = 1
		1:
			if not _talent_before.is_empty():
				_talent_state = 2
		2:
			if _talent_sent < _talent_spends:
				_receive_message.rpc_id(1, {"type": "spend_talent", "talent_id": _talent_id})
				_talent_sent += 1
				_talent_state = 3
			else:
				_receive_message.rpc_id(1, {"type": "request_talents"})
				_talent_state = 4
		3:
			if _talent_spend_results.size() >= _talent_sent:
				_talent_state = 2
		4:
			if not _talent_after.is_empty():
				_talent_done = true
				_movement_complete = true


# T-603: walk to the accepting quest's giver NPC (accept is giver-proximity gated server-side).
# False until our own position is known from the broadcast; once sent, _my_pos is the giver
# (optimistic — the move rides the same reliable in-order channel as the accept that follows).
func _move_to_giver() -> bool:
	if not _my_pos_known:
		return false
	var delta := Vector2(_giver_x, _giver_y) - _my_pos
	_receive_message.rpc_id(1, {"type": "request_move", "dx": delta.x, "dy": delta.y})
	_my_pos = Vector2(_giver_x, _giver_y)
	_giver_move_sent = true
	return true


# T-049: accept → one move into the reach radius → poll the log until the reach objective credits.
func _process_reach_mode() -> void:
	if not _reach_accept_sent:
		if not _move_to_giver():  # T-603: accept only resolves at the giver
			return
		_receive_message.rpc_id(1, {"type": "accept_quest", "quest_id": _reach_quest})
		_reach_accept_sent = true
		return
	if _quest_accept_result.is_empty():
		return  # await accept reply (captured by _receive_client_message, shared with T-047)
	if not _reach_move_sent:
		# MAX_SPEED_PER_TICK (100) >> the distance, so one move lands inside the reach radius.
		# T-603: _reach_x/_reach_y are the target's absolute position; we now start at the giver.
		var delta := Vector2(_reach_x, _reach_y) - _my_pos
		_receive_message.rpc_id(1, {"type": "request_move", "dx": delta.x, "dy": delta.y})
		_reach_move_sent = true
		return
	# Poll the quest log (never sleep) until the reach objective credits.
	var now := Time.get_ticks_msec()
	if now >= _reach_log_next_ms:
		_receive_message.rpc_id(1, {"type": "request_quest_log"})
		_reach_log_next_ms = now + 200
	if _objective_credited(_reach_quest, _reach_obj_index):
		_reach_done = true
		_movement_complete = true


# T-049: is objective `idx` of `quest_id` credited (current >= 1) in the latest enriched quest log?
func _objective_credited(quest_id: String, idx: int) -> bool:
	var quests: Array = _quest_log_result.get("result", {}).get("quests", [])
	for q: Dictionary in quests:
		if str(q.get("quest_id", "")) == quest_id:
			var objs: Array = q.get("objectives", [])
			if idx < objs.size():
				return int(objs[idx].get("current", 0)) >= 1
	return false


# T-049: accept → move to the NPC → talk → poll the log until the talk objective credits.
func _process_talk_mode() -> void:
	if not _talk_accept_sent:
		if not _move_to_giver():  # T-603: accept only resolves at the giver
			return
		_receive_message.rpc_id(1, {"type": "accept_quest", "quest_id": _talk_quest})
		_talk_accept_sent = true
		return
	if _quest_accept_result.is_empty():
		return
	if not _talk_move_sent:
		# T-603: _talk_x/_talk_y are the NPC's absolute position; we now start at the giver.
		var delta := Vector2(_talk_x, _talk_y) - _my_pos
		_receive_message.rpc_id(1, {"type": "request_move", "dx": delta.x, "dy": delta.y})
		_talk_move_sent = true
		return
	if not _talk_sent:
		# Move is processed before this reliable, in-order message → talk sees the new position.
		_receive_message.rpc_id(1, {"type": "talk", "npc_id": _talk_npc})
		_talk_sent = true
		return
	var now := Time.get_ticks_msec()
	if now >= _talk_log_next_ms:
		_receive_message.rpc_id(1, {"type": "request_quest_log"})
		_talk_log_next_ms = now + 200
		# Re-send talk in case the move hadn't landed when the first talk was processed (too_far).
		_receive_message.rpc_id(1, {"type": "talk", "npc_id": _talk_npc})
	if _objective_credited(_talk_quest, _talk_obj_index):
		_talk_done = true
		_movement_complete = true


# T-049: get_inventory → equip the seeded bag item → the equip_result carries the moved slots.
func _process_inv_mode() -> void:
	if not _inv_get_sent:
		_receive_message.rpc_id(1, {"type": "get_inventory"})
		_inv_get_sent = true
		return
	if _inv_get_result.is_empty():
		return
	if not _inv_equip_sent:
		_receive_message.rpc_id(1, {"type": "equip", "bag_slot": _inv_bag_slot})
		_inv_equip_sent = true
		return
	if _inv_equip_result.is_empty():
		return
	_inv_done = true
	_movement_complete = true


# T-049: accept → poll the log until the collect objective credits, WITHOUT any inventory change.
func _process_collect_mode() -> void:
	if not _collect_accept_sent:
		if not _move_to_giver():  # T-603: accept only resolves at the giver
			return
		_receive_message.rpc_id(1, {"type": "accept_quest", "quest_id": _collect_quest})
		_collect_accept_sent = true
		return
	if _quest_accept_result.is_empty():
		return
	var now := Time.get_ticks_msec()
	if now >= _collect_log_next_ms:
		_receive_message.rpc_id(1, {"type": "request_quest_log"})
		_collect_log_next_ms = now + 200
	if _objective_credited(_collect_quest, _collect_obj_index):
		_collect_done = true
		_movement_complete = true


func _slot_has(reply: Dictionary, slot_type: String, slot_index: int, item_id: String) -> bool:
	for s: Dictionary in reply.get("slots", []):
		if str(s.get("slot_type", "")) == slot_type and int(s.get("slot_index", -1)) == slot_index:
			return str(s.get("item_id", "")) == item_id
	return false


# T-047: orchestrate one quest loop over real ENet: accept → kill → quest_log → turn_in.
func _process_quest_mode() -> void:
	if not _quest_accept_sent:  # accept first — progress only credits ACTIVE quests
		if not _move_to_giver():  # T-603: accept only resolves at the giver
			return
		_receive_message.rpc_id(1, {"type": "accept_quest", "quest_id": _quest_id})
		_quest_accept_sent = true
		# The ability-phase target coords were authored as absolute (origin-relative deltas);
		# re-base them on the giver we now stand at so the kill move still lands on the mob.
		_ability_target_x -= _my_pos.x
		_ability_target_y -= _my_pos.y
		return
	if _quest_accept_result.is_empty():
		return
	if not _ability_done:  # kill the dummy via the existing ability loop
		_process_ability_mode()
		return
	# let the world's fire-and-forget kill-credit RPC land before reading the log
	if _quest_kill_time_ms == 0:
		_quest_kill_time_ms = Time.get_ticks_msec()
		return
	if Time.get_ticks_msec() - _quest_kill_time_ms < 1200:
		return
	if not _quest_log_requested:  # proves the kill objective credited over the wire
		_receive_message.rpc_id(1, {"type": "request_quest_log"})
		_quest_log_requested = true
		return
	if _quest_log_result.is_empty():
		return
	if not _quest_turn_in_sent:  # co-located with npc_drillmaster at the dummy (10,10)
		_receive_message.rpc_id(1, {"type": "turn_in", "quest_id": _quest_id})
		_quest_turn_in_sent = true
		return
	if _quest_turn_in_result.is_empty():
		return
	_quest_done = true
	_movement_complete = true


func _build_road_actions() -> Array:
	return [
		# T-603: accept is giver-proximity gated — start at the Regent's Courier (q010's giver).
		{"type": "move", "pos": Vector2(8.0, 1.1)},
		{"type": "accept", "quest": "q010"},
		# T-708: the starter wolves are six all-solo spawns now — 1102/1103 moved south of the hamlet.
		{"type": "kill", "mob": 1101, "pos": Vector2(30.0, 20.0)},
		{"type": "kill", "mob": 1102, "pos": Vector2(16.0, -34.0)},
		{"type": "kill", "mob": 1103, "pos": Vector2(20.0, -66.0)},
		{"type": "move", "pos": Vector2(8.0, 0.0)},
		{"type": "check", "quest": "q010", "progress": [3]},
		{"type": "turnin", "quest": "q010"},
		{"type": "accept", "quest": "q011"},
		{"type": "move", "pos": Vector2(8.0, -75.0)},
		{"type": "move", "pos": Vector2(4.0, -143.0)},
		{"type": "check", "quest": "q011", "progress": [1]},
		{"type": "turnin", "quest": "q011"},
		{"type": "accept", "quest": "q012"},
		{"type": "move", "pos": Vector2(-33.0, -207.0)},
		{"type": "talk", "npc": "npc_hk_banker"},
		{"type": "move", "pos": Vector2(33.6, -209.0)},
		{"type": "talk", "npc": "npc_hk_auctioneer"},
		{"type": "move", "pos": Vector2(45.0, -256.0)},
		{"type": "talk", "npc": "npc_hk_warrior_trainer"},
		{"type": "check", "quest": "q012", "progress": [1, 1, 1]},
		{"type": "move", "pos": Vector2(0.0, -210.0)},
		{"type": "move", "pos": Vector2(0.0, -148.0)},
		{"type": "turnin", "quest": "q012"},
		{"type": "accept", "quest": "q013"},
		{"type": "inventory", "expect": "letter"},
		{"type": "move", "pos": Vector2(0.0, -232.0)},
		{"type": "move", "pos": Vector2(0.0, -317.5)},
		{"type": "talk", "npc": "npc_hk_castellan"},
		{"type": "check", "quest": "q013", "progress": [1]},
		{"type": "turnin", "quest": "q013"},
		{"type": "inventory", "expect": "reward"},
		{"type": "complete"},
	]


func _process_road_mode() -> void:
	if _road_action_index >= _road_actions.size():
		_road_done = true
		_movement_complete = true
		return
	var action: Dictionary = _road_actions[_road_action_index]
	match str(action["type"]):
		"accept":
			if not _road_action_sent:
				_quest_accept_result.clear()
				_receive_message.rpc_id(1, {"type": "accept_quest", "quest_id": action["quest"]})
				_road_mark_sent()
			elif not _quest_accept_result.is_empty():
				if not bool(_quest_accept_result.get("ok", false)):
					_road_fail("accept %s: %s" % [action["quest"], _quest_accept_result])
				else:
					_road_advance()
		"kill":
			_road_kill(action)
		"move":
			_road_move(action["pos"])
		"talk":
			if not _road_action_sent:
				_road_talk_result.clear()
				_receive_message.rpc_id(1, {"type": "talk", "npc_id": action["npc"]})
				_road_mark_sent()
			elif not _road_talk_result.is_empty():
				if not bool(_road_talk_result.get("ok", false)):
					_road_fail("talk %s: %s" % [action["npc"], _road_talk_result])
				else:
					_road_advance()
		"check":
			_road_check_progress(action)
		"turnin":
			if not _road_action_sent:
				_quest_turn_in_result.clear()
				_receive_message.rpc_id(1, {"type": "turn_in", "quest_id": action["quest"]})
				_road_mark_sent()
			elif not _quest_turn_in_result.is_empty():
				if not bool(_quest_turn_in_result.get("ok", false)):
					_road_fail("turn in %s: %s" % [action["quest"], _quest_turn_in_result])
				else:
					_road_completed.append(str(action["quest"]))
					_road_coins_awarded += int(_quest_turn_in_result.get("coins", 0))
					_road_advance()
		"inventory":
			_road_check_inventory(str(action["expect"]))
		"complete":
			_road_advance()


func _road_kill(action: Dictionary) -> void:
	if not _road_action_sent:
		var target: Vector2 = action["pos"]
		_ability_target = int(action["mob"])
		_ability_target_x = target.x - _road_pos.x
		_ability_target_y = target.y - _road_pos.y
		_road_pos = target
		_ability_move_sent = false
		_ability_done = false
		_ability_mob_killed = false
		_ability_target_alive = false
		_ability_intents_sent = 0
		_ability_results_received.clear()
		_ability_rejections_received.clear()
		_ability_next_send_ms = 0
		_road_mark_sent()
	_process_ability_mode()
	if _ability_done and _ability_mob_killed:
		_road_advance()


func _road_move(target: Vector2) -> void:
	var now := Time.get_ticks_msec()
	if not _road_action_sent and now - _road_last_move_ms >= 1100:
		var delta := target - _road_pos
		if delta.length() > 100.0:
			_road_fail("move exceeds server cap: %s" % delta)
			return
		_receive_message.rpc_id(1, {"type": "request_move", "dx": delta.x, "dy": delta.y})
		_road_pos = target
		_road_last_move_ms = now
		_road_mark_sent()
	elif _road_action_sent and now - _road_action_started_ms >= 500:
		_road_advance()


func _road_check_progress(action: Dictionary) -> void:
	var now := Time.get_ticks_msec()
	if not _road_action_sent or now - _road_action_started_ms >= 350:
		_quest_log_result.clear()
		_receive_message.rpc_id(1, {"type": "request_quest_log"})
		_road_mark_sent()
	if _quest_log_result.is_empty():
		return
	for quest: Dictionary in _quest_log_result.get("result", {}).get("quests", []):
		if str(quest.get("quest_id", "")) != str(action["quest"]):
			continue
		var objectives: Array = quest.get("objectives", [])
		var expected: Array = action["progress"]
		if objectives.size() < expected.size():
			return
		for i in range(expected.size()):
			if int(objectives[i].get("current", 0)) < int(expected[i]):
				return
		_road_advance()
		return


func _road_check_inventory(expectation: String) -> void:
	if not _road_action_sent:
		_road_inventory_result.clear()
		_receive_message.rpc_id(1, {"type": "get_inventory"})
		_road_mark_sent()
		return
	if _road_inventory_result.is_empty():
		return
	var has_letter := _road_inventory_has("itm_letter_of_introduction")
	var has_voucher := _road_inventory_has("itm_vault_voucher")
	if expectation == "letter":
		_road_letter_received = has_letter
		if not has_letter:
			_road_fail("q013 did not provide the introduction letter")
			return
	else:
		_road_letter_removed = not has_letter
		_road_voucher_received = has_voucher
		if has_letter or not has_voucher:
			_road_fail("q013 reward inventory mismatch")
			return
	_road_advance()


func _road_inventory_has(item_id: String) -> bool:
	for slot: Dictionary in _road_inventory_result.get("slots", []):
		if str(slot.get("item_id", "")) == item_id and int(slot.get("count", 0)) > 0:
			return true
	return false


func _road_mark_sent() -> void:
	_road_action_sent = true
	_road_action_started_ms = Time.get_ticks_msec()


func _road_advance() -> void:
	_road_action_index += 1
	_road_action_sent = false
	_road_action_started_ms = 0


func _road_fail(reason: String) -> void:
	_error = "road chain: %s" % reason
	_road_done = true
	_movement_complete = true


func _process_ability_mode() -> void:
	var now_ms: int = Time.get_ticks_msec()
	if _ability_move_to_target and not _ability_move_sent:
		(
			_receive_message
			. rpc_id(
				1,
				{
					"type": "request_move",
					"dx": _ability_target_x,
					"dy": _ability_target_y,
				}
			)
		)
		_ability_move_sent = true
		_ability_next_send_ms = now_ms + 300 + _ability_aggro_wait_ms
		print(
			(
				"[test_client] T-030: moved toward target %d at (%.1f, %.1f)"
				% [_ability_target, _ability_target_x, _ability_target_y]
			)
		)
		return

	if _ability_mob_killed:
		# T-070: keep the connection (and our server-side threat entry) alive post-kill so a
		# second client's kill after the respawn can expose stale credit.
		if _ability_kill_time_ms == 0:
			_ability_kill_time_ms = now_ms
		if now_ms - _ability_kill_time_ms >= _ability_linger_ms:
			_ability_done = true
		return

	if _ability_intents_sent >= _ability_repeat:
		# T-067: don't finish before the aggro-linger window (and the last cast) has played out.
		if now_ms >= _ability_next_send_ms and now_ms - _ability_last_send_ms >= 1000:
			_ability_done = true
		return

	if now_ms < _ability_next_send_ms:
		return

	# TD-004 F1: never open fire on a dead/respawning mob — wait for the broadcast to show
	# it alive. Spawn-table mob entity ids live in [1000, 10000); ENet peer ids are huge
	# random ints — self/player targets must NOT hit this gate (a self-heal never appears
	# in the mobs array and would wait forever).
	if (
		not _ability_target_self
		and _ability_target >= 1000
		and _ability_target < 10000
		and not _ability_target_alive
	):
		return

	(
		_receive_message
		. rpc_id(
			1,
			{
				"type": "use_ability",
				"ability_id": _ability_id,
				"target_id": _ability_target,
			}
		)
	)
	_ability_intents_sent += 1
	_ability_last_send_ms = now_ms
	_ability_next_send_ms = now_ms + _ability_gap_ms
	print(
		(
			"[test_client] T-030: sent use_ability ability=%d target=%d count=%d"
			% [_ability_id, _ability_target, _ability_intents_sent]
		)
	)


@rpc("any_peer", "reliable")
func _receive_message(data: Dictionary, _mirror: bool = false) -> void:
	var msg_type: String = str(data.get("type", ""))
	if msg_type == "handshake_ok":
		_handshake_ok = true
		_movement_phase = true
		_movement_timer = 0.0
		# T-015: Track successful reconnect
		if _reconnect_mode and _reconnect_phase == 2:
			_reconnect_handshake_ok = true
			print("[test_client] T-015: reconnect handshake_ok — session restored!")
		else:
			print("[test_client] handshake_ok, starting movement for %.1fs" % _movement_duration)
	elif msg_type == "handshake_err":
		_error = "handshake rejected: %s" % data.get("reason", "unknown")
	elif msg_type == "pong":
		if _ping_sent_ms > 0.0 and _ping_rtt_ms < 0.0:
			_ping_rtt_ms = Time.get_ticks_msec() - _ping_sent_ms
	elif msg_type == "positions":
		_handle_positions(data)
	# T-029: Measure combat intent RTT on any combat response
	elif (
		msg_type == "ability_rejected"
		or msg_type == "ability_result"
		or msg_type == "cast_started"
		or msg_type == "cast_cancelled"
	):
		_handle_ability_message(data)
		if _latency_waiting and _latency_t0 > 0:
			var rtt_us: float = float(Time.get_ticks_usec() - _latency_t0)
			var rtt_ms: float = rtt_us / 1000.0
			_latency_samples.append(rtt_ms)
			_latency_waiting = false
	elif msg_type == "mob_death":
		_handle_ability_message(data)


@rpc("any_peer", "reliable")
func _receive_client_message(data: Dictionary, _mirror: bool = false) -> void:
	var msg_type: String = str(data.get("type", ""))
	if msg_type == "handshake_ok":
		_handshake_ok = true
		_movement_phase = true
		_movement_timer = 0.0
		# T-015: Track successful reconnect
		if _reconnect_mode and _reconnect_phase == 2:
			_reconnect_handshake_ok = true
			print("[test_client] T-015: reconnect handshake_ok — session restored!")
		else:
			print(
				(
					"[test_client] handshake_ok (client_msg), starting movement for %.1fs"
					% _movement_duration
				)
			)
	elif msg_type == "handshake_err":
		_error = "handshake rejected: %s" % data.get("reason", "unknown")
	elif msg_type == "pong":
		if _ping_sent_ms > 0.0 and _ping_rtt_ms < 0.0:
			_ping_rtt_ms = Time.get_ticks_msec() - _ping_sent_ms
	elif msg_type == "positions":
		_handle_positions(data)
	# T-029: Measure combat intent RTT on any combat response
	elif (
		msg_type == "ability_rejected"
		or msg_type == "ability_result"
		or msg_type == "cast_started"
		or msg_type == "cast_cancelled"
	):
		_handle_ability_message(data)
		if _latency_waiting and _latency_t0 > 0:
			var rtt_us: float = float(Time.get_ticks_usec() - _latency_t0)
			var rtt_ms: float = rtt_us / 1000.0
			_latency_samples.append(rtt_ms)
			_latency_waiting = false
	elif msg_type == "mob_death":
		_handle_ability_message(data)
	# T-047: capture the quest-loop replies (server → client).
	elif msg_type == "accept_quest_result":
		_quest_accept_result = data.duplicate()
	elif msg_type == "quest_log":
		_quest_log_result = data.duplicate()
	elif msg_type == "turn_in_result":
		_quest_turn_in_result = data.duplicate()
	elif msg_type == "talk_result" and _road_mode:
		_road_talk_result = data.duplicate()
	# T-049: inventory replies (get_inventory + equip both carry the post-op slots).
	elif msg_type == "inventory":
		_inv_get_result = data.duplicate()
		if _road_mode:
			_road_inventory_result = data.duplicate()
	elif msg_type == "equip_result":
		_inv_equip_result = data.duplicate()
	# T-060: the peer-only XP/level payload (latest wins).
	elif msg_type == "player_stats":
		_player_stats_last = data.duplicate()
	# T-058: targeted server pushes.
	elif msg_type == "quest_delta":
		_quest_delta_count += 1
	elif msg_type == "npc_indicator_delta":
		_npc_delta_count += 1
	# T-064: talent replies.
	elif msg_type == "talents":
		if _talent_state <= 1:
			_talent_before = data.duplicate()
		else:
			_talent_after = data.duplicate()
	elif msg_type == "spend_talent_result":
		_talent_spend_results.append(data.duplicate())
	elif msg_type == "set_class_result":
		_set_class_results.append(data.duplicate())


func _handle_ability_message(data: Dictionary) -> void:
	if not _ability_mode:
		return

	var msg_type: String = str(data.get("type", ""))
	if msg_type == "cast_started":
		_ability_cast_started_count += 1
		return
	if msg_type == "cast_cancelled":
		_ability_cast_cancel_reasons.append(str(data.get("reason", "")))
		return
	if msg_type == "ability_result":
		# T-067: a mob-initiated hit on ME proves server-side aggro against my LIVE position.
		if (
			int(data.get("target_id", -1)) == _my_peer_id
			and int(data.get("caster_id", -1)) != _my_peer_id
		):
			_ability_attacks_on_me += 1
		if int(data.get("target_id", -1)) != _ability_target:
			return
		var result: Dictionary = {
			"type": msg_type,
			"ability_id": int(data.get("ability_id", -1)),
			"target_id": int(data.get("target_id", -1)),
			"damage": int(data.get("damage", 0)),
			"outcome": str(data.get("outcome", "")),
			"target_hp": int(data.get("target_hp", -1)),
			"target_max_hp": int(data.get("target_max_hp", -1)),
		}
		_ability_results_received.append(result)
		_ability_last_outcome = str(data.get("outcome", ""))
		if data.has("damage") and data.has("target_hp"):
			_ability_damage_attributed_by_server = true
	elif msg_type == "ability_rejected":
		var rejection: Dictionary = {
			"type": msg_type,
			"ability_id": int(data.get("ability_id", -1)),
			"reason": str(data.get("reason", "")),
		}
		_ability_rejections_received.append(rejection)
		_ability_results_received.append(rejection)
		_ability_last_outcome = str(data.get("reason", ""))
	elif msg_type == "mob_death":
		if int(data.get("mob_id", -1)) != _ability_target:
			return
		_ability_mob_death_count += 1
		_ability_mob_killed = true
		_ability_last_outcome = "mob_death"
		# T-070: server-attributed kill credit for the LATEST death of the target.
		_ability_mob_death_credited = (data.get("credited_player_ids", []) as Array).duplicate()


func _handle_positions(data: Dictionary) -> void:
	_broadcasts_received += 1
	var players: Array = data.get("players", [])

	# TD-004 F1: track whether the ability target (a mob) is currently alive.
	for mob_dict in data.get("mobs", []):
		if int(mob_dict.get("mob_id", -1)) == _ability_target:
			_ability_target_alive = int(mob_dict.get("hp", 0)) > 0

	for player_dict in players:
		var peer_id: int = int(player_dict.get("peer_id", 0))
		if peer_id == _my_peer_id:
			# T-603: track own broadcast position until the giver move is sent (after that the
			# optimistic post-move value in _my_pos owns it — a stale echo must not regress it).
			if not _giver_move_sent:
				_my_pos = Vector2(
					float(player_dict.get("x", 0.0)), float(player_dict.get("y", 0.0))
				)
				_my_pos_known = true
			# T-071: record own server-broadcast HP (min seen + latest) — regen visibility.
			var hp_now: int = int(player_dict.get("hp", -1))
			if hp_now >= 0:
				if _my_hp_min == -1 or hp_now < _my_hp_min:
					_my_hp_min = hp_now
				_my_hp_last = hp_now
			# RTT: our own position echoed back — measure round-trip
			if _last_move_sent_ms > 0.0:
				var rtt: float = Time.get_ticks_msec() - _last_move_sent_ms
				if rtt >= 0.0 and rtt < 10000.0:
					_rtt_samples.append(rtt)
			continue  # skip self

		if not _other_peers_seen.has(peer_id):
			_other_peers_seen.append(peer_id)

		if not _other_positions_observed.has(peer_id):
			_other_positions_observed[peer_id] = []

		var pos_key: String = (
			"%.1f:%.1f" % [float(player_dict.get("x", 0.0)), float(player_dict.get("y", 0.0))]
		)
		if not _other_positions_observed[peer_id].has(pos_key):
			_other_positions_observed[peer_id].append(pos_key)

	print(
		(
			"[test_client] positions_update: %d players, other_peers=%s"
			% [players.size(), _other_peers_seen]
		)
	)


func _on_connected() -> void:
	_connected = true
	_my_peer_id = get_tree().get_multiplayer().get_unique_id()
	if _ability_target_self:
		_ability_target = _my_peer_id  # T-063: self-heal targets our own peer_id
	print("[test_client] connected, peer_id=%d" % _my_peer_id)


func _on_connection_failed() -> void:
	_error = "connection to world server failed"


func _on_server_disconnected() -> void:
	# T-015: Ignore disconnect during intentional reconnect teardown
	if _reconnect_mode and _reconnect_phase >= 1:
		return
	if not _handshake_ok:
		_error = "server disconnected before handshake"


func _finish() -> void:
	set_process(false)

	# Determine pass: handshake OK AND saw at least 1 other peer with 2+ distinct positions
	var saw_movement: bool = false
	for peer_id in _other_peers_seen:
		var positions: Array = _other_positions_observed.get(peer_id, [])
		if positions.size() >= 2:
			saw_movement = true
			break

	var pass_test: bool = _handshake_ok and saw_movement

	# Build other_peers array for JSON (convert from Array[int])
	var other_peers_json: Array = []
	for pid in _other_peers_seen:
		other_peers_json.append(pid)

	# RTT stats (min/avg/max in ms) from self-echo round-trips
	var rtt_min: float = -1.0
	var rtt_avg: float = -1.0
	var rtt_max: float = -1.0
	if _rtt_samples.size() > 0:
		rtt_min = _rtt_samples[0]
		rtt_max = _rtt_samples[0]
		var total: float = 0.0
		for s in _rtt_samples:
			total += s
			if s < rtt_min:
				rtt_min = s
			if s > rtt_max:
				rtt_max = s
		rtt_avg = total / float(_rtt_samples.size())

	# T-029: Latency percentile stats for combat RTT
	var latency_min: float = -1.0
	var latency_p50: float = -1.0
	var latency_p95: float = -1.0
	var latency_p99: float = -1.0
	var latency_max: float = -1.0
	var latency_avg: float = -1.0
	if _latency_samples.size() > 0:
		_latency_samples.sort()
		latency_min = _latency_samples[0]
		latency_max = _latency_samples[_latency_samples.size() - 1]
		var l_total: float = 0.0
		for ls in _latency_samples:
			l_total += ls
		latency_avg = l_total / float(_latency_samples.size())
		latency_p50 = _latency_samples[int(_latency_samples.size() * 0.5)]
		latency_p95 = _latency_samples[min(
			int(_latency_samples.size() * 0.95), _latency_samples.size() - 1
		)]
		latency_p99 = _latency_samples[min(
			int(_latency_samples.size() * 0.99), _latency_samples.size() - 1
		)]

	var result: Dictionary = {
		"pass": pass_test,
		"connected": _connected,
		"handshake_ok": _handshake_ok,
		"moves_sent": _moves_sent,
		"broadcasts_received": _broadcasts_received,
		"other_peers_seen": other_peers_json,
		"other_positions_observed": _other_positions_observed,
		"error": _error if _error else "",
		"rtt_samples": _rtt_samples.size(),
		"rtt_min_ms": rtt_min,
		"rtt_avg_ms": rtt_avg,
		"rtt_max_ms": rtt_max,
		"ping_rtt_ms": _ping_rtt_ms,
	}

	# T-064: talent mode result — raw server replies for the harness to assert.
	if _talent_mode:
		result["talent_mode"] = true
		result["talents_before"] = _talent_before
		result["talents_after"] = _talent_after
		result["spend_results"] = _talent_spend_results
		result["set_class_results"] = _set_class_results
		result["pass"] = _handshake_ok and _talent_done
		pass_test = result["pass"]

	# T-015: Reconnect mode adds its own pass criteria
	if _reconnect_mode:
		result["reconnect_mode"] = true
		result["reconnect_handshake_ok"] = _reconnect_handshake_ok
		result["pass"] = _reconnect_handshake_ok
		pass_test = result["pass"]
		if pass_test:
			print("[test_client] T-015: RESULT: PASS — session restored after disconnect")
		else:
			print("[test_client] T-015: RESULT: FAIL — reconnect handshake failed")

	# T-029: Include latency stats in result when in latency mode
	if _latency_mode:
		result["latency_mode"] = true
		result["latency_samples"] = _latency_samples.size()
		result["latency_min_ms"] = latency_min
		result["latency_p50_ms"] = latency_p50
		result["latency_p95_ms"] = latency_p95
		result["latency_p99_ms"] = latency_p99
		result["latency_max_ms"] = latency_max
		result["latency_avg_ms"] = latency_avg
		result["movement_rtt_ms"] = _ping_rtt_ms
		# T-029: PASS criteria — both metrics must have valid data AND be under threshold
		# -1.0 means no data collected → automatic FAIL
		var has_valid_data = _latency_samples.size() > 0 and _ping_rtt_ms >= 0.0
		result["pass"] = (has_valid_data and _ping_rtt_ms < 200.0 and latency_p95 < 100.0)
		pass_test = result["pass"]
		# Print human-readable summary
		print("[test_client] === T-029 Latency Report ===")
		print("[test_client] Movement RTT (ping/pong): %.2f ms" % _ping_rtt_ms)
		print("[test_client] Combat RTT samples: %d" % _latency_samples.size())
		print("[test_client] Combat RTT min: %.2f ms" % latency_min)
		print("[test_client] Combat RTT p50: %.2f ms" % latency_p50)
		print("[test_client] Combat RTT p95: %.2f ms" % latency_p95)
		print("[test_client] Combat RTT p99: %.2f ms" % latency_p99)
		print("[test_client] Combat RTT max: %.2f ms" % latency_max)
		print("[test_client] Combat RTT avg: %.2f ms" % latency_avg)
		if pass_test:
			print("[test_client] RESULT: PASS")
		else:
			print("[test_client] RESULT: FAIL")
			if not has_valid_data:
				print(
					(
						"[test_client] WARNING: No latency data collected (samples=%d, ping=%.1f)"
						% [_latency_samples.size(), _ping_rtt_ms]
					)
				)
			if _ping_rtt_ms >= 200.0:
				print("[test_client] WARNING: Movement RTT >= 200ms")
				print("[test_client] REMEDIATION: Check network interface, firewall, ENet settings")
			if latency_p95 >= 100.0:
				print("[test_client] WARNING: Combat p95 >= 100ms")
				print(
					"[test_client] REMEDIATION: Reduce server load, check ENet channel congestion"
				)

	# T-030: Ability-use mode result. The client records only server-emitted values.
	if _ability_mode:
		result["ability_mode"] = true
		# T-067: repeat==0 is pure-observation mode (aggro linger) and cast mode emits
		# cast_started instead of instant results — protocol-level pass; the harness script
		# asserts the semantics from the recorded fields.
		result["pass"] = (
			_handshake_ok
			and (
				_ability_repeat == 0
				or _ability_mob_killed
				or _ability_rejections_received.size() > 0
				or _ability_cast_started_count > 0
			)
		)
		result["attacks_on_me"] = _ability_attacks_on_me
		result["cast_started_count"] = _ability_cast_started_count
		result["cast_cancel_reasons"] = _ability_cast_cancel_reasons
		result["peer_id"] = _my_peer_id
		result["mob_death_credited"] = _ability_mob_death_credited
		result["my_hp_min"] = _my_hp_min
		result["my_hp_last"] = _my_hp_last
		result["intents_sent"] = _ability_intents_sent
		result["results_received"] = _ability_results_received
		result["rejections_received"] = _ability_rejections_received
		result["mob_killed"] = _ability_mob_killed
		result["mob_death_count"] = _ability_mob_death_count
		result["last_outcome"] = _ability_last_outcome
		result["damage_attributed_by_server"] = _ability_damage_attributed_by_server
		pass_test = result["pass"]
		if pass_test:
			print("[test_client] T-030: RESULT: PASS")
		else:
			print("[test_client] T-030: RESULT: FAIL")

	# T-049: reach-objective result.
	if _reach_mode:
		var reach_accept_ok: bool = bool(_quest_accept_result.get("ok", false))
		var reach_credited: bool = _objective_credited(_reach_quest, _reach_obj_index)
		result["reach_mode"] = true
		result["accept_ok"] = reach_accept_ok
		result["reach_credited"] = reach_credited
		result["pass"] = _handshake_ok and reach_accept_ok and reach_credited
		pass_test = result["pass"]
		if pass_test:
			print("[test_client] T-049: RESULT: PASS — reach credited over ENet")
		else:
			print("[test_client] T-049: RESULT: FAIL")

	# T-049: talk-objective result.
	if _talk_mode:
		var talk_accept_ok: bool = bool(_quest_accept_result.get("ok", false))
		var talk_credited: bool = _objective_credited(_talk_quest, _talk_obj_index)
		result["talk_mode"] = true
		result["accept_ok"] = talk_accept_ok
		result["talk_credited"] = talk_credited
		result["pass"] = _handshake_ok and talk_accept_ok and talk_credited
		pass_test = result["pass"]
		if pass_test:
			print("[test_client] T-049: RESULT: PASS — talk credited over ENet")
		else:
			print("[test_client] T-049: RESULT: FAIL")

	# T-049: inventory result — equip moved the seeded bag item to its equip slot, bag slot cleared.
	if _inv_mode:
		var bag_had: bool = _slot_has(_inv_get_result, "bag", _inv_bag_slot, _inv_item)
		var equipped: bool = _slot_has(_inv_equip_result, _inv_equip_slot, 0, _inv_item)
		var bag_cleared: bool = not _slot_has(_inv_equip_result, "bag", _inv_bag_slot, _inv_item)
		result["inv_mode"] = true
		result["bag_had_item"] = bag_had
		result["equipped"] = equipped
		result["bag_cleared"] = bag_cleared
		result["pass"] = _handshake_ok and bag_had and equipped and bag_cleared
		pass_test = result["pass"]
		if pass_test:
			print("[test_client] T-049: RESULT: PASS — equip moved item to its slot over ENet")
		else:
			print("[test_client] T-049: RESULT: FAIL")

	# T-049: collect result — the collect objective credited on accept (no inventory change).
	if _collect_mode:
		var collect_accept_ok: bool = bool(_quest_accept_result.get("ok", false))
		var collect_credited: bool = _objective_credited(_collect_quest, _collect_obj_index)
		result["collect_mode"] = true
		result["accept_ok"] = collect_accept_ok
		result["collect_credited"] = collect_credited
		result["pass"] = _handshake_ok and collect_accept_ok and collect_credited
		pass_test = result["pass"]
		if pass_test:
			print("[test_client] T-049: RESULT: PASS — collect credited on accept over ENet")
		else:
			print("[test_client] T-049: RESULT: FAIL")

	# T-047: quest-loop result overrides the ability pass with the full-loop criteria.
	if _quest_mode:
		var accept_ok: bool = bool(_quest_accept_result.get("ok", false))
		var credited: int = 0
		var log_quests: Array = _quest_log_result.get("result", {}).get("quests", [])
		for q: Dictionary in log_quests:
			if str(q.get("quest_id", "")) == _quest_id:
				# World enriches the log: objectives[i].current (not raw progress[]).
				var objs: Array = q.get("objectives", [])
				if objs.size() > 0:
					credited = int(objs[0].get("current", 0))
				# T-073: full per-objective progress so harnesses can assert kill AND
				# collect credit (loot delivery) without a turn-in.
				result["quest_objectives"] = objs
		var turn_in_ok: bool = bool(_quest_turn_in_result.get("ok", false))
		result["quest_mode"] = true
		result["quest_id"] = _quest_id
		result["accept_ok"] = accept_ok
		result["mob_killed"] = _ability_mob_killed
		result["objective_credited"] = credited
		result["turn_in_ok"] = turn_in_ok
		result["reward_xp"] = int(_quest_turn_in_result.get("xp", 0))
		result["player_stats_last"] = _player_stats_last  # T-060: XP-bar payload arrived
		result["quest_delta_count"] = _quest_delta_count  # T-058
		result["npc_delta_count"] = _npc_delta_count  # T-058
		result["pass"] = (
			_handshake_ok and accept_ok and _ability_mob_killed and credited >= 1 and turn_in_ok
		)
		pass_test = result["pass"]
		if pass_test:
			print("[test_client] T-047: RESULT: PASS — full quest loop over ENet")
		else:
			print("[test_client] T-047: RESULT: FAIL")

	if _road_mode:
		result["road_chain_mode"] = true
		result["completed"] = _road_completed
		result["letter_received"] = _road_letter_received
		result["letter_removed"] = _road_letter_removed
		result["voucher_received"] = _road_voucher_received
		result["coins_awarded"] = _road_coins_awarded
		result["pass"] = (
			_handshake_ok
			and _error == ""
			and _road_completed == ["q010", "q011", "q012", "q013"]
			and _road_letter_received
			and _road_letter_removed
			and _road_voucher_received
			and _road_coins_awarded == 250
		)
		pass_test = result["pass"]
		print("[test_client] T-216: RESULT: %s" % ("PASS" if pass_test else "FAIL"))

	# Write result file
	if _result_file:
		var file = FileAccess.open(_result_file, FileAccess.WRITE)
		if file:
			file.store_string(JSON.stringify(result))
			file.close()

	print("[test_client] result: %s" % JSON.stringify(result))

	if _enet != null:
		get_tree().get_multiplayer().set_multiplayer_peer(null)

	get_tree().quit(0 if pass_test else 1)


# ─── T-014: Gateway auth-handoff (additive) ──────────────────────


func _gateway_login() -> void:
	"""Connect to gateway via WebSocketPeer, send login, wait for response."""
	_gw_ws = WebSocketPeer.new()
	_gw_phase = 1  # connecting
	var gw_url = "ws://" + _gw_host + ":" + str(_gw_port)
	var err = _gw_ws.connect_to_url(gw_url)
	if err != OK:
		_error = "gateway connect failed (err=%d)" % err
		_gw_phase = 0
		_finish()
		return
	print("[test_client] connecting to gateway %s" % gw_url)
	_connect_start = Time.get_ticks_msec() / 1000.0
	_test_timeout = _movement_duration + 12.0  # extra time for WS login
	set_process(true)


func _gateway_process() -> void:
	"""Poll WebSocket until login_ok received, then close WS."""
	if _gw_ws == null:
		return

	_gw_ws.poll()
	var state = _gw_ws.get_ready_state()

	if state == WebSocketPeer.STATE_CONNECTING:
		return

	# Always try to drain packets first — gateway may send login_ok
	# then close in the same frame. Packets may still be buffered
	# even after the close frame arrives. We need to check CLOSED
	# AFTER draining to catch this race.
	_gateway_drain_packets()
	if _gw_response_received:
		return  # login_ok received, will transition to ENet next frame

	if state == WebSocketPeer.STATE_CLOSED:
		if not _gw_response_received:
			_error = "gateway closed before login_ok"
			_gw_ws = null
			_gw_phase = 0
		return

	# STATE_OPEN
	if _gw_phase == 1:
		_gw_phase = 2  # open — send login

	if _gw_phase == 2 and not _gw_response_received:
		var login_msg = {
			"type": "login",
			"username": _gw_username,
			"password": _gw_password,
		}
		_gw_ws.send_text(JSON.stringify(login_msg))
		print("[test_client] sent gateway login as %s" % _gw_username)

	# Drain again after sending (may catch immediate response)
	_gateway_drain_packets()


func _gateway_drain_packets() -> void:
	"""Read all WS packets. Sets gateway response state on login_ok/login_err."""
	if _gw_ws == null:
		return

	var avail = _gw_ws.get_available_packet_count()
	if avail == 0:
		return

	print("[test_client] draining %d gateway packet(s)" % avail)

	while _gw_ws.get_available_packet_count() > 0 and not _gw_response_received:
		var pkt = _gw_ws.get_packet()
		if _gw_ws.was_string_packet():
			var raw = pkt.get_string_from_utf8()
			print("[test_client] gateway response: %s" % raw)
			var parsed = JSON.parse_string(raw)
			if parsed is Dictionary:
				var msg = parsed
				var msg_type = str(msg.get("type", ""))
				if msg_type == "login_ok":
					_token = str(msg.get("access_token", ""))
					var world = msg.get("world", {})
					_host = str(world.get("host", _host))
					_port = int(world.get("port", _port))
					_gw_response_received = true
					_gw_phase = 3
					print(
						(
							"[test_client] login_ok — token=%s... world=%s:%d"
							% [_token.substr(0, min(16, _token.length())), _host, _port]
						)
					)
					_gw_ws.close()
					return
					if msg_type == "login_err":
						_error = "gateway login rejected: %s" % msg.get("reason", "unknown")
						_gw_phase = 0
						_gw_ws = null
					return


func _setup_enet_client() -> void:
	"""Create ENet client with gateway-obtained token/host/port (reuses direct path)."""
	_enet = ENetMultiplayerPeer.new()
	var err = _enet.create_client(_host, _port)
	if err != OK:
		_error = "failed to create ENet client (err=%d)" % err
		_finish()
		return

	get_tree().get_multiplayer().set_multiplayer_peer(_enet)
	get_tree().get_multiplayer().connected_to_server.connect(_on_connected)
	get_tree().get_multiplayer().connection_failed.connect(_on_connection_failed)
	get_tree().get_multiplayer().server_disconnected.connect(_on_server_disconnected)

	_rng = RandomNumberGenerator.new()
	_rng.seed = _move_seed

	# Reset ENet-phase state for the shared _process logic
	_connected = false
	_handshake_ok = false
	_handshake_sent = false
	_movement_phase = false
	_movement_complete = false

	# Already set by _gateway_login
	# _connect_start, _test_timeout, set_process already done
	# _connected will be set by _on_connected on next frame
	print("[test_client] connecting to world enet://%s:%d with gateway token" % [_host, _port])
