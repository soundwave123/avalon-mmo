# T-381: duel_service — pure-module unit suite for the consensual-duel rules + pair store.
# Covers request/accept/decline/timeout, the forged-accept defense, the eligibility predicate, the
# HP-floor end (no death → no penalty), the leash break, and session-scoped disconnect cleanup.

extends GutTest

const _DUEL = preload("res://scripts/duel_service.gd")

const A := 1
const B := 2
const C := 3


func _svc() -> RefCounted:
	return _DUEL.new()


# ---- request / accept happy path --------------------------------------------


func test_request_then_accept_flags_both() -> void:
	var d = _svc()
	var req = d.request(A, "Alice", B, "Bob", 0)
	assert_true(req["ok"], "a valid challenge is recorded")
	assert_false(d.is_dueling(A), "no one is in-duel until accept")
	var acc = d.accept(B, Vector2(1, 0), 100)
	assert_true(acc["ok"])
	assert_eq(int(acc["a_id"]), A)
	assert_eq(int(acc["b_id"]), B)
	assert_true(d.is_dueling(A) and d.is_dueling(B), "both flagged in-duel on accept")
	assert_eq(d.opponent_of(A), B)
	assert_eq(d.opponent_of(B), A)


# ---- eligibility predicate (the executor consent gate) ----------------------


func test_eligible_only_for_active_pair() -> void:
	var d = _svc()
	assert_false(d.eligible(A, B), "no duel → not eligible (fail-closed default)")
	d.request(A, "Alice", B, "Bob", 0)
	assert_false(d.eligible(A, B), "a pending offer is NOT yet consent")
	d.accept(B, Vector2.ZERO, 0)
	assert_true(d.eligible(A, B), "an active duel makes the pair eligible")
	assert_true(d.eligible(B, A), "eligibility is symmetric")
	assert_false(d.eligible(A, C), "a third party is never eligible")
	assert_false(d.eligible(A, A), "self is never an eligible PvP pair")


# ---- forged accept -----------------------------------------------------------


func test_forged_accept_without_request_rejected() -> void:
	var d = _svc()
	var acc = d.accept(B, Vector2.ZERO, 0)  # no one ever challenged B
	assert_eq(acc.get("error", ""), "no_request", "CRIT: self-flagged into a duel never offered")
	assert_false(d.is_dueling(B), "no duel may exist after a forged accept")


func test_accept_expired_request_rejected() -> void:
	var d = _svc()
	d.request(A, "Alice", B, "Bob", 0)
	var acc = d.accept(B, Vector2.ZERO, _DUEL.REQUEST_TTL_MS + 1)  # past the TTL
	assert_eq(acc.get("error", ""), "expired")
	assert_false(d.is_dueling(B), "an expired offer cannot start a duel")


# ---- decline / cancel / guards ----------------------------------------------


func test_decline_drops_offer() -> void:
	var d = _svc()
	d.request(A, "Alice", B, "Bob", 0)
	var dec = d.decline(B)
	assert_true(dec["ok"])
	assert_eq(int(dec["challenger_id"]), A, "the challenger is returned so it can be notified")
	assert_eq(d.accept(B, Vector2.ZERO, 1).get("error", ""), "no_request", "offer is gone")


func test_challenger_cancels_own_offer() -> void:
	var d = _svc()
	d.request(A, "Alice", B, "Bob", 0)
	var can = d.cancel(A)
	assert_true(can["ok"])
	assert_eq(int(can["target_id"]), B)
	assert_eq(d.accept(B, Vector2.ZERO, 1).get("error", ""), "no_request")


func test_cannot_request_or_accept_while_dueling() -> void:
	var d = _svc()
	d.request(A, "Alice", B, "Bob", 0)
	d.accept(B, Vector2.ZERO, 0)
	assert_eq(d.request(A, "Alice", C, "Cara", 0).get("error", ""), "already_dueling")
	assert_eq(d.request(C, "Cara", B, "Bob", 0).get("error", ""), "already_dueling")


func test_self_challenge_rejected() -> void:
	var d = _svc()
	assert_eq(d.request(A, "Alice", A, "Alice", 0).get("error", ""), "bad_target")


# ---- HP-floor end (no death, no penalty) ------------------------------------


func test_duel_continues_above_floor() -> void:
	var d = _svc()
	d.request(A, "Alice", B, "Bob", 0)
	d.accept(B, Vector2.ZERO, 0)
	assert_true(d.on_hit(B, 50, 100).is_empty(), "50/100 is above the 10% floor — duel continues")
	assert_true(d.is_dueling(B), "duel still active")


func test_hp_floor_ends_duel_winner_is_opponent() -> void:
	var d = _svc()
	d.request(A, "Alice", B, "Bob", 0)
	d.accept(B, Vector2.ZERO, 0)
	var end = d.on_hit(B, 8, 100)  # 8 <= 10% of 100 → floor reached
	assert_true(end["ended"])
	assert_eq(end["reason"], "hp_floor")
	assert_eq(int(end["winner_id"]), A, "the opponent wins, server-resolved")
	assert_eq(int(end["loser_id"]), B)
	assert_eq(str(end["winner_name"]), "Alice")
	assert_eq(str(end["loser_name"]), "Bob")
	# NO death: the caller clamps the loser to floor_hp (>0), so the alive→dead edge never fires and
	# T-364 durability wear cannot trigger from a friendly duel.
	assert_true(int(end["floor_hp"]) > 0, "loser is kept alive at the floor — no death penalty")
	assert_false(d.is_dueling(A) or d.is_dueling(B), "both cleared from the pair store on end")


func test_on_hit_ignores_non_duelists() -> void:
	var d = _svc()
	assert_true(d.on_hit(B, 1, 100).is_empty(), "a non-dueling player's hit is not a duel end")


# ---- leash break -------------------------------------------------------------


func test_leash_break_forfeits() -> void:
	var d = _svc()
	d.request(A, "Alice", B, "Bob", 0)
	d.accept(B, Vector2.ZERO, 0)  # anchor at origin
	assert_true(d.check_leash(B, Vector2(10, 0)).is_empty(), "within 40u — no forfeit")
	var end = d.check_leash(B, Vector2(50, 0))  # >40u from anchor
	assert_true(end["ended"])
	assert_eq(end["reason"], "leash")
	assert_eq(int(end["winner_id"]), A, "the runner forfeits to the opponent")
	assert_eq(int(end["loser_id"]), B)


# ---- disconnect cleanup (session-scoped; T-015 orphan lesson) ---------------


func test_disconnect_ends_active_duel_opponent_wins() -> void:
	var d = _svc()
	d.request(A, "Alice", B, "Bob", 0)
	d.accept(B, Vector2.ZERO, 0)
	var end = d.on_disconnect(A)  # Alice drops
	assert_true(end["ended"])
	assert_eq(end["reason"], "disconnect")
	assert_eq(int(end["winner_id"]), B, "the surviving opponent wins the forfeit")
	assert_eq(int(end["loser_id"]), A)
	assert_false(d.is_dueling(A) or d.is_dueling(B), "pair store cleaned up — no orphan")


func test_disconnect_clears_pending_offers() -> void:
	var d = _svc()
	d.request(A, "Alice", B, "Bob", 0)  # A's outbound offer to B
	d.on_disconnect(A)
	assert_eq(d.accept(B, Vector2.ZERO, 1).get("error", ""), "no_request", "leaver's offer dropped")
	# an inbound offer to the leaver is also dropped
	var d2 = _svc()
	d2.request(A, "Alice", B, "Bob", 0)
	d2.on_disconnect(B)
	assert_eq(d2.accept(B, Vector2.ZERO, 1).get("error", ""), "no_request")


func test_disconnect_of_non_duelist_is_noop() -> void:
	var d = _svc()
	assert_true(d.on_disconnect(C).is_empty(), "a peer with no duel/offer ends nothing")
