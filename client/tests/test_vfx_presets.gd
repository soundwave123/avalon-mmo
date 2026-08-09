extends GutTest

# T-343: the frost-bolt VFX preset library + the preset-driven VfxManager build. Preset 0 MUST
# reproduce the shipped baseline exactly (it is the "before" in the owner vote), env selection must
# clamp safely, and apply_preset must genuinely re-skin the pools (e.g. a coreless vapor preset).

const VfxPresets = preload("res://scripts/world/vfx_presets.gd")
const VfxManager = preload("res://scripts/world/vfx_manager.gd")


func test_gallery_has_at_least_twelve_variants() -> void:
	assert_true(
		VfxPresets.count() >= 12, "gallery spans >=12 variants (got %d)" % VfxPresets.count()
	)


func test_preset_zero_reproduces_baseline_exactly() -> void:
	var p := VfxPresets.resolve(0)
	# these are the shipped T-110 values — preset 0 is the honest baseline in the vote
	assert_eq(p["core"]["kind"], "sphere", "baseline core is the sphere orb")
	assert_almost_eq(float(p["core"]["radius"]), 0.13, 0.0001, "baseline orb radius")
	assert_eq(
		Color(p["impact"]["color"]), Color(1.0, 0.72, 0.32), "baseline impact stays warm orange"
	)
	assert_almost_eq(float(p["flight"]["speed"]), 20.0, 0.0001, "baseline flight speed")
	assert_almost_eq(float(p["cast"]["size"]), 0.16, 0.0001, "baseline cast quad size")


func test_active_index_env_clamps() -> void:
	OS.set_environment("AVALON_VFX_PRESET", "3")
	assert_eq(VfxPresets.active_index(), 3, "valid index read")
	OS.set_environment("AVALON_VFX_PRESET", "9999")
	assert_eq(VfxPresets.active_index(), 0, "out-of-range clamps to baseline")
	OS.set_environment("AVALON_VFX_PRESET", "junk")
	assert_eq(VfxPresets.active_index(), 0, "non-int clamps to baseline")
	OS.set_environment("AVALON_VFX_PRESET", "")
	assert_eq(VfxPresets.active_index(), 0, "unset -> baseline")


func test_resolve_is_complete_for_every_preset() -> void:
	for i in range(VfxPresets.count()):
		var p := VfxPresets.resolve(i)
		for section in ["cast", "core", "trail", "flight", "impact"]:
			assert_true(p.has(section), "preset %d has %s" % [i, section])
		assert_true(p["cast"].has("ramp"), "preset %d cast ramp present" % i)
		assert_true(p.has("name") and str(p["name"]) != "", "preset %d named" % i)


func test_apply_preset_reskins_the_pools() -> void:
	var v = VfxManager.new()
	add_child_autofree(v)
	assert_true(v._proj[0]["orb"].mesh != null, "baseline core has a mesh")
	# preset 2 (Wispy Vapor) has core kind "none" -> no core mesh, only the trail
	v.apply_preset(2)
	assert_eq(v._proj.size(), 4, "projectile pool rebuilt")
	assert_null(v._proj[0]["orb"].mesh, "vapor preset drops the solid core mesh")
	assert_eq(v._cast.size(), 5, "cast pool rebuilt")
	assert_eq(v._impact.size(), 6, "impact pool rebuilt")


func test_spinning_preset_enables_process() -> void:
	var v = VfxManager.new()
	add_child_autofree(v)
	v.apply_preset(1)  # Crystalline Shard spins its prism core
	assert_true(v._spinning, "a spinning core enables the process tick")
	v.apply_preset(0)  # baseline core does not spin
	assert_false(v._spinning, "baseline core leaves _process idle (T-210)")


# --- T-343 round 2: the Sub-Zero lance family (presets 13+, mode "lance") ----------------------


func test_round2_has_lance_presets_and_classics_still_resolve() -> void:
	assert_true(VfxPresets.count() >= 19, "r2 adds >=6 lance presets (got %d)" % VfxPresets.count())
	var lances := 0
	for i in range(VfxPresets.count()):
		var p := VfxPresets.resolve(i)
		if str(p["mode"]) == "lance":
			lances += 1
			for section in ["antic", "lance", "burst"]:
				assert_true(p.has(section), "lance preset %d has %s" % [i, section])
			assert_true(p["lance"]["core_color"] is Color, "lance %d core_color typed" % i)
			assert_true(p["burst"]["freeze_color"] is Color, "lance %d freeze_color typed" % i)
			assert_true(float(p["flight"]["speed"]) >= 38.0, "lance %d is FAST (2-3x)" % i)
	assert_true(lances >= 6, "at least 6 lance variants (got %d)" % lances)
	assert_eq(str(VfxPresets.resolve(0)["mode"]), "burst", "preset 0 stays the classic ball path")


func test_lance_mode_builds_frost_lance_and_delegates() -> void:
	var v = VfxManager.new()
	add_child_autofree(v)
	v.apply_preset(13)  # Ice Lance
	assert_not_null(v._lance, "lance preset builds the FrostLanceVfx module")
	assert_eq(v._proj.size(), 0, "ball projectile pool not built in lance mode")
	assert_eq(v._lance._lances.size(), 4, "lance pool built")
	assert_eq(v._lance._impacts.size(), 4, "impact kit pool built")
	assert_eq(v._lance._antic.size(), 2, "anticipation kit pool built")
	var lance0: Dictionary = v._lance._lances[0]
	assert_true(lance0["mesh"].mesh.get_surface_count() >= 2, "real mesh core: spear + sheath")
	v.spawn_projectile(Vector3.ZERO, Vector3(10, 0, 0))
	assert_true((lance0["root"] as Node3D).visible, "spawn_projectile launches the lance")
	v.apply_preset(0)
	assert_null(v._lance, "returning to a classic preset frees the lance module")
	assert_eq(v._proj.size(), 4, "ball pool restored")


# T-343 phase 2: the SHIPPED default is ability-aware. With NO env override (default preset 0 =
# generic burst), the frost bolt (id 204) still gets the dedicated FROST_PRESET lance while every
# other ability keeps the generic burst — the winner ships without an AVALON_VFX_PRESET env.
func test_frost_bolt_ability_routes_to_lance_by_default() -> void:
	var v = VfxManager.new()
	add_child_autofree(v)  # _ready resolves the default (preset 0) + builds the frost lance
	assert_null(v._lance, "no GLOBAL lance mode on the default (preset 0 is the generic burst)")
	assert_not_null(v._frost_lance, "a dedicated frost lance is built for the frost bolt")
	assert_eq(v._proj.size(), 4, "the generic ball pool still exists for other abilities")
	# frost bolt (204) -> the dedicated lance; a non-frost ability -> the generic path (null lance)
	assert_eq(v._lance_for(VfxManager.FROST_ABILITY_ID), v._frost_lance, "frost id -> frost lance")
	assert_null(v._lance_for(999), "a non-frost ability keeps the generic burst")
	assert_eq(VfxManager.FROST_PRESET, 13, "the shipped frost look is preset 13 (Ice Lance)")
	# spawn a frost projectile by id: the dedicated lance launches, the ball pool stays idle
	v.spawn_projectile(Vector3.ZERO, Vector3(10, 0, 0), VfxManager.FROST_ABILITY_ID)
	assert_true(
		(v._frost_lance._lances[0]["root"] as Node3D).visible, "frost id launches the lance"
	)
	assert_false(v._proj[0]["orb"].visible, "the generic ball did NOT fire for the frost bolt")


# --- T-351: the Era-2 (Ashmoor) ability re-skin — region -> preset set, zero mechanics change ----


func test_gaslight_lance_preset_exists_and_preserves_the_feel() -> void:
	# preset 19 = "Gaslight Lance": the Era-2 re-costume of the SHIPPED Ice Lance (13). SAME
	# three-act lance mode, SAME speed + freeze duration (feel bar §11.5), only the palette + a
	# denser sooty vapor change. A regression here (slower/floatier/limper) is a ship-blocker.
	var g := VfxPresets.resolve(19)
	var ice := VfxPresets.resolve(13)
	assert_eq(str(g["name"]), "Gaslight Lance", "preset 19 is the era-2 frost look")
	assert_eq(str(g["mode"]), "lance", "still the Sub-Zero three-act lance, not a billboard")
	assert_almost_eq(
		float(g["flight"]["speed"]),
		float(ice["flight"]["speed"]),
		0.0001,
		"delivery speed UNCHANGED vs era-1 (feel bar: delivery punch)"
	)
	assert_almost_eq(
		float(g["burst"]["freeze_dur"]),
		float(ice["burst"]["freeze_dur"]),
		0.0001,
		"target consequence (freeze) UNCHANGED vs era-1"
	)
	# the costume DID change: a distinct gaslight-azure edge vs the era-1 blue.
	assert_ne(
		Color(g["lance"]["edge_color"]), Color(ice["lance"]["edge_color"]), "re-costumed edge"
	)


func test_era_frost_preset_mapping() -> void:
	assert_eq(VfxManager.ERA_FROST_PRESET[0], 13, "era 1 keeps the shipped Ice Lance")
	assert_eq(VfxManager.ERA_FROST_PRESET[1], 19, "Ashmoor resolves to the Gaslight Lance")


func test_set_era_reskins_frost_lance_with_zero_mechanics_change() -> void:
	var v = VfxManager.new()
	add_child_autofree(v)  # default era 0 -> frost lance built from preset 13
	assert_eq(v._era, 0, "boots in era 1")
	var era1_speed: float = float(VfxPresets.resolve(13)["flight"]["speed"])
	v.set_era(1)  # Ashmoor
	assert_eq(v._era, 1, "era flipped to Ashmoor")
	assert_not_null(v._frost_lance, "the ability frost lance is rebuilt for the era")
	# MECHANICS INVARIANT: the era-2 lance flies at the same speed as era-1 (§11.1 — costume only).
	var era2_speed: float = float(VfxPresets.resolve(19)["flight"]["speed"])
	assert_almost_eq(era2_speed, era1_speed, 0.0001, "era re-skin changes NO mechanics (speed)")
	v.set_era(0)  # return to era 1
	assert_eq(v._era, 0, "era returns")
	v.set_era(0)  # idempotent no-op
	assert_eq(v._era, 0, "same-era set_era is a no-op")


func test_set_era_reskins_the_priest_heal_tint() -> void:
	var v = VfxManager.new()
	add_child_autofree(v)
	var era1_heal: Array = VfxManager.ERA_HEAL[0]["color"]
	var era2_heal: Array = VfxManager.ERA_HEAL[1]["color"]
	# era-1 holy green vs era-2 spiritualist-warm are genuinely different tints
	assert_ne(
		Color(era1_heal[0], era1_heal[1], era1_heal[2]),
		Color(era2_heal[0], era2_heal[1], era2_heal[2]),
		"the heal re-skins per era"
	)
	assert_true(v._heal.size() == 4, "heal pool built at boot")
	v.set_era(1)
	assert_eq(v._heal.size(), 4, "heal pool rebuilt (not leaked) on the era flip")


func test_flash_freeze_overlays_then_clears() -> void:
	var v = VfxManager.new()
	add_child_autofree(v)
	v.apply_preset(13)
	var victim := Node3D.new()
	var mi := MeshInstance3D.new()
	mi.mesh = BoxMesh.new()  # primitive: has tangents -> eligible for the overlay
	victim.add_child(mi)
	add_child_autofree(victim)
	v.spawn_impact_on(Vector3.ZERO, victim)
	assert_not_null(mi.material_overlay, "victim flash-freezes via material_overlay")
	# T-343 r3: the freeze eases out over a ~0.15s snap + maxf(freeze_dur, 1.5)s fade (up from a
	# flat freeze_dur pop), so the overlay clears later than the raw preset freeze_dur.
	var dur: float = maxf(float(VfxPresets.resolve(13)["burst"]["freeze_dur"]), 1.5)
	await wait_seconds(0.15 + dur + 0.3)
	assert_null(mi.material_overlay, "freeze overlay removed after the eased freeze")


# T-351: EraSkin.update (extracted from main.gd) resolves the era from a ground position and drives
# BOTH re-skin surfaces — the VfxManager frost lance and the EntityVisuals held-focus default.
func test_era_skin_update_resolves_district_and_flips_both_surfaces() -> void:
	var entity_visuals = load("res://scripts/world/entity_visuals.gd")
	var era_skin = load("res://scripts/world/era_skin.gd")
	var v = VfxManager.new()
	add_child_autofree(v)
	var prev: int = entity_visuals.era
	era_skin.update(Vector3(-420, 0, -2), v, null)  # inside the Ashmoor district
	assert_eq(v._era, 1, "in-district position resolves to era 2")
	assert_eq(entity_visuals.era, 1, "held-focus surface flipped to era 2")
	era_skin.update(Vector3(0, 0, 0), v, null)  # the home world
	assert_eq(v._era, 0, "outside the district resolves to era 1")
	assert_eq(entity_visuals.era, 0, "held-focus surface returns to era 1")
	entity_visuals.era = prev
