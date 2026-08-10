# TD-002: the single world→master quest/inventory RPC coordinator. Owns the content registries +
# every quest/inventory intent handler + kill-credit. main.gd keeps combat/movement/session and
# delegates via handles()/handle(). RefCounted; replies carry server-confirmed state via `_reply`.

extends RefCounted

const _CONTENT = preload("res://scripts/content/content_registry.gd")
const _CQ = preload("res://scripts/content/content_query.gd")
const _NIV = preload("res://scripts/content/npc_indicator_view.gd")  # T-426 carve: NPC-view payload
const PlayerSessions = preload("res://scripts/player_sessions.gd")
const _BB = preload("res://scripts/broadcast_builder.gd")  # T-225: gear derivation
const _LOOT = preload("res://scripts/combat/loot_table.gd")  # T-232: rarity weight table
const _DUNGEON_LOOT = preload("res://scripts/combat/dungeon_loot.gd")  # T-333
const _STC = preload("res://scripts/combat/stat_converter.gd")  # T-295: player_stats payload
const _NDIR = preload("res://scripts/npc_director.gd")  # T-311: ambient NPC movement owner
const _MCOL = preload("res://scripts/movement_collision.gd")  # Report #15: NPC wall oracle
const _FLIGHT = preload("res://scripts/flight_service.gd")  # T-431: persisted route graph + hops
const _DAILY = preload("res://scripts/daily_service.gd")  # T-450: date/content seam carved at cap
const _DISC = preload("res://scripts/discovery_nodes.gd")  # T-427: pure discovery edge query
const _LOOTD = preload("res://scripts/loot_delivery.gd")  # T-644: kill-loot fallback + hold-on-fail
const _MAIL = preload("res://scripts/mail_service.gd")  # T-613: mail seam, carved at the file cap
const _CONTENT_OPS = preload("res://scripts/content_summary_ops.gd")  # T-613 carve: file cap

# T-043: server-side interaction range — a player must be within this of an NPC to turn-in/talk.
const INTERACT_RADIUS := 3.0
const _QUEST_INTENTS := [
	"request_quest_log",
	"accept_quest",
	"turn_in",
	"talk",
	"service_intent",  # T-145: Highkeep service hubs (bank/vendor/inn/flight) — world-local stub
	"abandon",
	"request_npc_indicators",
]
const _INV_INTENTS := ["get_inventory", "equip", "unequip", "drop"]
# T-550 control-hint sighting + T-705 client boot timing: account-level reports, no gameplay state.
const _ONBOARD_INTENTS := ["onboarding_hint_seen", "client_boot_timing"]
const _PARTY_INTENTS := [
	"party_invite",
	"party_accept",
	"party_decline",
	"party_leave",
	"party_disband",
	"party_mentor_sync",
	"raid_convert",  # T-472: promote a party to a 10-man raid (leader only)
	"raid_set_group",  # T-472: seat a member in subgroup 0/1 (leader/assist)
	"raid_set_assist",  # T-472: grant/revoke assist (leader only)
	"raid_kick",  # T-472: remove a member (leader; assist for rank-and-file)
]  # T-280/T-452/T-472

var content_ops = _CONTENT_OPS.new()  # T-613/T-709: public — main calls the kill-loot roll
# T-710: first-entry tutorial offer push + chain auto-continue; public — main.gd calls
# tut_offers.push_tutorial_offer(peer_id) directly at handshake (see the service header).
var tut_offers = preload("res://scripts/onboarding_offer_service.gd").new()
# T-705: first-session funnel emitter; public — loot_delivery holds it too (see _set_telemetry).
var funnel = preload("res://scripts/funnel_events.gd").new()
var _master = null  # MasterClient (call_master)
var _reply: Callable  # main._send_to_peer(peer_id, dict)
# T-061: main._apply_combat_stats(peer_id, stat_vec) — re-derive a player's stats/pools on level-up.
var _apply_stats: Callable
var _kit_refresh: Callable = Callable()  # T-208: main re-sends the class kit after a train
var _gear_update: Callable = Callable()  # T-225: main caches equipped visuals per peer
var _mentor_svc = null  # T-452: server-truth sync policy + authoritative stat cache
var _content_quests: Dictionary = {}
var _content_npcs: Dictionary = {}
var _content_items: Dictionary = {}
var _content_talents: Dictionary = {}  # T-064: talent defs (content authority)
var _content_rarity_weights: Dictionary = {}  # T-232: difficulty -> {rarity: weight}
var _dungeon_schedule: Dictionary = {}  # T-333: boss alias -> green + named-blue schedule
var _discovery_nodes: Array = []  # T-427: authored POIs, checked from server movement truth
# T-058: npc_id -> {quest_id: def} (giver/turn-in/talk) so indicators are O(quests-for-npc).
var _npc_quest_index: Dictionary = {}
var _npc_director = _NDIR.new()  # T-311: ambient NPC movement (seeds at setup; main ticks it)
var _ach = preload("res://scripts/achievement_service.gd").new()  # T-367: read + earn-toast relay
var _craft = preload("res://scripts/craft_service.gd").new()  # T-414: gather/craft/use_item seam
var _flight = _FLIGHT.new()
var _daily = _DAILY.new()
var _wardrobe = preload("res://scripts/wardrobe_service.gd").new()  # T-428: look intent boundary
var _talents = preload("res://scripts/talent_service.gd").new()  # T-480 carve: T-064/T-065 seam
var _loot_delivery = _LOOTD.new()  # T-644: kill-loot fallback + hold-on-fail service
var _mail = _MAIL.new()  # T-613: mail seam
var _reach = preload("res://scripts/reach_service.gd").new()  # T-698 carve: reach/discovery credit
# T-698: content is STATIC after load — build these ONCE instead of re-walking the registries on
# every intent/kill/repush. Shapes are byte-identical to the _CQ builders they replace; treat them
# as read-only (they ride straight into call_master payloads).
var _item_registry_cache: Dictionary = {}
var _item_stats_cache: Dictionary = {}
var _all_quest_defs_cache: Dictionary = {}
var _kill_quest_index: Dictionary = {}  # kill target -> {quest_id: def}


# Loads content (fail-loud) + wires deps. Returns "" on success or an error string (boot aborts).
func setup(
	master, reply: Callable, base_path: String = "res://data", apply_stats: Callable = Callable()
) -> String:
	_master = master
	_reply = reply
	_apply_stats = apply_stats
	_kit_refresh = Callable()
	var loaded: Dictionary = _CONTENT.load_all(base_path)
	if not loaded["errors"].is_empty():
		return str(loaded["errors"])
	_content_quests = loaded["quests"]
	_content_npcs = loaded["npcs"]
	_content_items = loaded["items"]
	_content_talents = loaded.get("talents", {})
	var discoveries: Dictionary = _DISC.load_file(base_path.path_join("discovery_nodes.json"))
	if not discoveries["errors"].is_empty():
		return str(discoveries["errors"])
	_discovery_nodes = discoveries["nodes"]
	# T-698: one-time content folds (see the cache vars above) — before any consumer below.
	_item_registry_cache = _CQ.item_registry(_content_items)
	_item_stats_cache = _CQ.item_stats(_content_items)
	_all_quest_defs_cache = _CQ.all_quest_defs(_content_quests)
	_kill_quest_index = _CQ.kill_quest_index(_content_quests)
	_reach.setup(
		master,
		reply,
		Callable(self, "push_quest_delta"),
		Callable(_ach, "forward"),
		Callable(self, "_repush_combat_stats"),
		_discovery_nodes,
		_CQ.reach_objectives(_content_quests),
		_all_quest_defs_cache
	)
	_daily.setup(master, reply, _content_quests)
	# T-710: tutorial offer pushes ride the same master/reply/delta plumbing as the talk path.
	tut_offers.setup(
		master,
		reply,
		_content_quests,
		_content_npcs,
		_all_quest_defs_cache,
		Callable(self, "push_quest_delta")
	)
	_mail.setup(master, reply, _content_items)  # T-613: mail seam (item registry for bag/take)
	content_ops.setup(self)  # T-613 carve: content-summary/loot-roll queries
	_talents.setup(self)  # T-480 carve: shares this seam's master/reply/repush/gear plumbing
	_content_rarity_weights = _LOOT.load_rarity_weights(
		base_path.path_join("loot/rarity_weights.json")
	)
	_dungeon_schedule = _DUNGEON_LOOT.load_schedule(
		base_path.path_join("loot/dungeon_schedule.json")
	)
	_npc_quest_index = content_ops.build_npc_quest_index()
	_npc_director.seed(_content_npcs)  # T-311: seed ambient-movement state from content
	# Report #15: ambient NPCs respect world geometry — building footprints (npc_obstacles.json)
	# plus the curtain wall (barriers.json) feed one wall oracle; wanderers stop-and-turn at it.
	var npc_walls = _MCOL.new(base_path.path_join("regions/npc_obstacles.json"))
	npc_walls.load_barriers(base_path.path_join("regions/barriers.json"))
	_npc_director.set_blocker(npc_walls)
	_ach.setup(master, reply)  # T-367: achievement list read + earn-toast relay
	_loot_delivery.setup(master, reply)  # T-644: kill-loot fallback + hold-on-fail
	# T-414: crafting seam loads its own recipes/nodes data (fail-loud like the rest of content).
	var craft_err := _craft.setup(master, reply, base_path, _item_registry_cache, _content_npcs)
	if craft_err != "":
		return craft_err
	# T-570 (report #30): let the gather-grant path push a bag refresh the client actually renders.
	_craft.set_inventory_push(Callable(self, "_push_inventory_update"))
	# T-650: lets gather/craft credit collect objectives the way equip/unequip/drop already do.
	_craft.set_quest_defs(_all_quest_defs_cache)
	# T-657: push the live HUD delta (same push_quest_delta the equip-credit path uses below).
	_craft.set_quest_delta_push(Callable(self, "push_quest_delta"))
	var flight_err := _flight.setup(master, reply, base_path.path_join("travel/flight_nodes.json"))
	if flight_err != "":
		return flight_err
	return _wardrobe.setup(
		master, reply, _item_registry_cache, base_path.path_join("wardrobe.json")
	)


# T-420: equipped visuals for the spawn seed — enriches raw slots so each carries its armor_type
# (else logout-worn plate renders unrouted until re-equip). Underscored for the method-count budget.
func _equipped_visuals(slots: Array) -> Dictionary:
	return _BB.equipped_from_slots(_CQ.enrich_inventory(slots, _content_items))


# T-311: advance ambient NPCs and return live {npc_id, x, y}; delegates to NpcDirector.
# T-698: `awake` is main's sleeping-zone awake-region set — unobserved regions skip NPC/node work
# and resume on absolute ticks exactly as mobs do (null = tick everything, the pre-T-698 shape).
func tick_npcs(now: int, tick_hz: int, rng, awake = null) -> Array:
	_craft.tick(rng, awake)  # T-414: gather-node respawns ride the same cadence
	return _npc_director.tick(_content_npcs, now, tick_hz, rng, awake)


# T-698: inject the region table (main owns it) so NPC posts + gather nodes precompute their
# STATIC region once — the tick-time awake gate is then a dict probe, never an O(regions) scan.
func set_regions(regions) -> void:
	_npc_director.set_regions(regions)
	_craft.set_regions(regions)


# T-698: drop the reach throttle's per-peer checkpoint on disconnect (main's teardown path).
# Underscored for the 20-public-method budget (external-call precedent: _set_heal).
func _forget_peer(peer_id: int) -> void:
	_reach.forget(peer_id)


# T-577: fixed post for a WANDERING npc_id, else null (near_npc/at_turnin_npc then use live pos —
# a wanderer's live npc.x/npc.y drifts, so gating on it makes turn-in/talk depend on wander phase).
func _npc_anchor(npc_id: String):
	return _npc_director.post_of(npc_id) if _npc_director.is_tracked(npc_id) else null


# T-414: main injects the live-HP heal hook (potion use applies to server combat resources).
# Underscored for the 20-public-method lint budget (external-call precedent: _notify_members).
func _set_heal(heal: Callable) -> void:
	_craft.set_heal(heal)


# T-311: movers' live positions without advancing (test/introspection helper).
func npc_positions_array() -> Array:
	return _npc_director.positions(_content_npcs)


# T-705: main injects the telemetry pump for the first-session funnel; the event vocabulary lives
# in funnel_events.gd so the call sites below stay one line each (this file is at the gdlint cap).
# Underscored for the 20-public-method budget (precedent: _set_heal / _set_mentorship).
func _set_telemetry(tel: Callable) -> void:
	funnel.setup(tel)
	_loot_delivery.set_funnel(funnel)


func handles(msg_type: String) -> bool:
	return (
		_QUEST_INTENTS.has(msg_type)
		or _INV_INTENTS.has(msg_type)
		or _ONBOARD_INTENTS.has(msg_type)
		or _talents.handles(msg_type)
		or _PARTY_INTENTS.has(msg_type)
		or _daily.handles(msg_type)
		or _ach.handles(msg_type)
		or _craft.handles(msg_type)
		or _wardrobe.handles(msg_type)
	)


# T-064: world talent defs — main passes them to get_character_combat; master resolves stat_add.
func talent_defs() -> Dictionary:
	return _content_talents


# T-399: item stats injected into get_character_combat so the master gear-fold reads items.json.
func item_stats() -> Dictionary:
	return _item_stats_cache  # T-698: one-time fold (was rebuilt from the registry per repush)


# T-061/T-399: THE single re-derive seam — re-fetch via the master fold (gear in), sheet always.
# T-642 (portal #86): `refill` must be true ONLY for a genuine level-up (the one repush event that
# legitimately restores resources to full, matching the level-up bonus convention). Every OTHER
# re-derive this seam drives (gear equip/unequip, gear repair, non-level-up XP) must PRESERVE the
# current pool FRACTION — this was the actual live full-heal hole: repair_op/equip/unequip called
# this with no 3rd arg, so `_apply_stats` always ran with `preserve_resources=false` (its own
# default), full-healing on demand with zero cooldown any time gear changed or was repaired.
func _repush_combat_stats(
	peer_id: int, username: String, apply: bool = true, refill: bool = false
) -> void:
	if username == "":
		return
	var combat: Dictionary = await _master.call_master(
		"get_character_combat",
		{"username": username, "talent_defs": _content_talents, "item_stats": item_stats()}
	)
	if apply and _apply_stats.is_valid():
		_apply_stats.call(
			peer_id,
			combat.get("class", "warrior"),
			combat.get("stats", {}),
			combat.get("talents", {}),
			int(combat.get("level", 1)),
			not refill  # preserve_resources: never heal on repush unless this IS the level-up refill
		)
		if _mentor_svc != null:
			_mentor_svc.refresh_party_for(peer_id)
	if _mentor_svc != null:  # T-643: a synced peer's stat sheet shows the capped view, not truth
		combat = _mentor_svc.display_combat(peer_id, combat)
	_reply.call(peer_id, _STC.player_stats_msg(combat))


# Routes a quest/inventory intent → master RPC → reply. Fire-and-forget void coroutine.
func handle(msg_type: String, peer_id: int, data: Dictionary) -> void:
	var player: Dictionary = PlayerSessions.get_player(peer_id)
	if player.is_empty():
		return
	if _PARTY_INTENTS.has(msg_type):  # T-280/T-452/T-472: one coordinator owns party + raid
		if _mentor_svc != null:
			_mentor_svc.handle_party(msg_type, peer_id, player, data)
		else:
			_reply.call(peer_id, {"type": "party_result", "ok": false, "reason": "unavailable"})
		return
	match msg_type:
		"request_quest_log":
			await _request_quest_log(peer_id, player)
		"accept_quest":
			await _accept_quest(peer_id, player, data)
		"turn_in":
			await _turn_in(peer_id, player, data)
		"talk":
			await _talk(peer_id, player, data)
		"service_intent":
			# T-145 stubs are world-local; T-208 real ops await the master
			await _service_intent(peer_id, player, data)
		"abandon":
			await _abandon(peer_id, player, data)
		"request_npc_indicators":
			await _npc_indicators(peer_id, player)
		"onboarding_hint_seen":  # T-550: persist a control-hint sighting at account scope
			await _onboarding_hint_seen(player, data)
		"client_boot_timing":  # T-705: pre-spawn boot phases (clamped in funnel_events)
			funnel.boot_timing(peer_id, data)
		# T-480 carve: T-064/T-065 seam; T-520/T-716 add set_gender/set_name (creation choices).
		"spend_talent", "request_talents", "set_class", "set_gender", "set_name":
			await _talents.handle(msg_type, peer_id, player, data)
		"weekly_op":  # T-480: weekly vault status/claim (proximity-free; master owns state)
			await _daily.weekly(peer_id, str(player.get("username", "")), data)
		"achievement_list":  # T-367: read-only achievement panel feed
			await _ach.handle_read(peer_id, player)
		"renown_list":  # T-678: read-only renown standing feed (rides the T-367 relay)
			await _ach.handle_renown_read(peer_id, player)
		"gather", "gather_nodes", "craft", "use_item", "learn_recipe", "recipe_catalog":
			await _craft.handle(msg_type, peer_id, player, data)  # T-414
		# T-750: this list MUST mirror WardrobeService._INTENTS — wardrobe_buy was missing, so the
		# whole T-476 store's purchase path fell through to _inventory and was silently dropped.
		"wardrobe_list", "wardrobe_apply", "wardrobe_clear", "wardrobe_hide_helm", "wardrobe_buy":
			await _wardrobe.handle(peer_id, player, data)
		_:
			await _inventory(peer_id, player, msg_type, data)


# ---- quest handlers (T-041–T-044; reply via the injected Callable) -------


func _request_quest_log(peer_id: int, player: Dictionary) -> void:
	var result: Dictionary = await _master.call_master(
		"get_quest_log", {"username": player.get("username", "")}
	)
	# T-038: enrich with title + objective descs. T-621: char level -> per-entry difficulty band.
	var lvl := int(result.get("level", 1))
	result["quests"] = _CQ.enrich_quest_log(result.get("quests", []), _content_quests, lvl)
	_reply.call(peer_id, {"type": "quest_log", "result": result})


# T-550: forward a client-reported control-hint sighting to the master's account-level memory.
# Fire-and-forget (no reply needed — cosmetic fire-once state); master resolves the account from the
# authenticated character name, so the client cannot target another account.
func _onboarding_hint_seen(player: Dictionary, data: Dictionary) -> void:
	var hint_id: String = str(data.get("hint_id", ""))
	if hint_id == "":
		return
	await _master.call_master(
		"onboarding_hint_seen", {"username": player.get("username", ""), "hint_id": hint_id}
	)


# T-603: the accept-side rejection reply (unknown_quest / too_far — the latter mirrors _talk).
func _reject_accept(peer_id: int, quest_id: String, reason: String) -> void:
	_reply.call(
		peer_id,
		{"type": "accept_quest_result", "quest_id": quest_id, "ok": false, "reason": reason}
	)
	funnel.rejected(peer_id, "accept_quest", reason)  # T-705


func _accept_quest(peer_id: int, player: Dictionary, data: Dictionary) -> void:
	var quest_id: String = str(data.get("quest_id", ""))
	if not _content_quests.has(quest_id):
		_reject_accept(peer_id, quest_id, "unknown_quest")
		return
	# T-707: retired content takes no NEW accepts (server gate — the hidden offer card alone
	# wouldn't stop a forged intent); mid-quest characters still turn in / abandon normally.
	if _content_quests[quest_id].get("retired") == true:
		_reject_accept(peer_id, quest_id, "quest_retired")
		return
	# T-603: mirror _turn_in's server-authority gate on the ACCEPT side — the giver's T-577 anchor
	# proximity must pass before the master hears the intent (only forged/cross-map accepts hit this).
	var quest = _content_quests[quest_id]
	var ppos: Vector3 = player.get("pos", Vector3.ZERO)
	if not _CQ.at_giver_npc(
		_content_npcs, quest, ppos, INTERACT_RADIUS, _npc_anchor(str(quest.giver_npc))
	):
		# T-710: a server-PUSHED offer authorizes its own accept from anywhere (consumed once).
		if not tut_offers.consume_pushed(peer_id, quest_id):
			_reject_accept(peer_id, quest_id, "too_far")
			return
	# T-041: world resolves the def from its OWN registry (never trusts client content).
	var quest_def: Dictionary = _CQ.quest_to_dict(quest)
	var result: Dictionary = await (
		_master
		. call_master(
			"accept_quest",
			{
				"username": player.get("username", ""),
				"quest": quest_def,
				"item_registry": _item_registry_cache,  # T-058: provided items
			}
		)
	)
	var reply := {
		"type": "accept_quest_result",
		"quest_id": quest_id,
		"ok": result.get("ok", false),
		"reason": result.get("reason", ""),
	}
	_reply.call(peer_id, reply)
	if not bool(result.get("ok", false)):
		funnel.rejected(peer_id, "accept_quest", str(result.get("reason", "")))  # T-705
		return
	funnel.quest_accept(peer_id, quest_id)  # T-705: the "on quest" beat
	var username: String = str(player.get("username", ""))
	push_quest_delta(peer_id, username, quest_id)  # T-058
	# T-565: level-trigger — credit any reach objective the player is ALREADY standing inside at
	# accept time (reach_service.credit_on_activate; see it for the softlock this closes).
	_reach.credit_on_activate(peer_id, username, player.get("pos", Vector3.ZERO))
	await _flight.grant_for_quest(username, quest)  # T-689: authored roost grant, on ACCEPT


func _turn_in(peer_id: int, player: Dictionary, data: Dictionary) -> void:
	var quest_id: String = str(data.get("quest_id", ""))
	if not _content_quests.has(quest_id):
		_reply.call(
			peer_id,
			{"type": "turn_in_result", "quest_id": quest_id, "ok": false, "reason": "unknown_quest"}
		)
		funnel.rejected(peer_id, "turn_in", "unknown_quest")  # T-705
		return
	# T-043: world computes at_turnin_npc proximity from content positions; master grants atomically.
	var quest = _content_quests[quest_id]
	var ppos: Vector3 = player.get("pos", Vector3.ZERO)
	var daily: Dictionary = _daily.turn_in_context()
	var anchor = _npc_anchor(str(quest.turnin_npc))  # T-577: see _npc_anchor
	var at_npc: bool = _CQ.at_turnin_npc(_content_npcs, quest, ppos, INTERACT_RADIUS, anchor)
	var result: Dictionary = await (
		_master
		. call_master(
			"turn_in",
			{
				"username": player.get("username", ""),
				"quest": _CQ.quest_to_dict(quest),
				"at_turnin_npc": at_npc,
				"item_registry": _item_registry_cache,
				"date_key": daily["date_key"],
				"quest_defs": daily["quest_defs"],
			}
		)
	)
	var reply := {
		"type": "turn_in_result",
		"quest_id": quest_id,
		"ok": result.get("ok", false),
		"reason": result.get("reason", ""),
		"xp": result.get("xp", 0),
		"coins": result.get("coins", 0),
		"daily": result.get("daily", {}),
	}
	_reply.call(peer_id, reply)
	if bool(result.get("ok", false)):
		funnel.quest_turn_in(peer_id, quest_id)  # T-705: the "reward collected" beat
		push_quest_delta(peer_id, str(player.get("username", "")), quest_id)  # T-058
		# T-710: a tutorial turn-in immediately re-offers the chain successor in the same dialog.
		await tut_offers.maybe_continue_chain(peer_id, player, quest_id)
	else:
		funnel.rejected(peer_id, "turn_in", str(result.get("reason", "")))  # T-705
	_ach.forward(peer_id, result)  # T-367: toast a quest/level achievement the turn-in just earned

	# T-061/T-060: XP refreshes the sheet; a level-up re-applies + fully heals (apply=refill=leveled).
	var leveled: bool = bool(result.get("leveling", {}).get("leveled_up", false))
	if int(result.get("xp", 0)) > 0 or leveled:
		await _repush_combat_stats(peer_id, str(player.get("username", "")), leveled, leveled)


func _talk(peer_id: int, player: Dictionary, data: Dictionary) -> void:
	# T-044: proximity-gated server-side; client supplies only an npc_id.
	var npc_id: String = str(data.get("npc_id", ""))
	if not _content_npcs.has(npc_id):
		_reply.call(
			peer_id, {"type": "talk_result", "npc_id": npc_id, "ok": false, "reason": "unknown_npc"}
		)
		return
	var ppos: Vector3 = player.get("pos", Vector3.ZERO)
	if not _CQ.near_npc(_content_npcs, npc_id, ppos, INTERACT_RADIUS, _npc_anchor(npc_id)):
		_reply.call(
			peer_id, {"type": "talk_result", "npc_id": npc_id, "ok": false, "reason": "too_far"}
		)
		return
	var result: Dictionary = await (
		_master
		. call_master(
			"talk",
			{
				"username": player.get("username", ""),
				"npc": _CQ.npc_to_dict(_content_npcs[npc_id]),
				"quest_defs": _all_quest_defs_cache,
			}
		)
	)
	result["type"] = "talk_result"
	result["npc_id"] = npc_id
	result["ok"] = not result.has("error")
	# T-065: talking to a class trainer opens the talent UI client-side.
	result["trainer"] = bool(_content_npcs[npc_id].trainer)
	# T-145: a service NPC opens its stub hub panel instead; name titles it (server-authoritative).
	result["service"] = str(_content_npcs[npc_id].service)
	result["name"] = str(_content_npcs[npc_id].name)
	# T-519: quest-prompt previews so the click OPENS an offer/turn-in dialog (was a silent auto-
	# accept that only flipped the !/? marker). The client draws these; its buttons fire the intents.
	result["offers"] = _CQ.talk_previews(
		result.get("available", []), result.get("turn_in_ready", []), _content_quests
	)
	if result["service"] == "flight":
		await _flight.discover(peer_id, str(player.get("username", "")), npc_id)
	_reply.call(peer_id, result)
	for credited_id in result.get("credited", []):  # T-058: talk credit -> targeted delta
		push_quest_delta(peer_id, str(player.get("username", "")), str(credited_id))


# T-145: service hubs — client sends an intent; world validates known-npc → proximity → offers-svc
# then acks (real actions route to the master, stubs ack world-local; failures mirror talk's).
# gdlint: disable=max-returns
func _service_intent(peer_id: int, player: Dictionary, data: Dictionary) -> void:
	var npc_id: String = str(data.get("npc_id", ""))
	var action: String = str(data.get("action", ""))
	if not _content_npcs.has(npc_id):
		_service_reject(peer_id, npc_id, "unknown_npc")
		return
	var ppos: Vector3 = player.get("pos", Vector3.ZERO)
	if not _CQ.near_npc(_content_npcs, npc_id, ppos, INTERACT_RADIUS, _npc_anchor(npc_id)):
		_service_reject(peer_id, npc_id, "too_far")
		return
	var service: String = str(_content_npcs[npc_id].service)
	if service == "":
		_service_reject(peer_id, npc_id, "no_service")
		return
	if service == "flight":
		await _flight.handle(peer_id, str(player.get("username", "")), npc_id, data)
		return
	# T-450: carved helper adds today's rotating/claimed state to the T-293 bounty list.
	if service == "bounty":
		await _daily.browse(peer_id, str(player.get("username", "")), npc_id, action)
		return
	# T-613: mail is bundled onto the banker's "bank" hub — same NPC, an action namespace
	# instead of a second service tag. Proximity + service == "bank" are already validated above.
	if service == "bank" and _mail.handles(action):
		await _mail.handle(peer_id, npc_id, str(player.get("username", "")), action, data)
		return
	# T-208: bank/auction/trainer/repair actions are REAL — proximity-gated here, master owns state.
	var username := str(player.get("username", ""))
	var op := {}
	match service:
		"bank":
			if action in ["vault_list", "vault_move", "vault_upgrade"]:  # T-412: tier ladder sink
				op = {
					"username": username,
					"action": action.trim_prefix("vault_"),
					"from_type": str(data.get("from_type", "")),
					"from_index": int(data.get("from_index", -1)),
				}
				op["_method"] = "vault_op"
		"auction":
			if action in ["auction_browse", "auction_list", "auction_bid", "auction_buyout"]:
				op = {
					"username": username,
					"action": action.trim_prefix("auction_"),
					"from_index": int(data.get("from_index", -1)),
					"min_bid": int(data.get("min_bid", 0)),
					"buyout": int(data.get("buyout", 0)),
					"duration_s": int(data.get("duration_s", 3600)),
					"auction_id": int(data.get("auction_id", 0)),
					"amount": int(data.get("amount", 0)),
				}
				op["item_registry"] = _item_registry_cache
				op["_method"] = "auction_op"
		"vendor":
			if action in ["repair", "repair_quote"]:
				op = {"username": username, "quote": action == "repair_quote"}
				op["item_registry"] = _item_registry_cache  # T-412: rarity-scaled cost
				op["_method"] = "repair_op"
			elif action in ["browse", "sell", "buy", "buyback"]:
				# T-430: only desires cross from the client. Identity is session-derived above; this
				# vendor's stock and every item price/definition come from world content here.
				op = {
					"username": username,
					"action": action,
					"wares": _content_npcs[npc_id].wares.duplicate(),
					"item_registry": _item_registry_cache,
				}
				if action == "sell":
					op["slot_index"] = int(data.get("slot_index", -1))
					op["count"] = int(data.get("count", 1))
				elif action == "buy":
					op["item_id"] = str(data.get("item_id", ""))
				elif action == "buyback":
					op["buyback_index"] = int(data.get("buyback_index", -1))
				op["_method"] = "vendor_op"
		_:
			if service.begins_with("trainer:") and action in ["catalog", "train"]:
				op = {
					"username": username,
					"action": action,
					"service": service,
					"ability_id": int(data.get("ability_id", 0)),
				}
				op["_method"] = "trainer_op"
	if op.is_empty():
		# T-145 stub ack (vendor wares, inn set_home, flight, plain browse)
		_reply.call(
			peer_id,
			{
				"type": "service_ack",
				"ok": true,
				"npc_id": npc_id,
				"service": service,
				"action": action
			}
		)
		return
	var method := str(op["_method"])
	op.erase("_method")
	var result: Dictionary = await _master.call_master(method, op)
	var ack := {
		"type": "service_ack",
		"ok": not result.has("error"),
		"npc_id": npc_id,
		"service": service,
		"action": action,
	}
	if result.has("error"):
		ack["reason"] = str(result["error"])
	for key in [
		"vault",
		"bag",
		"vault_slots",
		"coins",
		"auctions",
		"listed",
		"bid_ok",
		"bought",
		"catalog",
		"unlocked",
		"cost",
		"repaired",
		"quote",
		"wares",
		"bag",
		"buyback",
		"sold",
		"bought",
		"count",
		"price",
		"buyback_purchase"
	]:
		if result.has(key):
			ack[key] = result[key]
	_reply.call(peer_id, ack)
	funnel.service(peer_id, service, action, ack)  # T-705: trainer/vendor refusal reasons
	# a successful train changes the kit — let the session layer re-send it
	if method == "trainer_op" and action == "train" and not result.has("error"):
		if _kit_refresh.is_valid():
			_kit_refresh.call(peer_id)
	# T-399: a real repair (not a quote) revives broken-gear stats — re-derive via the master fold.
	if method == "repair_op" and action == "repair" and not result.has("error"):
		await _repush_combat_stats(peer_id, username)


func _service_reject(peer_id: int, npc_id: String, reason: String) -> void:
	_reply.call(peer_id, {"type": "service_ack", "npc_id": npc_id, "ok": false, "reason": reason})
	funnel.rejected(peer_id, "service_intent", reason)  # T-705


func _abandon(peer_id: int, player: Dictionary, data: Dictionary) -> void:
	# T-044: no proximity — issued from the quest log.
	var quest_id: String = str(data.get("quest_id", ""))
	var quest_def: Dictionary = (
		_CQ.quest_to_dict(_content_quests[quest_id]) if _content_quests.has(quest_id) else {}
	)
	var result: Dictionary = await (
		_master
		. call_master(
			"abandon_quest",
			{
				"username": player.get("username", ""),
				"quest_id": quest_id,
				"quest": quest_def,  # T-058: provided items leave with the quest
			}
		)
	)
	(
		_reply
		. call(
			peer_id,
			{
				"type": "abandon_result",
				"quest_id": quest_id,
				"ok": result.get("ok", false),
				"reason": result.get("reason", ""),
			}
		)
	)
	if bool(result.get("ok", false)):
		push_quest_delta(peer_id, str(player.get("username", "")), quest_id)  # T-058


# ---- inventory handlers (T-045/T-039; absorbed from inventory_rpc.gd) -----


func _inventory(peer_id: int, player: Dictionary, msg_type: String, data: Dictionary) -> void:
	var username: String = player.get("username", "")
	var defs: Dictionary = _all_quest_defs_cache  # for collect refresh after a change
	match msg_type:
		"get_inventory":
			await _inv_reply(peer_id, "inventory", "get_inventory", {"username": username})
		"equip":
			await _inv_reply(
				peer_id,
				"equip_result",
				"equip",
				{
					"username": username,
					"bag_slot": int(data.get("bag_slot", -1)),
					"item_registry": _item_registry_cache,
					"quest_defs": defs,
				}
			)
		"unequip":
			await _inv_reply(
				peer_id,
				"unequip_result",
				"unequip",
				{
					"username": username,
					"equip_slot": str(data.get("equip_slot", "")),
					"quest_defs": defs,
				}
			)
		"drop":
			await _inv_reply(
				peer_id,
				"drop_result",
				"drop",
				{
					"username": username,
					"slot_type": str(data.get("slot_type", "bag")),
					"slot_index": int(data.get("slot_index", -1)),
					"count": int(data.get("count", 1)),
					"quest_defs": defs,
				}
			)


func _inv_reply(peer_id: int, reply_type: String, method: String, params: Dictionary) -> void:
	var result: Dictionary = await _master.call_master(method, params)
	# T-039: enrich slots with item names + int counts so the inventory UI renders the post-op state.
	if result.has("slots"):
		result["slots"] = _enrich_slots_and_push_gear(peer_id, result["slots"])
	result["type"] = reply_type
	_reply.call(peer_id, result)
	funnel.inventory(peer_id, method, result)  # T-705: first_equip beat + bag_full/count refusals
	# T-399: equip/unequip changed the gear set — re-derive (skipped for get_inventory/drop).
	if method in ["equip", "unequip"] and bool(result.get("ok", false)):
		await _repush_combat_stats(peer_id, str(params.get("username", "")))
	# T-570 (report #25): main.gd's _equip can credit a tutorial "equip" objective server-side
	# (result["equip_credited"]), but that credit never reached the client — the quest-tracker HUD
	# stayed stuck at 0/1 until an UNRELATED quest event happened to refresh it. Push the same
	# targeted quest-delta the kill/reach/ability credit paths already push.
	if method == "equip" and bool(result.get("ok", false)):
		for credited_id in result.get("equip_credited", []):
			push_quest_delta(peer_id, str(params.get("username", "")), str(credited_id))


# Shared by every inventory-state push: enrich raw slots with content names/stats, then re-derive
# worn-gear visuals for the positions broadcast (T-225/T-420: enriched slots carry armor_type).
# Single-sourced so _inv_reply's equip/unequip/drop replies and _push_inventory_update below (T-570)
# never drift apart.
func _enrich_slots_and_push_gear(peer_id: int, slots: Array) -> Array:
	var enriched: Array = _CQ.enrich_inventory(slots, _content_items)
	if _gear_update.is_valid():
		_gear_update.call(peer_id, _BB.equipped_from_slots(enriched))
	return enriched


# T-570 (report #30): the gather-grant path mints an item master-side but replies with its own
# "gather_result" type that client_net.gd doesn't route to the bag panel — so the bag looked frozen
# until reopened. Injected into craft_service as a Callable to push a fresh, enriched snapshot.
func _push_inventory_update(peer_id: int, slots: Array) -> void:
	_reply.call(
		peer_id, {"type": "inventory", "slots": _enrich_slots_and_push_gear(peer_id, slots)}
	)


# ---- T-058: targeted delta push (event-driven — no client re-request, no full recompute) ----


# After a change to `quest_id`: push the ONE quest-log entry + ONLY affected NPCs' indicators.
func push_quest_delta(peer_id: int, username: String, quest_id: String) -> void:
	if _master == null or not _content_quests.has(quest_id):
		return
	var entry_result: Dictionary = await _master.call_master(
		"quest_entry", {"username": username, "quest_id": quest_id}
	)
	var raw: Dictionary = entry_result.get("entry", {})
	var lvl := int(entry_result.get("level", 1))  # T-621: keeps the one card's difficulty band
	var rows: Array = [raw] if not raw.is_empty() else []
	var enriched: Array = _CQ.enrich_quest_log(rows, _content_quests, lvl)
	var delta := {
		"type": "quest_delta",
		"quest_id": quest_id,
		"quest": enriched[0] if not enriched.is_empty() else null,
	}
	_reply.call(peer_id, delta)
	await _push_npc_indicator_delta(peer_id, username, quest_id)


# The NPCs whose !/? can change when `quest_id` changes come straight from the index.
func _push_npc_indicator_delta(peer_id: int, username: String, quest_id: String) -> void:
	var npcs: Array = []
	for npc_id in _npc_quest_index:
		if not _npc_quest_index[npc_id].has(quest_id):
			continue
		if not _content_npcs.has(npc_id):
			continue
		npcs.append(_CQ.npc_to_dict(_content_npcs[npc_id]))
	if npcs.is_empty():
		return
	var result: Dictionary = await _master.call_master("get_quest_log", {"username": username})
	var indicators: Dictionary = _CQ.npc_indicators_from_state(
		_content_npcs, _npc_quest_index, result.get("quests", []), int(result.get("level", 1))
	)
	var affected_ids: Array = npcs.map(func(npc: Dictionary): return str(npc.get("id", "")))
	var out: Array = _NIV.build(_content_npcs, affected_ids, indicators)
	_reply.call(peer_id, {"type": "npc_indicator_delta", "npcs": out})


# ---- kill-credit (T-042; server-observed, from main's _check_death_mob) ---
# Server-observed kill credit: quest kill-objectives + mob-kill XP (party-split). Fire-and-forget.
func on_mob_kill(peers: Array, mob: String, xp: int = 0, lvl: int = 1, active: Array = []) -> void:
	if mob == "" or _master == null:
		return
	# T-698: the per-kill O(quests) def scan is a load-time index probe now (kill_quest_index).
	var quest_defs: Dictionary = _kill_quest_index.get(mob, {})
	if quest_defs.is_empty() and xp <= 0:
		return
	var party_size: int = peers.size()
	# T-620: usernames only — master resolves each one's persisted level + sums for the weighted split.
	var party_usernames: Array = []
	if party_size > 1:
		for pid2 in peers:
			var uname2: String = str(PlayerSessions.get_player_view(pid2).get("username", ""))
			if uname2 != "":
				party_usernames.append(uname2)
	for pid in peers:
		# T-698: read-only view — username read per recipient, no session-dict duplicate.
		var username: String = PlayerSessions.get_player_view(pid).get("username", "")
		if username == "":
			continue
		var params := {"username": username, "mob_id": mob, "quest_defs": quest_defs}
		params["mob_xp"] = xp
		params["mob_level"] = lvl
		params["party_size"] = party_size
		if party_size > 1:
			params["party_usernames"] = party_usernames
		if _mentor_svc != null:
			var mentor: Dictionary = _mentor_svc.credit_context(pid)
			params["mentor_level"] = int(mentor["effective_level"])
			params["mentor_opted_in"] = bool(mentor["opted_in"])
			params["mentor_active"] = active.has(pid)
		_credit_kill_async(pid, params)


func _credit_kill_async(peer_id: int, params: Dictionary) -> void:
	var r: Dictionary = await _master.call_master("credit_kill", params)
	_ach.forward(peer_id, r)  # T-367: toast any achievement the kill just earned
	# T-588: repush stats on any XP grant, not level-up only (mirrors _turn_in/_discover_async).
	# T-642: only a real level-up may refill (apply=refill=leveled) — a plain kill never heals.
	var leveled: bool = bool(r.get("leveling", {}).get("leveled_up", false))
	if int(r.get("mob_xp", 0)) > 0 or leveled:
		await _repush_combat_stats(peer_id, str(params.get("username", "")), leveled, leveled)
	for credited_id in r.get("credited", []):  # T-058: kill credit -> targeted delta
		push_quest_delta(peer_id, str(params["username"]), str(credited_id))


# T-426: forward an accepted ability use so the master credits `use_ability` tutorial objectives.
# Underscored so it stays off the 20-public-method budget (external-call precedent: _set_heal).
func _on_ability_used(peer_id: int, ability_slug: String) -> void:
	if ability_slug == "" or _master == null:
		return
	var quest_defs: Dictionary = _CQ.ability_quest_defs(_content_quests, ability_slug)
	if quest_defs.is_empty():
		return
	var username: String = PlayerSessions.get_player(peer_id).get("username", "")
	if username == "":
		return
	var params := {"username": username, "ability_slug": ability_slug, "quest_defs": quest_defs}
	var r: Dictionary = await _master.call_master("credit_ability", params)
	for credited_id in r.get("credited", []):
		push_quest_delta(peer_id, username, str(credited_id))


# T-426 slice 4: forward a server-detected training-effigy interrupt so the master credits the
# tutorial `interrupt` objective (q_tut_03). Called from main._commit_ability_result the instant
# training_interrupt.telegraph_broken is true — the interrupter's peer_id is the ability's caster,
# so attribution is the actual player who broke the wind-up (not a threat guess). Underscored to
# stay off the 20-public-method budget, mirroring _on_ability_used.
func _on_cast_interrupted(peer_id: int, mob_alias: String) -> void:
	if mob_alias == "" or _master == null:
		return
	var quest_defs: Dictionary = _CQ.interrupt_quest_defs(_content_quests, mob_alias)
	if quest_defs.is_empty():
		return
	var username: String = PlayerSessions.get_player(peer_id).get("username", "")
	if username == "":
		return
	var params := {"username": username, "mob_alias": mob_alias, "quest_defs": quest_defs}
	var r: Dictionary = await _master.call_master("credit_interrupt", params)
	for credited_id in r.get("credited", []):
		push_quest_delta(peer_id, username, str(credited_id))


# ---- T-073/T-644: loot delivery (server-observed, from main's _check_death_mob) ---


# Deliver a killed mob's rolled loot [{item,count}] to the killer's bag, falling back to other
# party members with space, and holding (never destroying) the drop on total failure — see
# loot_delivery.gd for the mechanism.
func on_mob_loot(peer_id: int, items: Array) -> void:
	var fallback: Array = [] if _mentor_svc == null else _mentor_svc.party_peers_of(peer_id)
	_loot_delivery.deliver(
		peer_id,
		fallback,
		items,
		_item_registry_cache,
		_all_quest_defs_cache,
		Callable(self, "push_quest_delta")
	)


# T-333/T-473: shares come from dungeon_loot.distribute — independent rolls for a plain party, one
# round-robin gated drop for a raid (the T-472 loot_rule seam); master applies the cadence lockout.
func on_dungeon_loot(peer_ids: Array, boss_id: String, rng: RandomNumberGenerator) -> void:
	if not content_ops.has_dungeon_schedule(boss_id):
		return
	var party: Dictionary = {} if _mentor_svc == null else _mentor_svc.party_record_for(peer_ids)
	var sched: Dictionary = _dungeon_schedule.get(boss_id, {})
	for share: Dictionary in _DUNGEON_LOOT.distribute(sched, peer_ids, party, rng):
		var peer := int(share["peer"])
		var username := str(PlayerSessions.get_player(peer).get("username", ""))
		if username == "":
			continue
		_grant_dungeon_loot_async(peer, username, boss_id, share["rolled"])


func _grant_dungeon_loot_async(peer_id: int, username: String, boss_id: String, rolled: Dictionary):
	var result: Dictionary = await _DUNGEON_LOOT.grant(
		_master,
		username,
		boss_id,
		rolled,
		{"items": _item_registry_cache, "quests": _all_quest_defs_cache}
	)
	if bool(result.get("ok", false)):
		for credited_id in result.get("credited", []):
			push_quest_delta(peer_id, username, str(credited_id))


# ---- T-046: reach credit (movement-observed, from main._on_request_move) --
# T-698: carved to reach_service.gd — precomputed reach list + the ~4 Hz per-player throttle live
# there; these delegators keep main's and instance_service's call surface unchanged.
# Credit reach objectives the player NEWLY entered (in new_pos radius, not old_pos). No client pos.
func on_player_moved(peer_id: int, username: String, old_pos: Vector3, new_pos: Vector3) -> void:
	_reach.on_player_moved(peer_id, username, old_pos, new_pos)


# ---- T-046: NPC !/? indicator query (client request) ---------------------


func _npc_indicators(peer_id: int, player: Dictionary) -> void:
	var result: Dictionary = await _master.call_master(
		"get_quest_log", {"username": player.get("username", "")}
	)
	# Enrich per-NPC indicator with name + position for the client to render over the NPC.
	var indicators: Dictionary = _CQ.npc_indicators_from_state(
		_content_npcs, _npc_quest_index, result.get("quests", []), int(result.get("level", 1))
	)
	var out: Array = _NIV.build(_content_npcs, _content_npcs.keys(), indicators)
	_reply.call(peer_id, {"type": "npc_indicators", "npcs": out})


func _set_mentorship(service) -> void:
	_mentor_svc = service


func set_gear_update(cb: Callable) -> void:
	_gear_update = cb
	_wardrobe.set_gear_update(cb)


func set_kit_refresh(cb: Callable) -> void:
	_kit_refresh = cb


func set_mark_mount_learned(cb: Callable) -> void:  # T-658: passthrough to the flight/trainer seam
	_flight.set_mark_learned(cb)
