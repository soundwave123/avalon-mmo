# T-377: adversarial-client test stub — the server-authority regression net.
#
# Premise: the client is attacker-controlled. Everything it SENDS is an intent; the server must
# roll/validate every state change itself. These tests forge the intents a cheat client would send
# and assert the server REJECTS them. If any assertion flips (a forgery is accepted), that is a
# CRITICAL trust-boundary regression — treat a red test here as a shipped exploit, not a flaky test.
#
# Scope: the PURE server-authority units a forged intent flows through (no scene tree / no master):
#   - AbilityExecutor  — the combat roll (fake-damage / out-of-range / dead-target / wrong-class)
#   - MoveRateLimiter  — the movement budget (teleport-speed burst)
#   - WorldRpc.handles — the inbound INTENT allow-list (a client cannot invoke a server-observed
#                        credit/loot/grant path as an intent → no self-item-grant/kill-credit)
# Deeper end-to-end forgeries (a full forged ENet peer against a booted world+master) are a
# follow-on integration harness — see docs/design/security-model.md.

extends "res://addons/gut/test.gd"

const _AE = preload("res://scripts/combat/ability_executor.gd")
const _ES = preload("res://scripts/combat/entity_snapshot.gd")
const _CS = preload("res://scripts/combat/combat_state.gd")
const _CR = preload("res://scripts/combat/combat_resources.gd")
const _CSTATS = preload("res://scripts/combat/character_stats.gd")
const _ADAT = preload("res://scripts/combat/ability_data.gd")
const _MRL = preload("res://scripts/move_rate_limiter.gd")
const _MCOL = preload("res://scripts/movement_collision.gd")  # T-379: anti-noclip geometry gate
const _IRL = preload("res://scripts/intent_rate_limiter.gd")  # T-382
const _WRPC = preload("res://scripts/world_rpc.gd")
const _SC = preload("res://scripts/server_config.gd")
const _SOCIAL = preload("res://scripts/social_service.gd")
const _ISVC = preload("res://scripts/instance_service.gd")  # T-380: teleport-via-intent gate
const _IM = preload("res://scripts/instance_manager.gd")  # T-380: WORLD sentinel
const _BLO = preload("res://scripts/bar_layout_ops.gd")  # T-422c: action-bar layout validation
const _MOUNT = preload("res://scripts/mount_service.gd")  # T-431: mounted-state forgery gate
const _FLIGHT = preload("res://scripts/flight_service.gd")  # T-431: route/cost teleport gate
const _RECAP = preload("res://scripts/performance_recap_service.gd")  # T-429 read-only mirror
const PlayerSessions = preload("res://scripts/player_sessions.gd")
const _TOK_A := "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"  # gitleaks:allow — 32-hex T-380 test token
const _TOK_B := "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"  # gitleaks:allow — 32-hex T-380 test token


# T-380: the teleport cases seed the STATIC PlayerSessions store; clear it after every test so a
# leftover session (e.g. peer 1 at a far position) can't leak into another suite's enter()/leave().
func after_each() -> void:
	PlayerSessions._reset_for_test()


func _rng() -> RandomNumberGenerator:
	var r := RandomNumberGenerator.new()
	r.seed = 1
	return r


func _stats() -> CharacterStats:
	var s := _CSTATS.new()
	s.str_val = 20
	s.int_val = 20
	s.dex_val = 20
	s.spirit_val = 20
	s.stamina_val = 20
	return s


func _res() -> CombatResources:
	var r := _CR.new()
	r.derive_from_stats(_stats())
	r.stamina = 500
	r.max_stamina = 500
	r.mana = 500
	r.max_mana = 500
	return r


func _actor(pos: Vector3, is_mob: bool = false, char_class: String = "warrior"):
	var s := _ES.new()
	s.peer_id = 1 if not is_mob else 9001
	s.position = pos
	s.combat_state = _CS.new()  # defaults to IDLE
	s.resources = _res()
	s.stats = _stats()
	s.char_class = char_class
	s.is_mob = is_mob
	return s


# A generic instant damage ability with a short range — the "strike" a cheat client claims to land.
func _melee_strike() -> AbilityData:
	var a := _ADAT.new()
	a.id = 42
	a.name = "Strike"
	a.effect = "damage"
	a.base_damage = 50
	a.range_units = 5.0
	a.char_class = ""  # usable by any class
	a.triggers_gcd = true
	return a


# --- VECTOR 2: Combat — a forged fake-damage claim from out of range ---------
# A cheat client sends use_ability at a target 100 units away (well past the 5u range) and expects
# the "damage" to apply. The server rolls the ability itself and MUST reject it out of range —
# the client's claim is never trusted.
func test_forged_damage_out_of_range_rejected() -> void:
	var caster = _actor(Vector3.ZERO)
	var target = _actor(Vector3(100.0, 0.0, 0.0))  # far away — forged "I hit them" claim
	var result = _AE.execute_ability(caster, target, _melee_strike(), 0, _rng())
	assert_false(result.accepted, "CRIT: server accepted an out-of-range forged hit")
	assert_eq(result.rejection_reason, "out_of_range", "must reject as out_of_range")
	assert_eq(result.damage_amount, 0, "no damage may be applied on a rejected forgery")


# --- VECTOR 2: Combat — a forged strike on an already-dead target ------------
# Corpse-camping / kill-stealing forgery: claim damage on a DEAD entity. Server rejects.
func test_forged_damage_on_dead_target_rejected() -> void:
	var caster = _actor(Vector3.ZERO)
	var target = _actor(Vector3(1.0, 0.0, 0.0))
	target.combat_state.state = _CS.CombatStateEnum.DEAD
	var result = _AE.execute_ability(caster, target, _melee_strike(), 0, _rng())
	assert_false(result.accepted, "CRIT: server accepted a hit on a dead target")
	assert_eq(result.rejection_reason, "target_is_dead")


# --- VECTOR 2: Combat — a forged resurrect on a LIVING target (T-364) --------
# Resurrection inverts the dead-target rule, so a cheat client might aim it at a LIVING ally/enemy to
# yank them to the caster or reset their state. The server requires a dead target and rejects a
# living one — the rez teleport/restore can never fire on someone who is up.
func _rez_ability() -> AbilityData:
	var a := _ADAT.new()
	a.id = 306
	a.name = "Resurrection"
	a.effect = "resurrect"
	a.char_class = "priest"
	a.targets_friendly = true
	a.range_units = 30.0
	return a


func test_forged_resurrect_on_living_target_rejected() -> void:
	var caster = _actor(Vector3.ZERO, false, "priest")
	var living = _actor(Vector3(2.0, 0.0, 0.0), false, "priest")  # IDLE, alive
	var result = _AE.execute_ability(caster, living, _rez_ability(), 0, _rng())
	assert_false(result.accepted, "CRIT: server let a rez fire on a living target")
	assert_eq(result.rejection_reason, "target_not_dead")
	assert_eq(result.new_target_state, null, "no state change may be applied to a living target")


# --- VECTOR 5: Class/stats — a forged wrong-class ability use ----------------
# A warrior client sends a mage-gated ability id. The class gate is server-side; the wire class is
# irrelevant — the SERVER's session-held class decides. Reject.
func test_forged_wrong_class_ability_rejected() -> void:
	var caster = _actor(Vector3.ZERO, false, "warrior")
	var target = _actor(Vector3(1.0, 0.0, 0.0), true)  # a mob, in range
	var mage_spell := _melee_strike()
	mage_spell.char_class = "mage"  # ability is mage-only; caster is a warrior
	var result = _AE.execute_ability(caster, target, mage_spell, 0, _rng())
	assert_false(result.accepted, "CRIT: server let a warrior cast a mage ability")
	assert_eq(result.rejection_reason, "wrong_class")


# T-434: a client can name an ability id, but cannot assert the full-interrupt flag or borrow
# another class's Counterspell. The registry/session class gate rejects before touching the cast.
func test_forged_wrong_class_interrupt_cannot_cancel_cast() -> void:
	var warrior = _actor(Vector3.ZERO, false, "warrior")
	var caster = _actor(Vector3(1.0, 0.0, 0.0), false, "mage")
	caster.peer_id = 2
	caster.combat_state.state = _CS.CombatStateEnum.CASTING
	caster.combat_state.cast_ability_id = 201
	caster.combat_state.cast_end = 200
	var counterspell := _melee_strike()
	counterspell.id = 206
	counterspell.char_class = "mage"
	counterspell.can_full_interrupt = true
	counterspell.triggers_gcd = false
	var consent := func(_a: int, _b: int) -> bool: return true
	var result = _AE.execute_ability(
		warrior, caster, counterspell, 100, _rng(), null, null, consent
	)
	assert_false(result.accepted, "CRIT: warrior forged a mage Counterspell")
	assert_eq(result.rejection_reason, "wrong_class")
	assert_eq(caster.combat_state.state, _CS.CombatStateEnum.CASTING, "target cast is untouched")


# --- VECTOR 2b: PvP consent — a forged strike on a non-dueling stranger (T-381) --------------
# The griefing hole T-377 flagged: any player could damage any player in range with no consent. The
# world injects a consent predicate that is FALSE unless the pair is in an active duel; a forged hit
# on an unflagged stranger MUST be rejected `pvp_not_allowed`. Fed the production fail-closed
# predicate here (returns false), the executor rejects — proving open-world PvP is off.
func test_forged_player_vs_player_strike_rejected() -> void:
	var caster = _actor(Vector3.ZERO)
	var stranger = _actor(Vector3(2.0, 0.0, 0.0))  # another PLAYER (is_mob=false), in range
	stranger.peer_id = 2
	var no_consent := func(_a: int, _b: int) -> bool: return false  # world's fail-closed default
	var result = _AE.execute_ability(
		caster, stranger, _melee_strike(), 0, _rng(), null, null, no_consent
	)
	assert_false(result.accepted, "CRIT: server accepted non-consensual player→player damage")
	assert_eq(result.rejection_reason, "pvp_not_allowed")
	assert_eq(result.damage_amount, 0, "no damage may land on a non-consensual PvP forgery")
	# Control: the SAME strike between two consenting duelists (predicate TRUE) IS accepted — the
	# gate is a consent check, not a blanket block on all player targets.
	var consent := func(_a: int, _b: int) -> bool: return true
	var opponent = _actor(Vector3(2.0, 0.0, 0.0))
	opponent.peer_id = 3  # a genuinely different player, not a self-cast
	var duel_hit = _AE.execute_ability(
		caster, opponent, _melee_strike(), 0, _rng(), null, null, consent
	)
	assert_true(duel_hit.accepted, "a consented duel strike must still be accepted")


# Control: an HONEST in-range hit on a live enemy IS accepted — proves the rejections above are the
# guards firing, not the executor being broken/closed for everything.
func test_honest_in_range_hit_accepted() -> void:
	var caster = _actor(Vector3.ZERO)
	var target = _actor(Vector3(2.0, 0.0, 0.0), true)  # a mob, within 5u
	var result = _AE.execute_ability(caster, target, _melee_strike(), 0, _rng())
	assert_true(result.accepted, "an honest in-range hit on a live enemy must be accepted")
	_assert_private_recap_forgery_is_unroutable()


# --- VECTOR 13: private recap — forged identity/metric/share fields have no route ----------------
# The only recap intent is a local read with no payload. World resolves `character` from the sender
# session before calling the service, so a packet cannot name a victim or write/share performance.
func _assert_private_recap_forgery_is_unroutable() -> void:
	var recap = _RECAP.new()
	var sent: Array = []
	recap.setup(func(peer: int, msg: Dictionary): sent.append({"peer": peer, "msg": msg}), 20)
	var event := {
		"type": "ability_result",
		"ability_id": 1,
		"ability_name": "Strike",
		"caster_id": 10,
		"target_id": 9001,
		"damage": 40,
		"outcome": "hit",
		"tick": 1,
	}
	recap.record_ability(event, 10, "alice", 9001, "", "wolf", "Wolf")
	recap.finish_target(9001, "wolf", "Wolf", 21)
	sent.clear()
	recap.handle("performance_recap_request", 20, "bob", 30)
	assert_eq(sent[0]["peer"], 20, "reply targets only the requesting session peer")
	assert_eq(sent[0]["msg"]["recap"]["damage_done"], 0, "Bob cannot read Alice via identity")
	for forged in ["performance_recap_share", "performance_recap_write", "set_recap_damage"]:
		assert_false(recap.handles(forged), "%s must not route" % forged)


# T-365: a ranked ability whose rank is DERIVED from the caster's authoritative level.
func _ranked_strike() -> AbilityData:
	var a := _melee_strike()
	a.base_damage = 30
	a.variance_min = 1.0
	a.variance_max = 1.0
	a.ranks = [{"min_level": 1, "base_damage": 30}, {"min_level": 12, "base_damage": 58}]
	return a


# --- VECTOR 5: Class/stats — the client cannot assert a higher ability RANK -----------------
# There is no rank channel on the wire; the server derives the rank purely from the session-held
# level. A level-1 caster gets rank-1 numbers no matter what it "claims"; only a genuinely higher
# server level yields the higher-rank damage. This proves rank power can't be forged.
func test_forged_rank_claim_uses_server_level_not_client() -> void:
	var mob = _actor(Vector3(2.0, 0.0, 0.0), true)
	var low = _actor(Vector3.ZERO)  # level defaults to 1
	var hit_low = _AE.execute_ability(low, mob, _ranked_strike(), 0, _rng())
	assert_eq(hit_low.damage_amount, 30, "a level-1 caster is capped at rank-1 damage")

	var high = _actor(Vector3.ZERO)
	high.level = 12  # only the server-held level (not any packet) can unlock the higher rank
	var hit_high = _AE.execute_ability(
		high, _actor(Vector3(2.0, 0.0, 0.0), true), _ranked_strike(), 0, _rng()
	)
	assert_eq(hit_high.damage_amount, 58, "the higher rank comes only from the authoritative level")


# --- VECTOR 5: a forged use of a TRAINED ability the caster never purchased ------------------
# Trainer-unlocked abilities are gated on server-held ownership (PlayerSessions/master), not the
# packet. A cheat client that names a trained ability id it never bought must be rejected; a caster
# that genuinely owns it is accepted (proving the gate isn't just closed for everyone).
func test_forged_untrained_ability_use_rejected() -> void:
	var trained := _melee_strike()
	trained.id = 777
	trained.trained = true
	var mob = _actor(Vector3(2.0, 0.0, 0.0), true)

	var thief = _actor(Vector3.ZERO)  # unlocked defaults to [] — owns nothing
	var forged = _AE.execute_ability(thief, mob, trained, 0, _rng())
	assert_false(forged.accepted, "CRIT: server let a client cast an unpurchased trained ability")
	assert_eq(forged.rejection_reason, "not_trained")

	var owner = _actor(Vector3.ZERO)
	owner.unlocked = [777]  # the server session says this character bought it
	var legit = _AE.execute_ability(owner, _actor(Vector3(2.0, 0.0, 0.0), true), trained, 0, _rng())
	assert_true(legit.accepted, "a caster that owns the trained ability may cast it")


# --- VECTOR 1: Movement — a forged teleport-speed burst ----------------------
# A cheat client fires one max-magnitude delta every tick (each individually under the per-message
# cap) to travel thousands of units/second. The per-second budget MUST cut it off within the window.
func test_forged_teleport_speed_burst_rejected() -> void:
	var limiter = _MRL.new()
	var accepted_units := 0.0
	var rejected := false
	# 40 hops of a full 100-unit delta inside one 1-second (TICK_RATE_HZ-tick) window.
	for i in range(40):
		if limiter.allow(1, _SC.MAX_SPEED_PER_TICK, 0):
			accepted_units += _SC.MAX_SPEED_PER_TICK
		else:
			rejected = true
	assert_true(rejected, "CRIT: movement budget never cut off a teleport-speed burst")
	assert_true(
		accepted_units <= _SC.MOVE_UNITS_PER_SECOND,
		(
			"accepted travel (%d) must not exceed the 1s budget (%d)"
			% [accepted_units, _SC.MOVE_UNITS_PER_SECOND]
		)
	)


# --- VECTOR 1 (noclip): Movement — a forged rate-legal delta THROUGH a wall ---
# The speed cap and per-second budget are geometry-blind: a cheat client can send a perfectly
# rate-legal delta whose segment crosses a curtain wall (outside a palisade -> the keep vault).
# The T-379 collision gate on the intake path (movement_collision.resolve) must reject it — while a
# same-magnitude move THROUGH the gate opening stays legal (no false-positive on real traversal).
func test_forged_noclip_through_wall_rejected() -> void:
	var col = _MCOL.new()  # loads the seed barriers (Highkeep curtain wall)
	var lim = _MRL.new()
	# A single legal-speed (< MAX_SPEED_PER_TICK) delta aimed straight through the north curtain,
	# off the central gate — the exact through-wall snap a noclip client would send.
	var forged: Dictionary = col.resolve(Vector2(-50, -130), Vector2(0, -40), 1, 0, lim)
	assert_false(forged["ok"], "CRIT: a rate-legal delta through a wall was accepted (noclip)")
	assert_eq(forged["reason"], "collision", "and is rejected specifically by the geometry gate")
	# Control: an identical-magnitude move down the gate-aligned spine is legitimate and MUST pass,
	# proving the gate isn't just closed for everything (that would break every real player).
	var legit: Dictionary = col.resolve(Vector2(0, -130), Vector2(0, -40), 2, 0, _MRL.new())
	assert_true(legit["ok"], "a legal move through the gate must still be accepted")


# --- VECTOR 1: Movement — the client cannot forge height (under-terrain/flight) ---
# request_move carries only a planar {dx,dy}; the server is planar-authoritative and DERIVES z from
# the terrain field in update_position. This asserts the intake carries no z channel to abuse — a
# forged altitude has nowhere to land, so under-terrain and no-support flight are structurally
# impossible, not merely range-checked.
func test_move_has_no_client_height_channel() -> void:
	var col = _MCOL.new("")
	# resolve returns a planar Vector2 only; there is no z in, and no z out. A forged "z" in the wire
	# dict is simply never read.
	var res: Dictionary = col.resolve(Vector2(0, 0), Vector2(3, 4), 1, 0, _MRL.new())
	assert_true(res["pos"] is Vector2, "movement resolves to a PLANAR position; height is derived")
	assert_true(res["ok"], "a normal planar delta is accepted (no client height needed or honored)")


func test_forged_mounted_flag_and_speed_gain_are_ignored() -> void:
	var svc = _MOUNT.new()
	var replies: Array = []
	svc.setup(func(_pid, _mounted, _visual): pass, func(_pid, msg): replies.append(msg))
	svc.seed(1, {"learned": false, "mount_id": "", "skin": ""})
	svc.handle(1, {"action": "toggle", "mounted": true, "speed": 999999}, 0)
	assert_false(svc.is_mounted(1), "CRIT: client-forged mounted=true changed server state")
	assert_eq(svc.speed_cap(1), _SC.MAX_SPEED_PER_TICK, "forger remains on the normal speed cap")
	assert_eq(str(replies[-1]["reason"]), "mount_not_learned")


class _PoorFlightMaster:
	extends RefCounted
	var calls: Array = []

	func call_master(method: String, params: Dictionary) -> Dictionary:
		calls.append({"method": method, "params": params.duplicate(true)})
		return {"error": "insufficient_coins"}


func test_forged_flight_destination_cost_and_underfunded_hop_never_reposition() -> void:
	PlayerSessions.add_player(5, _TOK_A, "forger", Vector3(8.0, -118.0, 0.0))
	var master := _PoorFlightMaster.new()
	var replies: Array = []
	var svc = _FLIGHT.new()
	assert_eq(svc.setup(master, func(_pid, msg): replies.append(msg)), "")
	var before: Vector3 = PlayerSessions.get_player(5)["pos"]
	await svc.handle(5, "forger", "npc_hk_flightmaster", {"action": "fly", "dest": "bogus"})
	assert_eq(master.calls.size(), 0, "unknown roost is rejected before any debit authority call")
	await svc.handle(
		5, "forger", "npc_hk_flightmaster", {"action": "fly", "dest": "ashmoor", "cost": 0}
	)
	assert_eq(int(master.calls[-1]["params"]["cost"]), 60, "client-forged free price is ignored")
	assert_eq(PlayerSessions.get_player(5)["pos"], before, "failed debit verdict never teleports")
	assert_eq(str(replies[-1]["reason"]), "insufficient_coins")


# --- VECTOR 3: Loot/economy — a forged self-item-grant / self-kill-credit ----
# The killing blow, loot roll, and kill credit are SERVER-OBSERVED: main.gd calls on_mob_kill /
# on_mob_loot from _check_death_mob. A client has NO intent to invoke them — they are not in the
# inbound handles() allow-list. This asserts the boundary: a forged {"type":"grant_loot"} (or
# credit_kill / carry_gear) is an UNKNOWN message the world will not route, so a client can never
# grant itself an item or credit itself a kill.
# T-358: mob-kill XP rides the SAME server-observed credit_kill path (world reports the kill, master
# runs mob_xp.gd + leveling.apply_xp) — there is NO client XP verb. The forged XP intents below MUST
# stay unroutable, or a cheat client could level itself by asserting a kill it never made.
func test_no_client_facing_item_grant_or_kill_credit_intent() -> void:
	var wr = _WRPC.new()
	for forged in [
		"grant_loot",
		"credit_kill",
		"on_mob_kill",
		"carry_gear",
		"adjust_coins",
		"grant_xp",
		"award_xp",
		"apply_xp",
		"mob_xp",
		# T-427: discovery is movement-observed; no client may name a node or claim its reward.
		"discover",
		"discovery_earned",
		"grant_discovery",
		# T-452: client may toggle the desire only; it can never name a cap/effective stat/reward level.
		"set_mentor_level",
		"mentor_level",
		"apply_mentor_stats",
		"mentor_credit",
		"mentor_unlock",
		# T-450: daily reads/grants are world/master-only; the client reaches status only through a
		# proximity-gated bounty service browse and can never name a reward, streak, or date key.
		"daily_status",
		"daily_claim",
		"daily_reward",
		# T-412: the new coin SINKS write coin only through master-validated ops (repair/vault_op/
		# auction_op), never a raw client verb. A forged top-level "vault_upgrade" (bypassing the bank
		# service's proximity gate) or the master-internal "set_vault_tier" must NOT be routable.
		"vault_upgrade",
		"set_vault_tier",
		# T-430: vendor changes are reachable ONLY through proximity-gated service_intent. Raw
		# grant/coin/master verbs would bypass stock, price, ownership, and identity validation.
		"vendor_op",
		"vendor_sell",
		"vendor_buy",
		"vendor_grant",
		"buyback_grant",
	]:
		assert_false(
			wr.handles(forged),
			(
				"CRIT: '%s' is client-routable — a forged intent could grant items/coin/credit/XP"
				% forged
			)
		)
	# And the legitimate client intents ARE routed (proves handles() isn't just false for everything).
	for legit in ["equip", "drop", "accept_quest", "turn_in", "party_mentor_sync"]:
		assert_true(wr.handles(legit), "legitimate intent '%s' must route" % legit)


# T-477: mentorship discovery can advertise consent and browse only. There is no auto-match,
# eligibility setter, sync grant, or power grant verb; the normal T-452 toggle remains separate.
func test_mentor_discovery_has_only_signal_and_read_intents() -> void:
	var svc = _SOCIAL.new()
	for legit in ["mentor_flag", "mentor_unflag", "mentor_list"]:
		assert_true(svc.handles(legit), "the opt-in discovery desire must route")
	for forged in [
		"mentor_match",
		"mentor_auto_party",
		"mentor_set_eligible",
		"mentor_grant_level",
		"mentor_grant_stats",
		"mentor_reward",
	]:
		assert_false(svc.handles(forged), "CRIT: grant/match verb '%s' is client-routable" % forged)


# --- VECTOR 3c: Crafting (T-414) — no forged grant verb; intents carry ONLY ids ---
# gather/craft/use_item/learn_recipe route as DESIRES: the world resolves node yields, recipe
# inputs/outputs, and item effects from ITS OWN registries (nodes.json/recipes.json/items.json) and
# the master re-validates ownership/known/coins. The master-op verbs and store writers must never
# be client-routable, or a cheat client could mint materials, name its own craft output, forge a
# consumable effect, or grant itself a recipe/rested pool for free.
func test_no_client_facing_craft_grant_verbs() -> void:
	var wr = _WRPC.new()
	for forged in [
		"gather_op",
		"craft_op",
		"use_item_op",
		"recipe_op",
		"grant_recipe",
		"grant_rested",
		"field_repair",
	]:
		assert_false(
			wr.handles(forged),
			"CRIT: '%s' is client-routable — a forged intent could mint items/effects" % forged
		)
	for legit in ["gather", "gather_nodes", "craft", "use_item", "learn_recipe", "recipe_catalog"]:
		assert_true(wr.handles(legit), "legitimate craft desire '%s' must route" % legit)


# --- VECTOR 3b: Trade (T-363) — no client verb can trigger the swap directly ---
# The atomic swap ONLY happens inside the master's double-confirm commit. A cheat client must have
# no routable intent that commits, grants, or completes a trade by assertion — only desires
# (request/offer/confirm) are routed, and each is re-validated server-side.
func test_no_client_facing_trade_commit_or_grant_intent() -> void:
	var svc = _SOCIAL.new()
	for forged in ["trade_commit", "trade_grant", "trade_complete", "trade_swap", "adjust_coins"]:
		assert_false(
			svc.handles(forged),
			"CRIT: '%s' is client-routable — a forged intent could move items/coin" % forged
		)
	for legit in ["trade_request", "trade_offer_item", "trade_confirm", "trade_cancel"]:
		assert_true(svc.handles(legit), "legitimate trade desire '%s' must route" % legit)


# --- VECTOR 7c: Guilds (T-362) — no client verb grants rank or membership by assertion ---
# Rank/membership is only ever conferred by a master-validated op (create pays a coin sink, accept
# consumes a master-held invite, promote is leader-gated). A cheat client must have NO routable
# intent that hands itself a rank, seats itself as leader, or force-adds a member. Only management
# DESIRES route; the master re-checks the actor's persisted rank on every one.
func test_no_client_facing_guild_grant_intent() -> void:
	var svc = _SOCIAL.new()
	for forged in [
		"guild_grant_rank",
		"guild_set_leader",
		"guild_add_member",
		"guild_set_rank",
		"guild_force_join",
		"guild_auto_join",
		"guild_seek_set_level",
		"guild_who_set_level",
	]:
		assert_false(
			svc.handles(forged),
			"CRIT: '%s' is client-routable — a forged intent could self-grant guild power" % forged
		)
	for legit in [
		"guild_create",
		"guild_invite",
		"guild_accept",
		"guild_kick",
		"guild_disband",
		"guild_browse",
		"guild_seek",
		"player_who",
	]:
		assert_true(svc.handles(legit), "legitimate guild desire '%s' must route" % legit)


# --- VECTOR 2c: Duels (T-381) — no client verb records a match/win by assertion ---
# A duel result is SERVER-OBSERVED: the world adjudicates the HP floor and calls record_match itself.
# A cheat client must have NO routable verb that reports a win, records a match, or self-flags a duel;
# only request/accept/decline/cancel DESIRES route, and the pair store gates each server-side.
func test_no_client_facing_duel_result_verb() -> void:
	var svc = _SOCIAL.new()
	for forged in ["duel_result", "record_match", "duel_win", "duel_flag", "duel_grant"]:
		assert_false(
			svc.handles(forged), "CRIT: '%s' is client-routable — a forged win could land" % forged
		)
	for legit in ["duel_request", "duel_accept", "duel_decline", "duel_cancel"]:
		assert_true(svc.handles(legit), "legitimate duel desire '%s' must route" % legit)


# A forged duel_accept for a pair that never exchanged a request must flag NO duel — otherwise a cheat
# client could self-consent into PvP eligibility and legally strike a stranger through the gate.
func test_forged_duel_accept_without_request_flags_nothing() -> void:
	PlayerSessions._reset_for_test()
	PlayerSessions.add_player(1, _TOK_A, "Alice", Vector3.ZERO)
	PlayerSessions.add_player(2, _TOK_B, "Bob", Vector3(2.0, 0.0, 0.0))
	var svc = _SOCIAL.new()
	svc.setup(func(_pid, _msg): pass, {}, _CaptureMaster.new(), null)
	svc.handle("duel_accept", 2, {}, 1000)  # Bob accepts a duel that was never offered
	assert_false(svc.pvp_eligible(1, 2), "CRIT: a forged accept flagged a duel never offered")
	assert_false(svc.pvp_eligible(2, 1), "eligibility must stay FALSE for a fabricated duel")


# --- VECTOR 2d: Battleground (T-413) — no client verb scores, wins, or ends a match ---------
# The Crownfield is SERVER-ADJUDICATED: the world tick accrues the score, resolves the end, and
# calls record_match itself (bracket "bg"). A cheat client must have NO routable verb that reports
# a score/win/end or flags itself into a match; only the queue DESIRES route.
func test_no_client_facing_bg_result_verb() -> void:
	var svc = _SOCIAL.new()
	for forged in ["bg_result", "bg_score", "bg_win", "bg_end", "bg_join", "bg_flag"]:
		assert_false(
			svc.handles(forged),
			"CRIT: '%s' is client-routable — a forged BG win could land" % forged
		)
	for legit in ["bg_queue", "bg_unqueue", "bg_status"]:
		assert_true(svc.handles(legit), "legitimate bg desire '%s' must route" % legit)


# A forged strike ACROSS matches (or at a teammate) must stay ineligible: two Crownfield matches
# are separate consent domains — the arena flag can never leak PvP onto bystanders or allies.
func test_forged_cross_match_and_team_attacks_ineligible() -> void:
	PlayerSessions._reset_for_test()
	var svc = _SOCIAL.new()
	svc.setup(func(_pid, _msg): pass, {}, _CaptureMaster.new(), null)
	for i in 12:  # two full 3v3 lobbies -> matches [1,2,3]v[4,5,6] and [7,8,9]v[10,11,12]
		var tok := "%032x" % (0xABC000 + i)
		PlayerSessions.add_player(i + 1, tok, "bgp%d" % (i + 1), Vector3(float(i), 0.0, 0.0))
	for i in 12:
		svc.handle("bg_queue", i + 1, {}, 1000)
	assert_true(svc.pvp_eligible(1, 4), "control: cross-team in the SAME match is consented")
	assert_false(svc.pvp_eligible(1, 2), "CRIT: teammate attack passed the consent gate")
	assert_false(svc.pvp_eligible(1, 7), "CRIT: cross-MATCH attack passed the consent gate")
	assert_false(svc.pvp_eligible(7, 4), "CRIT: cross-match attack (reverse) passed the gate")
	assert_false(svc.pvp_eligible(1, 999), "a stranger outside any match is never eligible")


# A forged bg_queue from a dueling/instanced peer must be refused — and an unhandshaked peer's
# queue must be dropped at the hub's session gate like every other social intent.
func test_forged_bg_queue_from_ineligible_states_rejected() -> void:
	PlayerSessions._reset_for_test()
	var svc = _SOCIAL.new()
	svc.setup(func(_pid, _msg): pass, {}, _CaptureMaster.new(), null)
	PlayerSessions.add_player(1, _TOK_A, "Alice", Vector3.ZERO)
	PlayerSessions.add_player(2, _TOK_B, "Bob", Vector3(2.0, 0.0, 0.0))
	svc.handle("duel_request", 1, {"target": "Bob"}, 1000)
	svc.handle("duel_accept", 2, {}, 1001)  # the pair is now in a live duel
	svc.handle("bg_queue", 1, {}, 1002)
	assert_eq(svc._bg.queue_size(), 0, "CRIT: a dueling peer entered the BG lobby")
	PlayerSessions.set_instance(2, 7)  # Bob stands inside a crypt instance
	svc.handle("bg_queue", 2, {}, 1003)
	assert_eq(svc._bg.queue_size(), 0, "CRIT: an instanced peer entered the BG lobby")
	svc.handle("bg_queue", 77, {}, 1004)  # never handshaked
	assert_eq(svc._bg.queue_size(), 0, "CRIT: an unhandshaked peer entered the BG lobby")


func test_forged_guild_op_from_unknown_peer_dropped() -> void:
	PlayerSessions._reset_for_test()
	var calls: Array = []
	var master := _CaptureMaster.new()
	master.sink = calls
	var svc = _SOCIAL.new()
	svc.setup(func(_pid, _msg): pass, {}, master, null)
	# Peer 77 never handshaked — a forged guild_disband must not reach the master.
	svc.handle("guild_disband", 77, {"username": "Admin"}, 1000)
	assert_eq(calls.size(), 0, "CRIT: an unhandshaked peer opened a master guild op")


# --- VECTOR: Emotes (T-361 item 3) — the client sends ONLY an emote id (an intent). A forged /
# unknown id must be rejected and NEVER fanned out; a spoofed "from"/"username" on the wire must be
# ignored in favour of the SESSION identity (an emote is local, routed like say through the hub).
func test_forged_emote_unknown_id_and_spoofed_from_rejected() -> void:
	PlayerSessions._reset_for_test()
	PlayerSessions.add_player(1, _TOK_A, "Alice", Vector3.ZERO)
	PlayerSessions.add_player(2, _TOK_B, "Bob", Vector3(5, 0, 0))
	var sent: Array = []
	var svc = _SOCIAL.new()
	svc.setup(func(pid, msg): sent.append({"pid": pid, "msg": msg}), {}, null, null)
	# 1) An unknown/forged emote id is rejected to the actor and reaches NO other peer.
	svc.handle("emote", 1, {"id": "__exploit__", "from": "Admin"}, 1000)
	assert_eq(
		sent.filter(func(e): return int(e["pid"]) == 2).size(),
		0,
		"CRIT: a forged emote id was broadcast to another peer"
	)
	var to_actor: Array = sent.filter(func(e): return int(e["pid"]) == 1)
	assert_eq(str(to_actor[0]["msg"]["type"]), "chat_rejected", "an unknown emote is rejected")
	# 2) A KNOWN emote carrying a spoofed username uses the SESSION identity, never the wire's.
	sent.clear()
	svc.handle("emote", 1, {"id": "wave", "from": "Admin", "username": "Admin"}, 1000)
	var bob_line: Array = sent.filter(func(e): return int(e["pid"]) == 2)
	assert_eq(
		str(bob_line[0]["msg"]["from"]), "Alice", "CRIT: emote trusted a spoofed wire identity"
	)


# --- VECTOR 3d: Achievements (T-367) — earns are SERVER-OBSERVED (folded into credit_kill/turn_in/
# credit_reach on the master). A client has NO verb to grant itself an achievement or its reward:
# only routable achievement intent is the read-only "achievement_list". A forged earn/grant is an
# unknown message the world will not route.
func test_no_client_facing_achievement_grant_intent() -> void:
	var wr = _WRPC.new()
	for forged in ["achievement_grant", "achievement_earn", "achievement_op", "grant_achievement"]:
		assert_false(
			wr.handles(forged),
			(
				"CRIT: '%s' is client-routable — a forged intent could self-grant an achievement"
				% forged
			)
		)
	assert_true(wr.handles("achievement_list"), "the read-only panel feed must route")


# --- VECTOR: PvP rating spine (T-390) — a client can neither report a win nor set a rating ---
# Rating is SERVER-OBSERVED from a match the server adjudicates (record_match lives only on the
# master, reached via the secret-gated world→master RPC). The ONLY routable PvP intents are the
# READ-ONLY ladder reads (leaderboard + own rating); a forged "I won / set my MMR" is an unknown
# message the world will not route, so a cheat client has no channel to self-rate.
func test_no_client_facing_pvp_rating_grant_intent() -> void:
	var svc = _SOCIAL.new()
	for forged in [
		"pvp_report_win",
		"pvp_set_rating",
		"record_match",
		"pvp_record_match",
		"pvp_grant_rating",
		"pvp_win",
	]:
		assert_false(
			svc.handles(forged),
			"CRIT: '%s' is client-routable — a forged intent could self-set a PvP rating" % forged
		)
	for legit in ["pvp_leaderboard", "pvp_rating", "pvp_tracks"]:
		assert_true(svc.handles(legit), "the read-only ladder read '%s' must route" % legit)
	var wr = _WRPC.new()
	assert_false(wr.handles("record_match"), "record_match must never be a world client intent")


# T-391: honor is granted ONLY inside the server-observed record_match; the track surface can
# spend (overdraft-guarded master-side) but no client verb can CREDIT honor, set a track tier
# directly, or grant a cosmetic. A forged grant is an unknown message with no route.
func test_no_client_facing_honor_or_cosmetic_grant_intent() -> void:
	var svc = _SOCIAL.new()
	for forged in [
		"pvp_grant_honor",
		"grant_honor",
		"honor_grant",
		"pvp_set_track_tier",
		"pvp_grant_cosmetic",
		"grant_cosmetic",
		"pvp_season_payout",
		"pvp_track_op",
	]:
		assert_false(
			svc.handles(forged),
			"CRIT: '%s' is client-routable — a forged intent could self-grant PvP rewards" % forged
		)


# T-428: a wardrobe choice is legitimate, but the client cannot grant an unlock or assert the
# display asset/dye/stat payload. WardrobeService resolves IDs from server data and master checks
# the persisted unlock; raw grant/apply-state verbs remain unroutable.
func test_wardrobe_surface_has_no_grant_or_power_channel() -> void:
	var wr = _WRPC.new()
	for legit in ["wardrobe_list", "wardrobe_apply", "wardrobe_clear", "wardrobe_hide_helm"]:
		assert_true(wr.handles(legit), "%s is the bounded wardrobe desire surface" % legit)
	for forged in [
		"wardrobe_grant",
		"grant_appearance",
		"grant_dye",
		"wardrobe_set_stats",
		"wardrobe_set_display_item",
		"wardrobe_op",
	]:
		assert_false(wr.handles(forged), "CRIT: forged wardrobe verb %s is routable" % forged)


# T-401: wearing a title is a legit client intent (pvp_set_title), but the world NEVER trusts the
# wire — it forwards the desire to the master's fail-closed pvp_track_op set_title and applies ONLY
# the verdict. A forged/unowned title (master → not_unlocked) must be rejected to the actor and never
# reach the nameplate broadcast store; an owned title (master → ok) rides the broadcast + confirms.
func test_forged_title_choice_rejected_and_never_broadcast() -> void:
	PlayerSessions._reset_for_test()
	PlayerSessions.add_player(1, _TOK_A, "Alice", Vector3.ZERO)
	var svc = _SOCIAL.new()
	assert_true(svc.handles("pvp_set_title"), "wearing a title is a legit client intent")
	var sent: Array = []
	var pushed: Array = []  # (pid, title) pairs the world pushed to its nameplate store
	svc.setup(
		func(pid, msg): sent.append({"pid": pid, "msg": msg}),
		{},
		_TitleMaster.new(),
		null,
		func(pid, t): pushed.append([pid, t])
	)
	# Forged: a title the caller never earned. The master fails closed → world must NOT broadcast it.
	svc.handle("pvp_set_title", 1, {"title": "title:Grand Champion"}, 1000)
	assert_eq(pushed.size(), 0, "CRIT: a forged title reached the nameplate broadcast")
	var reject: Array = sent.filter(func(e): return int(e["pid"]) == 1)
	assert_eq(str(reject[0]["msg"]["type"]), "pvp_result", "the forged title is answered")
	assert_false(bool(reject[0]["msg"]["ok"]), "a forged/unowned title is rejected to the actor")
	# Owned: the master validated ownership → the world pushes it to the broadcast and confirms.
	sent.clear()
	svc.handle("pvp_set_title", 1, {"title": "title:Owned"}, 1000)
	assert_eq(pushed.size(), 1, "an owned title rides the nameplate broadcast")
	assert_eq(str(pushed[0][1]), "title:Owned", "the exact validated title is broadcast")
	assert_true(bool(sent[0]["msg"]["ok"]), "an owned title is confirmed to the actor")


# Mimics the master's fail-closed pvp_track_op set_title: only "title:Owned" is in the unlock set.
class _TitleMaster:
	extends RefCounted

	func call_master(_method: String, params: Dictionary) -> Dictionary:
		if str(params.get("title", "")) == "title:Owned":
			return {"ok": true, "title": "title:Owned"}
		return {"error": "not_unlocked"}


# --- VECTOR 3c: Trade — a forged request naming an offline/absent target dies at the world edge,
# and the wire's identity claims never reach the master (identity = session).
func test_forged_trade_request_from_unknown_peer_dropped() -> void:
	PlayerSessions._reset_for_test()
	var calls: Array = []
	var master := _CaptureMaster.new()
	master.sink = calls
	var svc = _SOCIAL.new()
	svc.setup(func(_pid, _msg): pass, {}, master, null)
	# Peer 66 never handshaked — the hub must drop the intent before any master round-trip.
	svc.handle("trade_request", 66, {"target": "Anyone", "username": "Admin"}, 1000)
	assert_eq(calls.size(), 0, "CRIT: an unhandshaked peer opened a master trade op")


class _CaptureMaster:
	extends RefCounted
	var sink: Array = []

	func call_master(method: String, params: Dictionary) -> Dictionary:
		sink.append({"method": method, "params": params})
		return {"error": "test"}


# --- VECTOR 1b: Teleport-via-intent — a forged leave_era / enter_instance from anywhere ---------
# The repositioning intents snap the session to a fixed anchor, bypassing the movement budget. A
# cheat client fires leave_era from the open world (nowhere near Ashmoor) expecting a free teleport
# to RIFT_RETURN; and enter_instance from across the map expecting a free jump to CRYPT_ENTRANCE.
# instance_service gates both on PROXIMITY to the threshold the client legitimately fires from
# (ASHMOOR_RIFT / CRYPT_PORCH). The controls prove the gate isn't just closed: an at-anchor player
# still crosses / descends.
# A wired-but-master-less instance_service with a reply sink and a recording move callable, so the
# forged/legit teleport intents can be exercised on the PURE unit (no scene tree, no master).
func _teleport_svc(moves: Array, replies: Array):
	var svc = _ISVC.new()
	svc.setup(
		{}, {}, func(_pid, _iid): pass, func(pid, pos): moves.append([pid, pos]), func(_eid): pass  # mobs  # party_of  # set_session_instance  # move_session (records repositioning)  # clear_threat
	)
	svc.setup_lfg({}, func(pid, msg): replies.append([pid, msg]))  # no master → rift eligibility open
	return svc


func test_forged_leave_era_from_open_world_does_not_reposition() -> void:
	PlayerSessions._reset_for_test()
	# peer 1 sits in the open world, far from the Ashmoor arrival monolith (-420,-10).
	PlayerSessions.add_player(1, _TOK_A, "cheater", Vector3(120.0, 30.0, 0.0))
	var moves: Array = []
	var replies: Array = []
	var svc = _teleport_svc(moves, replies)
	svc.leave_era(1)
	assert_eq(
		moves.size(), 0, "CRIT: a distant forged leave_era teleported the session (free travel)"
	)
	assert_eq(
		str(replies[-1][1].get("type", "")), "rift_sealed", "and the client is told it's sealed"
	)


func test_forged_enter_instance_from_afar_does_not_teleport_into_crypt() -> void:
	PlayerSessions._reset_for_test()
	# peer 1 is nowhere near the churchyard porch (14,-12.5).
	PlayerSessions.add_player(1, _TOK_A, "cheater", Vector3(300.0, -80.0, 0.0))
	var moves: Array = []
	var replies: Array = []
	var svc = _teleport_svc(moves, replies)
	var iid: int = svc.enter(1)
	assert_eq(iid, _IM.WORLD, "CRIT: a distant forged enter_instance allocated/entered an instance")
	assert_eq(
		moves.size(), 0, "CRIT: a distant forged enter_instance snapped the session to a crypt"
	)


# Control: an at-anchor player IS repositioned by both — the gate is proximity, not a closed door.
func test_at_anchor_teleport_intents_still_pass() -> void:
	PlayerSessions._reset_for_test()
	PlayerSessions.add_player(1, _TOK_A, "traveller", Vector3(-420.0, -10.0, 0.0))  # at the rift
	PlayerSessions.add_player(2, _TOK_B, "delver", Vector3(14.0, -12.5, 0.0))  # on the crypt porch
	var moves: Array = []
	var replies: Array = []
	var svc = _teleport_svc(moves, replies)
	svc.leave_era(1)
	assert_eq(moves, [[1, _ISVC.RIFT_RETURN]], "an at-anchor player DOES return through the rift")
	var iid: int = svc.enter(2)
	assert_ne(iid, _IM.WORLD, "an on-porch player DOES descend into a crypt instance")


# --- VECTOR 9: Rate/DoS — a forged get_inventory/equip intent flood -----------
# The master-round-trip intents (get_inventory/equip/talk/service_intent/party…) each fan out to a
# master RPC + a Postgres read. main.gd meters them per-peer through IntentRateLimiter BEFORE
# dispatch, so a client flooding them in a tight loop is throttled (rate_limited) then disconnected
# instead of amplifying load onto the single master. This asserts the limiter that _receive_message
# gates the world_rpc/instance branches on actually cuts a flood off — a red assertion here means a
# forged intent flood reaches master unthrottled.
func test_forged_intent_flood_throttled_then_disconnected() -> void:
	var lim = _IRL.new()
	var allowed := 0
	var throttled := false
	var disconnected := false
	# A cheat client hammers get_inventory in a tight loop within the same instant (no refill).
	for i in range(3000):
		if lim.allow(1, 0):
			allowed += 1
		else:
			throttled = true
		if lim.should_disconnect(1):
			disconnected = true
			break
	assert_true(throttled, "CRIT: an intent flood was never throttled (rate_limited)")
	assert_true(disconnected, "CRIT: a sustained intent flood was never flagged for disconnect")
	assert_true(
		allowed <= int(_IRL.CAPACITY),
		"a same-instant flood must not pass more than the burst budget (got %d)" % allowed
	)


# Control: honest bursty UI use (open a bag, equip, talk, list an auction — a handful of intents,
# then paced ~1/sec) must NEVER trip the limiter. This is the tuning guard: pilot goto's rate-legal
# hops are request_move (a separate limiter) and combat spam is GCD-gated use_ability — neither is
# metered here, and ordinary panel traffic stays well under budget.
func test_legit_ui_intent_burst_not_throttled() -> void:
	var lim = _IRL.new()
	# Open-a-vendor burst: talk + service_intent + get_inventory + a few equips, all at once.
	for i in range(8):
		assert_true(lim.allow(1, 0), "a legit UI burst intent must pass")
	# Then paced UI traffic for a minute — never throttled, never flagged.
	for sec in range(60):
		assert_true(lim.allow(1, 1000 + sec * 1000), "1 intent/sec must always pass")
		assert_false(lim.should_disconnect(1), "legit play must never be flagged as a flood")


# --- VECTOR 5: Customization — a forged action-bar layout placing an UNLEARNED ability (T-422c) ---
# set_bar_layout lets a player reorder their bar, but the ordering must be a permutation of the
# character's KNOWN kit. A cheat client forges a layout naming an ability it never learned (or a
# duplicate) to try to slot it onto the bar. The world re-derives the known ids server-side and
# BarLayoutOps.sanitize MUST reject the whole layout (fail-closed) so nothing unowned is ever placed.
func test_forged_bar_layout_with_unowned_ability_rejected() -> void:
	var known := [1, 201, 202]  # what the server says this character actually knows
	assert_eq(
		_BLO.sanitize([1, 999, 201], known),
		[],
		"CRIT: a bar layout naming an unlearned ability (999) must be rejected wholesale"
	)
	assert_eq(_BLO.sanitize([1, 201, 1], known), [], "a duplicate slot assignment is also rejected")
	# A legal reorder of exactly the known ids still round-trips (the gate isn't over-eager).
	assert_eq(_BLO.sanitize([202, 1, 201], known), [202, 1, 201], "an honest reorder passes")


# --- T-393: Rift Trials — the keystone/tier/verdict trust boundary -------------------------------
# The client's ENTIRE rift vocabulary is "enter with my keystone" plus two reads. A cheat client
# forging "set my keystone to tier N" / "I cleared tier N" / "grant my rift reward" must find NO
# server verb that accepts it: neither intent hub handles the verbs, so they die at dispatch. The
# tier itself is read from the master's persisted keystone (rift_ladder rejects unknown actions on
# its side too — test_rift_ladder), and the verdict/reward path only exists as a world-observed
# adjudication inside instance_service.tick_bosses.
func test_forged_rift_tier_and_clear_intents_have_no_vocabulary() -> void:
	var wr = _WRPC.new()
	var svc = _ISVC.new()
	for forged in [
		"rift_set_tier",
		"set_keystone",
		"rift_cleared",
		"rift_clear",
		"rift_result",
		"rift_grant_reward",
		"rift_reward",
		"rift_upgrade_keystone",
		"rift_op",  # the master op name must not be reachable as a raw client intent either
	]:
		assert_false(wr.handles(forged), "CRIT: world_rpc accepts forged rift intent '%s'" % forged)
		assert_false(
			svc.handles(forged), "CRIT: instance_service accepts forged rift intent '%s'" % forged
		)
	# The legitimate vocabulary stays exactly: enter + two reads.
	assert_true(svc.handles("enter_rift_instance"))
	assert_true(svc.handles("rift_status"))
	assert_true(svc.handles("rift_leaderboard"))


# A forged enter_rift_instance fired from across the map is a free teleport attempt into the rift
# arena (security-model vector 1b) — the porch proximity gate must reject it with no session move
# and no scaled spawns seeded.
func test_forged_rift_enter_from_anywhere_rejected() -> void:
	PlayerSessions.add_player(66, _TOK_A, "rift_forger", Vector3(250.0, 250.0, 0.0))
	var mobs: Dictionary = {}
	var svc = _ISVC.new()
	svc.setup(mobs, {}, func(_a, _b): pass, func(_a, _b): pass, func(_a): pass)
	var iid: int = await svc.enter_rift(66)
	assert_eq(iid, _IM.WORLD, "CRIT: a far-away forged rift entry was accepted")
	assert_eq(mobs.size(), 0, "no rift spawns seeded for a rejected forgery")
