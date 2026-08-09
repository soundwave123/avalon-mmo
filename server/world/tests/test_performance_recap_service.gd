extends "res://addons/gut/test.gd"
# T-429: stateful world wrapper — stable-character history and peer-only replies.

const RecapService = preload("res://scripts/performance_recap_service.gd")
const _MD = preload("res://scripts/combat/mob_data.gd")


# Minimal duck for target_resources — relay_mob_damage only reads .hp / .max_hp off it.
class _Res:
	extends RefCounted
	var hp: int
	var max_hp: int

	func _init(h: int, m: int) -> void:
		hp = h
		max_hp = m


var _sent: Array = []
var _telemetry: Array = []
var _svc = null


func before_each() -> void:
	_sent = []
	_telemetry = []
	_svc = RecapService.new()
	_svc.setup(
		func(peer_id: int, msg: Dictionary): _sent.append({"peer": peer_id, "msg": msg}),
		20,
		Callable(),
		func(kind: String, account, character, payload: Dictionary):
			_telemetry.append(
				{"kind": kind, "account": account, "character": character, "payload": payload}
			)
	)


func _hit(caster: int, target: int, amount: int) -> Dictionary:
	return {
		"type": "ability_result",
		"ability_id": 101,
		"ability_name": "Heroic Strike",
		"caster_id": caster,
		"target_id": target,
		"damage": amount,
		"outcome": "hit",
		"mitigated": 5,
		"interrupt_landed": false,
		"tick": 10,
	}


func _incoming_damage(caster: int, target: int, amount: int, tick: int) -> Dictionary:
	return {
		"type": "damage",
		"caster_id": caster,
		"target_id": target,
		"damage": amount,
		"outcome": "hit",
		"mitigated": 2,
		"tick": tick,
	}


func test_encounter_close_sends_each_participant_only_their_own_recap() -> void:
	_svc.record_ability(_hit(11, 22, 30), 11, "alice", 22, "bob", "duel", "Duel")
	_svc.finish_target(22, "duel", "Duel", 30)
	assert_eq(_sent.size(), 2)
	assert_eq(_sent[0]["peer"], 11)
	assert_eq(_sent[0]["msg"]["type"], "performance_recap")
	assert_eq(_sent[0]["msg"]["recap"]["damage_done"], 30)
	assert_eq(_sent[0]["msg"]["recap"]["damage_taken"], 0)
	assert_eq(_sent[1]["peer"], 22)
	assert_eq(_sent[1]["msg"]["recap"]["damage_done"], 0)
	assert_eq(_sent[1]["msg"]["recap"]["damage_taken"], 30)
	assert_false(_sent[0]["msg"].has("other_players"), "reply has no group-performance payload")
	assert_false(_sent[1]["msg"].has("other_players"), "reply has no group-performance payload")


func test_scripted_death_recap_counts_incoming_damage_stream() -> void:
	_svc.record_ability(_incoming_damage(9001, 22, 35, 10), 9001, "", 22, "bob", "wolf", "Wolf")
	_svc.record_ability(_incoming_damage(9001, 22, 65, 20), 9001, "", 22, "bob", "wolf", "Wolf")
	_svc.finish_player_death(22, "bob", 21)
	assert_eq(_sent.size(), 1)
	var recap: Dictionary = _sent[0]["msg"]["recap"]
	assert_eq(recap["damage_taken"], 100, "100 -> 0 death session reports incoming damage")
	assert_eq(recap["healing_taken"], 0, "healing column stays stream-derived")
	assert_eq(recap["deaths"], 1, "death count is pinned by the player_death event")


func test_self_target_event_is_aggregated_once() -> void:
	var self_heal := _hit(11, 11, 18)
	self_heal["ability_name"] = "Mend"
	self_heal["outcome"] = "heal"
	self_heal["mitigated"] = 0
	_svc.record_ability(self_heal, 11, "alice", 11, "alice", "duel", "Duel")
	_svc.finish_target(11, "duel", "Duel", 30)
	assert_eq(_sent.size(), 1)
	assert_eq(_sent[0]["msg"]["recap"]["healing_done"], 18)
	assert_eq(_sent[0]["msg"]["recap"]["healing_taken"], 18)
	assert_eq(_sent[0]["msg"]["recap"]["abilities"][0]["uses"], 1)


func test_manual_request_resolves_server_character_not_claimed_identity() -> void:
	_svc.record_ability(_hit(11, 9001, 40), 11, "alice", 9001, "", "wolf", "Wolf")
	_svc.finish_target(9001, "wolf", "Wolf", 30)
	_svc.record_ability(_hit(22, 9002, 7), 22, "bob", 9002, "", "wolf", "Wolf")
	_svc.finish_target(9002, "wolf", "Wolf", 30)
	_sent.clear()

	_svc.handle("performance_recap_request", 22, "bob", 40)
	assert_eq(_sent.size(), 1)
	assert_eq(_sent[0]["peer"], 22)
	assert_eq(_sent[0]["msg"]["recap"]["damage_done"], 7, "Bob cannot request Alice's 40")


func test_history_survives_peer_change_but_stays_per_character() -> void:
	_svc.record_ability(_hit(11, 9001, 40), 11, "alice", 9001, "", "wolf", "Wolf")
	_svc.finish_target(9001, "wolf", "Wolf", 30)
	_sent.clear()
	_svc.record_ability(_hit(77, 9002, 50), 77, "alice", 9002, "", "wolf", "Wolf")
	_svc.finish_target(9002, "wolf", "Wolf", 60)
	assert_eq(_sent[0]["peer"], 77, "reconnected peer receives its stable-character recap")
	assert_eq(_sent[0]["msg"]["recap"]["comparison"]["runs"], 1)
	assert_eq(_sent[0]["msg"]["recap"]["comparison"]["damage_pct"], 25.0)
	assert_eq(_svc.history_for("alice", "wolf").size(), 2)
	assert_eq(_svc.history_for("bob", "wolf").size(), 0)


func test_relay_mob_damage_with_string_mob_id_does_not_crash_and_records_damage() -> void:
	# T-560: relay_mob_damage used to pass the STRING mob_id into ability_result's int caster_id arg,
	# throwing "Cannot convert argument 3 from String to int" on EVERY mob-on-player hit — the crash
	# swallowed the damage stream so a death recap showed "0 taken" and masked the effigy as drowning.
	var events: Array = []
	var svc = RecapService.new()
	svc.setup(
		func(peer_id: int, msg: Dictionary): _sent.append({"peer": peer_id, "msg": msg}),
		20,
		func(ev: Dictionary): events.append(ev),
		Callable()
	)
	var mob = _MD.new()
	mob.entity_id = 1051
	mob.mob_id = "mob_training_effigy"  # the String that used to be shoved into an int slot
	mob.name = "Straw Sparring Effigy"
	mob.mob_type_id = 5
	svc.relay_mob_damage(mob, 22, "bob", _Res.new(85, 100), 15, "hit", 10, {"weapon": "Straw Fist"})
	assert_eq(events.size(), 1, "the mob-damage event is emitted (the relay no longer crashes)")
	assert_eq(events[0]["damage"], 15, "the real damage is recorded, not masked as 0")
	assert_eq(
		events[0]["caster_id"], 1051, "caster_id is the mob entity_id (int), not the string alias"
	)
	assert_eq(
		events[0]["caster_name"], "Straw Sparring Effigy", "the string identity rides caster_name"
	)
	# And the hit accrues to the victim's death recap (the stream the crash used to drop).
	svc.finish_player_death(22, "bob", 11)
	var recap: Dictionary = _sent[-1]["msg"]["recap"]
	assert_eq(recap["damage_taken"], 15, "the victim's recap counts the mob damage")
	assert_eq(recap["deaths"], 1)


func test_new_real_encounter_rolls_over_and_archives_the_old_one() -> void:
	# T-568 report #21/#22: an effigy encounter (A) was still the "active" entry when a wolf-pack
	# encounter (B) started on the SAME peer. Before the fix, B's hits piled into A's entry and kept
	# A's label forever, so the death recap read "Straw Sparring Effigy" for a death the wolves caused,
	# and A's contamination inflated B's damage_taken. The active entry must re-scope to B, and A must
	# be archived on its own with only its own numbers.
	_svc.record_ability(
		_incoming_damage(5001, 22, 20, 10), 5001, "", 22, "bob", "effigy", "Straw Sparring Effigy"
	)
	_svc.record_ability(
		_incoming_damage(5001, 22, 15, 11), 5001, "", 22, "bob", "effigy", "Straw Sparring Effigy"
	)
	_svc.record_ability(
		_incoming_damage(6001, 22, 40, 20),
		6001,
		"",
		22,
		"bob",
		"wolf_pack",
		"Wolf Pack + Greymaw the Alpha"
	)
	_svc.record_ability(
		_incoming_damage(6002, 22, 165, 21),
		6002,
		"",
		22,
		"bob",
		"wolf_pack",
		"Wolf Pack + Greymaw the Alpha"
	)
	_svc.finish_player_death(22, "bob", 22)

	assert_eq(_sent.size(), 1)
	var recap: Dictionary = _sent[0]["msg"]["recap"]
	assert_eq(
		recap["encounter_label"],
		"Wolf Pack + Greymaw the Alpha",
		"death recap names the encounter that actually killed the player, not the earlier effigy"
	)
	assert_eq(recap["encounter_key"], "wolf_pack")
	assert_eq(
		recap["damage_taken"], 205, "wolf pack's 40+165 only, the effigy's 35 must not bleed in"
	)

	var archived: Array = _svc.history_for("bob", "effigy")
	assert_eq(
		archived.size(), 1, "the effigy encounter was archived when the wolf pack rolled it over"
	)
	assert_eq(
		archived[0]["damage_taken"], 35, "the archived effigy recap keeps only its own damage"
	)
	assert_eq(archived[0]["encounter_label"], "Straw Sparring Effigy")


func test_support_event_between_real_hits_does_not_roll_or_relabel_the_encounter() -> void:
	# T-568: a heal/buff tagged "support" must fold into whichever real encounter is active without
	# ever counting as an encounter change itself — otherwise a heal mid-fight would spuriously roll
	# the entry (or worse, create a phantom "support" encounter) and split one fight's stats in two.
	_svc.record_ability(
		_incoming_damage(6001, 22, 40, 10), 6001, "", 22, "bob", "wolf_pack", "Wolf Pack"
	)
	var self_heal := _hit(22, 22, 12)
	self_heal["ability_name"] = "Mend"
	self_heal["outcome"] = "heal"
	self_heal["mitigated"] = 0
	_svc.record_ability(self_heal, 22, "bob", 22, "bob", "support", "Support")
	_svc.record_ability(
		_incoming_damage(6002, 22, 65, 12), 6002, "", 22, "bob", "wolf_pack", "Wolf Pack"
	)
	_svc.finish_target(22, "wolf_pack", "Wolf Pack", 20)

	assert_eq(_sent.size(), 1)
	var recap: Dictionary = _sent[0]["msg"]["recap"]
	assert_eq(
		recap["encounter_key"], "wolf_pack", "a support event must not roll the active encounter"
	)
	assert_eq(recap["encounter_label"], "Wolf Pack", "the label is untouched by the support event")
	assert_eq(recap["damage_taken"], 105, "both real hits land in one encounter around the heal")
	assert_eq(recap["healing_done"], 12, "the support heal still folds into the active encounter")
	assert_true(
		_svc.history_for("bob", "support").is_empty(), "no phantom 'support' encounter is archived"
	)


func test_surface_is_read_only_and_has_no_share_or_metric_write_route() -> void:
	assert_true(_svc.handles("performance_recap_request"))
	for forged in ["performance_recap_share", "performance_recap_write", "set_recap_damage"]:
		assert_false(_svc.handles(forged), "%s must not be client-routable" % forged)


func test_finalize_records_one_server_derived_telemetry_event_but_read_does_not() -> void:
	_svc.record_ability(_hit(11, 9001, 40), 11, "alice", 9001, "", "wolf", "Wolf")
	_svc.finish_target(9001, "wolf", "Wolf", 30)
	assert_eq(_telemetry.size(), 1)
	assert_eq(_telemetry[0]["kind"], "performance_recap")
	assert_eq(_telemetry[0]["account"], "alice")
	assert_eq(_telemetry[0]["character"], "alice")
	assert_eq(_telemetry[0]["payload"]["damage_done"], 40)
	_svc.handle("performance_recap_request", 11, "alice", 40)
	assert_eq(_telemetry.size(), 1, "a read-only refresh never writes a second telemetry event")
