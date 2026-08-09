extends "res://addons/gut/test.gd"

# T-444 — the training-yard set piece centred on loc_training_ring (14,10): the tutorial's first
# objective ("walk to the training ring") must land on a real, bounded place, and no yard prop may
# block Drillmaster Hale, the practice dummy, the sparring effigy, or the open gate.
const T444_RING := Vector2(14.0, 10.0)
# entities that must never be blocked. Hale (npc_drillmaster) + the dummy (mob_dummy) share 10,10;
# the effigy (mob_training_effigy) is at 16,10; the arcane/cleric trainers at 14,7 / 16,7. Mirrors
# server/world/data/npcs/npcs.json + server/world/data/mobs/*.json.
const T444_ENTITIES := [
	Vector2(10.0, 10.0), Vector2(16.0, 10.0), Vector2(14.0, 7.0), Vector2(16.0, 7.0)
]
# the gate is left open toward -Z (the town approach), ~one apothem south of centre.
const T444_GATE := Vector2(14.0, 5.9)
# furniture that must not interpenetrate a capsule or each other. The floor + rail are co-centred
# structural pieces layered at 14,10 by design, so they are excluded from the pairwise check.
const T444_FURNITURE := [
	"prop_training_rack",
	"prop_training_butt",
	"prop_training_pell",
	"prop_training_shield",
	"prop_trough",
	"prop_mounting_block"
]


func _load_props() -> Array:
	var raw: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://assets/props.json"))
	return raw["props"] if raw is Dictionary and raw.has("props") else raw


func _t444_props() -> Array:
	var out := []
	for p in _load_props():
		if p is Dictionary and String(p.get("tag", "")) == "t444" and p.has("scene"):
			out.append(p)
	return out


func _mesh_aabb(node: Node, xf: Transform3D) -> AABB:
	var out := AABB()
	var have := false
	if node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
		var local := (node as MeshInstance3D).mesh.get_aabb()
		for i in range(8):
			var w: Vector3 = xf * local.get_endpoint(i)
			if not have:
				out = AABB(w, Vector3.ZERO)
				have = true
			else:
				out = out.expand(w)
	for ch in node.get_children():
		var ct: Transform3D = xf * (ch.transform if ch is Node3D else Transform3D.IDENTITY)
		var sub := _mesh_aabb(ch, ct)
		if sub.size != Vector3.ZERO or sub.position != Vector3.ZERO:
			out = out.merge(sub) if have else sub
			have = true
	return out


func _glb_aabb(basename: String) -> AABB:
	var inst: Node3D = (load("res://assets/models/%s.glb" % basename) as PackedScene).instantiate()
	autofree(inst)
	return _mesh_aabb(inst, inst.transform)


func test_ring_and_sand_floor_sit_on_the_tutorial_ring() -> void:
	var have_ring := false
	var have_floor := false
	for p in _t444_props():
		var scene := String(p.get("scene", ""))
		var pos := Vector2(float(p.get("x", 0.0)), float(p.get("y", 0.0)))
		if scene.ends_with("prop_training_ring.glb"):
			have_ring = true
			assert_lt(pos.distance_to(T444_RING), 0.2, "ring rail centred on loc_training_ring")
		if scene.ends_with("prop_training_floor.glb"):
			have_floor = true
			assert_lt(pos.distance_to(T444_RING), 0.2, "sand floor centred on loc_training_ring")
			assert_false(bool(p.get("solid", false)), "sand floor is walkable (non-solid)")
	assert_true(have_ring, "T-444 placed the practice-ring rail")
	assert_true(have_floor, "T-444 placed the distinct sand floor")


func test_yard_has_a_rack_at_least_two_butts_and_a_pell() -> void:
	var counts := {}
	for p in _t444_props():
		var base := String(p.get("scene", "")).get_file().replace(".glb", "")
		counts[base] = int(counts.get(base, 0)) + 1
	assert_gte(int(counts.get("prop_training_rack", 0)), 1, "a weapon rack is placed")
	assert_gte(int(counts.get("prop_training_butt", 0)), 2, "at least two straw butts are placed")
	assert_gte(int(counts.get("prop_training_pell", 0)), 1, "at least one pell/strawman is placed")
	assert_gte(int(counts.get("prop_trough", 0)), 1, "a water trough is placed")


func test_no_yard_prop_blocks_hale_dummy_effigy_or_the_gate() -> void:
	for p in _t444_props():
		var scene := String(p.get("scene", ""))
		# the co-centred rail + floor legitimately sit over the ring centre; skip them here.
		if scene.ends_with("prop_training_ring.glb") or scene.ends_with("prop_training_floor.glb"):
			continue
		var pos := Vector2(float(p.get("x", 0.0)), float(p.get("y", 0.0)))
		for e in T444_ENTITIES:
			assert_gt(
				pos.distance_to(e),
				0.8,
				"%s at %s clears the entity capsule at %s" % [scene.get_file(), pos, e]
			)
		assert_gt(
			pos.distance_to(T444_GATE), 1.0, "%s clears the open gate mouth" % scene.get_file()
		)


func test_yard_furniture_does_not_interpenetrate() -> void:
	var furniture := []
	for p in _t444_props():
		var base := String(p.get("scene", "")).get_file().replace(".glb", "")
		if base in T444_FURNITURE:
			furniture.append(Vector2(float(p.get("x", 0.0)), float(p.get("y", 0.0))))
	assert_gt(furniture.size(), 4, "the yard is actually furnished")
	for i in range(furniture.size()):
		for j in range(i + 1, furniture.size()):
			assert_gt(
				furniture[i].distance_to(furniture[j]),
				0.8,
				"yard props at %s and %s keep a capsule apart" % [furniture[i], furniture[j]]
			)


func test_every_yard_prop_carries_an_explicit_terrain_grade() -> void:
	# world-audit's float/sink check keys off terrain_y; a bare-grade prop on this sloped meadow
	# floats, so every t444 placement must pin its terrain-oracle grade.
	for p in _t444_props():
		assert_true(
			p.has("terrain_y"), "%s carries an explicit terrain grade" % String(p.get("scene", ""))
		)


func test_ring_glb_is_centred_grounded_and_ring_sized() -> void:
	var aabb := _glb_aabb("prop_training_ring")
	assert_almost_eq(aabb.position.y, 0.0, 0.02, "ring rail is grounded at y=0")
	assert_almost_eq(aabb.position.x + aabb.size.x / 2.0, 0.0, 0.05, "ring is X-centred")
	assert_almost_eq(aabb.position.z + aabb.size.z / 2.0, 0.0, 0.05, "ring is Z-centred")
	assert_between(aabb.size.x, 8.0, 10.0, "ring reads ~8-10 m across (X)")
	assert_between(aabb.size.z, 8.0, 10.0, "ring reads ~8-10 m across (Z)")


func test_furniture_glbs_are_grounded_centred_and_in_budget() -> void:
	for base in [
		"prop_training_floor",
		"prop_training_rack",
		"prop_training_butt",
		"prop_training_pell",
		"prop_training_shield"
	]:
		var aabb := _glb_aabb(base)
		assert_almost_eq(aabb.position.y, 0.0, 0.02, "%s is grounded at y=0" % base)
		assert_almost_eq(aabb.position.x + aabb.size.x / 2.0, 0.0, 0.06, "%s is X-centred" % base)
		assert_almost_eq(aabb.position.z + aabb.size.z / 2.0, 0.0, 0.06, "%s is Z-centred" % base)
		# nothing in the yard kit is larger than the ring itself — a sane footprint budget.
		assert_lt(maxf(aabb.size.x, aabb.size.z), 9.0, "%s stays within a sane footprint" % base)


# T-551: the straw sparring effigy mesh (mob_training_effigy / mob_dummy render). Grounded,
# X/Z-centred (so it seats on the mob spawn without floating or leaning off-anchor) and roughly
# human-scaled — the cruciform strawman silhouette, not a bare post or a red cube.
func test_effigy_glb_is_grounded_centred_and_human_scaled() -> void:
	var aabb := _glb_aabb("prop_training_effigy")
	assert_almost_eq(aabb.position.y, 0.0, 0.02, "effigy is grounded at y=0")
	assert_almost_eq(aabb.position.x + aabb.size.x / 2.0, 0.0, 0.06, "effigy is X-centred")
	assert_almost_eq(aabb.position.z + aabb.size.z / 2.0, 0.0, 0.06, "effigy is Z-centred")
	assert_between(aabb.size.y, 1.7, 2.1, "effigy reads roughly human height")
	# a cruciform strawman spreads its crossbar arms wider than it is deep, but stays compact.
	assert_between(aabb.size.x, 0.8, 1.6, "effigy has an arms-out cruciform width")
	assert_lt(aabb.size.z, 1.0, "effigy keeps a shallow front-to-back footprint")
