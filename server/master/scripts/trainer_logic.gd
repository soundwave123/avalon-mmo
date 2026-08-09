class_name TrainerLogic
extends RefCounted

# T-208: PURE trainer decisions — class-gated, level-gated, coin-priced ability unlocks.
# The catalog is data here; the kit filter in the world reads purchases from
# chars.character_abilities and the executor use-gates an unpurchased trained ability (T-365).
# T-365: a SPACED unlock schedule (a new ability every few levels, not just L2) so each class has
# something to look forward to across the 1–15 band. Coin costs climb with the band (T-366 tuning).
# Ranks (automatic level-banded scaling) are separate — this line is the whole-new-ability track.

const CATALOG := {
	"warrior":
	[
		{"ability": 104, "name": "Revenge", "cost": 60, "min_level": 2},
		{"ability": 105, "name": "Cleave", "cost": 150, "min_level": 8},
	],
	"mage":
	[
		{"ability": 203, "name": "Frost Nova", "cost": 60, "min_level": 2},
		{"ability": 205, "name": "Scorch", "cost": 150, "min_level": 8},
	],
	"priest":
	[
		{"ability": 304, "name": "Holy Fire", "cost": 60, "min_level": 2},
		{"ability": 305, "name": "Greater Heal", "cost": 150, "min_level": 8},
	],
}

# T-715: the starter hamlet's own trainer tag. Master-at-Arms Kessa carries it and teaches EVERY
# class — but only the L2 tier, so the L8 unlocks (and anything banded above them) stay a reason to
# make the trip to Highkeep. She stands 1.1 m from Hale, which is what makes T-712's "New ability
# ready — visit Master-at-Arms Kessa" banner a promise the player can act on at the ~4-minute ding
# instead of a 242 m breadcrumb behind a min_level-5 gate.
const STARTER_SERVICE := "trainer:starter"
const STARTER_MAX_LEVEL := 2


# `service` narrows the offer list: the starter tag shows only the tier it is allowed to sell.
static func catalog_for(char_class: String, service: String = "") -> Array:
	var rows: Array = CATALOG.get(char_class, [])
	if service != STARTER_SERVICE:
		return rows
	return rows.filter(func(row: Dictionary) -> bool: return _in_starter_tier(row))


## service tag "trainer:<class>" must match the buyer's class (T-205 gating data). T-715: the
## starter tag teaches whoever walks up, so it resolves to the BUYER's class (the tier cap above is
## the real gate) — never to a class the caller named.
static func class_for_service(service: String, buyer_class: String = "") -> String:
	if service == STARTER_SERVICE:
		return buyer_class
	if not service.begins_with("trainer:"):
		return ""
	return service.substr("trainer:".length())


static func can_train(
	char_class: String, level: int, coins: int, ability_id: int, owned: Array, service: String = ""
) -> Dictionary:
	var offer := {}
	for row in catalog_for(char_class, service):
		if int(row["ability"]) == ability_id:
			offer = row
			break
	if offer.is_empty():
		return {"ok": false, "reason": "not_taught_here"}
	if ability_id in owned:
		return {"ok": false, "reason": "already_known"}
	if level < int(offer["min_level"]):
		return {"ok": false, "reason": "level_too_low"}
	if coins < int(offer["cost"]):
		return {"ok": false, "reason": "insufficient_coins"}
	return {"ok": true, "cost": int(offer["cost"])}


static func _in_starter_tier(row: Dictionary) -> bool:
	return int(row.get("min_level", 1)) <= STARTER_MAX_LEVEL
