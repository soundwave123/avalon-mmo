extends Node

# T-048: client root (/root/Main mirrors the world's path so @rpc maps). This node IS the transport
# (ENet + @rpc), delegating to ClientNet + HudHandlers; the client sends INTENTS only.

const ClientNet = preload("res://scripts/net/client_net.gd")
const GatewayLogin = preload("res://scripts/net/gateway_login.gd")
const HarnessProbe = preload("res://scripts/net/harness_probe.gd")  # T-494 carve: smoke/result
const HudHandlers = preload("res://scripts/net/hud_handlers.gd")
const LoadPhases = preload("res://scripts/ui/load_phases.gd")  # T-691: phase bus + loading gate
const ServerConnectionConfig = preload("res://scripts/net/server_connection_config.gd")
const TargetSelection = preload("res://scripts/world/target_selection.gd")
const InteriorGate = preload("res://scripts/world/interior_gate.gd")
const CryptGate = preload("res://scripts/world/crypt_gate.gd")
const RiftGate = preload("res://scripts/world/rift_gate.gd")  # T-347: era-rift monolith trigger
const DeathPresentation = preload("res://scripts/ui/death_presentation.gd")  # T-506 local feedback
const HudPanelSweep = preload("res://scripts/ui/hud_panel_sweep.gd")  # T-576: open-panels sweep
const _WEEKLY_PANEL = preload("res://scripts/ui/weekly_panel.gd")  # T-480 weekly vault (J)
const _NET_TIMEOUT := 15.0
const PARTY_RANGE_M := 40.0  # T-285: party-frame dim threshold (distance from the local player)
const READY_MARKER_RADIUS := 6.0  # T-334: "at the crypt stair" ready marker (vs CryptGate porch)
const _INDOOR_CHECK_HZ := 5.0  # T-187: rain/ambience gating doesn't need per-frame precision
# T-343 phase 2: frost bolt (id 204) gets its own Sub-Zero VFX + icy SFX. Mirrors VfxManager const.
const FROSTBOLT_ABILITY_ID := 204
var world_view: WorldView = null  # T-053: the 3D world (ground/lighting/third-person camera)
var combat_feedback: CombatFeedback = null
var player_hud: PlayerHud = null  # T-308: vitals (HP + class resource) + action bar + compass
var death_presentation = null  # T-506: grayscale/death copy/respawn fade + input mirror
var quest_log_panel: QuestLogPanel = null  # T-038
var inventory_panel: InventoryPanel = null  # T-039
var item_tooltip: ItemTooltip = null  # T-233: hover-an-item tooltip (name/slot/stats/value)
var player_cast_bar: PlayerCastBar = null  # T-265: your own centered cast bar
var party_frames: PartyFrames = null  # T-285: stacked party-member frames (left side)
var talent_panel: TalentPanel = null  # T-065
var class_panel: ClassPanel = null  # T-065
var gender_panel: GenderPanel = null  # T-520: gender selection, shown before class at creation
var settings_panel: SettingsPanel = null  # T-078: Esc options menu (video / audio / controls)
var service_panel: ServicePanel = null  # T-145: stub service-hub panel (bank/vendor/inn/flight)
var character_sheet_panel: CharacterSheetPanel = null  # T-295: primaries + derived stats (C)
var chat_panel: ChatPanel = null  # T-361: player chat — say/party tabs, Enter to type
var social_ui: SocialUi = null  # T-363/T-361: trade window + friends panel (built by SocialUi)
var achievement_ui: AchievementUi = null  # T-367: achievements panel + earn toast
var pvp_panel: PvpPanel = null  # T-401: PvP panel (P) — rating/honor/tracks/titles via reply hub
var xp_bar: XpBar = null  # T-060
var npc_markers: NpcMarkersLayer = null  # T-048: quest-giver !/? markers (world-space)
var local_player: LocalPlayer = null  # T-054: the player you control
var remote_entities: RemoteEntitiesLayer = null  # T-055: other players + mobs (interpolated)
var npc_world: NpcWorldLayer = null  # T-056: NPC bodies + !/? billboards (clickable → talk)
var audio: AudioManager = null  # T-111: looping meadow ambience + one-shot SFX
var ambient_fx: AmbientFxLayer = null  # T-139: pollen motes + chimney smoke + campfire embers
var music_bed: MusicBedLayer = null  # T-416: per-zone music score beds (own "Music" bus)
var world_props: WorldPropsLayer = null  # T-081/T-187: placed props + derived interior volumes
var interior_gate := InteriorGate.new()  # T-187: indoor tracker driving rain/ambience gating
var crypt_gate := CryptGate.new()  # T-330: churchyard-stair threshold trigger
var rift_gate := RiftGate.new()  # T-347: Vault-monolith era-rift threshold trigger
var vfx: VfxManager = null  # T-110: spell/combat one-shot bursts (cast / impact / heal)
var party_members: Array = []  # T-280: usernames in my party (empty = solo)
var party_leader: String = ""  # T-280: leader username
var party_subgroups: Dictionary = {}  # T-472: username -> raid subgroup (empty = plain party)
var lfg_board: Array = []  # T-334: last lfg_board reply (pilot/E2E truth; board panel deferred)
var last_positions: Dictionary = {}  # T-334: last positions payload (pilot/E2E instance truth)
var level_up_ui: LevelUpUi = null  # T-635: level-up celebration (banner+flash+chat+T-111 sting)
var _indoor_check_accum := 0.0  # T-187: throttles the rain/ambience indoor check (see below)
var _onboarding = preload("res://scripts/ui/onboarding_controller.gd").new()  # T-376: controls card
var _net = null  # ClientNet
var _enet: ENetMultiplayerPeer = null
var _token: String = ""
# T-514: build stamp reported at the world handshake (gateway checks it at login too).
var _client_build := ServerConnectionConfig.resolve_build(
	OS.get_executable_path(), OS.get_environment("AVALON_CLIENT_BUILD")
)
var _connected: bool = false
var _world_built: bool = false  # T-494: false until login succeeds; gates HUD build + world hotkeys
var _my_peer_id: int = 0  # T-054: our ENet peer id (to pick our own position out of the broadcast)
var _own_cast: Dictionary = {}  # T-264: latest own cast payload from the broadcast
var _party_prompt = preload("res://scripts/net/party_invite_prompt.gd").new()  # T-598: invite UI
var _awaiting: bool = false  # true while the connect→handshake(→smoke reply) phase is in flight
var _smoke: bool = false
var _accept_ok: bool = false  # smoke: accept_quest reply
var _observe: bool = false  # AVALON_OBSERVE: headless two-client harness hook — stay alive, watch
var _observe_probe = preload("res://scripts/dev/observe_probe.gd").new()  # T-361: extracted
var _reply_router = preload("res://scripts/net/reply_router.gd").new()  # T-401: routed-reply hub
var _recovery = preload("res://scripts/net/connection_recovery.gd").new()  # T-511 reasoned login
var _awaiting_indicators: bool = false  # smoke: waiting for the npc_indicators reply → markers
var _result_file: String = ""
var _elapsed: float = 0.0
var _refresh_timer: Timer = null  # T-056: debounce quest-log/indicator refreshes (avoid a flood)
var _target_id: int = -1  # T-057: current combat target (peer_id or mob_id)
var _kit: Array = []  # T-063: the player's class ability kit (from the server's class_kit message)
var _autoattack: bool = false  # T-057: auto-attack toggle — Strike on the GCD while a target is set
var _attack_timer: Timer = null
var _cast_queue := AbilityCastQueue.new()  # T-721: press ledger + server-verdict account
var _panel_set: Array = []  # T-571: Esc-close-first (#28) / recap-yield (#27) candidate panels
var _recap_panel: PerformanceRecapPanel = null  # T-576: OUT of _panel_set (that set's #27 watcher)
var _creation: CreationFlow = null  # T-520/T-716: owns the gender→class→name modals + latches


func _ready() -> void:
	print("[client] Avalon client starting up")

	# Dev-only capture harnesses, each of which bypasses boot entirely and quits on its own:
	# T-121 asset review (one GLB from many angles) · T-343 frost-bolt VFX gallery (one
	# AVALON_VFX_PRESET as a mage casts) · prop showroom (props in a row at real scale to judge).
	for probe in [
		["AVALON_REVIEW_GLB", "AssetReview", preload("res://scripts/dev/asset_review.gd")],
		["AVALON_VFX_GALLERY", "VfxGallery", preload("res://scripts/dev/vfx_gallery.gd")],
		["AVALON_SHOWROOM", "PropShowroom", preload("res://scripts/dev/prop_showroom.gd")],
	]:
		if OS.get_environment(str(probe[0])) != "":
			var dev: Node = (probe[2] as GDScript).new()
			dev.name = str(probe[1])
			add_child(dev)
			return

	# T-494: boot routes through the gateway login FIRST — no HUD/world/hotkeys build until a token
	# exists, so nothing renders or fires behind the login (a real modal gate, not a translucent one).
	_setup_networking()


# T-494: build the 3D world + full HUD, then continue the handshake. Runs once, only after auth (env
# AVALON_TOKEN or a gateway login). Until it runs, _world_built is false and input handlers no-op.
func _enter_world() -> void:
	if _world_built:
		return
	_world_built = true
	await LoadPhases.cut(self, "world")  # T-691: paint the loading screen before the terrain block

	# T-053: the 3D world (gray-box ground + lighting + third-person camera), built in code.
	world_view = WorldView.new()
	world_view.name = "WorldView"
	add_child(world_view)

	# T-111: the world's sound — looping meadow ambience + a one-shot SFX pool (audio.play_sfx).
	audio = AudioManager.new()
	audio.name = "AudioManager"
	add_child(audio)

	# T-055: layer that renders/interpolates other players + mobs from the positions broadcast.
	remote_entities = RemoteEntitiesLayer.new()
	remote_entities.name = "RemoteEntities"
	world_view.add_child(remote_entities)

	# T-081: world dressing (GLB houses/trees). T-187: also the source of derived interior volumes.
	await LoadPhases.cut(self, "props")  # T-691: manifest + GLB pin seam (the big decode block)
	world_props = WorldPropsLayer.new()
	world_props.name = "WorldProps"
	world_view.add_child(world_props)

	# T-056: NPC bodies + !/? billboards in the world; click a body to talk.
	npc_world = NpcWorldLayer.new()
	npc_world.name = "NpcWorld"
	world_view.add_child(npc_world)
	get_viewport().physics_object_picking = true  # required for CollisionObject3D.input_event clicks

	# T-139: ambient particle FX (pollen motes, chimney smoke, campfire embers + firelight).
	ambient_fx = AmbientFxLayer.new()
	ambient_fx.name = "AmbientFx"
	world_view.add_child(ambient_fx)

	# T-416: per-zone MUSIC score beds on their own "Music" bus (crossfades between zone regions).
	music_bed = MusicBedLayer.new()
	music_bed.name = "MusicBed"
	world_view.add_child(music_bed)

	# T-110: spell/combat VFX bursts (cast/impact/heal), fired from the combat handlers.
	vfx = VfxManager.new()
	vfx.name = "Vfx"
	world_view.add_child(vfx)

	await LoadPhases.cut(self, "hud")  # T-691: interface build seam
	combat_feedback = CombatFeedback.new()
	combat_feedback.name = "CombatFeedback"
	$HUD.add_child(combat_feedback)
	combat_feedback.set_overlays_enabled(false)  # T-057: 3D health bars + log, not the 2D overlays

	# T-308: always-on combat HUD — health/resource bars, kit action bar, compass. Fed from _on_*.
	player_hud = PlayerHud.new()
	player_hud.name = "PlayerHud"
	$HUD.add_child(player_hud)
	death_presentation = DeathPresentation.new()
	death_presentation.name = "DeathPresentation"
	$HUD.add_child(death_presentation)
	death_presentation.setup(combat_feedback.get_combat_log())

	quest_log_panel = QuestLogPanel.new()
	quest_log_panel.name = "QuestLogPanel"
	$HUD.add_child(quest_log_panel)

	inventory_panel = InventoryPanel.new()
	inventory_panel.name = "InventoryPanel"
	$HUD.add_child(inventory_panel)

	# T-233: hover an item -> slot/stats/value; T-422e also feeds worn gear for +/- vs-equipped deltas.
	item_tooltip = ItemTooltip.new()
	item_tooltip.name = "ItemTooltip"
	$HUD.add_child(item_tooltip)
	inventory_panel.item_hover_started.connect(func(item): item_tooltip.show_for(item))
	inventory_panel.item_hover_ended.connect(func(): item_tooltip.hide_tooltip())
	inventory_panel.equipment_changed.connect(func(eq): item_tooltip.set_equipment(eq))

	# T-265: your own cast bar, centered under the HUD, fed each frame from _own_cast.
	player_cast_bar = PlayerCastBar.new()
	player_cast_bar.name = "PlayerCastBar"
	$HUD.add_child(player_cast_bar)

	# T-285: party frames (stacked left side); click a member to target them.
	party_frames = PartyFrames.new()
	party_frames.name = "PartyFrames"
	party_frames.member_clicked.connect(_on_entity_clicked)
	$HUD.add_child(party_frames)

	# T-065: talent tree. T-520/T-716: the creation sequence (gender → class → name) mounts its own
	# three modals (T-716 carve — main.gd sits at the 1000-line cap) and hands back the two handles
	# the rest of this file still needs.
	talent_panel = TalentPanel.new()
	talent_panel.name = "TalentPanel"
	$HUD.add_child(talent_panel)
	_creation = CreationFlow.mount($HUD)
	class_panel = _creation.class_panel
	gender_panel = _creation.gender_panel

	xp_bar = XpBar.new()  # T-060: level + XP progress bar
	xp_bar.name = "XpBar"
	$HUD.add_child(xp_bar)
	level_up_ui = LevelUpUi.mount($HUD, player_hud)  # T-635: banner+flash+chat celebration

	# T-308: dress the XP belt in the shared theme (it sits outside PlayerHud's subtree).
	if player_hud != null and player_hud.theme != null:
		xp_bar.theme = player_hud.theme

	# T-640: character window (paperdoll + sectioned stats), toggled C. mount() idiom (main.gd sits
	# at its 1000-line cap) moves the old 6-line wiring block into the panel as a single call.
	character_sheet_panel = CharacterSheetPanel.mount($HUD, item_tooltip, inventory_panel)

	# T-078: the WoW-style Esc options menu. setup() re-applies saved user://settings.cfg on boot.
	settings_panel = SettingsPanel.new()
	settings_panel.name = "SettingsPanel"
	$HUD.add_child(settings_panel)
	settings_panel.setup(world_view, audio)

	# T-145: stub service-hub panel (opens on a talk_result `service` tag); buttons ride ClientNet.
	service_panel = ServicePanel.new()
	service_panel.name = "ServicePanel"
	$HUD.add_child(service_panel)
	service_panel.setup(func(npc_id, action): _net.service_intent(npc_id, action))
	service_panel.setup_ex(func(n, a, e): _net.service_intent(n, a, e))
	service_panel.setup_accept(func(quest_id): _net.accept_quest(quest_id))  # T-293: bounty pickup
	QuestOfferPanel.mount($HUD, func(): return _net)  # T-519: quest-giver → offer/turn-in prompt

	# T-361: player chat, on the shared theme; send rides transport. T-607: the combat log is bound
	# INTO this same surface (no more standalone CombatLogPanel racing it for the same rect).
	chat_panel = ChatPanel.new()
	chat_panel.name = "ChatPanel"
	$HUD.add_child(chat_panel)
	if player_hud != null and player_hud.theme != null:
		chat_panel.theme = player_hud.theme
	chat_panel.setup(func(intent: Dictionary): _send_to_server(intent))  # chat OR /emote (T-361)
	if combat_feedback != null:
		chat_panel.bind_combat_log(combat_feedback.get_combat_log())  # T-607: merged combat channel
	# T-363/T-361: trade + friends panels; sends ride the generic transport (client_net at its cap).
	social_ui = SocialUi.new(
		$HUD, player_hud, func(m): _send_to_server(m), func(): return chat_panel.is_typing()
	)
	achievement_ui = AchievementUi.new(
		$HUD, player_hud, func(m): _send_to_server(m), func(): return chat_panel.is_typing()
	)  # T-367: achievements panel (Y) + earn toast
	# T-401: PvP panel (P). Self-carries its theme; self-registers its reply types on _reply_router.
	pvp_panel = PvpPanel.new()
	pvp_panel.name = "PvpPanel"
	$HUD.add_child(pvp_panel)
	pvp_panel.setup(
		func(m): _send_to_server(m), func(): return chat_panel.is_typing(), _reply_router
	)
	player_hud.spellbook.setup(func(): return chat_panel.is_typing())  # T-422b: chat-gated B toggle
	player_hud.action_bar.layout_changed.connect(func(ids): _net._set_bar_layout(ids))  # T-422c drag

	var craft_send := func(m): _send_to_server(m)
	var craft_typing := func(): return chat_panel.is_typing()
	CraftingUi.mount(
		$HUD, world_view, craft_send, craft_typing, _reply_router, combat_feedback.get_combat_log()
	)
	var wardrobe := WardrobePanel.mount($HUD, craft_send, craft_typing, _reply_router)
	var shop := CosmeticShopPanel.mount($HUD, craft_send, craft_typing, _reply_router)
	var mail := MailPanel.mount($HUD, func(n, a, e): _net.service_intent(n, a, e), service_panel)
	_panel_set = [quest_log_panel, inventory_panel, talent_panel, character_sheet_panel]
	_panel_set += [service_panel, player_hud.spellbook, wardrobe, shop, social_ui.guild_panel, mail]
	_panel_set.append(social_ui.lfg_panel)  # T-625: LFG board joins the Esc-close / recap-yield sweep
	_recap_panel = PerformanceRecapPanel.mount($HUD, craft_send, craft_typing, _reply_router)
	_recap_panel.watch_panels(_panel_set)  # #27
	PerformanceRecapPanel.wire_autopop_gate(_recap_panel, self)  # #79: no auto-pop mid-pull
	var weekly_panel: Control = _WEEKLY_PANEL.new()  # T-480 weekly vault (J)
	$HUD.add_child(weekly_panel)
	weekly_panel.setup(craft_send, craft_typing, _reply_router)
	# T-376 handbook; T-558/T-714 whole-sequence creation gate; T-710/T-711 guided-onboarding seams.
	_onboarding.setup($HUD, class_panel, gender_panel, _creation)
	_onboarding.bind_guide(
		player_hud, func(): return local_player, func(): return [_autoattack, _target_id]
	)
	# T-048 marker logic, superseded by the 3D NpcWorld (T-056); kept hidden as the net-smoke tracker.
	npc_markers = NpcMarkersLayer.new()
	npc_markers.name = "NpcMarkers"
	npc_markers.visible = false
	add_child(npc_markers)

	# T-075: agent pilot (screenshots + scripted input) — dev-only, env-gated.
	if OS.get_environment("AVALON_PILOT") == "1":
		var pilot: Node = preload("res://scripts/dev/pilot.gd").new()
		pilot.name = "Pilot"
		add_child(pilot)


func _setup_networking(token_override := "", host_override := "", port_override := 0) -> void:
	_token = token_override if token_override != "" else OS.get_environment("AVALON_TOKEN")
	var host := ServerConnectionConfig.resolve_runtime_host(
		host_override, OS.get_executable_path(), OS.get_environment("AVALON_HOST")
	)
	if _token == "":
		if DisplayServer.get_name() == "headless":
			print("[client] offline — no AVALON_TOKEN; nothing to connect to")
			get_tree().quit.bind(0).call_deferred()
			return
		# T-494: the login form is the only thing on screen; the HUD is built on success.
		GatewayLogin.new().mount($HUD, host, func(t, p): _setup_networking(t, host, p))
		return

	# T-691 gate, FIRST login only (a reconnect's world phases never fire -> it could never dismiss)
	await LoadPhases.boot_screen($HUD if not _world_built else null)
	await _enter_world()  # T-494: authenticated — now build the world + HUD before the handshake
	_smoke = OS.get_environment("AVALON_NET_SMOKE") == "1"
	_onboarding.begin(_token, _smoke)  # T-376: per-user onboarding key + harness-run guard
	_observe = OS.get_environment("AVALON_OBSERVE") == "1"  # two-client harness: watch remote entities
	if OS.get_environment("AVALON_OBSERVE_SECS") != "":
		_observe_probe.setup(float(OS.get_environment("AVALON_OBSERVE_SECS")))
	_result_file = OS.get_environment("AVALON_RESULT_FILE")
	_net = ClientNet.new()
	var handlers: Dictionary = HudHandlers.build(
		quest_log_panel, inventory_panel, combat_feedback, npc_markers
	)
	handlers["positions"] = func(d): _on_positions(d)  # T-054: reconcile the local player
	handlers["npc_indicators"] = func(d): _on_npc_indicators(d)  # T-056: feed 2D count + 3D world
	handlers["combat"] = func(d): _on_combat(d)  # T-057: feedback + refresh quests on a kill
	handlers["class_kit"] = func(d): _on_class_kit(d)  # T-063: the player's class ability kit
	handlers["talents"] = func(d): talent_panel.render(d)  # T-065: talent state -> tree UI
	handlers["player_stats"] = func(d): _on_player_stats(d)  # T-060 XP HUD + T-635 levelup celebration
	handlers["quest_delta"] = func(d): _on_quest_delta(d)  # T-058: targeted pushes
	handlers["party_invite"] = func(d): _party_prompt.show(chat_panel, str(d.get("from", "")))
	handlers["party_update"] = func(d): _on_party_update(d)  # T-280
	handlers["party_result"] = func(d): _party_prompt.on_result(d)  # T-598
	handlers["lfg_board"] = func(d): lfg_board = social_ui.on_lfg(d)  # T-334/T-625: panel + pilot var
	handlers["chat"] = func(d): _on_chat(d)  # T-361: relayed chat + rejections → the chat panel
	handlers["trade"] = func(d): social_ui.on_trade(d)  # T-363: server-fed trade window
	handlers["social"] = func(d): social_ui.on_social(d)  # T-361: friends/ignore lists
	handlers["achievements"] = func(d): achievement_ui.on_achievements(d)  # T-367: panel feed + toast
	handlers["pvp"] = func(d): _reply_router.route(d)  # T-401: routed-reply hub (PvP panel + future)
	handlers["result"] = _wire_result_handler(handlers["result"])  # T-578: chain, don't overwrite
	# T-426: first-item-in-bag contextual hint rides the existing inventory render (fire-once).
	var render_inventory: Callable = handlers["inventory"]
	handlers["inventory"] = func(d):
		render_inventory.call(d)
		if not (d.get("slots", []) as Array).is_empty():
			_onboarding.hint("bag_item")
	if player_cast_bar != null:  # T-426: first interrupted cast teaches "moving cancels casting"
		player_cast_bar.interrupted.connect(func(): _onboarding.hint("interrupt"))
	_net.setup(func(m): _send_to_server(m), handlers)
	# T-056: debounced refresh — a burst of quest results coalesces into ONE log+indicator re-request.
	_refresh_timer = Timer.new()
	_refresh_timer.one_shot = true
	_refresh_timer.wait_time = 0.3
	_refresh_timer.timeout.connect(_do_quest_refresh)
	add_child(_refresh_timer)
	# T-057: auto-attack timer (Strike on the GCD) + click-to-target.
	_attack_timer = Timer.new()
	_attack_timer.wait_time = 1.6  # ~GCD; the server harmlessly rejects an early cast
	_attack_timer.timeout.connect(_on_attack_tick)
	add_child(_attack_timer)
	add_child(_cast_queue)  # T-721: press ledger (surfaced via the pilot's observe())
	remote_entities.entity_clicked.connect(_on_entity_clicked)
	npc_world.npc_clicked.connect(_on_npc_clicked)  # T-056: click an NPC → talk intent
	# T-056 pass 2: clicked quest-log / inventory action links → the matching intent.
	quest_log_panel.action_selected.connect(func(meta): PanelActions.dispatch(_net, meta))
	# T-461/T-710: the quest log's active-objective state renders the always-on HUD tracker via the
	# controller (which injects the pre-accept tutorial line and feeds the T-711 stall clock).
	quest_log_panel.objectives_changed.connect(func(m): _onboarding.on_objectives(m))
	inventory_panel.action_selected.connect(func(meta): PanelActions.dispatch(_net, meta))
	talent_panel.action_selected.connect(func(meta): PanelActions.dispatch(_net, meta))
	_creation.connect_actions(func(meta): PanelActions.dispatch(_net, meta))  # T-520/T-716
	character_sheet_panel.action_selected.connect(func(m): PanelActions.dispatch(_net, m))  # T-640

	var port_env: String = OS.get_environment("AVALON_PORT")
	var port: int = (
		port_override if port_override > 0 else (int(port_env) if port_env != "" else 9200)
	)

	await LoadPhases.cut(self, "connect")  # T-691: ENet connect + world handshake seam
	_enet = ENetMultiplayerPeer.new()
	var err: int = _enet.create_client(host, port)
	if err != OK:
		_fail("create_client err=%d" % err)
		return
	var mp := get_tree().get_multiplayer()
	mp.multiplayer_peer = _enet
	mp.connected_to_server.connect(_on_connected)
	mp.connection_failed.connect(func(): _recovery.recover(self, {}))  # T-716 carve
	mp.server_disconnected.connect(_on_server_disconnected)
	_awaiting = true
	print("[client] connecting to world enet://%s:%d" % [host, port])


func _process(delta: float) -> void:
	if player_cast_bar != null:  # T-265: drive your cast bar every frame (smooth local fill)
		player_cast_bar.update_cast(_own_cast, delta)
		# T-503: the frostbolt CHARGE layer follows the cast bar — a rising icy drone while the
		# frostbolt bar is active, ramped up as it fills, stopped the instant it clears (completion,
		# a different spell, or an interrupt). Self-correcting off bar state, so no edge cases.
		if audio != null:
			if player_cast_bar.is_active() and player_cast_bar.ability_id() == FROSTBOLT_ABILITY_ID:
				audio.start_charge()
				audio.set_charge_progress(player_cast_bar.fill_ratio())
			elif audio.is_charging():
				audio.stop_charge()
	# T-308: compass tracks look-yaw (local_player.rotation.y; yaw 0 = north) — relabels on flip.
	if player_hud != null and local_player != null:
		player_hud.update_heading(local_player.rotation.y)
	# T-187: indoor gating — rain/ambience muffle, hysteresis-smoothed + throttled (T-310 tick).
	if local_player != null and world_props != null:
		_indoor_check_accum += delta
		if _indoor_check_accum >= 1.0 / _INDOOR_CHECK_HZ:
			_indoor_check_accum = 0.0
			var changed := interior_gate.update_position(
				local_player.global_position, world_props.interior_volumes
			)
			if changed:
				if world_view != null:
					world_view.set_rain_suppressed(interior_gate.is_indoors())
				if audio != null:
					audio.set_indoor_muffle(interior_gate.is_indoors())
				# T-330: crypt-stair threshold — fire enter/leave_instance on a crossing (sent via
				# _send_to_server, not a capped ClientNet method; instance_service handles both types).
				var pp := local_player.global_position
				var crypt_intent := crypt_gate.update(Vector2(pp.x, pp.z))
				if crypt_intent != "":
					_send_to_server({"type": crypt_intent})
			# T-347: rift threshold — the crypt Vault monolith teleports to Ashmoor (100y on), the
			# arrival monolith returns (dev). Server (instance_service.enter_era/leave_era) owns the move.
			var rp := local_player.global_position
			var rift_intent := rift_gate.update(Vector2(rp.x, rp.z))
			if rift_intent != "":
				_send_to_server({"type": rift_intent})
			# T-351: §11 per-era presentation re-skin (Ashmoor -> era 2) — ability VFX + held focus.
			EraSkin.update(rp, vfx, local_player, world_view)
	if _observe:
		_observe_tick(delta)
		return
	if not _awaiting:
		return
	# Smoke: the npc_indicators reply has landed once the marker layer is populated.
	if _awaiting_indicators and npc_markers.marker_count() > 0:
		HarnessProbe.finish(self)
		return
	_elapsed += delta
	if _elapsed > _NET_TIMEOUT:
		_fail("timeout after %.0fs" % _NET_TIMEOUT)


func _on_connected() -> void:
	_connected = true
	_my_peer_id = get_tree().get_multiplayer().get_unique_id()
	combat_feedback.local_player_id = _my_peer_id  # T-057: flash only when WE take damage
	print("[client] connected; sending session handshake")
	_send_to_server({"type": "session", "token": _token, "build": _client_build})


func _on_server_disconnected() -> void:
	var notice := chat_panel.disconnect_notice() if chat_panel != null else {}
	_recovery.recover(self, notice)


# Server → client. Handshake replies gate readiness; all else routes through ClientNet to the HUD.
@rpc("any_peer", "reliable")
func _receive_client_message(data: Dictionary, _mirror: bool = false) -> void:
	# T-074: only the SERVER (peer 1) may drive client state (default relay = spoofable broadcasts).
	if get_tree().get_multiplayer().get_remote_sender_id() != 1:
		return
	match str(data.get("type", "")):
		"handshake_ok":
			print("[client] handshake_ok — world ready")
			_onboarding.set_return_reason_state(data.get("daily", {}))
			# T-550: seed ACCOUNT onboarding (tutorial-skip + hints); report sightings server-side.
			_onboarding.begin_account(data.get("account_onboarding", {}), _send_to_server)
			_on_world_ready()
		"handshake_err":
			_fail("handshake_err: %s" % str(data.get("reason", "")))
		_:
			_net.handle_server_message(data)


# Both server→client RPC channels must route to ClientNet (a past no-op silently dropped positions).
@rpc("any_peer", "reliable")
func _receive_message(data: Dictionary, _mirror: bool = false) -> void:
	# T-074: only the SERVER (peer 1) may drive client state (default relay = spoofable broadcasts).
	if get_tree().get_multiplayer().get_remote_sender_id() != 1:
		return
	if _net != null:
		_net.handle_server_message(data)


func _on_world_ready() -> void:
	LoadPhases.cut_now("snapshot")  # T-691: handshake done — wait on the first own-position row
	_spawn_local_player()
	if _smoke:
		return  # T-603: HarnessProbe walks to the giver + accepts on the first positions broadcast
	_awaiting = false
	_net._report_boot_timing()  # T-705: launch→login→interactive, one event now we have control
	_onboarding.on_world_ready()  # T-426/T-550 fresh-account move nudge + T-711 stall clock
	_net.request_quest_log()
	_net.get_inventory()
	_net.request_npc_indicators()
	if DisplayServer.get_name() == "headless" and not _observe:
		get_tree().quit.bind(0).call_deferred()  # nothing to drive without a display


# T-054: spawn the controllable player in the 3D world; its camera takes over from the preview one.
func _spawn_local_player() -> void:
	if local_player != null:
		return
	local_player = LocalPlayer.new()
	local_player.name = "LocalPlayer"
	local_player.setup(_net)
	local_player.set_typing_check(func(): return chat_panel != null and chat_panel.is_typing())
	local_player.set_gameplay_input_check(death_presentation.is_input_disabled)
	local_player.set_username(OnboardingPrefs.username_from_token(_token))  # T-127: per-username look
	world_view.add_child(local_player)


# T-280/T-472: party roster push (names + leader); raid push adds {username -> subgroup} for frames.
func _on_party_update(d: Dictionary) -> void:
	party_members = d.get("members", [])
	party_leader = str(d.get("leader", ""))
	party_subgroups = d.get("subgroups", {})


# T-361: relayed chat line (or a rejection) from the server → the chat panel.
func _on_chat(d: Dictionary) -> void:
	if chat_panel != null:
		chat_panel.receive(d)


func _on_positions(data: Dictionary) -> void:
	last_positions = data  # T-334: pilot/E2E reads instance-scoped broadcast truth from here
	HarnessProbe.move_to_giver_and_accept(self, data)  # T-603: smoke-only, self-gated no-op
	if remote_entities != null:
		remote_entities.ingest(data, _my_peer_id, Time.get_ticks_msec())
	# T-311: moving NPCs ride the positions stream — feed the world layer so it interpolates + walks.
	if npc_world != null and data.has("npcs"):
		npc_world.ingest_positions(data.get("npcs", []), Time.get_ticks_msec())
	# T-462: the HUD joins selected id -> authoritative name/level/live HP. A vanished row clears all
	# target state (selection ring + autoattack too), preserving the old death/out-of-interest rule.
	if player_hud != null and not player_hud.update_target(_target_id, _my_peer_id, data):
		_clear_target()
	_refresh_party_frames(data)  # T-285: keep party-member frames' health/range live
	if local_player == null:
		return
	for p: Dictionary in data.get("players", []):
		if int(p.get("peer_id", -1)) == _my_peer_id:
			# T-308: refresh the vitals frame (HP + class resource) from our own broadcast entry.
			if player_hud != null:
				player_hud.update_vitals(
					int(p.get("hp", 0)),
					int(p.get("max_hp", 0)),
					str(p.get("resource_kind", "none")),
					int(p.get("resource", 0)),
					int(p.get("max_resource", 0))
				)
			var sp := Vector3(
				float(p.get("x", 0.0)), float(p.get("y", 0.0)), float(p.get("z", 0.0))
			)
			local_player.apply_server_position(sp)
			LoadPhases.end("snapshot")  # T-691: first own row applied (bus dedupes repeats)
			local_player.apply_gear(p.get("gear", {}))  # T-225: see your own equipment
			character_sheet_panel.update_preview(p)  # T-640: paperdoll mirrors the same gear/class
			_own_cast = p.get("cast", {})  # T-264: own cast truth (bar renders in T-265)
			return


# AVALON_OBSERVE harness: track peak remote players/entities seen, then write a result + quit.
func _observe_tick(delta: float) -> void:
	var cam = local_player.camera if local_player != null else null
	if not _observe_probe.tick(delta, remote_entities, cam):  # ADR 0009 perception gate lives inside
		return
	var payload := _observe_probe.result()
	print("[OBSERVE] %s" % JSON.stringify(payload))
	if _result_file != "":
		var f := FileAccess.open(_result_file, FileAccess.WRITE)
		if f != null:
			f.store_string(JSON.stringify(payload))
			f.close()
	get_tree().quit.bind(0).call_deferred()


# T-056: npc_indicators feeds the hidden 2D layer (net-smoke count) + the 3D NpcWorld (visual).
# T-058: targeted pushes — apply the delta locally, no re-request (full refresh is the backstop).
func _on_quest_delta(data: Dictionary) -> void:
	match str(data.get("type", "")):
		"quest_delta":
			quest_log_panel.apply_delta(str(data.get("quest_id", "")), data.get("quest"))
		"npc_indicator_delta":
			var npcs: Array = data.get("npcs", [])
			npc_markers.apply_partial(npcs)
			npc_world.apply_partial(npcs)


func _on_npc_indicators(data: Dictionary) -> void:
	var npcs: Array = data.get("npcs", [])
	npc_markers.update(npcs)
	npc_world.update(npcs)
	_onboarding.on_npc_indicators(npcs)  # T-426 quest hint + T-710/T-711 giver pip anchor


# T-056: clicking an NPC body sends a talk intent (the server validates proximity + state).
func _on_npc_clicked(npc_id: String) -> void:
	if _net != null:
		_net.talk(npc_id)
		_send_to_server({"type": "recipe_catalog", "npc_id": npc_id})  # T-414: trainers → recipe panel


# T-057: combat events → CombatFeedback; a mob_death may credit a kill → refresh quests + markers.
func _on_combat(data: Dictionary) -> void:
	_cast_queue.on_combat_event(data)  # T-721: ledger sees every server verdict first
	combat_feedback.process_event(data)
	# T-060: 3D-native floating combat numbers off the hit entity.
	if str(data.get("type", "")) == "ability_result":
		var dmg_target_id := int(data.get("target_id", -1))
		# T-255: damage IN anchors on our own body (remote_entities never tracks the local player).
		if dmg_target_id == _my_peer_id and local_player != null:
			remote_entities.spawn_damage_number_at(
				local_player.global_position,
				int(data.get("damage", 0)),
				str(data.get("outcome", "hit"))
			)
		else:
			remote_entities.spawn_damage_number(
				dmg_target_id, int(data.get("damage", 0)), str(data.get("outcome", "hit"))
			)
		var abil_id := int(data.get("ability_id", -1))
		var is_frost_hit := abil_id == FROSTBOLT_ABILITY_ID
		var is_ranged := bool(data.get("ranged", false))  # T-350: gun-mob hitscan
		if audio != null and int(data.get("damage", 0)) > 0:  # T-111/T-343/T-350: shatter/gun/thud
			if is_ranged:  # T-350 §11.5 sound weight — the tommy burst reads heavier than the revolver
				audio.play_sfx(
					"tommy_burst" if data.get("weapon", "") == "tommy_burst" else "gun_shot", -6.0
				)
			else:  # T-343 p3: the school-voiced impact (frost keeps its money hit)
				AbilitySfx.play_impact(audio, abil_id)
				if is_frost_hit:  # T-503: the heavy hit ducks the score + ends any lingering charge
					audio.duck_music()
					audio.stop_charge()
		if int(data.get("heal", 0)) > 0:  # T-343 p3: a landed heal rings its warm chime (§11.5)
			AbilitySfx.play_heal(audio, abil_id)
		var tid := int(data.get("target_id", -1))
		var tnode: Node3D = remote_entities.target_node(tid) if remote_entities != null else null
		if vfx != null and tnode != null:
			var tpos: Vector3 = tnode.global_position
			if str(data.get("outcome", "")) == "heal" or int(data.get("heal", 0)) > 0:
				vfx.spawn_heal(tpos)
			elif is_ranged and int(data.get("damage", 0)) > 0:  # T-350: muzzle flash + tracer + impact
				vfx.spawn_gunshot(remote_entities.target_node(int(data.get("caster_id", -1))), tpos)
			elif int(data.get("damage", 0)) > 0:
				# T-343: frost bolt flash-freezes the victim (by ability id); else generic burst.
				vfx.spawn_impact_on(tpos, tnode, abil_id)
		# T-125: both belligerents square up — the caster turns to its target and (melee read) back.
		# Local player / unknown ids no-op inside the layer, so it's safe to call unconditionally.
		var cid := int(data.get("caster_id", -1))
		remote_entities.face_target(cid, tid)
		remote_entities.face_target(tid, cid)
		# T-123: attack on a landed swing/cast-completion, hit-react on damage taken. A "heal" outcome
		# skips the caster's attack pose (that finished a CAST, below). -1/unknown ids no-op in helper.
		if str(data.get("outcome", "hit")) != "heal":
			_trigger_actor_anim(cid, "shoot" if is_ranged else "attack")  # T-350: gun recoil, not a swing
		if int(data.get("damage", 0)) > 0:
			_trigger_actor_anim(tid, "hit")
	if str(data.get("type", "")) == "mob_death":
		if audio != null:  # T-111: enemy-defeated cue
			audio.play_sfx("defeat", -8.0)
		if _refresh_timer != null:
			_refresh_timer.start()
		remote_entities.trigger_action(int(data.get("mob_id", -1)), "death")  # T-123
	if str(data.get("type", "")) == "mob_respawn":  # T-123: alive again — clear the corpse pose
		remote_entities.trigger_action(int(data.get("mob_id", -1)), "respawn")
	if str(data.get("type", "")) == "player_death":
		var dead_peer := int(data.get("peer_id", -1))
		if dead_peer == _my_peer_id:
			_clear_target()
			if death_presentation != null:
				death_presentation.begin_death()
		_trigger_actor_anim(dead_peer, "death")
	if str(data.get("type", "")) == "player_respawn":  # T-123: clear the corpse pose
		var pid := int(data.get("peer_id", -1))
		if pid == _my_peer_id and local_player != null:
			_clear_target()  # T-554: re-clear on respawn (a late broadcast can re-bind the stale frame)
			if death_presentation != null:
				death_presentation.begin_respawn()
			local_player.reset_anim()
		else:
			remote_entities.trigger_action(pid, "respawn")
	if str(data.get("type", "")) == "cast_started" and local_player != null:
		local_player.trigger_action("cast")  # T-123: cast_started only goes to the caster (= us)
	# T-402/T-644: floating text throttled like log line to avoid blob.
	if str(data.get("type", "")) == "ability_rejected" and local_player != null:
		if (
			str(data.get("reason", "")) == "out_of_range"
			and combat_feedback.should_show_reject_feedback()
		):
			remote_entities.spawn_damage_number_at(local_player.global_position, 0, "out_of_range")
		elif player_hud != null:  # T-666: first-ever starved press → one-time resource hint
			_onboarding.on_ability_rejected(data, player_hud.action_bar._resource_kind)


# T-123: route an attack/hit/death trigger to the LOCAL player's state machine when the actor is
# us (remote_entities never tracks us), else by id; unknown/mob-vs-mob ids no-op — safe to call.
func _trigger_actor_anim(actor_id: int, event: String) -> void:
	if actor_id == _my_peer_id and local_player != null:
		local_player.trigger_action(event)
	elif remote_entities != null:
		remote_entities.trigger_action(actor_id, event)


# T-060/T-635: the level/XP HUD + the level-up celebration when the server-reported level climbs.
func _on_player_stats(d: Dictionary) -> void:
	xp_bar.update_stats(d)
	if _creation != null:
		_creation.on_player_stats(d)  # T-716: name-step latch + the account-name suggestion
	if character_sheet_panel != null:  # T-295: primaries + derived (and level-up gains)
		character_sheet_panel.update_stats(d)
	if level_up_ui != null:
		level_up_ui.on_player_stats(d, audio, combat_feedback)


func _on_entity_clicked(target_id: int) -> void:  # T-057: click an entity to target it
	_target_id = target_id
	remote_entities.set_target(target_id)
	if target_id != -1:  # T-557: hint range tracks the live filled-slot count, not a stale "1-4"
		var slots := player_hud.action_bar.slot_count() if player_hud != null else 5
		_onboarding.hint("target", HintReference.target_hint(slots))


func _toggle_autoattack() -> void:
	if _target_id == -1:
		return
	_set_autoattack(not _autoattack)
	if _autoattack:
		_attack_timer.start()
		_on_attack_tick()  # swing immediately, then on the GCD
	else:
		_attack_timer.stop()


func _set_autoattack(active: bool) -> void:  # T-571 (#26): the one place `_autoattack` changes
	_autoattack = active
	if player_hud != null:
		player_hud.set_autoattack(active)


func _clear_target() -> void:
	_target_id = -1
	_set_autoattack(false)
	_attack_timer.stop()
	remote_entities.set_target(-1)
	if player_hud != null:
		player_hud.clear_target()


# T-285: rebuild the party-member rows from the roster (party_members/leader, T-280) joined to
# the live broadcast entries by username — health/resource/class/leader + out-of-range dim.
func _refresh_party_frames(data: Dictionary) -> void:
	if party_frames == null:
		return
	if party_members.size() < 2:
		party_frames.set_party([])
		return
	# T-511 carve: pure row-building lives in PartyFrameView now (kept main.gd under the 1000 cap).
	party_frames.set_party(
		PartyFrameView.build_rows(
			data,
			party_members,
			_my_peer_id,
			party_leader,
			party_subgroups,
			READY_MARKER_RADIUS,
			PARTY_RANGE_M
		)
	)


# T-063: store the class ability kit the server offers on spawn (server still gates every use).
func _on_class_kit(data: Dictionary) -> void:
	_kit = data.get("abilities", [])
	if player_hud != null:  # T-308: action-bar slots follow kit_size (hotkeys + cooldown sweeps)
		player_hud.set_kit(_kit)
	# T-265: feed the cast bar ability_id -> name so a cast shows its spell name.
	if player_cast_bar != null:
		var names := {}
		for ab: Dictionary in _kit:
			names[int(ab.get("id", -1))] = str(ab.get("name", ""))
		player_cast_bar.set_ability_names(names)
	# T-076: the local body wears its class figure. T-535: the class_kit gender swaps the body mesh.
	if local_player != null:
		local_player.apply_class(str(data.get("char_class", "")), str(data.get("gender", "")))
	print("[client] class kit %s: %d abilities" % [str(data.get("char_class", "")), _kit.size()])
	# T-065/T-320/T-520: gender FIRST, then class — both latches + panel visibility live in the flow.
	if _creation != null:
		_creation.on_class_kit(data)
	_onboarding.maybe_show()  # T-376: handbook for a returning locked player (fresh char: panel-hide)


# T-063: cast the kit ability in action-bar slot 0-3 at the current target (server validates/gates).
# T-721: every press either dispatches (note_manual_send) or records WHY it could not (note_blocked)
# so pilot-driven combat QA can attribute a lost press to a hop instead of guessing.
func _cast_kit_slot(slot: int) -> void:
	if death_presentation != null and death_presentation.is_input_disabled():
		_cast_queue.note_blocked(slot, "input_disabled")
		return
	if slot < 0 or slot >= _kit.size() or _target_id == -1:
		_cast_queue.note_blocked(slot, "no_target" if _target_id == -1 else "no_kit_slot")
		return
	var ability_id: int = player_hud.action_bar.ability_id_at(slot)  # T-422c: bar owns slot->id
	if ability_id < 0:
		_cast_queue.note_blocked(slot, "empty_slot")
		return
	if player_hud != null:  # T-308: press feedback + GCD-estimate cooldown sweep on the slot
		player_hud.on_ability_pressed(slot)
	_net.request_use_ability(ability_id, _target_id)
	_cast_queue.note_manual_send(slot, ability_id, _target_id)
	# T-721 carve: cast cue + shimmer/bolt presentation lives in CastFx (main.gd 1000-line cap).
	CastFx.on_cast_sent(audio, vfx, local_player, remote_entities, _target_id, ability_id)


# T-057: each GCD tick, Strike the target. Stop (and drop the target) once it has died / left.
func _on_attack_tick() -> void:
	if not _autoattack or _target_id == -1 or not remote_entities.has_target(_target_id):
		_set_autoattack(false)
		_attack_timer.stop()
		_target_id = -1
		return
	if _net != null:
		_net.request_use_ability(1, _target_id)  # ability 1 = Strike


func _wire_result_handler(quest_action_toast: Callable) -> Callable:
	if _smoke:
		return HudHandlers.chain(quest_action_toast, func(d): HarnessProbe.on_accept(self, d))
	return HudHandlers.chain(quest_action_toast, func(d): _on_result(d))


# T-056/T-519: route quest results. A plain quest-giver talk_result opens the offer/turn-in PROMPT
# (QuestOfferPanel); trainers/services open their own panels below. too_far → a one-line hint.
func _on_result(data: Dictionary) -> void:
	var t := str(data.get("type", ""))
	if t == "talk_result":
		# T-519/T-710/T-714: the controller routes the prompt (and defers it during creation).
		_onboarding.route_talk_result($HUD.get_node("QuestOfferPanel") as QuestOfferPanel, data)
		# T-208: a trainer:<class> service opens the TRAINING hub; plain trainer flags keep T-065 talents.
		if str(data.get("service", "")).begins_with("trainer:") and service_panel != null:
			service_panel.open(
				str(data.get("npc_id", "")), str(data.get("name", "")), str(data.get("service", ""))
			)
		elif bool(data.get("trainer", false)):
			talent_panel.visible = true
			_net.request_talents()
		# T-145: a service NPC (bank/vendor/inn/flight) opens its stub hub panel instead.
		elif str(data.get("service", "")) != "" and service_panel != null:
			service_panel.open(
				str(data.get("npc_id", "")), str(data.get("name", "")), str(data.get("service", ""))
			)
	if t == "service_ack" and service_panel != null:  # T-145: show the stub round-trip result
		service_panel.on_ack(data)
		if data.has("daily"):  # T-483: richer authoritative objective preview for the end cue
			_onboarding.set_return_reason_state(data["daily"])
	if t == "accept_quest_result" and service_panel != null:  # T-293: bounty pickup confirm in-panel
		service_panel.on_accept_result(data)
	if t == "spend_talent_result":  # T-065: any spend result re-syncs the tree
		if not bool(data.get("ok", false)):
			print("[client] talent: %s" % str(data.get("reason", "")))
		elif audio != null:
			audio.play_sfx("ui_click", -10.0)  # T-508: rank-up "brick laid" tick on a good spend
		_net.request_talents()
	if t == "set_gender_result" and bool(data.get("ok", false)) and _creation != null:
		_creation.on_gender_chosen()  # T-520: hide gender, advance to class (kit refresh follows)
	if t == "set_class_result" and bool(data.get("ok", false)) and _creation != null:
		_creation.on_class_locked()  # T-320: latch locked; hide class panel for good
	if t == "set_name_result" and _creation != null:
		_creation.on_name_result(data)  # T-716: latch + close, or plain-English retry
	if t == "turn_in_result":
		_onboarding.on_turn_in(data)  # T-713: graduation beat (long-term goal + LFG surface)
	if t in ["talk_result", "accept_quest_result", "turn_in_result", "abandon_result"]:
		_refresh_timer.start()  # debounced — coalesce a burst of results into one refresh


# T-056: the debounced refresh (fired once after results settle) — keeps log + markers current.
func _do_quest_refresh() -> void:
	if _net != null:
		_net.request_quest_log()
		_net.request_npc_indicators()


func _input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.is_pressed() or event.is_echo():
		return
	if not _world_built or has_node("HUD/LoadingScreen"):
		return  # T-494/T-691: no world hotkeys until login + loading finish building the HUD
	var key := event as InputEventKey
	if UiInputGate.is_text_input_focused(get_viewport()):
		return  # T-504: every free-type field owns all keyboard input, not only chat
	if chat_panel != null and chat_panel.is_typing():
		return  # T-361: focus discipline — typing in chat must not fire WASD/hotkeys/Esc menu
	if key.keycode in [KEY_L, KEY_I, KEY_N, KEY_C, KEY_QUOTELEFT, KEY_ESCAPE] and audio != null:
		audio.play_sfx("ui_click", -13.0)  # T-111: a click on panel toggles / autoattack toggle
	if key.keycode == KEY_L:
		quest_log_panel.toggle()
	elif key.keycode == KEY_C:  # T-295: character sheet (primaries + derived stats)
		character_sheet_panel.toggle()
	elif key.keycode == KEY_I:
		inventory_panel.toggle()
		if inventory_panel.visible:
			_net.get_inventory()  # T-225: fresh slots on open (same idiom as talents)
	elif key.keycode == KEY_N:  # T-065: talent tree
		talent_panel.toggle()
		if talent_panel.visible:
			_net.request_talents()
	elif key.keycode == KEY_QUOTELEFT:
		_toggle_autoattack()  # T-057: auto-attack (moved off "1" for the T-063 action bar)
	elif key.keycode == KEY_M:
		_net._toggle_mount()
	elif key.keycode == KEY_TAB:
		var origin := local_player.global_position if local_player != null else Vector3.ZERO
		var next_id := TargetSelection.next_hostile_target(
			remote_entities.get("_entities"), _target_id, origin
		)
		if next_id != -1:
			_on_entity_clicked(next_id)
	elif key.keycode >= KEY_1 and key.keycode <= KEY_4:
		# T-065: while the class panel is up, 1-3 belong to class selection, not the bar.
		if class_panel == null or not class_panel.visible:
			_cast_kit_slot(key.keycode - KEY_1)  # T-063: class action-bar slots 1-4
	elif key.keycode == KEY_ESCAPE:
		_handle_escape()


func _handle_escape() -> void:
	var menu_open := settings_panel != null and settings_panel.visible
	var has_panels := not _open_hud_panels().is_empty()
	var action := SettingsEscGate.next_action(menu_open, has_panels, _target_id != -1)
	match action:
		SettingsEscGate.CLOSE_MENU, SettingsEscGate.OPEN_MENU:
			if settings_panel != null:
				settings_panel.toggle()
			if action == SettingsEscGate.OPEN_MENU:
				_onboarding.show_return_reason()
		SettingsEscGate.CLOSE_PANELS:
			for p in _open_hud_panels():
				p.visible = false
		SettingsEscGate.CLEAR_TARGET:
			_clear_target()


func _open_hud_panels() -> Array:  # Esc closes these before opening Options (T-571: _panel_set)
	return HudPanelSweep.open_panels(_panel_set, [_onboarding.card, _recap_panel])


# T-057: left-click empty ground → deselect (like Esc); clicks that hit an entity/NPC are
# handled by their own input_event (target / talk), which leaves the target alone.
func _unhandled_input(event: InputEvent) -> void:
	if not _world_built or has_node("HUD/LoadingScreen"):
		return  # T-494/T-691: click-targeting is inert behind the login + loading gates
	if not (event is InputEventMouseButton) or not event.pressed:
		return
	if event.button_index != MOUSE_BUTTON_LEFT:
		return
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	var entities: Dictionary = remote_entities.get("_entities") if remote_entities != null else {}
	var picked := TargetSelection.target_id_for_click(cam, event.position, entities, npc_world)
	if picked == TargetSelection.NPC_CLICK:
		return  # NPC click belongs to its talk handler and leaves combat target alone
	if picked != -1:
		_on_entity_clicked(picked)
		return
	_clear_target()


func _send_to_server(msg: Dictionary) -> void:
	if _connected:
		_receive_message.rpc_id(1, msg)


func _fail(reason: String) -> void:
	push_warning("[client] net fail: %s" % reason)
	HarnessProbe.write(_result_file, {"handshake_ok": false, "accept_ok": false, "error": reason})
	get_tree().quit(1)
