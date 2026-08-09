extends GutTest
# T-452: pure mentorship cap + live party service authority. The client may request the toggle,
# but party membership, true levels, effective stats, and reward level all come from server stores.

const Sync = preload("res://scripts/combat/mentorship_sync.gd")
const MentorshipService = preload("res://scripts/mentorship_service.gd")
const DamageFormula = preload("res://scripts/combat/damage_formula.gd")
const PartyLogic = preload("res://scripts/party_logic.gd")
const PlayerSessions = preload("res://scripts/player_sessions.gd")

const TOKEN_A := "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa0"  # gitleaks:allow
const TOKEN_B := "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb1"  # gitleaks:allow


func _party(high_peer: int = 10, low_peer: int = 20) -> Dictionary:
	var store := PartyLogic.new_store()
	PartyLogic.invite(store, high_peer, low_peer)
	PartyLogic.accept(store, low_peer)
	return store


func _high_stats() -> Dictionary:
	return {
		"str": 135,
		"int": 10,
		"dex": 49,
		"spirit": 10,
		"stamina": 135,
		"attack": 80,
		"armor": 120,
	}


func test_cap_only_reduces_every_power_stat_without_mutating_true_stats() -> void:
	var original := _high_stats()
	var before := original.duplicate(true)
	var effective: Dictionary = Sync.scale_stats(original, 40, 5)
	for key: String in before:
		assert_lte(int(effective[key]), int(before[key]), "%s is cap-only" % key)
	assert_lt(int(effective["str"]), int(before["str"]), "a high-level primary is reduced")
	assert_lt(int(effective["attack"]), int(before["attack"]), "gear attack is reduced too")
	assert_eq(original, before, "the authoritative true stat vector is never mutated")


func test_sync_never_buffs_a_lower_or_equal_level_player() -> void:
	var earned := {"str": 13, "stamina": 13, "attack": 2, "armor": 0}
	assert_eq(Sync.scale_stats(earned, 2, 5), earned, "ceiling above true level is a no-op")
	assert_eq(Sync.scale_stats(earned, 2, 2), earned, "same-level ceiling is a no-op")


func test_ceiling_comes_from_server_party_and_level_truth() -> void:
	var store := _party()
	var levels := {10: 40, 20: 5}
	assert_eq(Sync.ceiling_for(10, store, levels, {10: true}), 5)
	assert_eq(Sync.ceiling_for(10, store, {10: 40, 20: 12}, {10: true}), 12)
	assert_eq(Sync.ceiling_for(10, store, levels, {}), 40, "not opted in -> true level")
	assert_eq(Sync.ceiling_for(99, store, levels, {99: true}), 1, "unknown peer fails closed")


func test_scaled_mentor_cannot_one_shot_level_five_content() -> void:
	var effective: Dictionary = Sync.scale_stats(_high_stats(), 40, 5)
	var attacker := CharacterStats.from_stat_vec(effective)
	var ability := AbilityData.new()
	ability.base_damage = 10
	ability.attacker_stat_coeffs = {"str": 0.5}
	ability.variance_min = 1.0
	ability.variance_max = 1.0
	var rng := RandomNumberGenerator.new()
	rng.seed = 452
	var hit = DamageFormula.compute_damage(attacker, CharacterStats.new(), ability, rng)
	assert_lt(hit.amount, 100, "a 100-HP level-five target survives the synced mentor's hit")
	assert_gt(
		hit.amount, 1, "sync leaves meaningful combat power rather than trivializing the mentor"
	)
	ability.ranks = [{"min_level": 1, "base_damage": 10}, {"min_level": 20, "base_damage": 100}]
	assert_eq(ability.effective_at_level(5).base_damage, 10, "effective level caps ability rank")


func test_service_ignores_forged_ceiling_and_uses_party_truth() -> void:
	var store := _party()
	var levels := {10: 40, 20: 5}
	var replies: Array = []
	var reapplied: Array = []
	var service := MentorshipService.new()
	service.setup(
		store,
		levels,
		func(peer, char_class, stats, talents, level, preserve = false):
			(
				reapplied
				. append(
					{
						"peer": peer,
						"class": char_class,
						"stats": stats,
						"talents": talents,
						"level": level,
						"preserve": preserve,
					}
				)
			),
		func(peer, msg): replies.append({"peer": peer, "msg": msg})
	)
	service.record_authoritative(10, "warrior", _high_stats(), {}, 40)
	service.record_authoritative(20, "warrior", {"str": 22, "stamina": 22}, {}, 5)
	service.toggle(10, {"level": 39, "ceiling": 39, "effective_stats": _high_stats()})
	assert_eq(service.reward_level(10), 5, "reward level is the server-truth party minimum")
	assert_eq(int(replies[-1]["msg"]["effective_level"]), 5, "forged level fields are ignored")
	assert_eq(int(reapplied[-1]["level"]), 40, "reapply retains the persisted true level")
	assert_true(reapplied[-1]["preserve"], "toggle reapply cannot refill current resources")
	assert_eq(int(reapplied[-1]["stats"]["attack"]), 80, "reapply uses truth, never compounds caps")
	var effective := service.record_authoritative(10, "warrior", _high_stats(), {}, 40)
	assert_lt(int(effective["attack"]), 80, "the live stat application receives a capped vector")


func test_service_rejects_sync_without_a_lower_party_member() -> void:
	var replies: Array = []
	var service := MentorshipService.new()
	service.setup(
		PartyLogic.new_store(),
		{10: 40},
		func(_peer, _class, _stats, _talents, _level, _preserve = false): pass,
		func(_peer, msg): replies.append(msg)
	)
	service.record_authoritative(10, "warrior", _high_stats(), {}, 40)
	service.toggle(10)
	assert_false(replies[-1]["ok"], "party membership is required")
	assert_eq(replies[-1]["reason"], "not_in_party")


func test_party_leave_immediately_restores_true_level() -> void:
	var store := _party()
	var reapplied: Array = []
	var service := MentorshipService.new()
	service.setup(
		store,
		{10: 40, 20: 5},
		func(peer, _class, _stats, _talents, level, preserve = false):
			reapplied.append({"peer": peer, "level": level, "preserve": preserve}),
		func(_peer, _msg): pass
	)
	service.record_authoritative(10, "warrior", _high_stats(), {}, 40)
	service.record_authoritative(20, "warrior", {"str": 22}, {}, 5)
	service.toggle(10)
	service.handle_party("party_leave", 20, {}, {})
	assert_eq(service.reward_level(10), 40, "auto-disband removes the cap immediately")
	var high_calls: Array = reapplied.filter(func(call): return int(call["peer"]) == 10)
	assert_eq(int(high_calls[-1]["level"]), 40, "true level is reapplied after the party ends")
	assert_true(high_calls[-1]["preserve"], "restoration cannot refill resources")


func test_party_coordinator_regression_invite_accept_and_notify() -> void:
	PlayerSessions._reset_for_test()
	PlayerSessions.add_player(10, TOKEN_A, "mentor", Vector3.ZERO)
	PlayerSessions.add_player(20, TOKEN_B, "friend", Vector3.ZERO)
	var store := PartyLogic.new_store()
	var replies: Array = []
	var service := MentorshipService.new()
	service.setup(
		store,
		{10: 40, 20: 5},
		func(_peer, _class, _stats, _talents, _level, _preserve = false): pass,
		func(peer, msg): replies.append({"peer": peer, "msg": msg})
	)
	service.handle_party("party_invite", 10, {"username": "mentor"}, {"target": "friend"})
	service.handle_party("party_accept", 20, {"username": "friend"}, {})
	assert_eq(store["party_of"][10], store["party_of"][20], "existing T-280 roster still forms")
	var types := replies.map(func(row): return str(row["msg"]["type"]))
	assert_true(types.has("party_invite"), "invitee notification survives the coordinator carve")
	assert_true(types.has("party_update"), "accepted roster is pushed to members")


# ---- T-654 (portal #88): a partner's disconnect never broadcast a party_update, so the survivor's
# client roster kept rendering a ghost frame for the gone member indefinitely (only a relog cleared
# it). peer_gone() now mirrors party_leave/party_disband/raid_kick and notifies the survivors.


func test_peer_gone_broadcasts_party_update_to_the_survivor() -> void:
	PlayerSessions._reset_for_test()
	PlayerSessions.add_player(10, TOKEN_A, "leader", Vector3.ZERO)
	PlayerSessions.add_player(20, TOKEN_B, "partner", Vector3.ZERO)
	var store := PartyLogic.new_store()
	PartyLogic.invite(store, 10, 20)
	PartyLogic.accept(store, 20)
	var replies: Array = []
	var service := MentorshipService.new()
	service.setup(
		store,
		{10: 8, 20: 3},
		func(_peer, _class, _stats, _talents, _level, _preserve = false): pass,
		func(peer, msg): replies.append({"peer": peer, "msg": msg})
	)
	service.peer_gone(20)  # the partner disconnects
	var pushed := replies.filter(func(r): return str(r["msg"].get("type", "")) == "party_update")
	assert_eq(pushed.size(), 1, "the survivor gets exactly one party_update push")
	assert_eq(int(pushed[0]["peer"]), 10, "it's addressed to the remaining member")
	assert_eq(pushed[0]["msg"]["members"], [], "the disbanded-to-one party reports an empty roster")


func test_peer_gone_never_replies_to_the_peer_that_just_disconnected() -> void:
	PlayerSessions._reset_for_test()
	PlayerSessions.add_player(10, TOKEN_A, "leader", Vector3.ZERO)
	PlayerSessions.add_player(20, TOKEN_B, "partner", Vector3.ZERO)
	var store := PartyLogic.new_store()
	PartyLogic.invite(store, 10, 20)
	PartyLogic.accept(store, 20)
	var replies: Array = []
	var service := MentorshipService.new()
	service.setup(
		store,
		{10: 8, 20: 3},
		func(_peer, _class, _stats, _talents, _level, _preserve = false): pass,
		func(peer, msg): replies.append({"peer": peer, "msg": msg})
	)
	service.peer_gone(20)
	var to_gone := replies.filter(func(r): return int(r["peer"]) == 20)
	assert_true(to_gone.is_empty(), "no RPC is sent to the already-closed connection")


func test_peer_gone_in_a_three_man_party_notifies_every_remaining_member() -> void:
	PlayerSessions._reset_for_test()
	PlayerSessions.add_player(10, TOKEN_A, "leader", Vector3.ZERO)
	PlayerSessions.add_player(20, TOKEN_B, "partner", Vector3.ZERO)
	PlayerSessions.add_player(30, "ccccccccccccccccccccccccccccccc2", "third", Vector3.ZERO)
	var store := PartyLogic.new_store()
	PartyLogic.invite(store, 10, 20)
	PartyLogic.accept(store, 20)
	PartyLogic.invite(store, 10, 30)
	PartyLogic.accept(store, 30)
	var replies: Array = []
	var service := MentorshipService.new()
	service.setup(
		store,
		{10: 8, 20: 3, 30: 5},
		func(_peer, _class, _stats, _talents, _level, _preserve = false): pass,
		func(peer, msg): replies.append({"peer": peer, "msg": msg})
	)
	service.peer_gone(20)
	var updates := replies.filter(func(r): return str(r["msg"].get("type", "")) == "party_update")
	var recipients: Array = updates.map(func(r): return int(r["peer"]))
	recipients.sort()
	assert_eq(recipients, [10, 30], "both remaining members are notified")
	for r in updates:
		assert_false(
			r["msg"]["members"].has("partner"), "the gone member is pruned from every push"
		)


func test_solo_peer_gone_sends_no_party_update() -> void:
	PlayerSessions._reset_for_test()
	PlayerSessions.add_player(10, TOKEN_A, "solo", Vector3.ZERO)
	var replies: Array = []
	var service := MentorshipService.new()
	service.setup(
		PartyLogic.new_store(),
		{10: 8},
		func(_peer, _class, _stats, _talents, _level, _preserve = false): pass,
		func(peer, msg): replies.append({"peer": peer, "msg": msg})
	)
	service.peer_gone(10)
	assert_true(replies.is_empty(), "a solo player's disconnect has no survivors to notify")


func test_resource_preservation_prevents_toggle_refill() -> void:
	var service := MentorshipService.new()
	var high := CombatResources.new()
	high.derive_from_stats(CharacterStats.from_stat_vec(_high_stats()))
	high = high.apply_damage(high.max_hp / 2)
	var low := CombatResources.new()
	low.derive_from_stats(CharacterStats.from_stat_vec(Sync.scale_stats(_high_stats(), 40, 5)))
	var preserved = service.preserve_resources(high, low)
	assert_eq(preserved.hp, low.max_hp / 2, "half-health mentor stays at half after syncing")
	assert_lt(preserved.hp, low.max_hp, "toggle cannot refill HP")


# ---- T-643 (portal #90): session-22 measured max_hp scaling (205->130 OK) but outgoing ability
# damage staying statistically unchanged (24-29 unsynced vs 24-26 synced) on identical wolf hits.
# Audit: `caster.stats` in the live combat_snapshot (world/main.gd's `_snap.caster()`) IS
# `_char_stats` — the exact dict `apply_authoritative` writes the capped vector into, the same seam
# max_hp's `resources.derive_from_stats(converted)` reads. These tests drive that real seam
# (MentorshipService.toggle -> apply_authoritative -> the live stats dict ->
# DamageFormula.compute_damage — the identical path _on_use_ability/_on_cast_complete use via
# combat_snapshot.gd) end-to-end with realistic L8->L3 warrior numbers (leveling.gd: base str=10,
# +3/level) and lock the reduction in as a deterministic regression — no RNG dependency (variance
# pinned to 1.0), so this can never silently regress back to "unchanged."
func test_synced_mentor_deals_measurably_less_strike_damage_than_unsynced() -> void:
	var store := PartyLogic.new_store()
	PartyLogic.invite(store, 10, 20)
	PartyLogic.accept(store, 20)
	var stats: Dictionary = {}
	var resources: Dictionary = {}
	var service := MentorshipService.new()
	service.setup(
		store,
		{10: 8, 20: 3},
		Callable(service, "apply_authoritative"),
		func(_peer, _msg): pass,
		[stats, {}, {}, resources]
	)
	# Real warrior growth (leveling.gd): L1 base str=10, +3/level -> L8 str=31, L3 str=16.
	var l8_stats := {"str": 31, "int": 10, "dex": 11, "spirit": 10, "stamina": 31}
	service.apply_authoritative(10, "warrior", l8_stats, {}, 8, false)
	var strike := AbilityData.new()  # mirrors data/abilities/strike.json's shape
	strike.base_damage = 10
	strike.attacker_stat_coeffs = {"str": 0.5}
	strike.variance_min = 1.0
	strike.variance_max = 1.0
	var wolf := CharacterStats.new()  # a Gray Wolf: no gear, no mitigation stats
	var rng := RandomNumberGenerator.new()
	var unsynced := DamageFormula.compute_damage(stats[10], wolf, strike, rng)
	assert_true(service.toggle(10)["ok"], "toggle ON succeeds (L3 partner is lower)")
	var synced := DamageFormula.compute_damage(stats[10], wolf, strike, rng)
	assert_lt(
		synced.amount, unsynced.amount, "synced mentor deals less Strike damage than unsynced"
	)
	assert_almost_eq(
		float(synced.amount),
		float(10 + 16 * 0.5),  # L3-equivalent str=16 (10 anchor + earned*2/7): an at-level hit
		1.0,
		"synced damage lands at an AT-LEVEL character's output, not a barely-reduced L8 hit"
	)
	assert_true(service.toggle(10)["ok"], "toggle OFF succeeds")
	var restored := DamageFormula.compute_damage(stats[10], wolf, strike, rng)
	assert_eq(restored.amount, unsynced.amount, "un-syncing restores the true L8 damage exactly")


func test_toggle_on_scales_the_live_stats_dict_every_power_stat() -> void:
	var store := PartyLogic.new_store()
	PartyLogic.invite(store, 10, 20)
	PartyLogic.accept(store, 20)
	var stats: Dictionary = {}
	var resources: Dictionary = {}
	var service := MentorshipService.new()
	service.setup(
		store,
		{10: 40, 20: 5},
		Callable(service, "apply_authoritative"),
		func(_peer, _msg): pass,
		[stats, {}, {}, resources]
	)
	service.apply_authoritative(10, "warrior", _high_stats(), {}, 40, false)
	var true_attack: int = stats[10].attack_val
	var true_str: int = stats[10].str_val
	assert_true(service.toggle(10)["ok"], "toggle ON succeeds")
	assert_lt(stats[10].attack_val, true_attack, "gear attack_val is capped after toggle ON")
	assert_lt(stats[10].str_val, true_str, "str is capped after toggle ON, in the same live dict")


# T-643: world_rpc._repush_combat_stats fires on nearly every XP-granting kill (T-588), always
# reaching the client with master's raw truth for the player_stats push — an opted-in mentor's OWN
# stat sheet silently reverted to full power on the very next kill, mid-sync. display_combat() is
# the fix: a side-effect-free peek that reshapes just that outgoing message, leaving _char_stats/
# damage (already correct — see above) untouched.
func test_display_combat_shows_the_capped_view_only_while_opted_in() -> void:
	var store := PartyLogic.new_store()
	PartyLogic.invite(store, 10, 20)
	PartyLogic.accept(store, 20)
	var service := MentorshipService.new()
	service.setup(
		store,
		{10: 8, 20: 3},
		func(_peer, _class, _stats, _talents, _level, _preserve = false): pass,
		func(_peer, _msg): pass
	)
	var raw := {"level": 8, "stats": {"str": 31, "stamina": 31}, "xp_into_level": 40}
	assert_eq(
		service.display_combat(10, raw), raw, "not opted in yet -> the raw truth passes through"
	)
	service.toggle(10)
	var shown := service.display_combat(10, raw)
	assert_eq(int(shown["level"]), 3, "the pushed level matches the synced ceiling")
	assert_lt(int(shown["stats"]["str"]), 31, "the pushed primaries match the capped vector")
	assert_eq(
		int(shown["xp_into_level"]), 40, "non-stat fields (XP progress) pass through untouched"
	)
	service.toggle(10)
	assert_eq(
		service.display_combat(10, raw), raw, "un-synced -> the raw truth passes through again"
	)


# T-642 (portal #86) — end-to-end through the REAL wiring shape main.gd uses (real live_stores
# Dictionaries + apply_authoritative as the `_apply` callable), not a stubbed `_apply` closure like
# the tests above. Toggling sync OFF mid-combat must preserve the current hp FRACTION, not restore
# to full — the exact live repro (45/130 -> expected ~71/205, not 205/205).
func test_toggle_off_mid_combat_preserves_hp_fraction_end_to_end() -> void:
	var store := PartyLogic.new_store()
	PartyLogic.invite(store, 10, 20)
	PartyLogic.accept(store, 20)
	var resources: Dictionary = {}
	var service := MentorshipService.new()
	service.setup(
		store,
		{10: 8, 20: 3},
		Callable(service, "apply_authoritative"),
		func(_peer, _msg): pass,
		[{}, {}, {}, resources]
	)
	# login-equivalent seed: initial full derive, preserve=false (mirrors main.gd's handshake path).
	service.apply_authoritative(10, "warrior", _high_stats(), {}, 8, false)
	var true_max: int = resources[10].max_hp
	assert_true(service.toggle(10)["ok"], "toggle ON succeeds with a lower party member present")
	resources[10] = resources[10].apply_damage(int(resources[10].max_hp * 0.65))  # ~35% remaining
	var frac_before := float(resources[10].hp) / float(resources[10].max_hp)
	assert_true(service.toggle(10)["ok"], "toggle OFF succeeds")
	assert_eq(resources[10].max_hp, true_max, "un-toggle restores the true (unscaled) max_hp")
	var frac_after := float(resources[10].hp) / float(resources[10].max_hp)
	assert_almost_eq(frac_after, frac_before, 0.02, "un-toggle preserves the hp fraction, no heal")
	assert_lt(resources[10].hp, true_max, "un-toggle must NOT restore to full hp")


# T-642: toggling ON must preserve the fraction just as strictly as toggling OFF — the exploit
# framing was "either direction", not just un-toggle.
func test_toggle_on_mid_combat_preserves_hp_fraction_end_to_end() -> void:
	var store := PartyLogic.new_store()
	PartyLogic.invite(store, 10, 20)
	PartyLogic.accept(store, 20)
	var resources: Dictionary = {}
	var service := MentorshipService.new()
	service.setup(
		store,
		{10: 8, 20: 3},
		Callable(service, "apply_authoritative"),
		func(_peer, _msg): pass,
		[{}, {}, {}, resources]
	)
	service.apply_authoritative(10, "warrior", _high_stats(), {}, 8, false)
	resources[10] = resources[10].apply_damage(int(resources[10].max_hp * 0.4))  # ~60% remaining
	var frac_before := float(resources[10].hp) / float(resources[10].max_hp)
	assert_true(service.toggle(10)["ok"], "toggle ON succeeds")
	var frac_after := float(resources[10].hp) / float(resources[10].max_hp)
	assert_almost_eq(frac_after, frac_before, 0.02, "toggle ON preserves the hp fraction too")


# T-642: a dead mentor (hp already 0) must stay dead across a toggle — 0% of any max is still 0.
func test_toggle_never_revives_a_dead_mentor() -> void:
	var store := PartyLogic.new_store()
	PartyLogic.invite(store, 10, 20)
	PartyLogic.accept(store, 20)
	var resources: Dictionary = {}
	var service := MentorshipService.new()
	service.setup(
		store,
		{10: 8, 20: 3},
		Callable(service, "apply_authoritative"),
		func(_peer, _msg): pass,
		[{}, {}, {}, resources]
	)
	service.apply_authoritative(10, "warrior", _high_stats(), {}, 8, false)
	resources[10] = resources[10].apply_damage(resources[10].max_hp)  # dead: hp == 0
	assert_eq(resources[10].hp, 0, "sanity: the mentor is dead before the toggle")
	assert_true(service.toggle(10)["ok"], "toggle ON succeeds")
	assert_eq(resources[10].hp, 0, "a dead mentor stays dead after toggling sync ON")
	assert_true(service.toggle(10)["ok"], "toggle OFF succeeds")
	assert_eq(resources[10].hp, 0, "a dead mentor stays dead after toggling sync OFF")
