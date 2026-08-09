# T-710 (portal #106): server-driven tutorial quest offers — the two pushes that close the
# "nothing offers the tutorial" gap:
#   1. push_tutorial_offer — on a force_tutorial account's world entry (the account_state gate,
#      onboarding_store.should_force_tutorial), the world PUSHES the tutorial giver's talk_result so
#      the client's QuestOfferPanel opens the q_tut_01 offer with no blind NPC hunt. Never a silent
#      auto-accept: the player still chooses Accept. The client defers the panel behind the
#      creation modals (the T-714 strictly-serial rule).
#   2. maybe_continue_chain — after a tutorial turn-in, re-offer the chain successor in the SAME
#      dialog flow (the WoW pattern) so active_quest never gaps between q_tut_01 -> 02 -> 03.
#
# Both routes run the SAME master "talk" op a real NPC click runs — the master stays the only
# authority on what is offered/acceptable — and only push when at least one ACCEPT-able offer
# exists (a proximity-free turn-in card would dead-end at the actual turn_in intent's range gate).
# Talk-objective crediting therefore matches a real talk; credited deltas ride the same push seam.
extends RefCounted

const _CQ = preload("res://scripts/content/content_query.gd")
const PlayerSessions = preload("res://scripts/player_sessions.gd")

# The guided chain's first quest. Its giver (content-derived, never a hard-coded NPC id) is who the
# first-entry offer comes from; graduation (q_tut_03) stays a master-side concern (T-550).
const CHAIN_HEAD := "q_tut_01"
const CHAIN_PREFIX := "q_tut"  # scope: only tutorial turn-ins auto-continue (see the ticket)

var _master = null  # MasterClient (call_master)
var _reply: Callable = Callable()  # main._send_to_peer(peer_id, dict)
var _content_quests: Dictionary = {}
var _content_npcs: Dictionary = {}
var _quest_defs: Dictionary = {}  # the world_rpc all-quest-defs cache (master talk input)
var _push_delta: Callable = Callable()  # world_rpc.push_quest_delta(peer_id, username, quest_id)
# peer_id -> {quest_id: true}: accepts authorized by a push. A server-PUSHED offer must be
# acceptable from wherever the player stands (the T-603 accept gate exists for FORGED intents;
# this offer is the server's own). Entries are consumed on accept — one authorization per push.
var _pushed: Dictionary = {}


func setup(
	master,
	reply: Callable,
	content_quests: Dictionary,
	content_npcs: Dictionary,
	quest_defs: Dictionary,
	push_delta: Callable
) -> void:
	_master = master
	_reply = reply
	_content_quests = content_quests
	_content_npcs = content_npcs
	_quest_defs = quest_defs
	_push_delta = push_delta


# The tutorial giver, resolved from content (Drillmaster Hale in the shipped data).
func tutorial_giver() -> String:
	if _content_quests.has(CHAIN_HEAD):
		return str(_content_quests[CHAIN_HEAD].giver_npc)
	return ""


# T-710 fix 1: the first-entry offer. main.gd calls this at handshake for a force_tutorial account;
# the master's talk evaluation decides WHICH chain step is offerable (a mid-chain reconnect resumes
# wherever it left off, and an account with the step already active gets no push at all).
func push_tutorial_offer(peer_id: int, player: Dictionary = {}) -> void:
	if player.is_empty():
		player = PlayerSessions.get_player(peer_id)
	if not player.is_empty():
		await _push_npc_offers(peer_id, player, tutorial_giver())


# T-710 fix 2: a successful tutorial turn-in immediately re-offers the chain successor in the same
# dialog. The player just turned in AT this NPC, so the interaction context (and proximity) is real.
func maybe_continue_chain(peer_id: int, player: Dictionary, quest_id: String) -> void:
	if not quest_id.begins_with(CHAIN_PREFIX):
		return
	var npc_id := _CQ.chain_successor_giver(quest_id, _content_quests)
	if npc_id != "":
		await _push_npc_offers(peer_id, player, npc_id)


# True exactly once per pushed (peer, quest): world_rpc's accept gate lets a pushed offer through
# the T-603 proximity check by consuming its authorization here.
func consume_pushed(peer_id: int, quest_id: String) -> bool:
	var peer_map: Dictionary = _pushed.get(peer_id, {})
	if not peer_map.get(quest_id, false):
		return false
	peer_map.erase(quest_id)
	return true


# Run the real master talk op for npc_id and push its talk_result WITHOUT a proximity gate (both
# callers are server-initiated, so there is no client input to distrust). Only ACCEPT-able offers
# are drawn (see the header); nothing is pushed when the master offers none.
func _push_npc_offers(peer_id: int, player: Dictionary, npc_id: String) -> void:
	if _master == null or not _content_npcs.has(npc_id) or not _reply.is_valid():
		return
	var username := str(player.get("username", ""))
	var result: Dictionary = await (
		_master
		. call_master(
			"talk",
			{
				"username": username,
				"npc": _CQ.npc_to_dict(_content_npcs[npc_id]),
				"quest_defs": _quest_defs,
			}
		)
	)
	if result.has("error"):
		return
	var offers: Array = _CQ.talk_previews(result.get("available", []), [], _content_quests)
	if offers.is_empty():
		return  # nothing accept-able right now — never push an empty prompt
	var peer_map: Dictionary = _pushed.get(peer_id, {})
	for offer in offers:
		peer_map[str(offer.get("quest_id", ""))] = true
	_pushed[peer_id] = peer_map
	var npc = _content_npcs[npc_id]
	(
		_reply
		. call(
			peer_id,
			{
				"type": "talk_result",
				"npc_id": npc_id,
				"ok": true,
				"trainer": bool(npc.trainer),
				"service": str(npc.service),
				"name": str(npc.name),
				"talk_text": str(result.get("talk_text", "")),
				"offers": offers,
			}
		)
	)
	if _push_delta.is_valid():  # talk credit -> targeted delta, mirroring world_rpc._talk
		for credited_id in result.get("credited", []):
			_push_delta.call(peer_id, username, str(credited_id))
