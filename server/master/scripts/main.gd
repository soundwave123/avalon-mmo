extends Node
# Avalon master server — headless WebSocket RPC server.
# Manages session tokens via Postgres.
#
# FAIL-FAST: Validates JWT signing secret on startup. If missing or
# too short (< 32 bytes), the master server refuses to start.

const SessionManager := preload("res://scripts/session_manager.gd")
const ServerConfig := preload("res://scripts/server_config.gd")
# T-041: quest RPC transport — dispatch arms route to the master's character authority.
const CharacterManager := preload("res://scripts/character_manager.gd")
const CharacterRoster := preload("res://scripts/character_roster.gd")  # T-507/T-672
const TalentLogic := preload("res://scripts/talent_logic.gd")  # T-064
const TelemetryStore := preload("res://scripts/telemetry_store.gd")  # T-186
const DungeonDailyLockout := preload("res://scripts/dungeon_daily_lockout.gd")  # T-333
const DailyAppointmentStore := preload("res://scripts/daily_appointment_store.gd")  # T-450
const PvpStore := preload("res://scripts/pvp_store.gd")  # T-390
const MobXp := preload("res://scripts/mob_xp.gd")  # T-358: pure mob-kill XP grant math
const Leveling := preload("res://scripts/leveling.gd")  # T-679: level-cap for guild cap credit
const TravelOps := preload("res://scripts/travel_ops.gd")  # T-431: roost discovery + flight sink
const WardrobeOps := preload("res://scripts/wardrobe_ops.gd")  # T-428: persisted cosmetic slots
const VendorOps := preload("res://scripts/vendor_ops.gd")  # T-430: vendor buy/sell + buyback
const DiscoveryStore := preload("res://scripts/discovery_store.gd")  # T-427: first-entry rewards
const MentorCreditStore := preload("res://scripts/mentor_credit_store.gd")  # T-481 prestige
const WeeklyVaultStore := preload("res://scripts/weekly_vault_store.gd")  # T-480 weekly vault
const OpsStore := preload("res://scripts/ops_store.gd")  # T-511 audited GM actions + account bans
const WorldStateStore := preload("res://scripts/world_state_store.gd")  # T-734 world-global KV
const FirstSessionFunnel := preload("res://scripts/first_session_funnel.gd")  # T-528 onramp funnel
const RiftSeason := preload("res://scripts/rift_season.gd")  # T-393/T-394 rift ladder + seasons
const AccountMastery := preload("res://scripts/account_mastery.gd")  # T-395 permanent mastery
const TutorialOps := preload("res://scripts/tutorial_ops.gd")  # T-426 tutorial + T-550 onboarding
const OnboardingStore := preload("res://scripts/onboarding_store.gd")  # T-706 graduation flag
const RpcIntake := preload("res://scripts/rpc_intake.gd")  # T-754 untrusted-frame decoder
# Default session TTL in minutes (2 hours for dev)
const DEFAULT_TTL_MINUTES := 120

# T-378: the only bind addresses allowed to run secret-less (dev convenience). Anything else
# is reachable off-host and MUST carry AVALON_RPC_SHARED_SECRET or the master refuses to boot.
const LOOPBACK_BINDS: Array[String] = ["127.0.0.1", "localhost", "::1"]

var _server: TCPServer
var _trade_ops := TradeOps.new()  # T-363: server-owned trade sessions + atomic swap
var _vendor_ops := VendorOps.new()  # T-430: per-character buyback + atomic vendor inventory/coin
var _rpc_shared_secret: String = ""  # T-074: required on every request when set
var _peers: Dictionary = {}  # WebSocketPeer -> {ws: WebSocketPeer}
var _running: bool = false


func _ready() -> void:
	print("[master] starting...")
	Engine.max_fps = 60  # T-698: headless _process free-ran uncapped for no benefit

	# Initialize session manager from environment
	if not SessionManager.init_from_env():
		print("[master] FATAL: cannot initialize session manager (JWT secret validation failed)")
		get_tree().quit(1)
		return

	# Verify Postgres connectivity
	if not SessionManager.check_db_connectivity():
		print("[master] FATAL: cannot reach Postgres")
		get_tree().quit(1)
		return

	# Start TCP server for WebSocket RPC
	_server = TCPServer.new()
	# T-074: loopback by default — the RPC surface is unauthenticated-by-trust (world/gateway
	# only). Set AVALON_MASTER_BIND=0.0.0.0 (+ AVALON_RPC_SHARED_SECRET) for real sharding.
	var bind_addr: String = OS.get_environment("AVALON_MASTER_BIND")
	if bind_addr == "":
		bind_addr = "127.0.0.1"
	_rpc_shared_secret = OS.get_environment("AVALON_RPC_SHARED_SECRET")
	# T-378: public bind ⇒ secret required (fail-closed). Without this, forgetting the secret
	# on a 0.0.0.0 bind silently exposes issue_session/turn_in/equip/adjust_coins for ANY
	# username to anyone who can reach the port (T-377 vector 8b). Mirrors the JWT fail-fast.
	if not bind_secret_ok(bind_addr, _rpc_shared_secret):
		print(
			(
				(
					"[master] FATAL: AVALON_MASTER_BIND=%s is non-loopback but "
					+ "AVALON_RPC_SHARED_SECRET is empty — refusing to expose the RPC surface "
					+ "unauthenticated. Set AVALON_RPC_SHARED_SECRET or bind to 127.0.0.1."
				)
				% bind_addr
			)
		)
		get_tree().quit(1)
		return
	var err: int = _server.listen(ServerConfig.listen_port(), bind_addr)
	if err != OK:
		print(
			(
				"[master] FATAL: failed to listen on port %d (error %d)"
				% [ServerConfig.listen_port(), err]
			)
		)
		get_tree().quit(1)
		return

	_running = true
	print("[master] listening on ws://%s:%d" % [bind_addr, ServerConfig.listen_port()])


# T-378: the boot-guard predicate — pure + static so tests exercise the refuse path without a
# real boot. True = safe to listen; false = FATAL (public bind with an empty shared secret).
static func bind_secret_ok(bind_addr: String, secret: String) -> bool:
	return secret != "" or bind_addr in LOOPBACK_BINDS


func _process(_delta: float) -> void:
	if not _running:
		return

	# Accept new connections
	while _server.is_connection_available():
		var ws := WebSocketPeer.new()
		# T-320: match the world client's enlarged buffers — content-scale RPC payloads
		# (npc_indicators with quest defs) exceed the 64KB default and stall the socket.
		ws.inbound_buffer_size = 1 << 20
		ws.outbound_buffer_size = 1 << 20
		var peer := _server.take_connection()
		if peer == null:
			continue
		var ws_err: int = ws.accept_stream(peer)
		if ws_err != OK:
			print("[master] failed to accept WebSocket upgrade (error %d)" % ws_err)
			continue
		_peers[ws] = ws

	# Process existing peers
	var ws_to_remove: Array[WebSocketPeer] = []
	for ws_key in _peers:
		var ws: WebSocketPeer = _peers[ws_key]
		ws.poll()

		var state: int = ws.get_ready_state()
		if state == WebSocketPeer.STATE_CLOSED:
			ws_to_remove.append(ws_key)
			continue

		if state != WebSocketPeer.STATE_OPEN:
			continue

		# Read incoming messages
		while ws.get_available_packet_count() > 0:
			var pkt := ws.get_packet()
			if ws.was_string_packet():
				var text: String = pkt.get_string_from_utf8()
				var response: String = _handle_message(text)
				ws.send_text(response)

	# Clean up closed peers
	for ws_key in ws_to_remove:
		_peers.erase(ws_key)


func _handle_message(raw: String) -> String:
	# T-754: decode types the envelope only; payload stays Variant until after auth.
	var frame: Dictionary = RpcIntake.decode(raw)
	var msg_id: String = str(frame.get(RpcIntake.MSG_ID, ""))
	if not bool(frame.get(RpcIntake.SLOT_OK, false)):
		return _json_resp(msg_id, {"error": str(frame.get(RpcIntake.SLOT_ERROR, "invalid_json"))})

	# T-074: shared-secret gate — anyone reaching the port could otherwise issue_session/
	# turn_in/equip as any user. T-754: runs BEFORE params is typed (no pre-auth coercion).
	if _rpc_shared_secret != "" and str(frame.get(RpcIntake.SECRET, "")) != _rpc_shared_secret:
		return _json_resp(msg_id, {"error": "unauthorized"})

	# T-754: receive as Variant, type-test, then assign typed.
	var raw_params: Variant = frame.get(RpcIntake.RAW_PARAMS, {})
	if not raw_params is Dictionary:
		return _json_resp(msg_id, {"error": "invalid_params"})
	var params: Dictionary = raw_params

	var result: Dictionary = _dispatch(str(frame.get(RpcIntake.METHOD, "")), params)
	return _json_resp(msg_id, result)


# Single-return dispatch (keeps gdlint max-returns happy as the method surface grows). Session arms
# delegate to SessionManager; T-041/T-042 quest arms resolve character/server-side facts in helpers.
func _dispatch(method: String, params: Dictionary) -> Dictionary:
	var result: Dictionary
	match method:
		"issue_session":
			result = SessionManager.issue_session(
				str(params.get("username", "")), DEFAULT_TTL_MINUTES
			)

		"validate_session":
			# T-672: JWT validation is shared (SessionManager); resolving the acting character is
			# the master's job (CharacterRoster.validate_and_resolve wraps both).
			result = CharacterRoster.validate_and_resolve(str(params.get("token", "")))
			if bool(result.get("success", false)):  # T-507: daily keys on the resolved CHARACTER
				result["daily"] = DailyAppointmentStore.login(
					str(result.get("character_name", "")), str(params.get("date_key", ""))
				)
				# T-706: account graduation rides the handshake so the world can pin a first-ever
				# character's spawn to hub[0] (dispersion hubs sit past the marker horizon).
				result["tutorial_done"] = OnboardingStore.is_tutorial_done(
					str(result.get("username", ""))
				)

		# T-186: append-only telemetry batch from the world (fire-and-forget; master is the writer).
		"record_events":
			result = TelemetryStore.record_events(RpcIntake.shaped(params, "events", []))

		"ops_apply":
			result = OpsStore.apply(params)
		"ops_tail":
			result = OpsStore.tail(params)
		# T-734: world-global scalar checkpoints (day/night clock) — world owns live, master persists.
		"world_state_op":
			result = WorldStateStore.handle(params)
		# T-528: read-only first-session funnel rollup over the T-186 log (GM console section).
		"first_session_funnel":
			result = FirstSessionFunnel.rollup(params)

		# T-427: world-observed movement edge; identity resolves to the persisted character here.
		"discover":
			result = _discover(
				str(params.get("username", "")), RpcIntake.shaped(params, "node", {})
			)

		"revoke_session":
			result = {"success": SessionManager.revoke_session(str(params.get("token", "")))}

		# T-041: quest RPC transport. character_id/level/prereq are resolved server-side from the
		# username's persisted character — never trusted from the client (combat-invariant #1).
		"get_quest_log":
			result = _quest_log(str(params.get("username", "")))

		"daily_status":
			result = DailyAppointmentStore.status(
				str(params.get("username", "")),
				str(params.get("date_key", "")),
				RpcIntake.shaped(params, "quest_defs", {})
			)
			# T-480: the weekly build-toward rides the daily browse (feeds the T-483 end cue).
			result["weekly"] = WeeklyVaultStore.summary(
				str(params.get("username", "")), str(params.get("date_key", ""))
			)

		# T-480: weekly vault status/claim. The world resolves identity from the live session and
		# stamps the UTC date; master owns progress, the once-per-week claim, and the grant.
		"weekly_op":
			result = WeeklyVaultStore.op(params)

		# T-058: one quest's row + progress — the targeted-delta push reads this, not the log.
		"quest_entry":
			result = _quest_entry(str(params.get("username", "")), str(params.get("quest_id", "")))

		"accept_quest":
			result = _accept_quest(
				str(params.get("username", "")),
				RpcIntake.shaped(params, "quest", {}),
				RpcIntake.shaped(params, "item_registry", {})
			)

		# T-042: server-observed kill credit. mob_id + quest_defs come from the world (def authority);
		# master credits only the player's active matching quests.
		"credit_kill":
			result = KillCreditOps.credit_kill(
				str(params.get("username", "")),
				str(params.get("mob_id", "")),
				RpcIntake.shaped(params, "quest_defs", {}),
				int(params.get("mob_xp", 0)),
				int(params.get("mob_level", 1)),
				int(params.get("party_size", 1)),
				int(params.get("mentor_level", -1)),
				bool(params.get("mentor_opted_in", false)),
				bool(params.get("mentor_active", false)),
				RpcIntake.shaped(params, "party_usernames", [])
			)

		# T-043: atomic turn-in + reward grant. objectives_complete is computed here (master holds
		# progress); at_turnin_npc (proximity) + item_registry come from the world.
		"turn_in":
			result = _turn_in(
				str(params.get("username", "")),
				RpcIntake.shaped(params, "quest", {}),
				bool(params.get("at_turnin_npc", false)),
				RpcIntake.shaped(params, "item_registry", {}),
				str(params.get("date_key", "")),
				RpcIntake.shaped(params, "quest_defs", {})
			)
			if bool(result.get("ok", false)):  # T-480: a turn-in ticks the weekly quests track
				WeeklyVaultStore.credit(
					str(params.get("username", "")), "quests", str(params.get("date_key", ""))
				)

		# T-044: talk to an NPC — credits talk objectives + returns !/? status (world proximity-gated).
		"talk":
			result = _talk(
				str(params.get("username", "")),
				RpcIntake.shaped(params, "npc", {}),
				RpcIntake.shaped(params, "quest_defs", {})
			)
		# T-044: abandon a quest (no proximity — issued from the quest log).
		"abandon_quest":
			result = _abandon_quest(
				str(params.get("username", "")),
				str(params.get("quest_id", "")),
				RpcIntake.shaped(params, "quest", {})
			)
		# T-550: control-hint sighting -> ACCOUNT-scoped fire-once memory (account resolved server-side).
		"onboarding_hint_seen":
			result = TutorialOps.record_hint_seen(params)
		# T-045: inventory. Reads + server-validated change ops; each change refreshes collect.
		"get_inventory":
			result = _get_inventory(str(params.get("username", "")))

		# T-428: world resolves catalog ids; master owns identity, unlocks, slot state, and persistence.
		"wardrobe_op":
			result = WardrobeOps.op(params)

		"equip":
			result = _equip(
				str(params.get("username", "")),
				int(params.get("bag_slot", -1)),
				RpcIntake.shaped(params, "item_registry", {}),
				RpcIntake.shaped(params, "quest_defs", {})
			)

		"unequip":
			result = _unequip(
				str(params.get("username", "")),
				str(params.get("equip_slot", "")),
				RpcIntake.shaped(params, "quest_defs", {})
			)

		"drop":
			result = _drop(
				str(params.get("username", "")),
				str(params.get("slot_type", "")),
				int(params.get("slot_index", -1)),
				int(params.get("count", 1)),
				RpcIntake.shaped(params, "quest_defs", {})
			)

		# T-073/T-644: server-observed loot grant (world rolls a killed mob's loot table). Tries the
		# killer, then party fallback, then holds for retry — see loot_ops.gd.
		"grant_loot":
			result = LootOps.grant_or_hold(params)

		"grant_dungeon_loot":
			result = DungeonDailyLockout.grant(params)
			if bool(result.get("ok", false)):  # T-480: a boss grant ticks the weekly dungeon track
				WeeklyVaultStore.credit(
					str(params.get("username", "")), "dungeons", str(params.get("date_key", ""))
				)

		# T-046: server-observed reach credit (world resolves the player entering a reach radius).
		"credit_reach":
			result = _credit_reach(
				str(params.get("username", "")),
				str(params.get("target", "")),
				RpcIntake.shaped(params, "quest_defs", {})
			)

		# T-426: world-observed ability-use credit (tutorial "use_ability" verb).
		"credit_ability":
			result = TutorialOps.credit_ability(
				str(params.get("username", "")),
				str(params.get("ability_slug", "")),
				RpcIntake.shaped(params, "quest_defs", {})
			)

		"credit_interrupt":  # T-426 slice 4: world-observed interrupt credit (tactical verb, q_tut_03)
			result = TutorialOps.credit_interrupt(
				str(params.get("username", "")),
				str(params.get("mob_alias", "")),
				RpcIntake.shaped(params, "quest_defs", {})
			)

		# T-046: per-player !/? indicator for each NPC.
		"npc_indicators":
			result = _npc_indicators(
				str(params.get("username", "")),
				RpcIntake.shaped(params, "npcs", []),
				RpcIntake.shaped(params, "quest_defs", {}),
				RpcIntake.shaped(params, "npc_quest_defs", {})
			)

		# T-064: talents — spend one point / read spent state / reroll-clear. talent defs come
		# from the world (content authority), mirroring quest_defs; master owns the character.
		"spend_talent":
			result = _spend_talent(
				str(params.get("username", "")),
				RpcIntake.shaped(params, "talent", {}),
				RpcIntake.shaped(params, "talent_defs", {})
			)

		"get_talents":
			result = _get_talents(str(params.get("username", "")))

		# T-065: one-shot class selection (locked after; reroll is the only way out).
		"set_class":
			result = _set_class(str(params.get("username", "")), str(params.get("class", "")))

		# T-520: one-shot gender selection at creation (before class; reroll is the only way out).
		"set_gender":
			result = _set_gender(str(params.get("username", "")), str(params.get("gender", "")))

		# T-716: one-shot name step at creation (after class). Existing characters never see it.
		"set_name":
			result = _set_name(str(params.get("username", "")), str(params.get("name", "")))

		"reroll_talents":
			result = _reroll_talents(str(params.get("username", "")))

		# T-360: rested XP lifecycle. The world calls rested_login at spawn (bank the offline window)
		# and rested_logout on disconnect (stamp the window start). Master owns the clock — it stamps
		# Time.get_unix_time_from_system() here so the world can't spoof accrual.
		"rested_login":
			result = _rested_login(str(params.get("username", "")))

		"rested_logout":
			result = _rested_logout(str(params.get("username", "")))

		# T-422c: persist the world-validated action-bar layout (an ordered ability-id list).
		"save_bar_layout":
			result = ServicesStore.save_layout_for_user(
				str(params.get("username", "")), RpcIntake.shaped(params, "layout", [])
			)

		# T-431: world-authoritative route gate; master persists discovery and commits coin sinks.
		"flight_op":
			result = TravelOps.op(params)

		# T-061: combat data (class/level/derived stats). The world drives stat-based combat from
		# this at spawn; class/level/stats are resolved server-side, never trusted from the client.
		"get_character_combat":
			result = CharacterManager.get_character_combat(
				str(params.get("username", "")),
				RpcIntake.shaped(params, "talent_defs", {}),
				RpcIntake.shaped(params, "item_stats", {})  # T-399: world-injected item_id -> stats registry
			)
			if not result.has("error"):
				# T-208: trained-ability unlocks ride the combat payload (world's kit filter)
				var cid_c := int(
					CharacterManager.get_character(str(params.get("username", ""))).get("id", -1)
				)
				result["unlocked_abilities"] = ServicesStore.get_unlocked_abilities(cid_c)
				result["bar_layout"] = ServicesStore.get_bar_layout(cid_c)  # T-422c saved slot order
				result["coins"] = ServicesStore.get_coins(cid_c)
				result["mount_profile"] = TravelOps.mount_profile(cid_c)
				# T-319: grant the class starter weapon (idempotent; skips unclassed/armed) and
				# hand the world the equipped slots so it seeds the gear broadcast at spawn.
				result["equipped_slots"] = WardrobeOps.decorate_slots(
					cid_c, CharacterManager.ensure_starting_weapon(cid_c).get("slots", [])
				)
				# T-361: ignore list rides the spawn payload — seeds the world's chat filter.
				result["ignores"] = SocialStore.names(cid_c, "ignore")
				# T-362: guild id rides the spawn payload — seeds the world's guild-chat routing.
				result.merge(GuildStore.profile_for(cid_c))
				# T-679: a capped member logging in flags the guild's "N members reach cap" milestone
				# (FLAG keyed on cid → distinct members; idempotent, and backfills members who capped
				# before this shipped). Server-authoritative: level read from the persisted character.
				if int(result.get("level", 0)) >= Leveling.MAX_LEVEL:
					KillCreditOps.credit_guild(result, cid_c, "guild_member_cap", str(cid_c))
				# T-451: persisted newcomer/help opt-in seeds the world's subscriber routing cache.
				result["help_subscribed"] = SocialStore.help_subscribed(cid_c)

		# T-353: the rift gear-carry (era-direction.md S4, Rule A). instance_service.enter_era fires
		# this on a crossing INTO the target era; rarities are injected by the world (items.json lives
		# there). Master re-scales held epics/legendaries one hop, retires the rest, and persists.
		"carry_gear":
			result = _carry_gear(params)

		# T-208: the three Highkeep services — world proximity-gates; master owns state.
		"vault_op":
			result = VaultOps.op(params)  # T-412: list/move/upgrade (tier-ladder coin sink)

		"auction_op":
			result = AuctionOps.op(params)

		# T-363: player-to-player trade — the world resolves BOTH identities from live sessions;
		# master owns the whole session state machine and commits the swap atomically (TradeOps).
		"trade_op":
			result = _trade_ops.op(params)

		# T-361 item 2: friends/ignore — persisted per-character lists; target resolved here.
		"social_op":
			result = SocialStore.op(params)

		# T-362: guilds — world resolves acting identity from the live session; master owns
		# membership + rank truth and gates every management verb by PERSISTED rank.
		"guild_op":
			result = GuildStore.op(params)

		# T-367: achievements — READ-ONLY client surface (action "list"). Grants are server-observed
		# inside _credit_kill/_turn_in/_credit_reach, never a client verb — so no forgeable earn path.
		"achievement_op":
			result = _achievement_op(params)
		"renown_op":  # T-678: read-only renown standing; grants ride _turn_in, never a verb
			result = RenownStore.op(params)

		"trainer_op":
			result = _trainer_op(params)

		# T-414: crafting — gather mints world-named materials (item faucet, tracked by inventory
		# row not coin), craft consumes→produces all-or-nothing, use_item reads the effect off ITEM
		# DATA, recipe learn is the ledgered "recipe" coin sink. World proximity-gates every verb.
		"gather_op":
			result = CraftOps.gather_op(params)
			_credit_collect_for_craft(params, result)
		"craft_op":
			result = CraftOps.craft_op(params)
			_credit_collect_for_craft(params, result)
		"use_item_op":
			result = CraftOps.use_item_op(params)
		"recipe_op":
			result = CraftOps.recipe_op(params)

		# T-364: bounded death penalty + repair sink. Both SERVER-OBSERVED (world calls them; no
		# client verb): wear rides the alive→dead edge, repair debits coins via the ledger sink.
		"apply_death_wear":
			result = DurabilityOps.apply_death_wear(params)
		"repair_op":
			result = DurabilityOps.repair_op(params)

		# T-430: world proximity-gates and injects NPC stock/item data; master resolves character,
		# inventory, balance, prices, and the bounded per-character buyback shortlist.
		"vendor_op":
			result = _vendor_ops.op(params)

		# T-613: mail — bundled onto the banker's "bank" service hub (world_rpc.gd proximity-
		# gates + injects the item registry). Fully static like AuctionOps: no per-request state.
		"mail_op":
			result = MailOps.op(params)

		# T-390: PvP rating spine. record_match is SERVER-OBSERVED — the world calls it after it
		# adjudicates a consensual rated match; there is NO client intent that reaches it. The
		# master stamps its OWN clock so the season is server-derived (no client names a season).
		"record_match":
			var mp := params.duplicate()
			mp["now"] = int(Time.get_unix_time_from_system())
			result = PvpStore.record_match(mp)
			if not result.has("error"):
				# T-480: PARTICIPATION ticks the weekly matches track — both sides, win or lose
				# (playing is the beat; never a win-grind chore). Date derives from the same clock.
				var match_day := Time.get_datetime_string_from_unix_time(int(mp["now"])).substr(
					0, 10
				)
				WeeklyVaultStore.credit(str(mp.get("winner", "")), "battlegrounds", match_day)
				WeeklyVaultStore.credit(str(mp.get("loser", "")), "battlegrounds", match_day)

		# T-392 duel/BG matchmaking: world-resolved usernames + server-side MMR, read-only.
		"matchmake_op":
			var mm := params.duplicate()
			mm["now"] = int(Time.get_unix_time_from_system())
			result = PvpStore.matchmake(mm)

		# T-390 READ-ONLY ladder surface (leaderboard + own rating; rate-limited social hub).
		"pvp_op":
			var pp := params.duplicate()
			pp["now"] = int(Time.get_unix_time_from_system())
			result = PvpStore.op(pp)

		# T-391 reward tracks: spends overdraft-guarded; honor only GRANTED in record_match.
		"pvp_track_op":
			var tp := params.duplicate()
			tp["season"] = int(
				PvpStore.PvpSeason.season_for(int(Time.get_unix_time_from_system()))["id"]
			)
			result = PvpStore.PvpHonor.track_op(tp)

		"rift_op":  # T-393 reads world-forced; T-394 rollover observer + season read ride here
			result = RiftSeason.dispatch(params)

		"mastery_op":  # T-395 permanent floor: read-only surface; accrual is server-internal
			result = AccountMastery.dispatch(params)

		_:
			result = {"error": "unknown_method"}
	return result


# T-041: returns {"quests": [{quest_id, state, progress:[int]}]} for the username; empty if unknown.
func _quest_log(username: String) -> Dictionary:
	var character: Dictionary = CharacterManager.get_character(username)
	if character.is_empty():
		return {"quests": [], "level": 1}
	var character_id: int = int(character.get("id", -1))
	var quests: Array = []
	for entry: Dictionary in CharacterManager.get_quests(character_id):
		var quest_id: String = str(entry.get("quest_id", ""))
		(
			quests
			. append(
				{
					"quest_id": quest_id,
					"state": str(entry.get("state", "")),
					"progress": CharacterManager.get_objective_progress(character_id, quest_id),
				}
			)
		)
	return {"quests": quests, "level": int(character.get("level", 1))}


# T-041: accept a quest. quest is the world-supplied def. Returns {"ok", "reason"}.
func _accept_quest(username: String, quest: Dictionary, item_registry: Dictionary) -> Dictionary:
	var character: Dictionary = CharacterManager.get_character(username)
	if character.is_empty():
		return {"ok": false, "reason": "unknown_character"}
	var character_id: int = int(character.get("id", -1))
	var level: int = int(character.get("level", 1))
	var prereq: String = str(quest.get("prerequisite_quest", ""))
	var prereq_complete: bool = (
		prereq == "" or CharacterManager.quest_state(character_id, prereq) == "complete"
	)
	var result = CharacterManager.try_accept(character_id, quest, level, prereq_complete)
	if result.ok:
		# T-058: grant the quest's provided items; a full bag rolls the accept back.
		var grant: Dictionary = CharacterManager.grant_provided_items(
			character_id, quest, item_registry
		)
		if not bool(grant.get("ok", true)):
			CharacterManager.abandon_quest(character_id, str(quest.get("id", "")))
			return {"ok": false, "reason": "bags_full"}
		# T-049: credit already-held items immediately (collect refresh on accept), like WoW —
		# otherwise a player holding the items stays at 0/N until some later inventory change.
		CharacterManager.refresh_collect_for_character(
			character_id, {str(quest.get("id", "")): quest}
		)
	return {"ok": result.ok, "reason": result.reason}


# T-058: one quest's persisted row + progress for the targeted delta push.
func _quest_entry(username: String, quest_id: String) -> Dictionary:
	var character: Dictionary = CharacterManager.get_character(username)
	if character.is_empty():
		return {"entry": {}, "level": 1}
	# T-621: level rides the reply so the delta-push enrich can colour the one card's difficulty.
	return {
		"entry": CharacterManager.quest_entry(int(character.get("id", -1)), quest_id),
		"level": int(character.get("level", 1)),
	}


# T-353: the master half of the rift GEAR-CARRY HOOK. Resolves the crossing character server-side
# (never client-trusted), re-scales its inventory into `target_era` and persists. Returns
# {carried, retired} item-id lists (empty on unknown user). Rarities are the world's items.json map.
func _carry_gear(params: Dictionary) -> Dictionary:
	var character: Dictionary = CharacterManager.get_character(str(params.get("username", "")))
	if character.is_empty():
		return {"carried": [], "retired": []}
	return CharacterManager.carry_gear_across_era(
		int(character.get("id", -1)),
		int(params.get("target_era", 2)),
		RpcIntake.shaped(params, "rarities", {})
	)


# T-064: spend one talent point. World supplies the talent def + full defs (content
# authority); master validates against the persisted character (level/class/spent).
func _spend_talent(username: String, talent: Dictionary, talent_defs: Dictionary) -> Dictionary:
	var character: Dictionary = CharacterManager.get_character(username)
	if character.is_empty():
		return {"ok": false, "reason": "unknown_character", "ranks": 0, "points_left": 0}
	return CharacterManager.spend_talent(int(character.get("id", -1)), talent, talent_defs)


# T-064: the character's spent talents + point budget (for the T-065 talent UI).
func _get_talents(username: String) -> Dictionary:
	var character: Dictionary = CharacterManager.get_character(username)
	if character.is_empty():
		return {"talents": {}, "points_available": 0, "points_spent": 0}
	var spent: Dictionary = CharacterManager.get_talents(int(character.get("id", -1)))
	var level: int = int(character.get("level", 1))
	return {
		"talents": spent,
		"class": str(character.get("class", "warrior")),  # T-065: world filters defs by this
		"points_available": TalentLogic.points_available(level),
		"points_spent": TalentLogic.points_spent(spent),
	}


# T-065: set the character's class once (server-locked afterwards).
# T-319: on a successful lock, grant the class's starting weapon into the equipped slot and
# return the post-op slots so the world can broadcast the armed avatar immediately (no relog).
func _set_class(username: String, char_class: String) -> Dictionary:
	var character: Dictionary = CharacterManager.get_character(username)
	if character.is_empty():
		return {"ok": false, "reason": "unknown_character"}
	var cid := int(character.get("id", -1))
	var result: Dictionary = CharacterManager.set_class(cid, char_class)
	if bool(result.get("ok", false)):
		result["slots"] = CharacterManager.ensure_starting_weapon(cid).get("slots", [])
	return result


# T-520: persist the gender chosen at character creation (before class). Master owns the write.
func _set_gender(username: String, gender: String) -> Dictionary:
	var character: Dictionary = CharacterManager.get_character(username)
	if character.is_empty():
		return {"ok": false, "reason": "unknown_character"}
	return CharacterManager.set_gender(int(character.get("id", -1)), gender)


# T-716: persist the name chosen at character creation (after class). `username` is the CHARACTER
# name the session currently acts as (T-507) — i.e. the OLD name — so a success also tells the
# world which identity string to rebind for the live session (previous_name -> name).
func _set_name(username: String, name: String) -> Dictionary:
	var character: Dictionary = CharacterManager.get_character(username)
	if character.is_empty():
		return {"ok": false, "reason": "unknown_character"}
	return CharacterManager.set_character_name(int(character.get("id", -1)), name)


# T-064: reroll — clear every spent talent (the build dies wholesale). T-475/T-525: against a
# scaling coin cost (TalentLogic.reroll_cost), debited atomically with the clear; a purse that
# cannot cover it rejects cleanly. Clearing an empty build stays free (nothing is bought).
func _reroll_talents(username: String) -> Dictionary:
	var character: Dictionary = CharacterManager.get_character(username)
	if character.is_empty():
		return {"ok": false, "reason": "unknown_character"}
	var cid := int(character.get("id", -1))
	if CharacterManager.get_talents(cid).is_empty():
		return {"ok": true, "reason": "", "cost": 0}
	var cost := TalentLogic.reroll_cost(ServicesStore.get_talent_rerolls(cid))
	if not ServicesStore.commit_talent_reroll(cid, cost):
		return {"ok": false, "reason": "insufficient_coins", "cost": cost}
	return {"ok": true, "reason": "", "cost": cost}


# T-620: sum of party_usernames' PERSISTED levels; <=1 name -> -1 (MobXp.share's legacy-split flag).
func _achievement_op(params: Dictionary) -> Dictionary:
	if str(params.get("action", "list")) != "list":
		return {"error": "unknown_action"}
	var character: Dictionary = CharacterManager.get_character(str(params.get("username", "")))
	if character.is_empty():
		return {"error": "unknown_character"}
	return AchievementStore.list(int(character.get("id", -1)))


# T-427: no client dispatch reaches this method; world supplies an authored node after authoritative
# movement. DiscoveryStore revalidates the definition and owns the atomic persisted reward gate.
func _discover(username: String, node: Dictionary) -> Dictionary:
	var character := CharacterManager.get_character(username)
	if character.is_empty():
		return {"discovered": false, "reason": "unknown_character"}
	var result := DiscoveryStore.discover(int(character.get("id", -1)), username, node)
	if bool(result.get("discovered", false)):
		# T-480: a first-entry discovery ticks the weekly track (master stamps its own UTC date).
		WeeklyVaultStore.credit(username, "discoveries", Time.get_date_string_from_system(true))
	return result


# T-360: bank rested for the offline window since the character's last logout. Returns the new pool.
func _rested_login(username: String) -> Dictionary:
	var character: Dictionary = CharacterManager.get_character(username)
	if character.is_empty():
		return {"rested_remaining": 0}
	var now := int(Time.get_unix_time_from_system())
	return {"rested_remaining": CharacterManager.accrue_rested_on_login(int(character["id"]), now)}


# T-360: stamp the start of the offline accrual window at logout.
func _rested_logout(username: String) -> Dictionary:
	var character: Dictionary = CharacterManager.get_character(username)
	if character.is_empty():
		return {"ok": false}
	CharacterManager.mark_rested_logout(int(character["id"]), int(Time.get_unix_time_from_system()))
	return {"ok": true}


# T-046: credit a reach to the username's active matching quests. Returns {"credited": [quest_id]}.
func _credit_reach(username: String, target: String, quest_defs: Dictionary) -> Dictionary:
	var character: Dictionary = CharacterManager.get_character(username)
	if character.is_empty():
		return {"credited": []}
	var cid := int(character.get("id", -1))
	var result: Dictionary = CharacterManager.credit_reach(cid, target, quest_defs)
	AchievementStore.merge_into(result, AchievementStore.observe(cid, "reach", target))  # T-367
	return result


# T-046: {npc_id: indicator} for the username across the given NPCs.
# T-058: npc_quest_defs ({npc_id: defs}) makes each NPC's indicator O(quests-for-this-npc)
# — the world builds the index once from content; the full defs dict is the fallback.
func _npc_indicators(
	username: String, npcs: Array, quest_defs: Dictionary, npc_quest_defs: Dictionary = {}
) -> Dictionary:
	var character: Dictionary = CharacterManager.get_character(username)
	if character.is_empty():
		return {"indicators": {}}
	var character_id: int = int(character.get("id", -1))
	var out: Dictionary = {}
	for npc: Variant in npcs:  # T-754: the npcs Array is wire-supplied; entries may be anything
		if not npc is Dictionary:
			continue
		var npc_id := str(npc.get("id", ""))
		var defs: Dictionary = RpcIntake.shaped(npc_quest_defs, npc_id, quest_defs)
		out[npc_id] = CharacterManager.npc_state_for_character(character_id, npc, defs)["indicator"]
	return {"indicators": out}


# T-043: turn in a quest + grant rewards atomically. Master computes objectives_complete from its
# own persisted progress; at_turnin_npc/item_registry are world-supplied. Returns {ok, reason, ...}.
func _turn_in(
	username: String,
	quest: Dictionary,
	at_turnin_npc: bool,
	item_registry: Dictionary,
	date_key: String,
	quest_defs: Dictionary
) -> Dictionary:
	var character: Dictionary = CharacterManager.get_character(username)
	if character.is_empty():
		return {"ok": false, "reason": "unknown_character"}
	var character_id: int = int(character.get("id", -1))
	var objectives_complete: bool = CharacterManager.objectives_complete(character_id, quest)
	var result: Dictionary = CharacterManager.try_turn_in_with_rewards(
		character_id, quest, objectives_complete, at_turnin_npc, item_registry
	)
	if bool(result.get("ok", false)):
		var coins := int(quest.get("rewards", {}).get("coins", 0))
		if coins > 0:
			ServicesStore.adjust_coins(character_id, coins, "quest_reward")  # T-366: coin faucet
		result["coins"] = coins
		# T-058: provided quest items are quest-bound — they leave when the quest completes.
		CharacterManager.remove_provided_items(character_id, quest)
		var qid := str(quest.get("id", ""))  # T-367 achievements + T-536 mastery: server-observed
		AchievementStore.merge_into(result, AchievementStore.observe(character_id, "quest", qid))
		# T-679: roster-total quests, credited to the actor's current guild (no-op if guildless).
		KillCreditOps.credit_guild(result, character_id, "guild_quest", qid)
		AccountMastery.observe(username, character_id, "quest_complete", 1)
		RenownStore.observe(character_id, "quest_turnin", RenownStore.hub_for_quest(quest))
		TutorialOps.note_quest_completion(username, qid)  # T-426 funnel + T-550 account graduation
		var new_level := int(result.get("leveling", {}).get("level", 0))
		if new_level > 0:
			AchievementStore.merge_into(
				result, AchievementStore.observe(character_id, "level", "*", new_level)
			)
		var daily := DailyAppointmentStore.complete_quest(
			character_id, username, date_key, quest, quest_defs
		)
		result["daily"] = daily
		result["coins"] = int(result.get("coins", 0)) + int(daily.get("reward", {}).get("coins", 0))
	return result


# T-044: talk — credit active talk objectives for the NPC + return the !/? status. npc is the
# {id, gives_quests, talk_text} dict; quest_defs are world-supplied. Returns npc_talk's payload.
func _talk(username: String, npc: Dictionary, quest_defs: Dictionary) -> Dictionary:
	var character: Dictionary = CharacterManager.get_character(username)
	if character.is_empty():
		return {"credited": [], "talk_text": "", "indicator": "", "error": "unknown_character"}
	return CharacterManager.npc_talk(int(character.get("id", -1)), npc, quest_defs)


# T-044: abandon a quest. Returns {ok, reason} (try_abandon guards non-active).
func _abandon_quest(username: String, quest_id: String, quest: Dictionary) -> Dictionary:
	var character: Dictionary = CharacterManager.get_character(username)
	if character.is_empty():
		return {"ok": false, "reason": "unknown_character"}
	var character_id: int = int(character.get("id", -1))
	var result = CharacterManager.try_abandon(character_id, quest_id)
	if result.ok:
		# T-058: a quest's provided items leave with it.
		CharacterManager.remove_provided_items(character_id, quest)
	return {"ok": result.ok, "reason": result.reason}


# T-045: read the character's inventory. Returns {"slots": [...]}; empty if unknown.
func _get_inventory(username: String) -> Dictionary:
	var character: Dictionary = CharacterManager.get_character(username)
	if character.is_empty():
		return {"slots": []}
	var cid := int(character.get("id", -1))
	return {"slots": WardrobeOps.decorate_slots(cid, CharacterManager.get_inventory(cid))}


# T-650: gather/craft mint or consume-and-produce items master-side (CraftOps) but — unlike
# equip/unequip/drop, which all route through _inventory_change's collect refresh below — never
# told CharacterManager an inventory change happened. A player gathering or crafting a collect
# quest's target item saw it land in the bag while the tracker stayed at 0. Mirrors
# _inventory_change's refresh, keyed off the same "quest_defs" param the world already sends on
# every other credited op (equip/unequip/drop/credit_kill/...). use_item_op/recipe_op are excluded:
# neither ever ADDS a bag item (use_item only removes; recipe_op only grants recipe knowledge and
# debits coins), so there is no gap for a collect objective to miss there.
func _credit_collect_for_craft(params: Dictionary, result: Dictionary) -> void:
	if not bool(result.get("ok", false)):
		return
	var character: Dictionary = CharacterManager.get_character(str(params.get("username", "")))
	if character.is_empty():
		return
	result["collect_refreshed"] = CharacterManager.refresh_collect_for_character(
		int(character["id"]), RpcIntake.shaped(params, "quest_defs", {})
	)


# T-045: a server-validated inventory change (T-036 try_*) + a collect refresh on success.
# Returns the try_* result ({ok, reason, slots}) plus collect_refreshed.
func _inventory_change(username: String, op: Callable, quest_defs: Dictionary) -> Dictionary:
	var character: Dictionary = CharacterManager.get_character(username)
	if character.is_empty():
		return {"ok": false, "reason": "unknown_character"}
	var character_id: int = int(character.get("id", -1))
	var result: Dictionary = op.call(character_id)
	if result["ok"]:
		result["collect_refreshed"] = CharacterManager.refresh_collect_for_character(
			character_id, quest_defs
		)
		result["slots"] = WardrobeOps.decorate_slots(character_id, result.get("slots", []))
	return result


func _equip(
	username: String, bag_slot: int, item_registry: Dictionary, quest_defs: Dictionary
) -> Dictionary:
	var result := _inventory_change(
		username,
		func(cid): return CharacterManager.try_equip(cid, bag_slot, item_registry),
		quest_defs
	)
	# T-426: credit the tutorial "equip" verb for the item that was just equipped.
	if result.get("ok", false) and result.has("equipped_item"):
		var character: Dictionary = CharacterManager.get_character(username)
		if not character.is_empty():
			var credited: Dictionary = CharacterManager.credit_event(
				int(character.get("id", -1)), "equip", str(result["equipped_item"]), quest_defs
			)
			result["equip_credited"] = credited.get("credited", [])
	return result


func _unequip(username: String, equip_slot: String, quest_defs: Dictionary) -> Dictionary:
	return _inventory_change(
		username, func(cid): return CharacterManager.try_unequip(cid, equip_slot), quest_defs
	)


func _drop(
	username: String, slot_type: String, slot_index: int, count: int, quest_defs: Dictionary
) -> Dictionary:
	return _inventory_change(
		username,
		func(cid): return CharacterManager.try_remove_item(cid, slot_type, slot_index, count),
		quest_defs
	)


func _json_resp(id: String, payload: Dictionary) -> String:
	return RpcIntake.encode_response(id, payload)  # T-754 carve: envelope codec lives together


func _exit_tree() -> void:
	_running = false
	for ws_key in _peers:
		var ws: WebSocketPeer = _peers[ws_key]
		ws.close()
	_peers.clear()
	if _server != null:
		_server.stop()
	print("[master] shut down")


# ---- T-208: Highkeep services ------------------------------------------------
# Shapes: vault_op {username, action: list|move, from_type?, from_index?}
#         auction_op {username, action: browse|list|bid|buyout, ...}
#         trainer_op {username, action: catalog|train, service, ability_id?}


func _services_char(username: String) -> Dictionary:
	CharacterManager.ensure_character(username)
	return CharacterManager.get_character(username)


func _trainer_op(params: Dictionary) -> Dictionary:
	var character := _services_char(str(params.get("username", "")))
	if character.is_empty():
		return {"error": "unknown_character"}
	var cid := int(character["id"])
	# T-715: `service` also decides WHICH TIER is on sale here (the starter tag = L2 only).
	var service := str(params.get("service", ""))
	var char_class := str(character.get("class", ""))
	var trainer_class := TrainerLogic.class_for_service(service, char_class)
	if trainer_class == "" or trainer_class != char_class:
		return {"error": "wrong_class"}
	if str(params.get("action", "catalog")) == "train":
		var check := TrainerLogic.can_train(
			trainer_class,
			int(character.get("level", 1)),
			ServicesStore.get_coins(cid),
			int(params.get("ability_id", 0)),
			ServicesStore.get_unlocked_abilities(cid),
			service
		)
		if not bool(check.get("ok", false)):
			return {"error": str(check.get("reason", "cannot_train"))}
		ServicesStore.adjust_coins(cid, -int(check["cost"]), "trainer")  # T-366: coin sink
		ServicesStore.grant_ability(cid, int(params.get("ability_id", 0)))
	return {
		"catalog": TrainerLogic.catalog_for(trainer_class, service),
		"unlocked": ServicesStore.get_unlocked_abilities(cid),
		"coins": ServicesStore.get_coins(cid),
	}
