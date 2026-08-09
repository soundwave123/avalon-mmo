extends GutTest
# T-535: the stored gender drives a distinct hero BODY mesh. The female player-class GLBs ride the
# identical 65-bone UBC rig + baked clip set as the male siblings (so gear/clips/tints retarget with
# no re-bake), and make_visual selects them by gender for both the local and remote player paths.

const EV = preload("res://scripts/world/entity_visuals.gd")


# The three playable classes each ship a female sibling GLB (char_hero_<class>_female.glb).
func test_female_hero_meshes_are_registered_and_load() -> void:
	for cls in ["warrior", "mage", "priest"]:
		var path := "res://assets/models/char_hero_%s_female.glb" % cls
		assert_true(ResourceLoader.exists(path), "female %s GLB present: %s" % [cls, path])
		assert_not_null(load(path) as PackedScene, "female %s GLB loads as a scene" % cls)


# The selection helper: "female" swaps for the _female sibling when it exists; anything else — a
# male/empty gender OR a path with no female sibling — keeps the original mesh. Pure + deterministic.
func test_gendered_path_selects_female_sibling_only_for_female() -> void:
	var male := "res://assets/models/char_hero_warrior.glb"
	var female := "res://assets/models/char_hero_warrior_female.glb"
	assert_eq(EV._gendered_path(male, "female"), female, "female gender picks the sibling")
	assert_eq(EV._gendered_path(male, "male"), male, "male gender keeps the default mesh")
	assert_eq(EV._gendered_path(male, ""), male, "empty gender keeps the default mesh")
	# A kind with no female sibling on disk (a mob rig) falls back to the given path, never a 404.
	var mob := "res://assets/models/mob_wolf.glb"
	assert_eq(EV._gendered_path(mob, "female"), mob, "no female sibling -> keep the original")


# make_visual with gender "female" builds the female body: a real rig (Skeleton3D) with an
# AnimationPlayer, and the rig matches the male sibling's bone count (identical 65-joint UBC rig).
func test_female_gender_builds_a_distinct_rigged_body() -> void:
	var female := EV.make_visual("warrior", 1.0, "female")
	add_child_autofree(female)
	var fskel := female.find_child("Skeleton3D", true, false) as Skeleton3D
	assert_not_null(fskel, "female warrior carries a skeleton rig")
	var fap := female.find_child("AnimationPlayer", true, false) as AnimationPlayer
	assert_not_null(fap, "female warrior carries an AnimationPlayer")
	var male := EV.make_visual("warrior", 1.0, "")
	add_child_autofree(male)
	var mskel := male.find_child("Skeleton3D", true, false) as Skeleton3D
	assert_eq(
		fskel.get_bone_count(), mskel.get_bone_count(), "female rig matches the male bone count"
	)


# Clip parity: the female rig carries the SAME animation set as the male sibling (the T-535 splice
# gives byte-for-byte clip names). Both go through the same Godot import (_Loop stripping), so the
# in-engine name sets are directly comparable.
func test_female_hero_clip_set_matches_the_male_sibling() -> void:
	for cls in ["warrior", "mage", "priest"]:
		var female := EV.make_visual(cls, 1.0, "female")
		add_child_autofree(female)
		var male := EV.make_visual(cls, 1.0, "")
		add_child_autofree(male)
		var fap := female.find_child("AnimationPlayer", true, false) as AnimationPlayer
		var map := male.find_child("AnimationPlayer", true, false) as AnimationPlayer
		assert_not_null(fap, "female %s has an AnimationPlayer" % cls)
		assert_not_null(map, "male %s has an AnimationPlayer" % cls)
		var fclips := fap.get_animation_list()
		fclips.sort()
		var mclips := map.get_animation_list()
		mclips.sort()
		assert_eq(fclips, mclips, "female %s clip set matches the male sibling" % cls)
		# Every gameplay state must still resolve on the female rig (gate a silent clip gap).
		for state in ["idle", "walk", "run", "attack", "cast", "hit", "death"]:
			assert_true(EV.has_state_clip(female, state), "female %s resolves '%s'" % [cls, state])


# gate-7 gear-fit: the T-224 plate paperdoll pieces bone-attach + seat on the FEMALE warrior rig
# exactly as on the male (same bone names -> same GEAR_BONES / ARMOR_FIT path), no floating/absent.
func test_plate_gear_seats_on_the_female_warrior_rig() -> void:
	var warrior := EV.make_visual("warrior", 1.0, "female")
	add_child_autofree(warrior)
	(
		EV
		. apply_gear(
			warrior,
			{
				"head": "itm_warrior_plate_helm|plate",
				"chest": "itm_warrior_plate_cuirass|plate",
				"legs": "itm_warrior_plate_greaves|plate",
			}
		)
	)
	var skel := warrior.find_child("Skeleton3D", true, false) as Skeleton3D
	assert_not_null(skel, "female warrior rig has a skeleton")
	for item in [
		"itm_warrior_plate_helm", "itm_warrior_plate_cuirass", "itm_warrior_plate_greaves"
	]:
		var gear := skel.find_child("Gear_%s" % item, true, false)
		assert_not_null(gear, "%s bone-attached to the female rig" % item)
		assert_gt(gear.get_child_count(), 0, "%s holds a loaded plate mesh" % item)
