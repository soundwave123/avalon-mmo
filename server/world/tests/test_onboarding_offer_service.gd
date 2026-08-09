extends "res://addons/gut/test.gd"
# T-710: server-driven tutorial offers. Proves (against the REAL shipped content) that:
#   * chain_successor_giver reads the authored chain (q_tut_01 -> 02 -> 03, all at the Drillmaster);
#   * push_tutorial_offer pushes ONE talk_result built by the master's own talk evaluation — an
#     accept-able offer opens the client prompt, and nothing is pushed when the master offers
#     nothing (already active / graduated edge) or only a proximity-gated turn-in would show;
#   * maybe_continue_chain re-offers the successor only for tutorial-chain turn-ins;
#   * credited talk objectives ride the same quest-delta seam a real talk uses.

const OfferService = preload("res://scripts/onboarding_offer_service.gd")
const ContentRegistry = preload("res://scripts/content/content_registry.gd")
const ContentQuery = preload("res://scripts/content/content_query.gd")


class FakeMaster:
	var calls: Array = []
	var responses: Dictionary = {}  # method -> Dictionary reply

	func call_master(method: String, params: Dictionary) -> Dictionary:
		calls.append({"method": method, "params": params})
		await Engine.get_main_loop().process_frame
		if responses.has(method):
			return responses[method]
		return {"available": [], "turn_in_ready": [], "credited": [], "talk_text": ""}


var _quests: Dictionary = {}
var _npcs: Dictionary = {}
var _fm: FakeMaster = null
var _svc = null
var _replied: Array = []
var _deltas: Array = []


func before_each() -> void:
	var loaded: Dictionary = ContentRegistry.load_all("res://data")
	assert_eq(loaded["errors"], [], "shipped content loads clean")
	_quests = loaded["quests"]
	_npcs = loaded["npcs"]
	_fm = FakeMaster.new()
	_replied = []
	_deltas = []
	_svc = OfferService.new()
	_svc.setup(
		_fm,
		func(_pid, d): _replied.append(d),
		_quests,
		_npcs,
		ContentQuery.all_quest_defs(_quests),
		func(_pid, _u, qid): _deltas.append(str(qid))
	)


# ---- chain_successor_giver: the authored chain, read pure from content -------


func test_chain_successor_giver_walks_the_tutorial_chain() -> void:
	assert_eq(
		ContentQuery.chain_successor_giver("q_tut_01", _quests),
		"npc_drillmaster",
		"q_tut_02 (prereq q_tut_01) is given by the Drillmaster"
	)
	assert_eq(ContentQuery.chain_successor_giver("q_tut_02", _quests), "npc_drillmaster")
	# T-719: graduation is no longer the end of the chain. q_tut_04 (The Shallow Graves, the
	# capstone mini-dungeon) is prereq'd on q_tut_03, so Hale's turn-in hands the player straight to
	# Father Osric — the zero-gap handoff wave 1 built, extended one step past the training ring.
	assert_eq(
		ContentQuery.chain_successor_giver("q_tut_03", _quests),
		"npc_village_parson",
		"graduation hands off to the capstone's giver"
	)
	assert_eq(
		ContentQuery.chain_successor_giver("q_tut_04", _quests),
		"",
		"the chain ends at the capstone — no successor"
	)
	assert_eq(ContentQuery.chain_successor_giver("", _quests), "", "empty id is safe")


# ---- push_tutorial_offer -----------------------------------------------------


func test_first_entry_push_offers_the_chain_head() -> void:
	_fm.responses["talk"] = {
		"available": ["q_tut_01"], "turn_in_ready": [], "credited": [], "talk_text": "New blood?"
	}
	await _svc.push_tutorial_offer(7, {"username": "newbie"})
	assert_eq(_replied.size(), 1, "exactly one pushed talk_result")
	var r: Dictionary = _replied[0]
	assert_eq(str(r["type"]), "talk_result")
	assert_eq(str(r["npc_id"]), "npc_drillmaster", "the offer comes from the tutorial giver")
	assert_true(bool(r["ok"]))
	var offers: Array = r["offers"]
	assert_eq(offers.size(), 1)
	assert_eq(str(offers[0]["quest_id"]), "q_tut_01", "the chain head is the card")
	assert_eq(str(offers[0]["kind"]), "offer", "an ACCEPT card — never a silent accept")
	assert_eq(str(_fm.calls[0]["method"]), "talk", "built by the master's own talk evaluation")


func test_no_push_when_the_master_offers_nothing() -> void:
	_fm.responses["talk"] = {"available": [], "turn_in_ready": [], "credited": []}
	await _svc.push_tutorial_offer(7, {"username": "midchain"})
	assert_eq(_replied.size(), 0, "the step is already active -> no empty prompt")


func test_no_push_for_a_turn_in_only_state() -> void:
	# A reconnect with objectives complete: the actual turn_in intent is proximity-gated, so a
	# spawn-time turn-in card would dead-end. The tracker's "ready to turn in" guides instead.
	_fm.responses["talk"] = {"available": [], "turn_in_ready": ["q_tut_01"], "credited": []}
	await _svc.push_tutorial_offer(7, {"username": "readyer"})
	assert_eq(_replied.size(), 0, "turn-in-ready alone never pushes a prompt")


func test_master_error_pushes_nothing() -> void:
	_fm.responses["talk"] = {"error": "unknown_character"}
	await _svc.push_tutorial_offer(7, {"username": "ghost"})
	assert_eq(_replied.size(), 0)


# ---- maybe_continue_chain ----------------------------------------------------


func test_tutorial_turn_in_re_offers_the_successor() -> void:
	_fm.responses["talk"] = {
		"available": ["q_tut_02"], "turn_in_ready": [], "credited": [], "talk_text": "Gear up."
	}
	await _svc.maybe_continue_chain(7, {"username": "newbie"}, "q_tut_01")
	assert_eq(_replied.size(), 1, "the next chain step is offered in the same dialog flow")
	var offers: Array = _replied[0]["offers"]
	assert_eq(str(offers[0]["quest_id"]), "q_tut_02")


func test_non_tutorial_turn_in_never_continues() -> void:
	await _svc.maybe_continue_chain(7, {"username": "vet"}, "q001")
	assert_eq(_fm.calls.size(), 0, "no master round-trip outside the tutorial chain")
	assert_eq(_replied.size(), 0)


# T-719: graduation now CONTINUES the chain into the capstone (Osric's q_tut_04) instead of ending
# it. The quiet-tail case moved one step along: q_tut_04 is the last link, so ITS turn-in is what
# must push nothing. The push itself still only happens when the master offers something accept-able
# (the FakeMaster's default reply is an empty offer list), so no card is ever opened on an empty
# prompt — that guarantee is unchanged.
func test_graduation_hands_off_to_the_capstone_giver() -> void:
	await _svc.maybe_continue_chain(7, {"username": "newbie"}, "q_tut_03")
	assert_eq(_fm.calls.size(), 1, "a successor exists -> Osric's talk is evaluated")
	assert_eq(str(_fm.calls[0]["params"]["npc"]["id"]), "npc_village_parson")
	assert_eq(_replied.size(), 0, "…and nothing is pushed while the master offers nothing")


func test_capstone_turn_in_ends_the_chain_quietly() -> void:
	await _svc.maybe_continue_chain(7, {"username": "newbie"}, "q_tut_04")
	assert_eq(_fm.calls.size(), 0, "no successor exists -> no talk, no push")
	assert_eq(_replied.size(), 0)


func test_credited_talk_objectives_ride_the_delta_seam() -> void:
	_fm.responses["talk"] = {
		"available": ["q_tut_01"], "turn_in_ready": [], "credited": ["q_somewhere"]
	}
	await _svc.push_tutorial_offer(7, {"username": "newbie"})
	assert_eq(
		_deltas, ["q_somewhere"], "talk credit pushes the same targeted delta a real talk does"
	)


func test_pushed_offer_authorizes_one_remote_accept() -> void:
	# T-603-gate bypass: a push records authorization; consume returns true exactly once.
	_fm.responses["talk"] = {
		"available": ["q_tut_01"], "turn_in_ready": [], "credited": [], "talk_text": "New blood?"
	}
	await _svc.push_tutorial_offer(7, {"username": "newbie"})
	assert_true(_svc.consume_pushed(7, "q_tut_01"), "pushed offer must authorize the accept")
	assert_false(_svc.consume_pushed(7, "q_tut_01"), "authorization is consumed, not reusable")
	assert_false(_svc.consume_pushed(7, "q003"), "never authorizes a quest that was not pushed")
	assert_false(_svc.consume_pushed(9, "q_tut_01"), "never authorizes another peer")
