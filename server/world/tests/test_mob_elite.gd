# T-294: elite / rare open-world monster tier — headless unit tests.
# Covers: loader multiplies HP/damage; enrage fires on the swing path at low HP; the elite content
# JSON loads with a UNIQUE kill-credit alias decoupled from the render silhouette; the spawn table
# includes the starter elites; loot is authored at the top difficulty tier.
# No OS time, no engine loop, no network — pure loader + AI-tick simulation.

extends GutTest

const _MAI = preload("res://scripts/combat/mob_ai.gd")
const _MD = preload("res://scripts/combat/mob_data.gd")
const _ML = preload("res://scripts/combat/mob_loader.gd")
const _CS = preload("res://scripts/combat/combat_state.gd")
const _TT = preload("res://scripts/combat/threat_table.gd")

const _MOBS_DIR := "res://data/mobs"

const _ERA1_COMBAT_MOB_FILES := [
	"wolf.json",
	"kobold_miner.json",
	"bloodthorn_lasher.json",
	"greymaw_alpha.json",
	"grexrok_deepwarden.json",
	"elderthorn_guardian.json",
	"crypt_ghoul.json",
	"restless_shade.json",
	"skeletal_warrior.json",
	"crypt_aldric.json",
	"crypt_vharis.json",
	"crypt_maldrath.json",
	"vault_sentinel.json",
	"vault_dirgemother.json",
	"vault_hollow_king.json",
]


func _make_rng() -> RandomNumberGenerator:
	var rng := RandomNumberGenerator.new()
	rng.seed = 42
	return rng


# An elite mob built in code with a fixed, deterministic swing (variance 1.0, no coeffs, no
# miss/crit) so a damage assertion is exact. base_damage 10, max_hp 100.
func _make_elite_mob(hp: int) -> Object:
	var mob = _MD.new()
	mob.entity_id = 2001
	mob.mob_type_id = 20
	mob.mob_id = "mob_test_elite"
	mob.position = Vector3(0.0, 0.0, 0.0)
	mob.spawn_position = Vector3(0.0, 0.0, 0.0)
	mob.aggro_radius = 5.0
	mob.leash_radius = 30.0
	mob.melee_range = 2.0
	mob.ai_state = _MAI.MobAIState.MELEE
	mob.current_target_id = 1
	mob.combat_state = CombatState.new()
	mob.combat_state.next_swing_tick = 0
	var cr := CombatResources.new()
	cr.hp = hp
	cr.max_hp = 100
	cr.stamina = 100
	cr.max_stamina = 100
	mob.resources = cr
	var stats := CharacterStats.new()
	stats.weapon_speed = 1.0
	stats.str_val = 10
	stats.dex_val = 10
	mob.stats = stats
	var ab := AbilityData.new()
	ab.id = 0
	ab.name = "Elite Melee"
	ab.range_units = 2.0
	ab.base_damage = 10
	ab.variance_min = 1.0
	ab.variance_max = 1.0
	ab.crit_multiplier = 2.0
	mob.melee_ability = ab
	mob.elite = true
	mob.enrage_threshold = 0.3
	mob.enrage_mult = 1.5
	return mob


func _make_player(pos: Vector3) -> Dictionary:
	var cr := CombatResources.new()
	cr.hp = 200
	cr.max_hp = 200
	return {
		"position": pos,
		"combat_state": CombatState.new(),
		"resources": cr,
		"stats": CharacterStats.new(),
	}


func _swing_damage(mob) -> Dictionary:
	# One MELEE tick; return the first damage event ({amount, enraged}) or {} if none.
	var players := {1: _make_player(Vector3(0.0, 1.0, 0.0))}
	var result = _MAI.ai_tick(mob, players, _TT.new(), 0, _make_rng())
	for ev in result.events:
		if ev.get("type", "") == "damage":
			return ev
	return {}


# ---- Loader: HP/damage multipliers baked in ----


func test_loader_elite_multiplies_hp_five_x():
	# Greymaw reuses the Gray Wolf stat block (stamina 6 -> 80 base HP). Elite 5x -> 400.
	var elite = _ML.load_from_file(_MOBS_DIR + "/greymaw_alpha.json", 9001)
	assert_not_null(elite, "greymaw_alpha.json must load")
	assert_eq(elite.resources.max_hp, 400, "elite HP is 5x the 80 HP base wolf block")
	assert_eq(elite.resources.hp, 400, "elite spawns at full (elevated) HP")


func test_loader_elite_multiplies_base_damage():
	# Wolf base_damage 5 * 2.5 = 13 (rounded) — tuned up from the 1.8 suggestion so the solo-loses
	# gate is robust against the soft base damage + high player HP (see ticket balance math).
	var elite = _ML.load_from_file(_MOBS_DIR + "/greymaw_alpha.json", 9002)
	assert_eq(elite.melee_ability.base_damage, 13, "elite melee base damage is 2.5x (5 -> 13)")


func test_loader_normal_mob_untouched_by_elite_path():
	# The plain wolf (no elite flag) keeps its 80 HP / 5 base damage — additive, no regression.
	var wolf = _ML.load_from_file(_MOBS_DIR + "/wolf.json", 9003)
	assert_false(wolf.elite, "normal wolf is not elite")
	assert_eq(wolf.resources.max_hp, 80, "normal wolf HP unchanged")
	assert_eq(wolf.melee_ability.base_damage, 5, "normal wolf damage unchanged")


func test_era1_combat_mobs_load_with_xp_and_gray_cutoff_level():
	# T-432/T-620: JSON `level` is the loader input that becomes MobData.mob_level for mob_xp.gd's
	# master-side gray cutoff; xp is now the WoW-shape formula (mobLevel*5+45, doubled for elites),
	# not an authored flat value. The dummy is the only Era-1 mob intentionally left at zero XP.
	for file_name in _ERA1_COMBAT_MOB_FILES:
		var mob = _ML.load_from_file(_MOBS_DIR.path_join(file_name), 9400)
		assert_not_null(mob, "%s loads through mob_loader" % file_name)
		var expected: int = mob.mob_level * 5 + 45
		if mob.elite:
			expected *= 2
		assert_eq(mob.xp, expected, "%s pays the WoW-shape formula" % file_name)
		assert_gte(mob.mob_level, 1, "%s has a gray-cutoff level" % file_name)
		assert_lt(mob.mob_level, 20, "%s remains in the Era-1 leveling band" % file_name)


# T-620: the formula table itself — mobLevel*5+45, independent of any authored JSON "xp" value
# (wolf.json still authors "xp": 8 as dead legacy data; the loader now ignores it).
func test_kill_xp_formula_table():
	var wolf = _ML.load_from_file(_MOBS_DIR + "/wolf.json", 9410)  # level 3, not elite
	assert_eq(wolf.xp, 3 * 5 + 45, "L3 wolf: 3*5+45 = 60")

	var greymaw = _ML.load_from_file(_MOBS_DIR + "/greymaw_alpha.json", 9411)  # elite
	assert_true(greymaw.elite, "greymaw is elite")
	assert_eq(greymaw.xp, (greymaw.mob_level * 5 + 45) * 2, "elite kill XP is doubled")


func test_training_dummy_loads_as_zero_xp():
	var dummy = _ML.load_from_file(_MOBS_DIR.path_join("dummy.json"), 9401)

	assert_not_null(dummy)
	assert_eq(dummy.xp, 0, "the training dummy stays non-progression content")
	assert_eq(dummy.mob_level, 1, "missing level still maps to the harmless default")
	assert_eq(
		dummy.xp,
		0,
		"is_dummy hard-pins zero even though the formula (1*5+45=50) would otherwise pay out"
	)


# T-620: an explicit authored "xp": 0 (training_effigy.json — non-lethal, retaliate-only tutorial
# target) also hard-pins zero, distinct from the is_dummy path above.
func test_explicit_zero_authored_xp_overrides_the_formula():
	var effigy = _ML.load_from_file(_MOBS_DIR.path_join("training_effigy.json"), 9402)
	assert_not_null(effigy)
	assert_false(effigy.is_dummy, "the effigy is retaliate_only, not a static dummy")
	assert_eq(effigy.xp, 0, 'explicit "xp": 0 stays zero despite a non-zero formula level')


# ---- Kill-credit decoupling: alias distinct from render silhouette ----


func test_elite_alias_decoupled_from_render_kind():
	# T-293 bounties target mob_id (the alias). It must be UNIQUE per elite and must NOT be the
	# base model kind — else killing a normal wolf would credit the Greymaw bounty.
	var elite = _ML.load_from_file(_MOBS_DIR + "/greymaw_alpha.json", 9004)
	assert_eq(elite.mob_id, "mob_greymaw", "unique kill-credit alias")
	assert_eq(elite.render_kind, "mob_wolf", "reuses the wolf silhouette")
	assert_ne(elite.mob_id, elite.render_kind, "alias must differ from the shared render model")


func test_elite_alias_survives_ai_tick_copy():
	# Kill credit fires on mob.mob_id in main._check_death_mob; the alias must survive the tick copy
	# (the T-047 trap) or the bounty never credits.
	var mob = _make_elite_mob(100)
	mob.mob_id = "mob_greymaw"
	mob.render_kind = "mob_wolf"
	var result = _MAI.ai_tick(mob, {}, _TT.new(), 0, _make_rng())
	assert_eq(result.new_mob.mob_id, "mob_greymaw", "alias survives copy (kill credit)")
	assert_eq(result.new_mob.render_kind, "mob_wolf", "render_kind survives copy")
	assert_true(result.new_mob.elite, "elite flag survives copy")


# ---- Enrage: the extra ability on the existing swing path ----


func test_enrage_inactive_above_threshold():
	# Full HP (100/100 > 30%): swing lands for the plain 10, not enraged.
	var ev := _swing_damage(_make_elite_mob(100))
	assert_false(ev.is_empty(), "a swing must fire in MELEE")
	assert_eq(int(ev.get("amount", 0)), 10, "no enrage above threshold")
	assert_false(bool(ev.get("enraged", false)), "enraged flag off above threshold")


func test_enrage_active_below_threshold():
	# 20/100 HP (<= 30%): the same swing hits for 1.5x (10 -> 15), enraged flag set.
	var ev := _swing_damage(_make_elite_mob(20))
	assert_false(ev.is_empty(), "a swing must fire in MELEE")
	assert_eq(int(ev.get("amount", 0)), 15, "enrage applies 1.5x at low HP (10 -> 15)")
	assert_true(bool(ev.get("enraged", false)), "enraged flag on below threshold")


func test_enrage_does_not_fire_for_non_elite():
	# Same low HP, but elite=false: no enrage buff (the buff is gated on the elite flag).
	var mob = _make_elite_mob(20)
	mob.elite = false
	var ev := _swing_damage(mob)
	assert_eq(int(ev.get("amount", 0)), 10, "non-elite never enrages")
	assert_false(bool(ev.get("enraged", false)), "non-elite enraged flag off")


# ---- Content: spawn table + loot ----


func test_spawn_table_includes_starter_elites():
	var mobs := _ML.load_spawn_table(_MOBS_DIR)
	assert_gt(mobs.size(), 0, "spawn table must load")
	var aliases: Dictionary = {}
	var elite_count: int = 0
	for id in mobs:
		aliases[mobs[id].mob_id] = true
		if mobs[id].elite:
			elite_count += 1
	# T-350: the Syndicate Torpedo (tommy-gun elite) joins the three starter world elites.
	# T-411: the Ashmoor rare champion is the 5th elite-tier open-world spawn.
	# T-627: + 2 roaming named Heartwold elites (Direfang the Matriarch L13 darkwood, Grymm the
	# Moorlord L18 moor) — the group-option quarry for the L10-20 solo band's Elite hunts -> 7.
	assert_eq(elite_count, 7, "5 prior elite-tier spawns + T-627 Direfang + Grymm")
	assert_true(aliases.has("mob_rare_ashmoor_kingpin"), "the T-411 Ashmoor rare spawns")
	assert_true(aliases.has("mob_greymaw"), "Greymaw spawns")
	assert_true(aliases.has("mob_grexrok"), "Grexrok spawns")
	assert_true(aliases.has("mob_elderthorn"), "Elderthorn spawns")


func test_elite_loot_is_top_tier_and_spans_rarities():
	# Elites roll on difficulty 5 (the rare/epic-weighted schedule) and author loot in more than one
	# rarity tier so the single-tier weighted roll reliably lands better-than-common quality.
	for f in ["greymaw_alpha.json", "grexrok_deepwarden.json", "elderthorn_guardian.json"]:
		var elite = _ML.load_from_file(_MOBS_DIR + "/" + f, 9100)
		assert_eq(elite.difficulty, 5, "%s is difficulty 5 (top loot tier)" % f)
		assert_gte(elite.loot.size(), 2, "%s authors multiple loot entries" % f)
