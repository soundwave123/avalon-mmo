# T-048: client network layer — the decoupled router/intent brain.
#
# RefCounted + injected Callables (mirrors world_rpc's `_reply` pattern): the transport Node feeds
# incoming server messages to handle_server_message() and supplies `send_fn` (its @rpc send); UI
# handlers are injected too — so this whole layer is unit-testable without a live peer. The client
# sends INTENTS only and never asserts state (server-authoritative). Slice A of T-048; the ENet/WS
# transport that drives it (mirroring server/world/tests/test_client.gd) is the next slice.
extends RefCounted

# T-705: preloaded, not referenced by class_name — a source-run client's global class cache is a
# gitignored local artifact that can lag a new script (s26 import-cache trap).
const BootClock = preload("res://scripts/net/boot_clock.gd")

# Injected handler map {category: Callable(data: Dictionary)}. Categories:
#   quest_log | inventory | npc_indicators | result | combat | loot_notice
var _handlers: Dictionary = {}
var _send_fn: Callable = Callable()
# T-372: reconstructs the full player view from the server's per-peer delta position frames before
# the "positions" handler ever sees it, so every downstream consumer stays delta-unaware.
var _pos_delta = preload("res://scripts/net/positions_delta.gd").new()
# T-572: server-confirmed mount state (set only from an authoritative "mount_state" reply below —
# the client never asserts this on its own). LocalPlayer polls it each physics tick to pick its
# predicted move speed, so mounting the M key actually moves the player faster, not just the label.
var _mounted: bool = false
# T-573: the server-chosen mount visual id riding the same authoritative "mount_state" reply
# (mount_service.gd::visual_for() — cosmetic skin if set, else the mount id). LocalPlayer reads it
# on a mount transition to spawn the matching MountVisuals model; cleared on dismount.
var _mount_visual: String = ""


func setup(send_fn: Callable, handlers: Dictionary) -> void:
	_send_fn = send_fn
	_handlers = handlers


# Server → client. The world tags every message with `type`; we group them into handler categories
# and pass the whole dict (shape-agnostic — the handler extracts what it needs). Unknown types are
# ignored so a newer server can add messages without breaking an older client.
func handle_server_message(data: Dictionary) -> void:
	match str(data.get("type", "")):
		"quest_log":
			_dispatch("quest_log", data)
		"inventory", "equip_result", "unequip_result", "drop_result":
			_dispatch("inventory", data)
		"npc_indicators":
			_dispatch("npc_indicators", data)
		"accept_quest_result", "turn_in_result", "talk_result", "abandon_result":
			_dispatch("result", data)
		"spend_talent_result", "set_class_result":  # T-064/T-065: talent/class replies
			_dispatch("result", data)
		"set_gender_result":  # T-520: gender-selection ack (creation, before class)
			_dispatch("result", data)
		"set_name_result":  # T-716: name-step ack (creation, after class)
			_dispatch("result", data)
		# T-583 (report #39): use_item_result was never routed at all — using an item gave zero
		# client feedback. The bag refresh itself rides a SEPARATE "inventory" push (the craft_service
		# T-570 seam, fired only on success); this reply carries ok/reason/effect, so it rides the
		# SAME "result" category the T-575/T-578 quest-action failure toasts use.
		"use_item_result":
			_dispatch("result", data)
		"service_ack":  # T-431: confirmed travel state
			_dispatch("result", data)
		# T-648 (W1b flag): instance_denied (level_too_low/too_far/requires_raid/wrong_threshold)
		# reached the client already (instance_service.gd's _lfg_reply == main._send_to_peer) but
		# was never routed anywhere — an under-level player bouncing off the crypt gate got zero
		# visible feedback. Same "result" category the T-575/T-578 failure toasts ride.
		"instance_denied":
			_dispatch("result", data)
		# T-719: the crypt stair now ROUTES an under-level party into the Shallow Graves instead of
		# denying it, so the player needs to be told which dungeon they just walked into and what
		# opens later. Same "result" category as its instance_denied sibling.
		"instance_entered":
			_dispatch("result", data)
		# T-662 (#69): rift_sealed (dead/not_eligible/not_in_ashmoor) reached the client already
		# (instance_service.gd's _lfg_reply == main._send_to_peer, same wiring as instance_denied)
		# but fell through this router unrouted — the era-rift monolith rejection was completely
		# silent. Same "result" category + T-575/T-648 failure-toast idiom.
		"rift_sealed":
			_dispatch("result", data)
		"mount_state":  # T-431 ack; T-572: cache mounted for LocalPlayer's speed prediction (no new
			# main.gd handler needed — mirrors the T-362/T-401 "no new handler" self-registration idiom)
			_mounted = bool(data.get("mounted", false))
			# T-573: the reply's `visual` field names the mount model to render (empty on dismount).
			_mount_visual = str(data.get("visual", "")) if _mounted else ""
			_dispatch("result", data)
		"talents":  # T-064: spent-talent state + point budget
			_dispatch("talents", data)
		"player_stats":  # T-060: peer-only level/XP for the HUD bar
			_dispatch("player_stats", data)
		"quest_delta", "npc_indicator_delta":  # T-058: targeted server pushes
			_dispatch("quest_delta", data)
		# T-072: cast_cancelled / death / respawn were silently dropped (_: pass) — the
		# feedback parser supports them all but never received them in the real client.
		"ability_result", "ability_rejected", "cast_started", "cast_cancelled":
			_dispatch("combat", data)
		"mob_death", "mob_respawn", "player_death", "player_respawn":
			_dispatch("combat", data)
		"class_kit":  # T-072: the action bar's kit offer — dropped == action bar dead
			_dispatch("class_kit", data)
		"positions":  # T-054: local reconcile + (T-055) remote entities; T-372: merge delta → full view
			_dispatch("positions", _pos_delta.reconstruct(data))
		"party_invite":  # T-280: pending invite pushed to the invitee
			_dispatch("party_invite", data)
		"party_update":  # T-280: roster (members + leader) pushed to every member
			_dispatch("party_update", data)
		"party_result":  # T-280: ack of the actor's own party intent
			_dispatch("party_result", data)
		"lfg_board":  # T-334: LFG-lite board reply/ack (board rows: peer/name/level/role)
			_dispatch("lfg_board", data)
		"chat", "chat_rejected", "emote", "help_subscription", "maintenance", "kicked":
			_dispatch("chat", data)
		"loot_notice":  # T-649: bag-full kill loot held for retry (never silently lost)
			_dispatch("loot_notice", data)
		"trade_update", "trade_result":  # T-363: server-owned trade session mirror + rejections
			_dispatch("trade", data)
		"social_list", "social_result":  # T-361: friends/ignore lists (+ rejections)
			_dispatch("social", data)
		# T-362: guild roster/invite/result/disband — rides the shared "social" category so
		# client/main.gd (at the gdlint cap) needs no new handler; SocialUi fans them to the guild panel.
		"guild_roster", "guild_result", "guild_invite", "guild_disbanded":
			_dispatch("social", data)
		"guild_discovery", "guild_seek_board", "guild_who", "mentor_board", "mentor_result":
			_dispatch("social", data)
		"achievement_list", "achievements_earned", "discovery_earned", "renown_list":  # +T-678
			_dispatch("achievements", data)
		# T-401: the routed-reply hub. This NAMED SET of PvP replies (+ future routed panels) rides a
		# SINGLE "pvp" category into ReplyRouter, which fans them to the panel that self-registered the
		# type — so client_net/main.gd need no per-panel handler as more reply types land.
		"pvp_leaderboard", "pvp_rating", "pvp_tracks", "pvp_result":
			_dispatch("pvp", data)
		# T-414: the crafting UI replies ride the SAME routed-reply hub — the "pvp" category is just
		# the internal transport label; ReplyRouter fans each reply to the panel/layer that
		# self-registered its `type` (RecipePanel + GatherNodesLayer), so main.gd needs no new handler.
		"gather_nodes", "gather_result", "craft_result", "learn_recipe_result", "recipe_catalog":
			_dispatch("pvp", data)
		"wardrobe_state", "wardrobe_result":  # T-428: self-registered wardrobe panel replies
			_dispatch("pvp", data)
		"performance_recap":  # T-429: peer-only self mirror, self-registered SolidWindow panel
			_dispatch("pvp", data)
		"weekly_state":  # T-480: self-registered weekly vault panel reply
			_dispatch("pvp", data)
		_:
			pass


func _dispatch(category: String, data: Dictionary) -> void:
	if _handlers.has(category) and (_handlers[category] as Callable).is_valid():
		_handlers[category].call(data)


# T-572: the last server-confirmed mount state (never client-asserted). LocalPlayer's move
# prediction reads this directly instead of routing through main.gd (which sits at the gdlint cap).
# Underscored (like _toggle_mount/_set_bar_layout above) to stay under the 20-public-method budget.
func _is_mounted() -> bool:
	return _mounted


# T-573: the last server-confirmed mount visual id ("" while dismounted). Same direct-read seam
# (and the same underscore public-method-budget reasoning) as _is_mounted above.
func _mount_visual_id() -> String:
	return _mount_visual


# ---- intents (client sends INTENT only; server validates + persists) -----


func request_quest_log() -> void:
	_send({"type": "request_quest_log"})


# T-705: ONE boot-timing report per session, sent the moment the world is interactive — this is the
# only place the client can measure its own launch→login→interactive dead air. Fire-and-forget, two
# durations, no wall clock; the world clamps them and drops them on the 5s telemetry batch.
# Underscored for the 20-public-method budget (precedent: _toggle_mount / _set_bar_layout).
func _report_boot_timing() -> void:
	BootClock.mark_interactive()
	var payload := BootClock.timing_payload()
	if payload.is_empty():
		return  # boot phases were never marked (harness/dev boot) — report nothing over a guess
	payload["type"] = "client_boot_timing"
	_send(payload)


func accept_quest(quest_id: String) -> void:
	_send({"type": "accept_quest", "quest_id": quest_id})


func turn_in(quest_id: String) -> void:
	_send({"type": "turn_in", "quest_id": quest_id})


func talk(npc_id: String) -> void:
	_send({"type": "talk", "npc_id": npc_id})


# T-145: service-hub stub intent (browse / set_home / …). Server acks after proximity + gating.
# T-208: real service ops carry parameters (slots, bids, ability ids) via the optional `extra`.
func service_intent(npc_id: String, action: String, extra: Dictionary = {}) -> void:
	var msg := {"type": "service_intent", "npc_id": npc_id, "action": action}
	msg.merge(extra)
	_send(msg)


func abandon(quest_id: String) -> void:
	_send({"type": "abandon", "quest_id": quest_id})


# T-054: movement intent — ground delta (server x,y). Server validates speed + is authoritative.
func request_move(dx: float, dy: float) -> void:
	_send({"type": "request_move", "dx": dx, "dy": dy})


# T-057: combat — cast an ability at a target (ability_id 1 = Strike). Server validates GCD/range.
func request_use_ability(ability_id: int, target_id: int) -> void:
	_send({"type": "use_ability", "ability_id": ability_id, "target_id": target_id})


# T-431: intent only. Learned state, mounted state, visual and both speed caps live server-side.
# Underscored to preserve the ClientNet 20-public-method budget.
func _toggle_mount() -> void:
	_send({"type": "mount_intent", "action": "toggle"})


# T-422c: the desired action-bar slot order (ability ids). Intent only — the server validates it's a
# permutation of the character's known kit and persists it; the client never asserts what it owns.
# Underscored for the 20-public-method lint budget (external-call precedent: world_rpc._set_heal).
func _set_bar_layout(ability_ids: Array) -> void:
	_send({"type": "set_bar_layout", "layout": ability_ids})


# T-064/T-065: talents + class selection — intents only; the server validates every spend.
func spend_talent(talent_id: String) -> void:
	_send({"type": "spend_talent", "talent_id": talent_id})


func request_talents() -> void:
	_send({"type": "request_talents"})


# T-508: respec — wipe every spent point (master _reroll_talents). Intent only; the server owns the
# clear. (The world->master route for this intent is the one server-side follow-up this client lane
# does not touch — see the T-508 build log.) Underscored for the 20-public-method lint budget
# (external-call precedent: _set_bar_layout).
func _reroll_talents() -> void:
	_send({"type": "reroll_talents"})


func set_class(char_class: String) -> void:
	_send({"type": "set_class", "class": char_class})


# T-520: gender selection at character creation (server persists + locks; before class).
func set_gender(gender: String) -> void:
	_send({"type": "set_gender", "gender": gender})


# T-716: the name step at character creation (server validates charset/length/uniqueness and
# persists it one-shot; after class). The server also RENAMES the live session identity on
# success. Underscored for the 20-public-method lint budget (like _reroll_talents).
func _set_character_name(name: String) -> void:
	_send({"type": "set_name", "name": name})


func request_npc_indicators() -> void:
	_send({"type": "request_npc_indicators"})


func get_inventory() -> void:
	_send({"type": "get_inventory"})


func equip(bag_slot: int) -> void:
	_send({"type": "equip", "bag_slot": bag_slot})


func unequip(equip_slot: String) -> void:
	_send({"type": "unequip", "equip_slot": equip_slot})


func drop(slot_type: String, slot_index: int, count: int) -> void:
	_send({"type": "drop", "slot_type": slot_type, "slot_index": slot_index, "count": count})


func _send(msg: Dictionary) -> void:
	if _send_fn.is_valid():
		_send_fn.call(msg)


# T-280: party intents (server-authoritative roster).
func party(intent: String, target: String = "") -> void:
	# intent: "invite" (needs target username) | "accept" | "decline" | "leave" | "disband"
	var msg := {"type": "party_" + intent}
	if not target.is_empty():
		msg["target"] = target
	_send(msg)
