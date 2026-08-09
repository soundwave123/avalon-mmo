# T-719: The Shallow Graves scaling brain — the PURE headcount curve for the tutorial capstone.
# Mirrors rift_scaling.gd's idiom (deterministic, no DB, no OS time, inputs never mutated) with one
# deliberate difference that IS the design: **only HP scales**.
#
# The campaign's evidence rule is that a newcomer's first grouped content must never be blocked by
# role or composition scarcity (Exile's Reach: 1-5, no tank, no healer). Scaling mob DAMAGE with
# headcount is what creates a tank requirement — someone has to be built to eat the bigger hit — so
# dmg_mult is pinned at 1.0 forever. The consequence is intentional and asymmetric: a group is
# strictly SAFER than a solo run (the same swing spread over more targets and more healing) and
# strictly FASTER (HP grows sub-linearly at +60% a head against +100% a head of damage output). A
# player who brings friends is rewarded; a player who has none is never punished.
#
# SERVER-AUTHORITY: headcount comes from the live party record read at instance creation, never the
# wire — instance_service passes it in, the same way the rift's tier comes from the master keystone.
extends RefCounted

# Party bounds. A trial instance is authored for one to five players; a raid-sized group entering
# through the churchyard stair is clamped to the 5-player tuning rather than scaled off the curve.
const MIN_PLAYERS := 1
const MAX_PLAYERS := 5
# Each player past the first adds this fraction of the authored HP pool. SUB-LINEAR on purpose: five
# players bring ~5x the damage against 3.4x the HP, so the group clears in ~2/3 the solo time.
const HP_PER_EXTRA := 0.6


# Headcount clamped into the authored band. A missing/garbage count clamps UP to solo, never to a
# free zero-player discount.
static func clamp_players(players: int) -> int:
	return clampi(players, MIN_PLAYERS, MAX_PLAYERS)


static func hp_mult(players: int) -> float:
	return 1.0 + HP_PER_EXTRA * float(clamp_players(players) - 1)


# Pinned at 1.0 for every headcount — see the header. Exists as a function (rather than an omitted
# concept) so the no-role-scarcity rule is something a test can assert, not something a later edit
# can quietly reintroduce.
static func dmg_mult(_players: int) -> float:
	return 1.0


# The full tuning block for a headcount — the one call site instance_service uses, so the two curves
# can never drift apart from each other.
static func params_for(players: int) -> Dictionary:
	var n := clamp_players(players)
	return {"players": n, "hp_mult": hp_mult(n), "dmg_mult": dmg_mult(n)}
