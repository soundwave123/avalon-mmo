class_name Relationship
# T-281: the WoW visibility lynchpin — a pure client function that classifies any unit
# relative to the viewer from broadcast facts alone (is_mob / peer_id / party_id / pvp_flag).
# Nameplate color (T-286), cast-bar visibility (T-266), health-bar color, and targetability
# all branch on this one value, so the server stays render-cheap: it ships facts, the client
# computes relationship. No Node/scene state -> unit-testable off the truth table directly.
#
#   viewer: {peer_id:int, party_id?:int, pvp_flag?:bool}  — the local player's context.
#   unit:   a mob entry (has "mob_id" or is_mob=true) OR a broadcast player entry
#           ({peer_id, party_id?, pvp_flag?}). party_id is present only for a 2+ party
#           (server omits it for solo players); real party ids are >= 1, so 0 == no party.

extends RefCounted

enum Rel { SELF, PARTY, FRIENDLY, NEUTRAL, HOSTILE }

# T-286: WoW health-bar/nameplate color language. Hostile is red; self/party/friendly are
# green (a class-color option overrides friendly plates — resolved by the caller, which owns
# the class palette). Depletion is shown by the bar SHRINKING, not by a hue shift.
const HOSTILE_PLATE := Color(0.80, 0.16, 0.16)
const NEUTRAL_PLATE := Color(0.90, 0.72, 0.12)
const FRIENDLY_PLATE := Color(0.18, 0.80, 0.24)


# Classifies `unit` from the `viewer`'s perspective. Order matters: mob > self > party >
# player (friendly unless both PvP-flagged — the flag itself lands in T-282).
static func of(viewer: Dictionary, unit: Dictionary) -> Rel:
	if bool(unit.get("is_mob", false)) or unit.has("mob_id"):
		return Rel.HOSTILE if bool(unit.get("hostile", true)) else Rel.NEUTRAL
	var unit_peer := int(unit.get("peer_id", -1))
	if unit_peer != -1 and unit_peer == int(viewer.get("peer_id", -1)):
		return Rel.SELF
	var viewer_party := int(viewer.get("party_id", 0))
	if viewer_party != 0 and viewer_party == int(unit.get("party_id", 0)):
		return Rel.PARTY
	if bool(viewer.get("pvp_flag", false)) and bool(unit.get("pvp_flag", false)):
		return Rel.HOSTILE
	return Rel.FRIENDLY


# T-286: base plate color for a relationship (before any class-color override).
static func plate_color(rel: Rel) -> Color:
	match rel:
		Rel.HOSTILE:
			return HOSTILE_PLATE
		Rel.NEUTRAL:
			return NEUTRAL_PLATE
		_:
			return FRIENDLY_PLATE


static func name_of(rel: Rel) -> String:
	match rel:
		Rel.SELF:
			return "SELF"
		Rel.PARTY:
			return "PARTY"
		Rel.FRIENDLY:
			return "FRIENDLY"
		Rel.NEUTRAL:
			return "NEUTRAL"
		_:
			return "HOSTILE"
