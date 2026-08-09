class_name AbilityIcons
# T-555: some server ability rows reuse another ability's icon slug (Pummel ships the Heroic Strike
# slug, Concussive Blow the Sunder Armor slug), so the action bar + spellbook drew only ~3 distinct
# glyphs for the warrior's 5 abilities — the bar read as duplicate buttons. This is the CLIENT-side
# icon resolver: a curated per-ability override for the known collisions, then a generic same-kit
# de-dup so no two FILLED slots ever share a glyph — for ANY class kit, not just the warrior's.
# The server ability data is deliberately untouched here (a sibling lane owns that data).
#
# Pure + static: no Node/tree state, unit-tested directly. Input is the kit Array the client already
# holds ({id,name,icon,...}); output is a COPY with a distinct "icon" per ability.

extends RefCounted

# Curated overrides for abilities whose server slug collides with another ability's. Keyed by the
# display name (the slug itself can't tell the collision apart — both rows carry the SAME slug).
const _NAME_OVERRIDES := {
	"Pummel": "revenge",  # an interrupt/kick — the counter-fist glyph, not Heroic Strike's blades
	"Concussive Blow": "cleave",  # a heavy stun — a distinct sweep, not Sunder Armor's shield/bolt
}

# Distinct ability icons that ship under res://assets/icons/abilities/, used to break any residual
# collision generically. Ordered so the first free one is a sensible generic weapon strike.
const _FALLBACK_POOL := [
	"strike",
	"cleave",
	"revenge",
	"smite",
	"scorch",
	"holy_fire",
	"fire_blast",
	"frost_nova",
	"renew",
	"greater_heal",
]


# Return a COPY of the kit with a distinct "icon" slug per ability. Only reassigns when a NON-EMPTY
# slug collides with an earlier ability's; an empty slug stays empty (so the text-glyph fallback is
# preserved for a genuinely icon-less ability). Idempotent — re-running on a deduped kit is stable.
static func deduped(kit: Array) -> Array:
	var out: Array = []
	var used := {}
	for entry: Variant in kit:
		var ability: Dictionary = (entry as Dictionary).duplicate(true)
		var slug := _preferred(ability)
		if slug != "" and used.has(slug):
			slug = _next_free(used, slug)
		if slug != "":
			used[slug] = true
		ability["icon"] = slug
		out.append(ability)
	return out


static func _preferred(ability: Dictionary) -> String:
	var ability_name := str(ability.get("name", ""))
	if _NAME_OVERRIDES.has(ability_name):
		return str(_NAME_OVERRIDES[ability_name])
	return str(ability.get("icon", ""))


static func _next_free(used: Dictionary, current: String) -> String:
	for candidate: String in _FALLBACK_POOL:
		if candidate != current and not used.has(candidate):
			return candidate
	return current  # pool exhausted (>10 colliding slots) — keep the dup rather than blank the slot
