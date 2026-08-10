extends GutTest
# T-076: procedural entity visuals — every kind yields a distinct, non-empty composition.

const EV = preload("res://scripts/world/entity_visuals.gd")


func test_every_known_kind_builds_a_visual() -> void:
	# GLB-backed kinds (T-130+) load a one-child model wrapper when the GLB is present, falling back
	# to the procedural composition otherwise, so they are checked for non-emptiness rather than a
	# brittle exact count. T-551: mob_dummy + mob_training_effigy joined the GLB set (strawman mesh).
	var glb_kinds := [
		"mob_wolf",
		"mob_kobold_miner",
		"mob_bloodthorn_lasher",
		"mob_dummy",
		"mob_training_effigy",
		"warrior",
		"mage",
		"priest",
		"player",
	]
	for glb_kind: String in glb_kinds:
		var v := EV.make_visual(glb_kind)
		assert_not_null(v, glb_kind)
		assert_gt(v.get_child_count(), 0, "%s non-empty (GLB or fallback)" % glb_kind)
		v.free()


func test_unknown_kind_falls_back_to_generic_mob() -> void:
	var v := EV.make_visual("mob_never_heard_of_it")
	assert_eq(v.get_child_count(), 1, "generic box")
	v.free()


# T-551: the tutorial's straw sparring effigy (mob_training_effigy) used to have NO GLB mapping and
# fell through make_visual's match to the `_` generic-box branch — the flat saturated-red CUBE the
# realism-auditor flagged as the loudest onboarding immersion break. The practice dummy (mob_dummy)
# rendered the bare-post procedural. Both must now register + load the lashed-strawman GLB. The
# generic-box fallback attaches a MeshInstance3D child directly, while a loaded GLB attaches its
# instantiated scene root (a plain Node3D) — so a non-MeshInstance first child proves the GLB won.
func test_training_effigy_and_dummy_render_the_strawman_glb() -> void:
	for kind in ["mob_training_effigy", "mob_dummy"]:
		assert_true(EV.GLB_MODELS.has(kind), "%s is registered in GLB_MODELS" % kind)
		var path := str((EV.GLB_MODELS[kind] as Dictionary).get("path", ""))
		assert_eq(
			path,
			"res://assets/models/prop_training_effigy.glb",
			"%s points at the strawman GLB" % kind
		)
		assert_true(ResourceLoader.exists(path), "%s GLB present on disk" % kind)
		var v := EV.make_visual(kind)
		assert_eq(v.get_child_count(), 1, "%s builds a single GLB wrapper child" % kind)
		assert_false(
			v.get_child(0) is MeshInstance3D,
			"%s renders the GLB scene, not the red-cube fallback primitive" % kind
		)
		v.free()


func test_class_colors_are_distinct() -> void:
	var seen := {}
	for cls in ["warrior", "mage", "priest"]:
		var c: Color = EV.CLASS_COLORS[cls]
		assert_false(seen.has(c.to_html()), "class colors must differ")
		seen[c.to_html()] = true


# T-118: the eight canonical animation states each map to a non-empty clip-name preference
# list, and the UAL clip names baked onto the hero rigs appear as candidates so play_state
# can resolve them. Pure map assertions — no AnimationPlayer runtime needed.
func test_state_clip_map_covers_eight_states() -> void:
	for state in ["idle", "walk", "run", "jump", "attack", "cast", "hit", "death"]:
		assert_true(EV.STATE_CLIPS.has(state), "state %s mapped" % state)
		assert_gt((EV.STATE_CLIPS[state] as Array).size(), 0, "%s has candidates" % state)
	# The clips T-118 baked onto every UBC/UAL hero must be reachable by state.
	var baked := {
		"walk": "Walk_Loop",
		"run": "Jog_Fwd_Loop",
		"jump": "Jump_Loop",
		"attack": "Sword_Attack",
		"cast": "Spell_Simple_Shoot",
		"hit": "Hit_Chest",
		"idle": "Idle_Loop",
		"death": "Death01",
	}
	for state: String in baked:
		assert_true(baked[state] in EV.STATE_CLIPS[state], "%s resolves %s" % [state, baked[state]])


# Looping locomotion loops; one-shot combat/jump/death clips do not (they hold the last pose).
func test_looping_states_are_locomotion_only() -> void:
	for s in ["idle", "walk", "run"]:
		assert_true(s in EV.LOOPING_STATES, "%s loops" % s)
	for s in ["attack", "cast", "hit", "jump", "death"]:
		assert_false(s in EV.LOOPING_STATES, "%s is a one-shot" % s)


# T-307: has_state_clip reports whether a rig actually carries a clip for a state — the hook that
# routes heroes to their baked clip and clipless creatures to the procedural CombatMotion stand-in.
# The hero GLB (char_hero_warrior via "player") has the full eight; mob_wolf carries only idle/walk.
func test_has_state_clip_distinguishes_hero_from_clipless_creature() -> void:
	var hero := EV.make_visual("player")
	add_child_autofree(hero)
	assert_true(EV.has_state_clip(hero, "attack"), "the baked hero rig has an attack clip")
	assert_true(EV.has_state_clip(hero, "death"), "and a death clip")
	var wolf := EV.make_visual("mob_wolf")
	add_child_autofree(wolf)
	assert_true(EV.has_state_clip(wolf, "idle"), "the wolf rig has idle")
	assert_false(EV.has_state_clip(wolf, "attack"), "but NO attack clip → procedural stand-in")
	assert_false(EV.has_state_clip(wolf, "death"), "and NO death clip → procedural topple")


func test_has_state_clip_false_without_an_animation_player() -> void:
	var box := EV.make_visual("mob_never_heard_of_it")  # generic box, no AnimationPlayer
	add_child_autofree(box)
	assert_false(EV.has_state_clip(box, "idle"), "no AnimationPlayer → no clip for any state")


# T-351: the Era-2 (Ashmoor) caster FOCUS items socket via the SAME family map + WeaponSocket
# contract as the starter weapons — the sigil cane / reliquary GLBs load onto the mage/priest rig.
# T-224: the warrior plate set (helm/cuirass/leg-harness/pauldrons, TRELLIS-2) is registered
# and every piece loads as a scene.
func test_plate_armor_glbs_are_registered_and_load() -> void:
	assert_true(EV.ARMOR_GLBS.has("plate"), "plate family registered")
	var plate: Dictionary = EV.ARMOR_GLBS["plate"]
	for slot in ["head", "chest", "legs", "shoulders"]:
		assert_true(plate.has(slot), "plate has %s piece" % slot)
		var path: String = plate[slot]
		assert_true(ResourceLoader.exists(path), "%s GLB present: %s" % [slot, path])
		assert_not_null(load(path) as PackedScene, "%s GLB loads as a scene" % slot)


# T-224: equipping a plate item bone-attaches the matching piece to the rig (the T-225
# paperdoll seam) — head/chest/legs ride the server's real EQUIP_SLOTS.
func test_plate_gear_attaches_to_rig_bones() -> void:
	var warrior := EV.make_visual("warrior")
	add_child_autofree(warrior)
	(
		EV
		. apply_gear(
			warrior,
			{
				"head": "itm_warrior_plate_helm",
				"chest": "itm_warrior_plate_cuirass",
				"legs": "itm_warrior_plate_greaves",
			}
		)
	)
	var skel := warrior.find_child("Skeleton3D", true, false) as Skeleton3D
	assert_not_null(skel, "warrior rig has a skeleton")
	for item in [
		"itm_warrior_plate_helm", "itm_warrior_plate_cuirass", "itm_warrior_plate_greaves"
	]:
		var gear := skel.find_child("Gear_%s" % item, true, false)
		assert_not_null(gear, "%s bone-attached" % item)
		assert_gt(gear.get_child_count(), 0, "%s holds a loaded plate mesh" % item)


# T-224: a non-plate item does NOT show the plate mesh (family gating — cloth/chain keep
# their own look; only "plate"-family ids light the set).
func test_non_plate_chest_item_does_not_render_plate() -> void:
	assert_eq(EV._armor_family("itm_gravewarden_hauberk"), "", "hauberk is not plate family")
	assert_eq(EV._armor_family("itm_warrior_plate_cuirass"), "plate", "plate id reads as plate")


# T-420: family gating routes by the SERVER-authored armor_type, not an id substring. A plate item
# whose id has no "plate" substring (itm_maldrath_hollow_crown) still lights the set; a cloth/mail/
# leather item never does (their sets don't exist yet), so casters keep their own look.
func test_armor_family_routes_by_armor_type_not_id_substring() -> void:
	assert_eq(EV._armor_family("itm_maldrath_hollow_crown", "plate"), "plate", "armor_type wins")
	assert_eq(EV._armor_family("itm_ironward_cuirass", "plate"), "plate", "new plate set routes")
	assert_eq(EV._armor_family("itm_bonepriest_wraps", "cloth"), "", "cloth keeps its own look")
	assert_eq(EV._armor_family("itm_unhallowed_guard", "mail"), "", "mail keeps its own look")
	assert_eq(EV._armor_family("itm_rift_worn_coat", "leather"), "", "leather keeps its own look")


# T-420: apply_gear splits the server visual token "<id>|<armor_type>", so a plate item with no
# "plate" substring in its id renders the plate set once its armor_type says so — the end-to-end
# routing fix (an armor_type-carried token, not the id).
func test_apply_gear_renders_plate_from_armor_type_token() -> void:
	var warrior := EV.make_visual("warrior")
	add_child_autofree(warrior)
	# itm_maldrath_hollow_crown has NO "plate" substring; the server token carries armor_type=plate.
	EV.apply_gear(warrior, {"head": "itm_maldrath_hollow_crown|plate"})
	var skel := warrior.find_child("Skeleton3D", true, false) as Skeleton3D
	assert_not_null(skel, "warrior rig has a skeleton")
	var gear := skel.find_child("Gear_itm_maldrath_hollow_crown", true, false)
	assert_not_null(gear, "the crown bone-attached (holder named by the split id, not the token)")
	assert_gt(gear.get_child_count(), 0, "it holds a loaded plate helm mesh")


# T-428: the fourth token field is an authored mask and the third is a validated dye color. The
# dye is applied to duplicated per-instance materials on the attached gear, never the shared GLB.
func test_apply_gear_dyes_attached_piece_from_server_token() -> void:
	var warrior := EV.make_visual("warrior")
	add_child_autofree(warrior)
	EV.apply_gear(warrior, {"head": "itm_ironward_helm|plate|#9f3142|all"})
	var gear := warrior.find_child("Gear_itm_ironward_helm", true, false) as Node3D
	assert_not_null(gear, "dyed display item attached")
	assert_eq(str(gear.get_meta("wardrobe_dye", "")), "#9f3142", "validated dye stamped")
	assert_eq(str(gear.get_meta("wardrobe_dye_mask", "")), "all", "authored mask stamped")


func test_hidden_head_token_removes_previous_helm() -> void:
	var warrior := EV.make_visual("warrior")
	add_child_autofree(warrior)
	EV.apply_gear(warrior, {"head": "itm_ironward_helm|plate"})
	assert_not_null(warrior.find_child("GearSlot_head", true, false), "control helm attached")
	EV.apply_gear(warrior, {"head": ""})
	assert_null(
		warrior.find_child("GearSlot_head", true, false), "explicit hidden token removes helm"
	)


# T-420: a cloth chest token does NOT render the plate mesh — the cloth family has no GLB set, so
# the holder loads nothing (family gating survives the armor_type routing).
func test_apply_gear_cloth_token_does_not_render_plate() -> void:
	var warrior := EV.make_visual("warrior")
	add_child_autofree(warrior)
	EV.apply_gear(warrior, {"chest": "itm_bonepriest_wraps|cloth"})
	var skel := warrior.find_child("Skeleton3D", true, false) as Skeleton3D
	assert_not_null(skel, "warrior rig has a skeleton")
	var gear := skel.find_child("Gear_itm_bonepriest_wraps", true, false)
	assert_not_null(gear, "the chest holder attaches (empty — no cloth GLB set)")
	assert_eq(gear.get_child_count(), 0, "no plate mesh loaded for a cloth item")


# T-224 (mage + priest sets): the cloth-caster armor families (robe/vestment) are registered with a
# head/chest/legs GLB each, and every piece loads as a scene (mirrors the plate registration test).
func test_caster_armor_glbs_are_registered_and_load() -> void:
	for fam in ["robe", "vestment"]:
		assert_true(EV.ARMOR_GLBS.has(fam), "%s family registered" % fam)
		var glbs: Dictionary = EV.ARMOR_GLBS[fam]
		for slot in ["head", "chest", "legs"]:
			assert_true(glbs.has(slot), "%s has %s piece" % [fam, slot])
			var path: String = glbs[slot]
			assert_true(ResourceLoader.exists(path), "%s GLB present: %s" % [slot, path])
			assert_not_null(load(path) as PackedScene, "%s %s GLB loads" % [fam, slot])
	# cloth casters carry no pauldrons — the sets deliberately omit the shoulders slot.
	assert_false((EV.ARMOR_GLBS["robe"] as Dictionary).has("shoulders"), "robe has no shoulders")
	assert_false(
		(EV.ARMOR_GLBS["vestment"] as Dictionary).has("shoulders"), "vestment has no shoulders"
	)


# T-224 (mage + priest sets): family gating routes the new caster armor_types to their own set while
# the generic "cloth" family (dungeon caster drops) keeps its own look; plate still routes to plate.
func test_caster_armor_family_routes_by_armor_type() -> void:
	assert_eq(EV._armor_family("itm_arcanist_robe", "robe"), "robe", "robe armor_type routes")
	assert_eq(
		EV._armor_family("itm_sanctified_vestment", "vestment"), "vestment", "vestment routes"
	)
	assert_eq(EV._armor_family("itm_ironward_cuirass", "plate"), "plate", "plate still routes")
	assert_eq(EV._armor_family("itm_bonepriest_wraps", "cloth"), "", "cloth keeps its own look")


# T-224 (mage + priest sets): apply_gear splits the "<id>|<armor_type>" token and renders the robe /
# vestment set onto the rig; a cloth token still renders nothing (family gating survives).
func test_apply_gear_renders_caster_sets_from_armor_type_token() -> void:
	var mage := EV.make_visual("mage")
	add_child_autofree(mage)
	EV.apply_gear(mage, {"chest": "itm_arcanist_robe|robe", "head": "itm_arcanist_cowl|robe"})
	var mskel := mage.find_child("Skeleton3D", true, false) as Skeleton3D
	assert_not_null(mskel, "mage rig has a skeleton")
	for item in ["itm_arcanist_robe", "itm_arcanist_cowl"]:
		var gear := mskel.find_child("Gear_%s" % item, true, false)
		assert_not_null(gear, "%s bone-attached" % item)
		assert_gt(gear.get_child_count(), 0, "%s holds a loaded robe mesh" % item)
	var priest := EV.make_visual("priest")
	add_child_autofree(priest)
	EV.apply_gear(priest, {"legs": "itm_sanctified_skirts|vestment"})
	var pskel := priest.find_child("Skeleton3D", true, false) as Skeleton3D
	var vgear := pskel.find_child("Gear_itm_sanctified_skirts", true, false)
	assert_not_null(vgear, "vestment legs bone-attached")
	assert_gt(vgear.get_child_count(), 0, "it holds a loaded vestment mesh")
	# a plain cloth token still loads nothing — the generic family has no GLB set.
	EV.apply_gear(priest, {"chest": "itm_bonepriest_wraps|cloth"})
	var cgear := pskel.find_child("Gear_itm_bonepriest_wraps", true, false)
	assert_eq(cgear.get_child_count(), 0, "no mesh loaded for a plain cloth item")


func test_focus_item_glbs_are_registered_and_load() -> void:
	assert_true(EV.WEAPON_GLBS.has("cane"), "sigil-cane family registered")
	assert_true(EV.WEAPON_GLBS.has("reliquary"), "reliquary family registered")
	for fam in ["cane", "reliquary"]:
		var path: String = EV.WEAPON_GLBS[fam]
		assert_true(ResourceLoader.exists(path), "%s GLB present: %s" % [fam, path])
		assert_not_null(load(path) as PackedScene, "%s GLB loads as a scene" % fam)


# T-351: the era re-skin (§11.1). In Ashmoor (era 1) a bare mage/priest carries its FOCUS as the
# default held item; era 0 keeps the era-1 staff/mace. Presentation only — mechanics untouched.
func test_era_flag_reskins_caster_default_weapon() -> void:
	var prev: int = EV.era
	# era 0: the mage's bare default is the era-1 staff
	EV.era = 0
	var mage := EV.make_visual("mage")
	add_child_autofree(mage)
	EV.apply_gear(mage, {})
	var skel := mage.find_child("Skeleton3D", true, false) as Skeleton3D
	assert_not_null(skel, "mage rig has a skeleton")
	assert_not_null(
		skel.find_child("Gear_default_staff", true, false), "era-1 mage holds the staff"
	)
	# era 1 (Ashmoor): the same bare mage now holds the occult sigil cane
	EV.era = 1
	EV.apply_gear(mage, {})
	# the old socket is queue_freed (deferred): let the frame end so the era-1 staff is truly gone.
	await get_tree().process_frame
	await get_tree().process_frame
	assert_not_null(
		skel.find_child("Gear_itm_occult_sigil_cane", true, false),
		"era-2 mage holds the occult sigil cane"
	)
	assert_null(skel.find_child("Gear_default_staff", true, false), "the era-1 staff is gone")
	EV.era = prev


# T-697 fix 8: request_kinds() is a headless-safe no-op (a threaded GLB load corrupts the dummy
# renderer — see visual_preload.gd), and make_visual still resolves every registered kind through
# VisualPreload.load_scene regardless (headless: the plain-load fallback path).
func test_warmup_request_is_headless_safe_and_make_visual_still_builds() -> void:
	EV.VisualPreload.request_kinds(EV.GLB_MODELS)  # no-op under the dummy renderer; must not crash
	var wolf := EV.make_visual("mob_wolf")
	add_child_autofree(wolf)
	assert_gt(wolf.get_child_count(), 0, "the wolf still resolves to a model after the warm-up")
	var second := EV.make_visual("mob_wolf")  # repeat sighting keeps resolving (engine cache)
	add_child_autofree(second)
	assert_gt(second.get_child_count(), 0, "repeat sightings keep resolving")


# T-758: tinted materials are memo-cached on (source material, tint, hair). Before this, every
# entity's every surface got a fresh mat.duplicate(), so two identical NPCs shared no material and
# the renderer could not batch them. _apply_body_tints is private, so drive it through the public
# apply_appearance seam. A BoxMesh's single-surface material is what get_active_material returns.
func after_each() -> void:
	TintMaterialCache.clear()  # T-758: drop cached duplicates so RIDs don't leak to exit


func _rig_sharing_material(mat: StandardMaterial3D) -> Node3D:
	var root := Node3D.new()
	var mi := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.material = mat  # a material name that maps to no special slot resolves to "body"
	mi.mesh = mesh
	root.add_child(mi)
	return root


func _body_override(root: Node3D) -> BaseMaterial3D:
	var mi := root.get_child(0) as MeshInstance3D
	return mi.get_surface_override_material(0) as BaseMaterial3D


func test_same_tint_entities_share_one_cached_material() -> void:
	# One SHARED source material (as GLB sub-resources are shared across scene instances) tinted the
	# same way on two separate rigs must resolve to the SAME duplicate — that is what lets the
	# renderer batch identical NPCs again.
	var source := StandardMaterial3D.new()
	source.albedo_color = Color(0.8, 0.8, 0.8)
	var tint := {"body": Color(0.5, 0.4, 0.3)}
	var a: Node3D = autofree(_rig_sharing_material(source))
	var b: Node3D = autofree(_rig_sharing_material(source))
	EV.apply_appearance(a, tint)
	EV.apply_appearance(b, tint)
	var ma := _body_override(a)
	var mb := _body_override(b)
	assert_not_null(ma, "rig A got a tinted body material")
	assert_not_null(mb, "rig B got a tinted body material")
	assert_eq(
		ma.get_instance_id(), mb.get_instance_id(), "same source+tint share ONE cached material"
	)
	# Tint still applied correctly: source albedo * tint.
	assert_almost_eq(ma.albedo_color.r, 0.8 * 0.5, 0.001, "tint multiplies the source albedo (r)")
	assert_almost_eq(ma.albedo_color.g, 0.8 * 0.4, 0.001, "tint multiplies the source albedo (g)")


func test_different_tints_do_not_collide_on_one_material() -> void:
	# The cache key includes the EXACT tint, so two differently-tinted NPCs off the same source must
	# get DISTINCT materials (else one dye would recolor the other).
	var source := StandardMaterial3D.new()
	source.albedo_color = Color.WHITE
	var a: Node3D = autofree(_rig_sharing_material(source))
	var b: Node3D = autofree(_rig_sharing_material(source))
	EV.apply_appearance(a, {"body": Color(0.9, 0.2, 0.2)})
	EV.apply_appearance(b, {"body": Color(0.2, 0.2, 0.9)})
	var ma := _body_override(a)
	var mb := _body_override(b)
	assert_ne(
		ma.get_instance_id(), mb.get_instance_id(), "different tints -> different cached materials"
	)
	assert_gt(ma.albedo_color.r, ma.albedo_color.b, "red-tinted rig stays red")
	assert_gt(mb.albedo_color.b, mb.albedo_color.r, "blue-tinted rig stays blue")
