class_name CombatLogFormatter
# T-308: turns raw combat events into styled, colour-coded log lines. Two jobs the old inline
# formatter (combat_feedback.gd) didn't do: (1) drop the raw [tick=NNN] debug prefix by default
# (kept only behind a debug flag), and (2) colour by MEANING relative to the local player — your
# own hits read gold, damage you take reads red, crits orange, misses grey, heals green, loot blue.
# Pure static utility (no scene) so the stripping + colouring is unit-testable headlessly.

extends RefCounted

const COLOR_YOUR_HIT := Color(0.95, 0.85, 0.45)  # gold — damage YOU deal
const COLOR_DAMAGE_TAKEN := Color(0.88, 0.24, 0.20)  # red — damage YOU take
const COLOR_CRIT := Color(1.0, 0.55, 0.14)  # orange — a critical hit
const COLOR_MISS := Color(0.58, 0.58, 0.58)  # grey — miss/dodge/parry
const COLOR_HEAL := Color(0.32, 0.85, 0.36)  # green — healing
const COLOR_LOOT := Color(0.45, 0.72, 1.0)  # blue — loot / rewards
const COLOR_NEUTRAL := Color(0.80, 0.76, 0.66)  # parchment — third-party / system


# Format an ability_result into {msg, color, category}. local_id ties "your hits" vs "damage taken".
static func format_ability(
	caster_id: int,
	caster_name: String,
	target_id: int,
	target_name: String,
	damage: int,
	outcome: String,
	tick: int,
	local_id: int,
	show_tick: bool = false,
	kind: String = ""
) -> Dictionary:
	var prefix := _prefix(tick, show_tick)
	# T-586: environmental fall damage has no caster — its own line, tagged by source kind.
	if kind == "falling":
		if target_id == local_id:
			return _line(
				prefix + "You fall and take %d damage." % damage, COLOR_DAMAGE_TAKEN, "damage_taken"
			)
		return _line(
			prefix + "%s falls and takes %d damage." % [target_name, damage],
			COLOR_NEUTRAL,
			"neutral"
		)
	if outcome in ["miss", "dodge", "parry"]:
		return _line(
			prefix + "%s's attack %s on %s." % [caster_name, outcome, target_name],
			COLOR_MISS,
			"miss"
		)
	if outcome == "crit":
		return _line(
			prefix + "%s critically hits %s for %d!" % [caster_name, target_name, damage],
			COLOR_CRIT,
			"crit"
		)
	var msg := prefix + "%s hits %s for %d damage." % [caster_name, target_name, damage]
	if caster_id == local_id:
		return _line(msg, COLOR_YOUR_HIT, "your_hit")
	if target_id == local_id:
		return _line(msg, COLOR_DAMAGE_TAKEN, "damage_taken")
	return _line(msg, COLOR_NEUTRAL, "neutral")


static func format_heal(
	caster_name: String, target_name: String, amount: int, tick: int, show_tick: bool = false
) -> Dictionary:
	return _line(
		_prefix(tick, show_tick) + "%s heals %s for %d." % [caster_name, target_name, amount],
		COLOR_HEAL,
		"heal"
	)


static func format_loot(item_name: String, tick: int = -1, show_tick: bool = false) -> Dictionary:
	return _line(_prefix(tick, show_tick) + "You receive %s." % item_name, COLOR_LOOT, "loot")


static func format_system(message: String) -> Dictionary:
	return _line(message, COLOR_NEUTRAL, "system")


static func _prefix(tick: int, show_tick: bool) -> String:
	return "[tick=%d] " % tick if (show_tick and tick >= 0) else ""


static func _line(msg: String, color: Color, category: String) -> Dictionary:
	return {"msg": msg, "color": color, "category": category}
