# T-061: Stat -> combat conversion — the single tunable home for how character attributes
# (str/int/dex/spirit/stamina) become resource pools and heal power.
#
# Pure module: no OS time, no global state, no RNG; inputs never mutated (RefCounted, all static).
#
# Division of responsibility:
#   - Resource POOLS (max HP/mana, swing pool, mana regen) derive from stats HERE.
#   - Per-ability DAMAGE/HEAL *scaling* is DATA (an ability's `attacker_stat_coeffs` in JSON),
#     applied by damage_formula.gd — never hardcoded here. `heal_power()` is the stat term that
#     T-063's heal effect multiplies by its ability coefficient.
#
# Scales to N classes with NO change here: classes differ in stat VALUES (the leveling.gd table),
# never in these formulas. Retune base feel by editing the constants below — this is the one place.

extends RefCounted

# --- HP: driven by the Stamina STAT (NOT the dex-derived swing pool below). ---
# L1 base stamina (10) -> 50 + 10*5 = 100 HP, matching the old hardcoded spawn HP for continuity.
const HP_BASE := 50
const HP_PER_STAMINA := 5

# --- Mana: max from Intellect (WoW-ish base + Int*k). T-063 bumped this from the M1 `= int` so that
#     caster kits are castable at low levels (L1 int ~10 -> ~150 mana). Tunable. ---
const MANA_BASE := 50
const MANA_PER_INT := 10

# --- Swing/endurance POOL: the UO swing-economy resource (CombatResources.stamina) that gates
#     auto-attack speed and pays ability stamina_cost. Named apart from the Stamina STAT (which
#     drives HP) per the naming-collision note. M1 players spawned with a flat 100 pool; preserve
#     that baseline (L1 dex 10 -> 100) so the swing/ability economy is unchanged here. T-062's
#     resource framework replaces this pool (rage/mana) and owns its real model. ---
const SWING_POOL_BASE := 90
const SWING_POOL_PER_DEX := 1

# --- Mana regen: Spirit-driven. Exposed here as the formula's home; the full 5-second-rule regen
#     model is T-062; vitals regen wiring is T-071 (resource_ticker). ---
const MANA_REGEN_BASE := 1
const MANA_REGEN_PER_SPIRIT := 0.1

# --- Heal power: the stat term for T-063's heal effect (Intellect primary, Spirit secondary). ---
const HEAL_POWER_PER_INT := 0.5
const HEAL_POWER_PER_SPIRIT := 0.3


static func max_hp(stamina_val: int) -> int:
	return HP_BASE + maxi(0, stamina_val) * HP_PER_STAMINA


static func max_mana(int_val: int) -> int:
	return MANA_BASE + maxi(0, int_val) * MANA_PER_INT


static func swing_pool(dex_val: int) -> int:
	return SWING_POOL_BASE + maxi(0, dex_val) * SWING_POOL_PER_DEX


# Spirit -> mana regen per regen-interval. Floored to int (whole points). Consumed by T-062.
static func mana_regen_per_interval(spirit_val: int) -> int:
	return MANA_REGEN_BASE + int(floor(float(maxi(0, spirit_val)) * MANA_REGEN_PER_SPIRIT))


# Stat contribution to healing — T-063's heal effect multiplies this by its per-ability coefficient.
static func heal_power(int_val: int, spirit_val: int) -> float:
	return (
		float(maxi(0, int_val)) * HEAL_POWER_PER_INT
		+ float(maxi(0, spirit_val)) * HEAL_POWER_PER_SPIRIT
	)


# T-295: legible derived-stat summary for the character sheet — the SAME formulas the combat pools
# use, so the sheet never drifts from what actually drives combat. `stats` is the class+level vector
# (str/int/dex/spirit/stamina); `spell_power` reuses heal_power (Int primary + Spirit secondary,
# the caster damage/heal term). Pure; unknown/missing stats read 0.
static func derived_summary(stats: Dictionary) -> Dictionary:
	var int_val: int = int(stats.get("int", 0))
	var spirit_val: int = int(stats.get("spirit", 0))
	return {
		"max_hp": max_hp(int(stats.get("stamina", 0))),
		"max_mana": max_mana(int_val),
		"endurance": swing_pool(int(stats.get("dex", 0))),
		"spell_power": int(round(heal_power(int_val, spirit_val))),
		"mana_regen": mana_regen_per_interval(spirit_val),
	}


# T-295: the peer-only `player_stats` message — level/XP (T-060) plus the four primaries (+ Spirit)
# and their derived pools (T-295). One builder so main (spawn) and world_rpc (level-up) send the
# identical shape. `combat` is master's get_character_combat payload.
static func player_stats_msg(combat: Dictionary) -> Dictionary:
	var stats: Dictionary = combat.get("stats", {})
	return {
		"type": "player_stats",
		"level": int(combat.get("level", 1)),
		"xp_into_level": int(combat.get("xp_into_level", 0)),
		"xp_for_next_level": int(combat.get("xp_for_next_level", 0)),
		"rested_remaining": int(combat.get("rested_remaining", 0)),  # T-360 rested XP band
		"talent_points": int(combat.get("talent_points", 0)),  # T-712: banner names the point earned
		# T-716: creation naming. `name` is the live character name; `name_chosen` false means the
		# in-world name step is still owed (bootstrap characters only). This message rides the
		# handshake AND every _repush_combat_stats — including the one the class lock triggers, which
		# is exactly when the client's creation flow needs to know whether a name step follows.
		"name": str(combat.get("name", "")),
		"name_chosen": bool(combat.get("name_chosen", true)),
		"primaries":
		{
			"str": int(stats.get("str", 0)),
			"stamina": int(stats.get("stamina", 0)),
			"dex": int(stats.get("dex", 0)),
			"int": int(stats.get("int", 0)),
			"spirit": int(stats.get("spirit", 0)),
		},
		"derived": derived_summary(stats),
	}
