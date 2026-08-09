# T-381: PvP-consent gate — unit tests for ability_executor's player→player guard.
# The gate rejects a hostile ability on a DIFFERENT player unless the injected `pvp_eligible`
# predicate confirms an active consensual duel. Mobs, self-targets, friendly effects, and the
# absent-predicate (pure combat) path are never gated. All calls are pure — no scene/network.

extends GutTest

const _AE = preload("res://scripts/combat/ability_executor.gd")
const _CS = preload("res://scripts/combat/combat_state.gd")
const _ES = preload("res://scripts/combat/entity_snapshot.gd")


func _rng() -> RandomNumberGenerator:
	var r := RandomNumberGenerator.new()
	r.seed = 42
	return r


func _entity(peer_id: int, pos: Vector3, is_mob: bool = false):
	var s = _ES.new()
	s.peer_id = peer_id
	s.position = pos
	var cs := CombatState.new()
	cs.state = _CS.CombatStateEnum.IDLE
	s.combat_state = cs
	var cr := CombatResources.new()
	cr.hp = 100
	cr.max_hp = 100
	cr.stamina = 100
	cr.max_stamina = 100
	s.resources = cr
	s.stats = CharacterStats.new()
	s.is_mob = is_mob
	return s


func _strike() -> AbilityData:
	var a := AbilityData.new()
	a.id = 1
	a.name = "Strike"
	a.effect = "damage"
	a.base_damage = 10
	a.range_units = 5.0
	a.stamina_cost = 5
	a.triggers_gcd = true
	a.variance_min = 1.0
	a.variance_max = 1.0
	return a


func _heal() -> AbilityData:
	var a := _strike()
	a.effect = "heal"
	a.targets_friendly = true
	return a


func _always_false() -> Callable:
	return func(_a: int, _b: int) -> bool: return false


func _always_true() -> Callable:
	return func(_a: int, _b: int) -> bool: return true


# --- the core rejection: a hostile hit on a non-dueling player is rejected -----
func test_player_vs_player_without_duel_rejected() -> void:
	var caster = _entity(1, Vector3.ZERO)
	var target = _entity(2, Vector3(2, 0, 0))
	var r = _AE.execute_ability(caster, target, _strike(), 0, _rng(), null, null, _always_false())
	assert_false(r.accepted, "CRIT: non-consensual player→player damage was accepted")
	assert_eq(r.rejection_reason, "pvp_not_allowed")
	assert_eq(r.damage_amount, 0, "no damage may be applied on a rejected forgery")


# --- an active duel (predicate TRUE) lets the same strike through --------------
func test_player_vs_player_in_duel_accepted() -> void:
	var caster = _entity(1, Vector3.ZERO)
	var target = _entity(2, Vector3(2, 0, 0))
	var r = _AE.execute_ability(caster, target, _strike(), 0, _rng(), null, null, _always_true())
	assert_true(r.accepted, "a hit between two consenting duelists must be accepted")
	assert_eq(r.damage_amount, 10)


# --- mob targets are NEVER gated (predicate FALSE but target is a mob) ---------
func test_mob_target_unaffected_by_gate() -> void:
	var caster = _entity(1, Vector3.ZERO)
	var mob = _entity(9001, Vector3(2, 0, 0), true)
	var r = _AE.execute_ability(caster, mob, _strike(), 0, _rng(), null, null, _always_false())
	assert_true(r.accepted, "PvE damage on a mob must never be blocked by the PvP gate")


# --- self-target is never gated (a self-effect isn't PvP) ---------------------
func test_self_target_unaffected() -> void:
	var caster = _entity(1, Vector3.ZERO)
	var self_t = _entity(1, Vector3.ZERO)
	var r = _AE.execute_ability(caster, self_t, _strike(), 0, _rng(), null, null, _always_false())
	assert_true(r.accepted, "a self-cast must not be treated as non-consensual PvP")


# --- a friendly (heal) effect on another player is cooperative, not gated -----
func test_friendly_effect_on_player_unaffected() -> void:
	var caster = _entity(1, Vector3.ZERO)
	var ally = _entity(2, Vector3(2, 0, 0))
	var r = _AE.execute_ability(caster, ally, _heal(), 0, _rng(), null, null, _always_false())
	assert_true(r.accepted, "healing an ally is cooperative — the PvP gate must not block it")


# --- absent predicate (pure combat unit path) skips the gate entirely ---------
func test_absent_predicate_skips_gate() -> void:
	var caster = _entity(1, Vector3.ZERO)
	var target = _entity(2, Vector3(2, 0, 0))
	var r = _AE.execute_ability(caster, target, _strike(), 0, _rng())  # no predicate wired
	assert_true(r.accepted, "with no predicate injected the gate is inert (pure-unit default)")


# --- the gate also guards cast-completion damage ------------------------------
func test_complete_cast_player_target_gated() -> void:
	var caster = _entity(1, Vector3.ZERO)
	var target = _entity(2, Vector3(2, 0, 0))
	var r = _AE.complete_cast(caster, target, _strike(), 0, _rng(), null, null, _always_false())
	assert_false(r.accepted, "CRIT: cast-completion bypassed the PvP consent gate")
	assert_eq(r.rejection_reason, "pvp_not_allowed")
