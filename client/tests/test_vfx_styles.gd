extends GutTest

# T-343 (owner ruling 2026-07-16): the ability-VFX STYLE candidate registry. This is a pure-data
# selection bank for the core hit types — nothing here fires gameplay or touches the shipped
# VfxManager path, so the test is purely the registry wiring (types present, each hit type carries
# 3-4 distinct candidates, resolve() types the colours/vectors, env selection clamps safely).

const VfxStyles = preload("res://scripts/world/vfx_styles.gd")


func test_all_core_hit_types_present() -> void:
	var types := VfxStyles.hit_types()
	for t in ["impact", "cast", "heal"]:
		assert_true(t in types, "core hit type present: %s" % t)


func test_each_hit_type_has_three_or_four_candidates() -> void:
	for t in VfxStyles.hit_types():
		var n := VfxStyles.count(t)
		assert_true(n >= 3 and n <= 4, "%s has 3-4 style candidates (got %d)" % [t, n])


func test_style_ids_are_unique_per_type() -> void:
	for t in VfxStyles.hit_types():
		var seen := {}
		for i in range(VfxStyles.count(t)):
			var sid := VfxStyles.style_id(t, i)
			assert_false(seen.has(sid), "%s style id unique: %s" % [t, sid])
			seen[sid] = true


func test_resolve_types_emitters_and_extras() -> void:
	var s := VfxStyles.resolve("impact", 0)
	assert_true(s.has("emitters") and (s["emitters"] as Array).size() >= 1, "has emitters")
	var e: Dictionary = s["emitters"][0]
	assert_true(e["color"] is Color, "emitter color typed to Color")
	assert_true(e["dir"] is Vector3, "emitter dir typed to Vector3")
	assert_true(e["grav"] is Vector3, "emitter gravity typed to Vector3")
	assert_true(e["ramp"][0] is Color and e["ramp"][1] is Color, "ramp endpoints typed to Color")


func test_projectile_styles_carry_a_core_and_speed() -> void:
	assert_true(VfxStyles.count("projectile") >= 1, "projectile candidates exist")
	for i in range(VfxStyles.count("projectile")):
		var s := VfxStyles.resolve("projectile", i)
		assert_true(s.has("core"), "projectile #%d has a core" % i)
		assert_true(s["core"]["color"] is Color, "projectile core color typed")
		assert_true(float(s.get("speed", 0.0)) > 0.0, "projectile #%d has a positive speed" % i)


func test_ring_and_column_extras_type_their_color() -> void:
	# heal 'bloom' carries a ring, heal 'column' carries a column — both extras' colour must type.
	var bloom := VfxStyles.resolve("heal", 2)
	assert_true(bloom.has("ring") and bloom["ring"]["color"] is Color, "heal ring color typed")
	var col := VfxStyles.resolve("heal", 1)
	assert_true(col.has("column") and col["column"]["color"] is Color, "heal column color typed")


# T-343 phase 3: the canonical live house selection the owner chose per hit type. VfxManager wires
# THESE ids as the live default (see test_vfx_manager); a data edit here retargets the kit.
func test_default_selection_is_the_owner_choice() -> void:
	assert_eq(VfxStyles.default_id("impact"), "grounded", "impact house = Grounded Sparks & Dust")
	assert_eq(VfxStyles.default_id("cast"), "handglow", "cast house = Subtle Hand-Glow Windup")
	assert_eq(VfxStyles.default_id("heal"), "motes", "heal house = Warm Rising Motes")
	assert_eq(VfxStyles.default_id("projectile"), "comet", "projectile house = Comet Streak")


func test_resolve_default_returns_the_chosen_style_typed() -> void:
	for t in ["impact", "cast", "heal", "projectile"]:
		var idx := VfxStyles.default_index(t)
		assert_eq(
			VfxStyles.style_id(t, idx), VfxStyles.default_id(t), "%s default index resolves" % t
		)
		var s := VfxStyles.resolve_default(t)
		assert_eq(
			str(s["id"]), VfxStyles.default_id(t), "%s resolve_default is the chosen style" % t
		)
		assert_true(s["emitters"][0]["color"] is Color, "%s default emitter color typed" % t)


func test_index_of_handles_unknown_ids() -> void:
	assert_eq(VfxStyles.index_of("impact", "grounded"), 0, "known id -> its index")
	assert_eq(VfxStyles.index_of("impact", "no_such_style"), -1, "unknown id -> -1")
	assert_eq(VfxStyles.default_index("impact"), 0, "grounded is impact index 0")


func test_active_selection_clamps_from_env() -> void:
	OS.set_environment("AVALON_VFX_STYLE_TYPE", "cast")
	OS.set_environment("AVALON_VFX_STYLE_INDEX", "1")
	assert_eq(VfxStyles.active_type(), "cast", "valid type read")
	assert_eq(VfxStyles.active_index(), 1, "valid index read")
	OS.set_environment("AVALON_VFX_STYLE_TYPE", "junk")
	assert_eq(VfxStyles.active_type(), "impact", "bad type clamps to first")
	OS.set_environment("AVALON_VFX_STYLE_TYPE", "heal")
	OS.set_environment("AVALON_VFX_STYLE_INDEX", "9999")
	assert_eq(VfxStyles.active_index(), 0, "out-of-range index clamps to 0")
	OS.set_environment("AVALON_VFX_STYLE_TYPE", "")
	OS.set_environment("AVALON_VFX_STYLE_INDEX", "")
