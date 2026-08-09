extends GutTest

# T-302: pure AppearanceResolver mapping (npc_id + appearance block -> rig + tint palette + scale).
# No OS time, no globals: same id ALWAYS resolves to the same look; different roles pick different
# rigs; same-role neighbours still differ; the guard case wears the realm livery. Mirrors the
# npc_wander.gd / critter_wander.gd pure-module test shape.

const _AR = preload("res://scripts/world/appearance_resolver.gd")

# ---- determinism (same id -> same look, always) ----


func test_same_id_resolves_identically() -> void:
	var a := _AR.resolve("npc_hk_regent", {"role": "noble", "seed": "npc_hk_regent"})
	var b := _AR.resolve("npc_hk_regent", {"role": "noble", "seed": "npc_hk_regent"})
	assert_eq(_AR.signature(a), _AR.signature(b), "same id + block -> identical signature")
	assert_eq(a["mesh"], b["mesh"], "mesh is stable")
	assert_almost_eq(float(a["scale"]), float(b["scale"]), 0.00001, "scale is stable")


func test_hash_seed_is_stable_and_bounded() -> void:
	assert_eq(_AR.hash_seed("npc_farmer_geld"), _AR.hash_seed("npc_farmer_geld"), "deterministic")
	assert_true(_AR.hash_seed("x") >= 0 and _AR.hash_seed("x") <= 0xFFFFFFFF, "32-bit unsigned")
	assert_ne(_AR.hash_seed("a"), _AR.hash_seed("b"), "different inputs differ")


# ---- role -> rig selection (silhouette read) ----


func test_role_selects_the_right_rig() -> void:
	assert_true(str(_AR.resolve("g", {"role": "guard"})["mesh"]).ends_with("char_hero_warrior.glb"))
	assert_true(str(_AR.resolve("p", {"role": "priest"})["mesh"]).ends_with("char_hero_mage.glb"))
	assert_true(
		str(_AR.resolve("r", {"role": "ranger"})["mesh"]).ends_with("char_hero_trainer.glb")
	)
	assert_true(
		str(_AR.resolve("v", {"role": "peasant"})["mesh"]).ends_with("char_hero_villager.glb")
	)


func test_empty_block_falls_back_to_a_deterministic_peasant() -> void:
	var look := _AR.resolve("npc_unspecified", {})
	assert_eq(look["role"], "peasant", "no role -> peasant fallback")
	assert_true(str(look["mesh"]).ends_with("char_hero_villager.glb"))
	# still individual: another id gets a different body tint
	var other := _AR.resolve("npc_other_one", {})
	assert_ne(_AR.signature(look), _AR.signature(other), "unspecified NPCs still differ by id")


# ---- scale (children read smaller; adults jitter within +/-4%) ----


func test_child_role_scales_down() -> void:
	var look := _AR.resolve("npc_child_pip", {"role": "child", "seed": "npc_child_pip"})
	assert_lt(float(look["scale"]), 0.80, "child is clearly smaller than an adult")
	assert_gt(float(look["scale"]), 0.70, "but within jitter of the 0.75 base")


func test_adult_scale_jitters_within_bounds() -> void:
	var s := float(_AR.resolve("npc_farmer_geld", {"role": "peasant"})["scale"])
	assert_almost_eq(s, 1.0, _AR.SCALE_JITTER + 0.001, "adult height within +/- jitter of 1.0")


func test_explicit_body_scale_is_honoured() -> void:
	var look := _AR.resolve("x", {"role": "peasant", "body_scale": 0.5})
	assert_almost_eq(float(look["scale"]), 0.5, _AR.SCALE_JITTER + 0.02, "explicit body_scale wins")


# ---- material name -> semantic slot ----


func test_material_slot_mapping() -> void:
	assert_eq(_AR.material_slot("MI_Hair_1"), "hair")
	assert_eq(_AR.material_slot("MI_Hair_1.002"), "hair")
	assert_eq(_AR.material_slot("MI_Eyes"), "eyes")
	assert_eq(_AR.material_slot("MI_Regular_Male"), "skin")
	assert_eq(_AR.material_slot("MI_Superhero_Male"), "skin")
	assert_eq(_AR.material_slot("MI_Robe"), "robe")
	assert_eq(_AR.material_slot("MI_Peasant"), "body")
	assert_eq(_AR.material_slot("MI_Ranger"), "body", "the armour body is a body slot")
	assert_eq(_AR.material_slot("MI_Ranger.001"), "trim", "belts/straps are trim")


# ---- hair colour: a real texture swap reaches light hair a multiply can't ----


func test_hair_texture_swap_is_reachable_and_varied() -> void:
	# Across a spread of ids at least one draws a recoloured (non-empty) hair atlas, and more than
	# one distinct swap appears — the whole point (light/silver/ginger heads, not all dark).
	var swaps := {}
	for i in range(40):
		var tex := str(_AR.resolve("npc_villager_%d" % i, {"role": "peasant"}).get("hair_tex", ""))
		swaps[tex] = true
	assert_true(swaps.size() >= 3, "dark + at least two recoloured hair variants appear")
	assert_true(swaps.has(""), "most keep the embedded dark hair")


func test_children_never_go_grey() -> void:
	for i in range(40):
		var tex := str(_AR.resolve("npc_kid_%d" % i, {"role": "child"}).get("hair_tex", ""))
		assert_false(tex.ends_with("grey.png"), "a child never gets elderly silver hair")


# ---- guard livery = realm palette (madder trim + steel body) ----


func test_guard_wears_house_livery() -> void:
	var look := _AR.resolve("npc_hk_watch_market", {"role": "guard", "seed": "npc_hk_watch_market"})
	var tints: Dictionary = look["tints"]
	assert_true(tints.has("body"), "guard has a steel body tint")
	assert_true(tints.has("trim"), "guard has a madder livery trim tint")
	var trim: Color = tints["trim"]
	assert_gt(trim.r, trim.g, "madder livery: red dominant")
	assert_gt(trim.r, trim.b, "madder livery: red dominant")


func test_clergy_gets_a_robe_tint() -> void:
	var tints: Dictionary = _AR.resolve("npc_cleric", {"role": "priest"})["tints"]
	assert_true(tints.has("robe"), "clergy tint the robe slot")


# ---- individuals: same role, different look ----


func test_two_same_role_peasants_differ() -> void:
	var a := _AR.resolve("npc_hk_cit_ward1", {"role": "peasant", "seed": "npc_hk_cit_ward1"})
	var b := _AR.resolve("npc_hk_cit_ward2", {"role": "peasant", "seed": "npc_hk_cit_ward2"})
	assert_ne(_AR.signature(a), _AR.signature(b), "same-role neighbours are not identical")


# ---- distribution: the whole roster reads as a crowd, not two clones ----


func test_roster_has_many_distinct_appearances() -> void:
	# A representative slice across roles/ids (mirrors npcs.json assignments).
	var roster := [
		["npc_farmer_geld", "peasant"],
		["npc_hk_cit_ward2", "peasant"],
		["npc_hk_cook", "peasant"],
		["npc_hk_watch_market", "guard"],
		["npc_hk_watch_keep_west", "guard"],
		["npc_hk_guard_west", "guard"],
		["npc_cleric", "priest"],
		["npc_hk_archprelate", "priest"],
		["npc_hk_regent", "noble"],
		["npc_hk_banker", "merchant"],
		["npc_hk_tailor", "merchant"],
		["npc_arcanist", "mage"],
		["npc_ranger", "ranger"],
		["npc_blacksmith", "smith"],
		["npc_child_pip", "child"],
		["npc_child_nell", "child"],
		["npc_child_tam", "child"],
	]
	var sigs := {}
	for entry: Array in roster:
		var look := _AR.resolve(str(entry[0]), {"role": str(entry[1]), "seed": str(entry[0])})
		sigs[_AR.signature(look)] = true
	# Baseline was exactly 2 (villager x45, trainer x7). Ticket wants >= 5 distinct; assert well past.
	assert_gt(sigs.size(), 8, "roster yields many distinct appearance signatures, not 2 clones")


# ---- T-127: deterministic per-USERNAME player appearance ----


func test_player_same_username_resolves_identically() -> void:
	# Determinism is the whole contract: every viewer (self + everyone else) must derive the same
	# look from the same username, with no other input.
	var a := _AR.resolve_player("Aldric")
	var b := _AR.resolve_player("Aldric")
	assert_eq(_AR.signature(a), _AR.signature(b), "same username -> identical signature")
	assert_almost_eq(float(a["scale"]), float(b["scale"]), 0.00001, "build/height is stable")
	assert_eq(str(a["hair_tex"]), str(b["hair_tex"]), "hair swap is stable")


func test_player_is_a_pure_function_of_username_only() -> void:
	# The look depends ONLY on the username string — no globals, no OS time, no viewer identity —
	# which is what makes it consistent across clients AND unspoofable (there is no other input a
	# client could feed to change its tint).
	var seed_a := _AR.hash_seed("player:Mira")
	var seed_b: int = _AR.resolve_player("Mira")["seed"]
	assert_eq(seed_a, seed_b, "seed is exactly hash_seed('player:'+username)")


func test_player_carries_no_clothing_tint() -> void:
	# T-224 re-scope: the base body is an armorless UBC rig; class silhouette comes from EQUIPMENT,
	# not a dyed outfit. So a player look tints ONLY the identity-bearing body traits (skin + hair),
	# never body/robe/trim — those slots belong to gear.
	var tints: Dictionary = _AR.resolve_player("Corwin")["tints"]
	assert_true(tints.has("skin"), "player has a skin tint")
	assert_true(tints.has("hair"), "player has a hair tint")
	assert_false(tints.has("body"), "no clothing body tint — equipment owns that")
	assert_false(tints.has("robe"), "no robe tint")
	assert_false(tints.has("trim"), "no trim tint")


func test_player_build_stays_in_a_believable_range() -> void:
	for name in ["a", "Zoltan", "player_00", "xX_slayer_Xx", "Ê"]:
		var s := float(_AR.resolve_player(name)["scale"])
		assert_almost_eq(s, 1.0, _AR.PLAYER_BUILD_JITTER + 0.001, "build within +/- jitter of 1.0")


func test_different_usernames_spread_across_the_look_space() -> void:
	# A sample of distinct usernames must land on many distinct appearances (not two clones), and
	# collisions must be rare — the ticket's "distinct-looking players pre-customization" bar.
	var sigs := {}
	var n := 200
	for i in range(n):
		sigs[_AR.signature(_AR.resolve_player("user_%d" % i))] = true
	# skin(4) x hair(6 incl. swaps) x build-bucket is a large space; a 200-name sample should spread
	# very wide. Assert a strong lower bound so a regression that collapses the space fails loudly.
	assert_gt(sigs.size(), 40, "200 usernames spread across many distinct looks, not a handful")


func test_no_appearance_collisions_within_a_small_lineup() -> void:
	# A realistic starting-zone lineup of hand-picked names: every one should look distinct.
	var lineup := ["Aldric", "Mira", "Corwin", "Bramble", "Sable", "Thorne", "Wren", "Gale"]
	var sigs := {}
	for name in lineup:
		sigs[_AR.signature(_AR.resolve_player(name))] = true
	assert_eq(sigs.size(), lineup.size(), "no two players in the lineup share an appearance")
