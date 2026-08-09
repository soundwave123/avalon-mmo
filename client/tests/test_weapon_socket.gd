extends GutTest
# T-109: WeaponSocket — the shared hand-socket contract, proven against the REAL master
# rig (char_hero_warrior.glb, Quaternius UBC 65-bone skeleton) and the real starter
# weapon GLBs, not stub scenes.

const EV = preload("res://scripts/world/entity_visuals.gd")


func _hero_skeleton() -> Skeleton3D:
	var packed := load("res://assets/models/char_hero_warrior.glb") as PackedScene
	assert_not_null(packed, "master rig GLB loads")
	var model := packed.instantiate() as Node3D
	add_child_autofree(model)
	return model.find_child("Skeleton3D", true, false) as Skeleton3D


func test_socket_resolves_right_hand_bone_on_master_rig() -> void:
	var skel := _hero_skeleton()
	assert_not_null(skel, "rig carries a Skeleton3D")
	var sock := WeaponSocket.attach(skel, "weapon")
	assert_not_null(sock, "socket attaches")
	assert_eq(sock.bone_name, "hand_r", "bound to the UBC right hand")
	assert_true(skel.find_bone(sock.bone_name) >= 0, "bone exists on the real rig")
	assert_eq(sock.get_parent(), skel, "socket lives under the skeleton")
	assert_eq(str(sock.name), "GearSlot_weapon", "named for apply_gear's idempotent sweep")


func test_attach_rejects_missing_bone_or_skeleton() -> void:
	var skel := _hero_skeleton()
	var before := skel.get_child_count()
	assert_null(WeaponSocket.attach(skel, "weapon", "hand_nope"), "bogus bone -> null")
	assert_eq(skel.get_child_count(), before, "no orphan node added on failure")
	assert_null(WeaponSocket.attach(null, "weapon"), "null skeleton -> null")


func test_every_starter_weapon_glb_loads_and_is_grip_scaled() -> void:
	# One shared contract: each family GLB exists, instances, and spans a human-held size
	# (longest AABB axis 0.3m..1.7m — catches both a normalized-unit micro mesh and a
	# building-scale export).
	for family: String in EV.WEAPON_GLBS:
		var path: String = EV.WEAPON_GLBS[family]
		assert_true(ResourceLoader.exists(path), "%s exists" % path)
		var packed := load(path) as PackedScene
		assert_not_null(packed, "%s loads" % path)
		var w := packed.instantiate() as Node3D
		assert_not_null(w, "%s instances" % path)
		add_child_autofree(w)
		var mesh := w.find_child("*", true, false)
		assert_not_null(mesh, "%s has content" % family)
		var aabb := AABB()
		for mi: MeshInstance3D in w.find_children("*", "MeshInstance3D", true, false):
			aabb = aabb.merge(mi.get_aabb())
		var longest: float = aabb.size[aabb.get_longest_axis_index()]
		assert_between(longest, 0.3, 1.7, "%s human-grip scale (got %.2f m)" % [family, longest])


func test_weapon_parents_under_socket_without_scale_distortion() -> void:
	var skel := _hero_skeleton()
	var sock := WeaponSocket.attach(skel, "weapon")
	var packed := load(EV.WEAPON_GLBS["sword"]) as PackedScene
	var weapon := packed.instantiate() as Node3D
	sock.equip(weapon)
	assert_eq(weapon.get_parent(), sock, "weapon parents under the socket")
	assert_eq(weapon.transform, Transform3D.IDENTITY, "identity local transform (contract)")
	await wait_frames(2)
	var s := weapon.global_transform.basis.get_scale()
	for axis in 3:
		assert_almost_eq(s[axis], 1.0, 0.05, "no scale distortion through the bone chain")


func test_equip_swaps_mesh_not_rig() -> void:
	var skel := _hero_skeleton()
	var sock := WeaponSocket.attach(skel, "weapon")
	var sword := (load(EV.WEAPON_GLBS["sword"]) as PackedScene).instantiate() as Node3D
	var axe := (load(EV.WEAPON_GLBS["axe"]) as PackedScene).instantiate() as Node3D
	sock.equip(sword)
	sock.equip(axe)
	var live := 0
	for child in sock.get_children():
		if not child.is_queued_for_deletion():
			live += 1
	assert_eq(live, 1, "exactly one live weapon after a swap")
	assert_eq(axe.get_parent(), sock, "the new weapon is the live one")


func test_apply_gear_attaches_real_weapon_glb() -> void:
	var v := EV.make_visual("warrior")
	add_child_autofree(v)
	EV.apply_gear(v, {"weapon": "itm_iron_sword"})
	var skel := v.find_child("Skeleton3D", true, false) as Skeleton3D
	assert_not_null(skel, "hero visual has the rig")
	var sock := skel.find_child("GearSlot_weapon", false, false)
	assert_not_null(sock, "weapon socket created")
	assert_true(sock is WeaponSocket, "held slot goes through the WeaponSocket contract")
	var holder := sock.find_child("Gear_itm_iron_sword", false, false)
	assert_not_null(holder, "item holder attached")
	var meshes := holder.find_children("*", "MeshInstance3D", true, false)
	assert_gt(meshes.size(), 0, "real GLB mesh in hand (not an empty holder)")


func test_gun_mobs_spawn_armed_with_their_firearm() -> void:
	# T-350: the Gunsel/Torpedo carry a real firearm GLB in hand_r straight out of make_visual
	# (the GLB_MODELS "weapon" key routes through apply_gear), no gear broadcast needed.
	for kind: String in ["mob_syndicate_gunsel", "mob_syndicate_torpedo"]:
		var v := EV.make_visual(kind)
		add_child_autofree(v)
		var skel := v.find_child("Skeleton3D", true, false) as Skeleton3D
		assert_not_null(skel, "%s rides the hero rig" % kind)
		var sock := skel.find_child("GearSlot_weapon", false, false)
		assert_not_null(sock, "%s spawns with a weapon socket" % kind)
		if sock == null:
			continue
		var meshes := sock.find_children("*", "MeshInstance3D", true, false)
		assert_gt(meshes.size(), 0, "%s holds a real firearm mesh" % kind)


func test_empty_hand_shows_class_default_weapon() -> void:
	# T-109: the server doesn't grant starter weapons yet (T-319), so an empty gear dict
	# shows the class default — mage/staff here — replaced when real gear arrives.
	var v := EV.make_visual("mage")
	add_child_autofree(v)
	var skel := v.find_child("Skeleton3D", true, false) as Skeleton3D
	assert_not_null(skel)
	var sock := skel.find_child("GearSlot_weapon", false, false)
	assert_not_null(sock, "armed at spawn before any gear broadcast")
	assert_not_null(
		sock.find_child("Gear_default_staff", false, false), "mage default is the staff"
	)
	EV.apply_gear(v, {"weapon": "itm_iron_sword"})
	var socks := []
	for child in skel.get_children():
		if str(child.name).begins_with("GearSlot_") and not child.is_queued_for_deletion():
			socks.append(child)
	assert_eq(socks.size(), 1, "real gear replaces the default, no double-attach")
	assert_not_null(
		socks[0].find_child("Gear_itm_iron_sword", false, false),
		"the broadcast weapon wins over the class default"
	)
