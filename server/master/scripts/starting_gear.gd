extends RefCounted
# T-319: the class -> starting equipped weapon table + a pure slot builder.
#
# A character must never stand empty-handed: on class lock (and defensively at spawn) the
# master grants the class's starting weapon straight into the EQUIPPED weapon slot, so it
# rides the T-225 gear broadcast and everyone (local + remote) sees the real item — not the
# client-side placeholder default (EntityVisuals.CLASS_DEFAULT_WEAPONS, T-109).
#
# The item_id's family substring (sword / staff / mace) is what the client's WeaponSocket
# resolver (EntityVisuals.WEAPON_GLBS, T-109) maps to a starter-weapon GLB, so these ids MUST
# keep their family word to render — warrior/sword, mage/staff, priest/mace mirror the client.

const STARTING_WEAPONS := {
	"warrior": "itm_starter_sword",
	"mage": "itm_starter_staff",
	"priest": "itm_starter_mace",
}

# Fail-open for an unknown/blank class: a blade reads as a generic weapon (matches the
# client's sword fallback in _add_weapon_glb).
const DEFAULT_WEAPON := "itm_starter_sword"


static func weapon_for_class(char_class: String) -> String:
	return STARTING_WEAPONS.get(char_class, DEFAULT_WEAPON)


# Pure: given a character's current inventory slots + class, return the slot set to persist.
# Idempotent by design — a character who already has ANY weapon equipped (a starter OR a
# looted upgrade) is returned UNCHANGED, so this never clobbers earned gear. Otherwise the
# class starting weapon is appended as the equipped weapon slot (slot_index 0, count 1).
static func with_starting_weapon(slots: Array, char_class: String) -> Array:
	for s in slots:
		if s is Dictionary and str(s.get("slot_type", "")) == "weapon":
			return slots
	var out: Array = slots.duplicate(true)
	(
		out
		. append(
			{
				"slot_type": "weapon",
				"slot_index": 0,
				"item_id": weapon_for_class(char_class),
				"item_count": 1,
			}
		)
	)
	return out
